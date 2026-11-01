#!/usr/bin/env python3
"""Offline-only binary Transformer inference for real MagicGI source-probe geometry.

Input is a strict geometry job exported from the actual classified source chunk
and captured Placement.faces. It contains no label/domain/portal fields. Output
is one OLV code byte per logical source probe, with invalid slots set to UNSET.
The command never edits Godot resources; its result directory is atomically
published only after all geometry, model, and byte-count checks pass.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import math
import os
import shutil
import struct
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Sequence

import numpy as np

HERE = Path(__file__).resolve().parent
# HERE contains the standalone runtime inference and shared geometry.
# Inference outputs are intentionally constrained to each fresh job directory
# instead of being coupled to the installed addon location.
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


from dataclasses import dataclass
from typing import Iterable, Callable

# Frozen geometry and model primitives; no historical training imports.
tm_EPS = 1e-10

tm_Vec3 = tuple[float, float, float]

tm_Bounds = tuple[tm_Vec3, tm_Vec3]

class tm_GeometryError(ValueError):
    """Invalid source geometry, sidecar, or geometry audit input."""

def tm__xyz(value: Any, name: str) -> tm_Vec3:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise tm_GeometryError(f'{name} must contain three coordinates')
    result: list[float] = []
    for index, item in enumerate(value):
        if isinstance(item, bool) or not isinstance(item, (int, float)) or (not math.isfinite(float(item))):
            raise tm_GeometryError(f'{name}[{index}] must be finite')
        result.append(float(item))
    return (result[0], result[1], result[2])

def tm__bounds(value: Any, name: str) -> tm_Bounds:
    if not isinstance(value, dict):
        raise tm_GeometryError(f'{name} must be an object')
    low = tm__xyz(value.get('min'), f'{name}.min')
    high = tm__xyz(value.get('max'), f'{name}.max')
    if any((low[i] > high[i] for i in range(3))):
        raise tm_GeometryError(f'{name}.min must not exceed max')
    return (low, high)

def tm__sub(a: tm_Vec3, b: tm_Vec3) -> tm_Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

def tm__dot(a: tm_Vec3, b: tm_Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

def tm__cross(a: tm_Vec3, b: tm_Vec3) -> tm_Vec3:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

def tm__length(a: tm_Vec3) -> float:
    return math.sqrt(tm__dot(a, a))

def tm__union_bounds(bounds: Iterable[tm_Bounds]) -> tm_Bounds:
    entries = list(bounds)
    if not entries:
        raise tm_GeometryError('cannot compute bounds of an empty mesh')
    return (tuple((min((item[0][axis] for item in entries)) for axis in range(3))), tuple((max((item[1][axis] for item in entries)) for axis in range(3))))

def tm__triangle_bounds(vertices: Sequence[tm_Vec3]) -> tm_Bounds:
    return (tuple((min((point[axis] for point in vertices)) for axis in range(3))), tuple((max((point[axis] for point in vertices)) for axis in range(3))))

@dataclass(slots=True)
class tm__BvhNode:
    low: tm_Vec3
    high: tm_Vec3
    indices: tuple[int, ...] | None = None
    left: tm__BvhNode | None = None
    right: tm__BvhNode | None = None

class tm_TriangleMesh:

    def _build_bvh(self, indices: tuple[int, ...]) -> tm__BvhNode:
        bounds = tm__union_bounds((self.triangle_bounds[index] for index in indices))
        if len(indices) <= 8:
            return tm__BvhNode(bounds[0], bounds[1], indices=indices)
        extents = [bounds[1][axis] - bounds[0][axis] for axis in range(3)]
        axis = max(range(3), key=lambda item: (extents[item], -item))
        ordered = sorted(indices, key=lambda index: (self.triangle_bounds[index][0][axis] + self.triangle_bounds[index][1][axis], index))
        split = len(ordered) // 2
        left = self._build_bvh(tuple(ordered[:split]))
        right = self._build_bvh(tuple(ordered[split:]))
        return tm__BvhNode(bounds[0], bounds[1], left=left, right=right)

    def _ray_triangle(self, origin: tm_Vec3, direction: tm_Vec3, indices: tuple[int, int, int], maximum_distance: float) -> float | None:
        a, b, c = (self.vertices[index] for index in indices)
        edge1 = tm__sub(b, a)
        edge2 = tm__sub(c, a)
        p = tm__cross(direction, edge2)
        determinant = tm__dot(edge1, p)
        determinant_tolerance = 1e-14 * max(1.0, tm__length(edge1) * tm__length(edge2))
        if abs(determinant) <= determinant_tolerance:
            return None
        inv = 1.0 / determinant
        tvec = tm__sub(origin, a)
        u = tm__dot(tvec, p) * inv
        barycentric_tolerance = 1e-10
        if u < -barycentric_tolerance or u > 1.0 + barycentric_tolerance:
            return None
        q = tm__cross(tvec, edge1)
        v = tm__dot(direction, q) * inv
        if v < -barycentric_tolerance or u + v > 1.0 + barycentric_tolerance:
            return None
        distance = tm__dot(edge2, q) * inv
        if distance < -self.distance_tolerance or distance > maximum_distance + self.distance_tolerance:
            return None
        return max(0.0, distance)

def tm__octahedral_decode(u: float, v: float) -> tm_Vec3:
    x = u * 2.0 - 1.0
    y = v * 2.0 - 1.0
    z = 1.0 - abs(x) - abs(y)
    if z < 0.0:
        old_x = x
        x = (1.0 - abs(y)) * (-1.0 if old_x < 0.0 else 1.0)
        y = (1.0 - abs(old_x)) * (-1.0 if y < 0.0 else 1.0)
    length = math.sqrt(x * x + y * y + z * z)
    if length <= 1e-15:
        raise tm_GeometryError('octahedral direction collapsed to zero')
    return (x / length, y / length, z / length)

r4_FEATURE_SCHEMA_ID = 'feng_magic_gi_olv_octa8_center4origin_ray_geometry_v2'

r4_GRID_SIZE = 8

r4_ORIGIN_OFFSETS = ((0.0, 0.0, 0.0), (0.0, 0.375, 0.0), (-0.375, -0.375, 0.375), (0.375, -0.375, -0.375))
SURFACE_LAYOUTS = ("surface_octa8_v1", "surface_horizon16_v1", "surface_patch_horizon16_v2")

class r4_R4FeatureError(ValueError):
    """Invalid r4 feature contract, source geometry, or sidecar."""

def r4__directions() -> list[tuple[float, float, float]]:
    result = []
    for bin_y in range(r4_GRID_SIZE):
        for bin_x in range(r4_GRID_SIZE):
            u = (bin_x + 0.5) / r4_GRID_SIZE
            v = (bin_y + 0.5) / r4_GRID_SIZE
            result.append(tm__octahedral_decode(u, v))
    if len(result) != 64:
        raise r4_R4FeatureError('internal octahedral direction count mismatch')
    return result


def ray_directions(layout: str = "octa8") -> list[tuple[float, float, float]]:
    """A sealed 64-direction experiment; the production octa8 layout is unchanged."""
    original=r4__directions()
    if layout in ("surface_horizon16_v1","surface_patch_horizon16_v2"):layout="horizon16_v1"
    if layout in ("octa8","surface_octa8_v1"):return original
    if layout!="horizon16_v1":raise InferenceError("unsupported ray layout: "+layout)
    values=np.asarray(original);pairs=[];seen=set()
    for index,direction in enumerate(values):
        if index in seen:continue
        partner=int(np.linalg.norm(values-direction*[-1,1,-1],axis=1).argmin())
        if partner==index or np.linalg.norm(values[partner]-direction*[-1,1,-1])>1e-9:
            raise InferenceError("ray layout lacks exact half-turn pairing")
        seen.update((index,partner));pairs.append((index,partner))
    chosen=sorted(pairs,key=lambda pair:(abs(values[pair[0],1]),pair[0]))[:8]
    result=list(original)
    for slot,(index,partner) in enumerate(chosen):
        angle=slot*math.pi/8;direction=(math.cos(angle),0.,math.sin(angle))
        result[index]=direction;result[partner]=(-direction[0],0.,-direction[2])
    return result


def ray_layout_extension(layout: str) -> dict[str, Any]:
    if layout=="octa8":return {}
    directions=np.asarray(ray_directions(layout),dtype='<f8').round(12)
    if layout=="surface_patch_horizon16_v2":
        return {"base_feature_schema_id":r4_FEATURE_SCHEMA_ID,"ray_layout":layout,
            "directions_sha256":sha_bytes(directions.tobytes()),"rays_per_probe":256,"shape":[64,26],
            "metadata_semantics":"two signed box-axis distances plus true physical coplanar patch footprint distance in the dominant-normal axis; center facing normal XYZ",
            "replaces_metadata_columns":[3,4,5,8,9,10,13,14,15,18,19,20,23,24,25]}
    return {"base_feature_schema_id":r4_FEATURE_SCHEMA_ID,"ray_layout":layout,
            "directions_sha256":sha_bytes(directions.tobytes()),"rays_per_probe":256,"shape":[64,26],
            **({"metadata_semantics":("per-origin signed box-axis distances of the center projected onto a connected coplanar hit patch; center facing normal XYZ" if layout=="surface_horizon16_v1" else "per-origin signed box-axis distances of the center projected onto the hit triangle plane, normalized by 8m and clamped; center facing normal XYZ"),"replaces_metadata_columns":[3,4,5,8,9,10,13,14,15,18,19,20,23,24,25]} if layout in SURFACE_LAYOUTS else {})}


def ray_layout_schema_id(layout: str) -> str:
    ray_directions(layout)
    return {"octa8":r4_FEATURE_SCHEMA_ID,"surface_octa8_v1":"feng_magic_gi_olv_surface_octa8_center4origin_ray_geometry_v1",
        "horizon16_v1":"feng_magic_gi_olv_horizon16_center4origin_ray_geometry_v1",
        "surface_horizon16_v1":"feng_magic_gi_olv_surface_horizon16_center4origin_ray_geometry_v1",
        "surface_patch_horizon16_v2":"feng_magic_gi_olv_surface_patch_horizon16_center4origin_ray_geometry_v2"}[layout]

def r4__extent_and_bounds(candidate: dict[str, Any]) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]:
    center = tm__xyz(candidate.get('world_center'), 'candidate.world_center')
    low, high = tm__bounds(candidate.get('world_bounds'), 'candidate.world_bounds')
    extent = tuple((high[axis] - low[axis] for axis in range(3)))
    if any((not math.isfinite(value) or value <= 0.0 for value in extent)):
        raise r4_R4FeatureError('candidate.world_bounds must have positive finite full extent on all axes')
    return (center, low, extent)

baseline_CLASS_IDS = (1, 2)

baseline_MODEL_WIDTH = 16

baseline_ATTENTION_HEADS = 4

baseline_ENCODER_LAYERS = 1

baseline_FEEDFORWARD_WIDTH = 32

class baseline_TransformerError(ValueError):
    """A safe, actionable OLV Transformer experiment error."""

def baseline__load_torch() -> Any:
    try:
        import torch
    except ImportError as exc:
        raise baseline_TransformerError('CPU PyTorch is required in an isolated task environment') from exc
    return torch

def baseline__resolve_device(torch: Any, requested: str='auto') -> Any:
    if requested not in {'auto', 'cpu', 'cuda'}:
        raise baseline_TransformerError('device must be auto, cpu, or cuda')
    if requested in {'auto', 'cuda'}:
        os.environ.setdefault('CUBLAS_WORKSPACE_CONFIG', ':4096:8')
    if requested == 'cuda' and (not bool(torch.cuda.is_available())):
        raise baseline_TransformerError('CUDA was explicitly requested, but this PyTorch environment has no usable CUDA device')
    if requested == 'auto':
        requested = 'cuda' if bool(torch.cuda.is_available()) else 'cpu'
    return torch.device('cuda:0' if requested == 'cuda' else 'cpu')

def baseline__configure_determinism(torch: Any) -> dict[str, Any]:
    torch.use_deterministic_algorithms(True)
    if hasattr(torch.backends, 'cudnn'):
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False
        if hasattr(torch.backends.cudnn, 'allow_tf32'):
            torch.backends.cudnn.allow_tf32 = False
    if hasattr(torch.backends, 'cuda') and hasattr(torch.backends.cuda, 'matmul'):
        torch.backends.cuda.matmul.allow_tf32 = False
    return {'deterministic_algorithms': bool(torch.are_deterministic_algorithms_enabled()), 'cudnn_deterministic': bool(torch.backends.cudnn.deterministic) if hasattr(torch.backends, 'cudnn') else None, 'cudnn_benchmark': bool(torch.backends.cudnn.benchmark) if hasattr(torch.backends, 'cudnn') else None, 'tf32_matmul': bool(torch.backends.cuda.matmul.allow_tf32) if hasattr(torch.backends, 'cuda') and hasattr(torch.backends.cuda, 'matmul') else None, 'tf32_cudnn': bool(torch.backends.cudnn.allow_tf32) if hasattr(torch.backends, 'cudnn') and hasattr(torch.backends.cudnn, 'allow_tf32') else None, 'cublas_workspace_config': os.environ.get('CUBLAS_WORKSPACE_CONFIG')}

def baseline_new_model(torch: Any, token_width: int, *, model_width: int=baseline_MODEL_WIDTH,
                       attention_heads: int=baseline_ATTENTION_HEADS,encoder_layers: int=baseline_ENCODER_LAYERS,
                       feedforward_width: int=baseline_FEEDFORWARD_WIDTH,class_count: int=2,pooling: str="mean") -> Any:
    if token_width < 6 or model_width % attention_heads or pooling not in ("mean","class_query"):
        raise baseline_TransformerError('invalid Transformer token/model width')
    nn = torch.nn

    class GeometryTransformer(nn.Module):

        def __init__(self) -> None:
            super().__init__()
            self.input_projection = nn.Linear(token_width, model_width)
            layer = nn.TransformerEncoderLayer(d_model=model_width, nhead=attention_heads, dim_feedforward=feedforward_width, dropout=0.0, activation='gelu', batch_first=True, norm_first=True)
            self.encoder = nn.TransformerEncoder(layer, num_layers=encoder_layers, enable_nested_tensor=False)
            self.final_norm = nn.LayerNorm(model_width)
            self.output = nn.Linear(model_width, class_count,bias=pooling=="mean")
            if pooling=="class_query":self.class_queries=nn.Parameter(torch.zeros(class_count,model_width))

        def _pool_and_classify(self, encoded: Any) -> tuple[Any,Any]:
            if pooling=="class_query":
                weights=torch.einsum('btd,cd->bct',encoded,self.class_queries).div(math.sqrt(model_width)).softmax(-1)
                pooled=self.final_norm(torch.einsum('bct,btd->bcd',weights,encoded))
                return (pooled*self.output.weight.unsqueeze(0)).sum(-1),pooled.mean(1)
            pooled=self.final_norm(encoded.mean(dim=1))
            return self.output(pooled),pooled

        def forward(self, tokens: Any) -> Any:
            embedded = self.input_projection(tokens)
            encoded = self.encoder(embedded)
            return self._pool_and_classify(encoded)[0]

        def forward_with_embedding(self, tokens: Any) -> tuple[Any, Any]:
            embedded = self.input_projection(tokens)
            encoded = self.encoder(embedded)
            return self._pool_and_classify(encoded)
    return GeometryTransformer().to(device='cpu', dtype=torch.float32)

FORMAT_JOB = "feng_magic_gi_olv_offline_inference_geometry_job_v1"
FORMAT_RESULT = "feng_magic_gi_olv_offline_inference_result_v1"
FORMAT_BUNDLE = "feng_magic_gi_olv_r5_offline_model_bundle_v1"
MAX_PROBES = 262144
MAX_RANGE_M = 8.0
CONTEXT_EXTENT = (0.5, 0.5, 0.5)
CLASS_IDS = (1, 2)
POLICY_ID = "olv_binary2000_center_single_view_argmax_v2"
EXPECTED_CONTRACT_SHA = "c13e9ab78c57ab52010a589c09ebb07726372c3a363245b6e80c4eed2425f383"
JOB_KEYS = {
    "format", "schema_version", "probe_count", "source_spacing_m",
    "source_geometry_signature", "source_directional_signature",
    "source_layout_sha256", "probe_position_sha256", "geometry_triangles_sha256",
    "geometry_faces_file", "source_positions_file", "source_validity_file",
    "feature_context_extent_m", "supported_target_cell_spacings_m",
    "scene_id", "volume_id", "layout_revision", "target_layout_signature",
    "target_label_set_sha256",
}
FILE_REF_KEYS = {"path", "sha256"}
SHA_RE = __import__("re").compile(r"^[0-9a-f]{64}$")
CURRENT_PROGRESS: dict[str, Any] | None = None
ATOMIC_PUBLISH_METRICS = {"calls": 0, "retries": 0, "seconds": 0.0}
MAX_ATOMIC_REPLACE_RETRIES = 20
ATOMIC_REPLACE_RETRY_SECONDS = 0.025
WORKER_SNAPSHOTS = False
SNAPSHOT_SEQUENCE = 0


def _atomic_replace_with_retry(temp: Path, target: Path) -> int:
    """Replace one snapshot, retrying transient Windows reader sharing locks."""
    start = time.perf_counter()
    retries = 0
    try:
        while True:
            try:
                os.replace(temp, target)
                return retries
            except OSError as exc:
                winerror = getattr(exc, "winerror", None)
                retryable = os.name == "nt" and (
                    winerror in (5, 32) or exc.errno in (errno.EACCES, errno.EBUSY))
                if not retryable or retries >= MAX_ATOMIC_REPLACE_RETRIES:
                    raise
                retries += 1
                ATOMIC_PUBLISH_METRICS["retries"] += 1
                time.sleep(ATOMIC_REPLACE_RETRY_SECONDS)
    finally:
        ATOMIC_PUBLISH_METRICS["calls"] += 1
        ATOMIC_PUBLISH_METRICS["seconds"] += time.perf_counter() - start


class InferenceError(ValueError):
    pass


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def _write_progress(progress_path: Path | None, event: dict[str, Any]) -> None:
    if progress_path is None:
        return
    if WORKER_SNAPSHOTS:
        _atomic_json(progress_path, event)
        return
    progress_path.parent.mkdir(parents=True, exist_ok=True)
    temp = progress_path.with_name(f".{progress_path.name}.{os.getpid()}.tmp")
    try:
        with temp.open("wb") as stream:
            stream.write(canonical_bytes(event) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        _atomic_replace_with_retry(temp, progress_path)
    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def _progress(stage: str, done: int, total: int, progress_path: Path | None,
              *, emit_console: bool = True, **extra: Any) -> None:
    global CURRENT_PROGRESS
    event = {"event": "progress", "stage": stage, "done": done,
             "total": total, **extra}
    CURRENT_PROGRESS = event
    try:
        _write_progress(progress_path, event)
    except OSError as exc:
        # Progress is advisory. A persistent reader lock should not discard a
        # completed inference; the request status/result remain authoritative.
        event["progress_publish_warning"] = str(exc)
    if emit_console:
        print(json.dumps(event, ensure_ascii=False, sort_keys=True), flush=True)


def _check_cancel(cancel_path: Path | None) -> None:
    if cancel_path is not None and cancel_path.exists():
        raise InterruptedError(f"cancel requested by marker: {cancel_path}")


def _read_job(path: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
    raw = path.read_bytes()
    try:
        job = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InferenceError(f"job JSON is invalid: {exc}") from exc
    if not isinstance(job, dict) or set(job) != JOB_KEYS:
        missing = sorted(JOB_KEYS - set(job)) if isinstance(job, dict) else sorted(JOB_KEYS)
        extra = sorted(set(job) - JOB_KEYS) if isinstance(job, dict) else []
        raise InferenceError(f"job has wrong keys (missing={missing}, extra={extra})")
    if job.get("format") != FORMAT_JOB or job.get("schema_version") != 1:
        raise InferenceError("unsupported geometry job format/version")
    count = job.get("probe_count")
    if isinstance(count, bool) or not isinstance(count, int) or not 0 < count <= MAX_PROBES:
        raise InferenceError(f"probe_count must be in [1,{MAX_PROBES}]")
    spacing = job.get("source_spacing_m")
    if isinstance(spacing, bool) or not isinstance(spacing, (float, int)) or \
            not math.isfinite(float(spacing)) or float(spacing) <= 0.0:
        raise InferenceError("source_spacing_m must be positive and finite")
    signature = job.get("source_geometry_signature")
    if isinstance(signature, bool) or not isinstance(signature, int):
        raise InferenceError("source_geometry_signature must be an integer")
    for key in ("source_directional_signature", "source_layout_sha256",
                "probe_position_sha256", "geometry_triangles_sha256"):
        value = job.get(key)
        if not isinstance(value, str) or not value:
            raise InferenceError(f"{key} is required")
    for key in ("source_layout_sha256", "probe_position_sha256", "geometry_triangles_sha256"):
        if SHA_RE.fullmatch(job[key]) is None:
            raise InferenceError(f"{key} must be a lowercase SHA-256")
    label_set_sha = job.get("target_label_set_sha256")
    if label_set_sha not in (None, "") and \
            (not isinstance(label_set_sha, str) or SHA_RE.fullmatch(label_set_sha) is None):
        raise InferenceError("target_label_set_sha256 must be null/empty or a lowercase SHA-256")
    for key in ("scene_id", "volume_id", "target_layout_signature"):
        if not isinstance(job.get(key), str) or not job[key]:
            raise InferenceError(f"{key} must be a non-empty string")
    revision = job.get("layout_revision")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
        raise InferenceError("layout_revision must be a non-negative integer")
    extent = job.get("feature_context_extent_m")
    if not isinstance(extent, list) or len(extent) != 3 or \
            tuple(float(v) for v in extent) != CONTEXT_EXTENT:
        raise InferenceError("frozen model supports only the fixed full feature extent [0.5,0.5,0.5]")
    supported = job.get("supported_target_cell_spacings_m")
    if not isinstance(supported, list) or not supported:
        raise InferenceError("supported_target_cell_spacings_m must be a non-empty list")
    if any(isinstance(v, bool) or not isinstance(v, (float, int)) or
           not math.isfinite(float(v)) or float(v) <= 0 for v in supported):
        raise InferenceError("target-cell spacing list contains an invalid value")
    files: dict[str, bytes] = {}
    base = path.resolve().parent
    for key in ("geometry_faces_file", "source_positions_file", "source_validity_file"):
        ref = job.get(key)
        if not isinstance(ref, dict) or set(ref) != FILE_REF_KEYS:
            raise InferenceError(f"{key} must contain exactly path and sha256")
        relative = ref.get("path")
        if not isinstance(relative, str) or not relative:
            raise InferenceError(f"{key}.path is required")
        file_path = (base / relative).resolve()
        try:
            file_path.relative_to(base)
        except ValueError as exc:
            raise InferenceError(f"{key} escapes the job directory") from exc
        expected_sha = ref.get("sha256")
        if not isinstance(expected_sha, str) or SHA_RE.fullmatch(expected_sha) is None:
            raise InferenceError(f"{key}.sha256 must be a lowercase SHA-256")
        data = file_path.read_bytes()
        if sha_bytes(data) != expected_sha:
            raise InferenceError(f"{key} hash mismatch")
        files[key] = data
    geometry_sha = sha_bytes(files["geometry_faces_file"])
    if geometry_sha != job["geometry_triangles_sha256"]:
        raise InferenceError("geometry_triangles_sha256 does not bind the captured faces bytes")
    if len(files["source_positions_file"]) != count * 12:
        raise InferenceError("source_positions_file byte count must equal probe_count*12")
    if len(files["source_validity_file"]) != count:
        raise InferenceError("source_validity_file byte count must equal probe_count")
    if len(files["geometry_faces_file"]) == 0 or len(files["geometry_faces_file"]) % 36:
        raise InferenceError("geometry_faces_file must contain sequential float32 triangles (36 bytes each)")
    positions = np.frombuffer(files["source_positions_file"], dtype="<f4")
    validity = np.frombuffer(files["source_validity_file"], dtype=np.uint8)
    if not np.isfinite(positions).all():
        raise InferenceError("source probe positions contain non-finite values")
    if not np.isin(validity, np.array([0, 1, 2], dtype=np.uint8)).all():
        raise InferenceError("source validity bytes must use the frozen 0/1/2 status code")
    positions = positions.reshape(count, 3)
    # Mirror FMagicGIOlvProbeDomainPayload.source_binding byte-for-byte: logical index,
    # validity and the exact float32 world position in source logical order.
    digest = hashlib.sha256()
    positions_raw = files["source_positions_file"]
    validity_raw = files["source_validity_file"]
    for index in range(count):
        digest.update(struct.pack("<ii", index, int(validity[index])))
        digest.update(positions_raw[index * 12:(index + 1) * 12])
    if digest.hexdigest() != job["probe_position_sha256"]:
        raise InferenceError("probe_position_sha256 does not match exact source positions and validity")
    return job, files


CONSTANT_GEOMETRY_COLUMNS = (3,4,5,8,9,10,13,14,15,18,19,20,23,24,25)
SURFACE_DISTANCE_COLUMNS = (3,4,5,8,9,10,13,14,15,18,19,20)


def configure_model_input_transform(torch: Any, model: Any, mean: Any, std: Any,
                                    transform: str = "identity") -> Any:
    """Use captured hit geometry in constant slots, without learned parameters.

    The public model input remains normalized raw [64,26] ray geometry. This
    adapter is shared by training and offline inference. Nonpersistent buffers
    move with the model but neither alter its checkpoint nor parameter count.
    """
    if transform not in ("identity","relative_hit_geometry_v1","domain_statistics_v1","surface_log_v1","surface_origin_residual_v1","range_multiscale_v1"):
        raise InferenceError("unsupported model input transform: "+str(transform))
    original=getattr(model,"_olv_original_forward",model.forward)
    model._olv_original_forward=original
    original_embedding=getattr(model,"_olv_original_forward_with_embedding",getattr(model,"forward_with_embedding",None))
    if original_embedding is not None:model._olv_original_forward_with_embedding=original_embedding
    model._olv_input_transform=transform
    if transform=="identity":
        model.forward=original
        if original_embedding is not None:model.forward_with_embedding=original_embedding
        return model
    device=next(model.parameters()).device
    mu=torch.as_tensor(mean,dtype=torch.float32,device=device).reshape(1,1,26)
    sigma=torch.as_tensor(std,dtype=torch.float32,device=device).reshape(1,1,26)
    if "_olv_raw_mean" not in model._buffers:
        model.register_buffer("_olv_raw_mean",mu.clone(),persistent=False)
        model.register_buffer("_olv_raw_std",sigma.clone(),persistent=False)
    else:model._olv_raw_mean=mu.clone();model._olv_raw_std=sigma.clone()
    if transform=="surface_origin_residual_v1":
        offsets=torch.as_tensor(np.asarray(r4_ORIGIN_OFFSETS[1:])*np.asarray(CONTEXT_EXTENT),dtype=torch.float32,device=device)
        if '_olv_origin_offsets' not in model._buffers:model.register_buffer('_olv_origin_offsets',offsets,persistent=False)
        else:model._olv_origin_offsets=offsets
    def transformed(normalized):
        raw=normalized*model._olv_raw_std+model._olv_raw_mean
        derived=normalized.clone();direction=raw[...,:3];extent=raw[...,23:26]
        if transform=="range_multiscale_v1":
            # Preserve every raw distance/hit channel. Previously constant slots
            # expose near/far geometry without extra rays or learned parameters.
            distance=raw[...,[6,11,16,21]].clamp(0,1)
            hit=(raw[...,[7,12,17,22]]>.5).to(normalized.dtype)
            logarithmic=2*torch.log1p(distance*8000)/math.log1p(8000)*hit
            relative=(distance[...,1:]-distance[...,:1])/(distance[...,1:]+distance[...,:1]+1e-4)
            relative=relative*hit[...,1:]*hit[...,:1]
            center_position=4*direction*distance[...,:1]*hit[...,:1]
            y=direction[...,1];bands=(y>.25,y<-.25,y.abs()<=.25)
            enclosure=torch.stack([2*(hit[...,0]*band).sum(-1)/band.sum(-1).clamp_min(1)-1 for band in bands],-1)
            center_range=torch.where(hit[...,0]>.5,distance[...,0],torch.ones_like(distance[...,0]))
            minimum=2*torch.log1p(center_range.amin(-1)*8000)/math.log1p(8000)
            spread=center_range.var(-1,unbiased=False).clamp_min(1e-12).sqrt()
            summary=torch.cat([enclosure,minimum.unsqueeze(-1),spread.unsqueeze(-1)],-1).unsqueeze(-2).expand(-1,normalized.shape[1],-1)
            derived[...,list(CONSTANT_GEOMETRY_COLUMNS)]=torch.cat([logarithmic,relative,center_position,summary],-1)
            return derived
        if transform in ("surface_log_v1","surface_origin_residual_v1"):
            # Match the logarithmic TRAIN boundary scales without new weights.
            # Raw signed distances use 8m units; 4000 corresponds to 2mm.
            distances=raw[...,list(SURFACE_DISTANCE_COLUMNS)]
            derived[...,list(SURFACE_DISTANCE_COLUMNS)]=2*distances.sign()*torch.log1p(distances.abs()*4000)/math.log1p(4000)
            if transform=="surface_origin_residual_v1":
                # A common hit plane predicts each offset ray's range exactly.
                # Remove that predictable displacement, exposing observed
                # occlusion/discontinuity without new rays or learned weights.
                normal=raw[...,23:26];cosine=(normal*direction).sum(-1,keepdim=True)
                safe=torch.where(cosine.abs()>=.15,cosine,-torch.ones_like(cosine))
                plane_shift=torch.einsum('btd,od->bto',normal,model._olv_origin_offsets)/(MAX_RANGE_M*safe)
                ranges=raw[...,[6,11,16,21]];hits=raw[...,[7,12,17,22]]>.5
                residual=ranges[...,1:]-ranges[...,:1]+plane_shift
                encoded=2*residual.sign()*torch.log1p(residual.abs()*4000)/math.log1p(4000)
                valid=(cosine.abs()>=.15)&hits[...,:1]&hits[...,1:]&(normal.square().sum(-1,keepdim=True)>.5)
                derived[...,[11,16,21]]=torch.where(valid,encoded,normalized[...,[11,16,21]])
            return derived
        distances=[];hits=[]
        for slot in range(4):
            start=3+slot*5;distance=raw[...,start+3].clamp(0,1)
            hit=(raw[...,start+4]>.5).to(normalized.dtype)
            # Positions relative to the center in two-meter units. No extra rays.
            derived[...,start:start+3]=4*(direction*distance.unsqueeze(-1)+raw[...,start:start+3]*extent)*hit.unsqueeze(-1)
            distances.append(distance);hits.append(hit)
        derived[...,23]=4*(distances[1]-distances[0])*hits[1]*hits[0]
        derived[...,24]=2*((distances[2]-distances[0])*hits[2]*hits[0]+(distances[3]-distances[0])*hits[3]*hits[0])
        derived[...,25]=2*((hits[1]+hits[2]+hits[3])/3-hits[0])
        if transform=="domain_statistics_v1":
            # Rotation-invariant enclosure cues, derived only from the same rays.
            # Repetition across ray tokens lets the tiny network use probe-level
            # geometry without learning the pooling operation from sparse labels.
            y=direction[...,1];bands=(y>.25,y<-.25,y.abs()<=.25)
            def average(value,band):
                return (value*band).sum(-1)/band.sum(-1).clamp_min(1)
            summaries=[average(hit,band) for hit in hits for band in bands]
            closeness=-distances[0].clamp_min(1e-5).log()/math.log(1e5)*hits[0]
            summaries.extend(average(closeness,band) for band in bands)
            derived[...,list(CONSTANT_GEOMETRY_COLUMNS)]=torch.stack(summaries,-1).unsqueeze(-2)
        return derived
    model.forward=lambda normalized:original(transformed(normalized))
    if original_embedding is not None:model.forward_with_embedding=lambda normalized:original_embedding(transformed(normalized))
    return model


def _load_bundle(bundle_dir: Path) -> tuple[dict[str, Any], str, Any, list[tuple[int, Any]]]:
    bundle_dir = bundle_dir.resolve()
    manifest_path = bundle_dir / "inference_manifest.json"
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw.decode("utf-8"))
    if manifest.get("format") != FORMAT_BUNDLE or manifest.get("schema_version") != 1:
        raise InferenceError("unsupported model bundle format/version")
    architecture = manifest.get("architecture", {})
    model_shape=(architecture.get("input_channels"), architecture.get("model_width"),
        architecture.get("encoder_layers"), architecture.get("attention_heads"),
        architecture.get("feedforward_width"), architecture.get("parameter_count"))
    capacity_shapes=tuple((26,width,2,2,ff,count) for width,ff,count in
        ((10,64,3998),(12,65,5014),(14,64,5994),(16,63,7022),(18,61,8024),(20,70,9960),(24,94,15044),(28,108,20012),(40,217,49994),(64,248,100016),(80,294,149948),(80,450,200180)))+((26,64,3,2,250,149742),(26,56,4,2,212,149864),(26,64,3,2,380,200052))
    if model_shape not in ((26,16,1,4,32,2722),(26,8,2,2,53,2722))+capacity_shapes or \
            architecture.get("pooling","mean")!=("mean" if model_shape==(26,16,1,4,32,2722) else "class_query"):
        raise InferenceError("bundle architecture differs from frozen R5 model")
    if manifest.get("class_id_order") != [1, 2] or manifest.get("inference_policy_id") != POLICY_ID:
        raise InferenceError("bundle class order or inference policy mismatch")
    contract_path = Path(__file__).resolve().with_name("feature_contract.json")
    contract_raw = contract_path.read_bytes()
    layout=manifest.get("ray_layout","octa8")
    if sha_bytes(contract_raw) != EXPECTED_CONTRACT_SHA or \
            manifest.get("feature_contract", {}).get("feature_contract_document_sha256") != EXPECTED_CONTRACT_SHA or \
            manifest.get("feature_contract", {}).get("schema_id") != ray_layout_schema_id(layout):
        raise InferenceError("R4 feature contract hash/schema mismatch")
    contract = json.loads(contract_raw)
    if layout!="octa8" and manifest.get("feature_contract_extension")!=ray_layout_extension(layout):
        raise InferenceError("experimental observation contract extension mismatch")
    if layout in SURFACE_LAYOUTS and manifest.get("model_input_transform","identity") not in ("identity","surface_log_v1","surface_origin_residual_v1"):
        raise InferenceError("live surface observations cannot use a constant-metadata adapter")
    if manifest.get('model_input_transform')=='surface_origin_residual_v1' and layout!='surface_patch_horizon16_v2':
        raise InferenceError('origin residual encoding requires the explicit physical patch observation schema')
    if layout not in SURFACE_LAYOUTS and manifest.get("model_input_transform")=="surface_log_v1":raise InferenceError("surface distance encoding requires live surface observations")
    if contract.get("schema_id") != r4_FEATURE_SCHEMA_ID \
            or contract.get("origin_offsets_full_extent") != [list(offset) for offset in r4_ORIGIN_OFFSETS] \
            or contract.get("shape") != [64, 26] or contract.get("rays_per_probe") != 256:
        raise InferenceError("production ray layout disagrees with the pinned model feature contract")
    normalizer_path = bundle_dir / str(manifest.get("normalizer_file", ""))
    normalizer_raw = normalizer_path.read_bytes()
    normalizer_sha = sha_bytes(normalizer_raw)
    if normalizer_sha != manifest.get("normalizer_sha256"):
        raise InferenceError("frozen train-only normalizer hash mismatch")
    normalizer = json.loads(normalizer_raw.decode("utf-8"))
    mean_values, std_values = normalizer.get("mean"), normalizer.get("std")
    if not isinstance(mean_values, list) or not isinstance(std_values, list) or \
            len(mean_values) != 26 or len(std_values) != 26:
        raise InferenceError("normalizer must have 26 channels")
    mean = np.asarray(mean_values, dtype=np.float32).reshape(1, 1, 26)
    std = np.asarray(std_values, dtype=np.float32).reshape(1, 1, 26)
    if not np.isfinite(mean).all() or not np.isfinite(std).all() or np.any(std <= 0):
        raise InferenceError("normalizer contains non-finite or non-positive values")
    torch = baseline__load_torch()
    loaded_models: list[tuple[int, Any]] = []
    seed_items = manifest.get("seeds")
    if not isinstance(seed_items, list) or len(seed_items) != 1 or not isinstance(seed_items[0], dict) \
            or type(seed_items[0].get("seed")) is not int or not 0 <= seed_items[0]["seed"] < 2**63:
        raise InferenceError("binary model bundle requires one checkpoint with a valid integer training seed")
    for item in seed_items:
        checkpoint_path = bundle_dir / str(item.get("checkpoint_file", ""))
        if sha_file(checkpoint_path) != item.get("checkpoint_sha256"):
            raise InferenceError(f"checkpoint hash mismatch for seed {item.get('seed')}")
        model = baseline_new_model(torch, token_width=26, model_width=int(architecture["model_width"]),
            attention_heads=int(architecture["attention_heads"]),encoder_layers=int(architecture["encoder_layers"]),
            feedforward_width=int(architecture["feedforward_width"]),pooling=architecture.get("pooling","mean"))
        if sum(p.numel() for p in model.parameters())!=architecture["parameter_count"]:raise InferenceError("model parameter count changed")
        state_dict = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
        model.load_state_dict(state_dict, strict=True)
        configure_model_input_transform(torch,model,mean,std,manifest.get("model_input_transform","identity"))
        model.eval()
        loaded_models.append((int(item["seed"]), model))
    return manifest, sha_bytes(raw), (torch, mean, std), loaded_models


def _coplanar_patch_components(vertices: np.ndarray) -> tuple[np.ndarray,np.ndarray,np.ndarray]:
    """Edge-connected coplanar patches, independent of internal triangulation.

    Original triangle bounds remain in the ray accelerator. Only the extra
    observed extent uses these bounds; disconnected and parallel walls stay apart.
    """
    tri=np.asarray(vertices,dtype='<f4').reshape(-1,3,3).copy();tri[tri==0]=0.
    value=tri.astype('f8');normal=np.cross(value[:,1]-value[:,0],value[:,2]-value[:,0])
    length=np.linalg.norm(normal,axis=1)
    if np.any(length<1e-14):raise InferenceError('degenerate triangle in observed surface patch')
    normal/=length[:,None];parent=list(range(len(tri)))
    def find(i):
        while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
        return i
    edges={}
    for i,face in enumerate(tri):
        for a,b in ((0,1),(1,2),(2,0)):
            key=tuple(sorted((face[a].tobytes(),face[b].tobytes())))
            for j in edges.get(key,()):
                if abs(float(normal[i]@normal[j]))>1-1e-7 and abs(float((value[i,0]-value[j,0])@normal[j]))<1e-5:
                    first,second=find(i),find(j)
                    if first!=second:parent[max(first,second)]=min(first,second)
            edges.setdefault(key,[]).append(i)
    roots=np.asarray([find(i) for i in range(len(tri))])
    return value,normal,roots


def _coplanar_patch_bounds(vertices: np.ndarray) -> tuple[np.ndarray,np.ndarray]:
    value,_normal,roots=_coplanar_patch_components(vertices)
    low=value.min(1);high=value.max(1)
    patch_low=np.full_like(low,np.inf);patch_high=np.full_like(high,-np.inf)
    np.minimum.at(patch_low,roots,low);np.maximum.at(patch_high,roots,high)
    return patch_low[roots],patch_high[roots]


def _make_triangle_ray_soup(face_bytes: bytes) -> Any:
    """Use the existing exact ray/BVH implementation without its closed-mesh label-audit gate."""
    raw_vertices = np.frombuffer(face_bytes, dtype="<f4")
    if raw_vertices.size < 12 or raw_vertices.size % 9:
        raise InferenceError("captured geometry must contain at least four complete triangles")
    if not np.isfinite(raw_vertices).all():
        raise InferenceError("captured geometry vertices contain non-finite coordinates")
    vertices = [tuple(float(x) for x in row) for row in raw_vertices.reshape(-1, 3)]
    triangle_count = len(vertices) // 3
    mesh = tm_TriangleMesh.__new__(tm_TriangleMesh)
    mesh.vertices = vertices
    mesh.triangles = [(3 * i, 3 * i + 1, 3 * i + 2) for i in range(triangle_count)]
    mesh.triangle_bounds = [tm__triangle_bounds(vertices[3 * i:3 * i + 3]) for i in range(triangle_count)]
    mesh.bounds = tm__union_bounds(mesh.triangle_bounds)
    mesh.scale = max(1.0, *[mesh.bounds[1][axis] - mesh.bounds[0][axis] for axis in range(3)])
    mesh.distance_tolerance = mesh.scale * 1.0e-9
    mesh.root = mesh._build_bvh(tuple(range(triangle_count)))
    return mesh


def _candidate_at(center: Sequence[float]) -> dict[str, Any]:
    half = CONTEXT_EXTENT[0] * 0.5
    c = [float(v) for v in center]
    return {"world_center": c,
            "world_bounds": {"min": [v - half for v in c], "max": [v + half for v in c]}}


def _generate_batch_features(job: dict[str, Any], files: dict[str, bytes],
                             indices: np.ndarray, original_mesh: Any,
                              cancel_path: Path | None, ray_layout: str = "octa8") -> np.ndarray:
    positions = np.frombuffer(files["source_positions_file"], dtype="<f4").reshape(-1, 3)
    if isinstance(original_mesh, _CudaRayFeatures):
        return original_mesh.extract(positions[indices], cancel_path)
    original_rows = np.empty((len(indices), 64, 26), dtype="<f4")
    for row_no, source_index in enumerate(indices.tolist()):
        if row_no % 8 == 0:
            _check_cancel(cancel_path)
        center = positions[source_index]
        candidate = _candidate_at(center)
        array = _fast_tokens_for_candidate(candidate, [original_mesh],ray_layout)
        if array.shape != (64, 26) or not np.isfinite(array).all():
            raise InferenceError(f"R4 extractor produced invalid I features at source probe {source_index}")
        original_rows[row_no] = array
    return original_rows


class _CudaRayFeatures:
    """Batched exact first-hit rays, with the CPU triangle tolerances in float64.

    This is offline feature extraction only. No ray tracing or network calls
    are added to the frame renderer. CPU/BVH remains the non-CUDA path.
    """
    def __init__(self, torch: Any, faces: bytes, device: Any, ray_layout: str = "octa8", *, precomputed_footprints: Any = None) -> None:
        self.torch, self.device = torch, device
        self.surface_info=ray_layout in SURFACE_LAYOUTS
        raw = np.frombuffer(faces, dtype="<f4")
        if raw.size < 36 or raw.size % 9 or not np.isfinite(raw).all():
            raise InferenceError("invalid triangle soup for CUDA OLV features")
        vertices = raw.reshape(-1, 3).astype(np.float64)
        scale = max(1.0, float(np.ptp(vertices, axis=0).max()))
        self.distance_tolerance = scale * 1e-9
        triangles = torch.as_tensor(vertices.reshape(-1,3,3), dtype=torch.float64, device=device)
        self.a = triangles[:,0]
        self.e1, self.e2 = triangles[:,1]-triangles[:,0], triangles[:,2]-triangles[:,0]
        if self.surface_info:
            self.normals=torch.linalg.cross(self.e1,self.e2)
            self.normals=self.normals/self.normals.norm(dim=1,keepdim=True).clamp_min(1e-30)
        self.det_tolerance = 1e-14 * torch.clamp(self.e1.norm(dim=1)*self.e2.norm(dim=1), min=1.0)
        self.low, self.high = triangles.amin(dim=1), triangles.amax(dim=1)
        self.attribute_low,self.attribute_high=self.low,self.high
        self.footprints=None
        if precomputed_footprints is not None and ray_layout!="surface_patch_horizon16_v2":
            raise InferenceError('physical footprint cache requires its explicit observation version')
        if ray_layout=="surface_horizon16_v1":
            patch_low,patch_high=_coplanar_patch_bounds(raw)
            self.attribute_low=torch.as_tensor(patch_low,dtype=torch.float64,device=device)
            self.attribute_high=torch.as_tensor(patch_high,dtype=torch.float64,device=device)
        if ray_layout=="surface_patch_horizon16_v2":
            from olv_patch_geometry import PatchFootprints
            if precomputed_footprints is None:
                value,normal,roots=_coplanar_patch_components(raw)
                self.footprints=PatchFootprints(value,normal,roots)
            else:
                if not np.array_equal(precomputed_footprints.triangles.reshape(-1,3),vertices):
                    raise InferenceError('physical footprint cache belongs to different captured geometry')
                self.footprints=precomputed_footprints
            self.attribute_low=torch.as_tensor(self.footprints.bounds_low[self.footprints.triangle_patch_ids],dtype=torch.float64,device=device)
            self.attribute_high=torch.as_tensor(self.footprints.bounds_high[self.footprints.triangle_patch_ids],dtype=torch.float64,device=device)
        self.numpy_directions=np.asarray(ray_directions(ray_layout)).round(12)
        self.directions = torch.tensor(ray_directions(ray_layout), dtype=torch.float64, device=device)
        self.offsets = torch.tensor(r4_ORIGIN_OFFSETS, dtype=torch.float64, device=device)
        # Direction-dependent terms are shared by every probe/origin.
        self.cross_direction_e2 = self.nonparallel = self.inverse_det = None
        if len(triangles) <= 16384:
            self.cross_direction_e2 = torch.linalg.cross(self.directions[:,None,:],self.e2[None,:,:])
            determinant = (self.e1[None,:,:]*self.cross_direction_e2).sum(-1)
            self.nonparallel = determinant.abs()>self.det_tolerance[None,:]
            self.inverse_det = torch.where(self.nonparallel,1.0/determinant,0.0)

    def extract(self, positions: np.ndarray, cancel_path: Path | None) -> np.ndarray:
        torch = self.torch
        centers = torch.as_tensor(positions.astype(np.float64), device=self.device)
        count = len(centers)
        origins = (centers[:,None,:] + self.offsets[None,:,:]*0.5).reshape(-1,3)
        nearest = torch.full((len(origins),64), float("inf"), dtype=torch.float64, device=self.device)
        if self.surface_info:nearest_id=torch.full((len(origins),64),len(self.a),dtype=torch.int64,device=self.device)
        bounds_low, bounds_high = origins.amin(0)-MAX_RANGE_M, origins.amax(0)+MAX_RANGE_M
        candidates = torch.nonzero(((self.high>=bounds_low)&(self.low<=bounds_high)).all(1)).flatten()
        triangle_batch=256 if self.surface_info else 64
        for start in range(0,len(candidates),triangle_batch):
            if start % 512 == 0: _check_cancel(cancel_path)
            selected = candidates[start:start+triangle_batch]
            a,e1,e2 = self.a[selected],self.e1[selected],self.e2[selected]
            if self.cross_direction_e2 is None:
                p = torch.linalg.cross(self.directions[:,None,:],e2[None,:,:])
                det = (e1[None,:,:]*p).sum(-1)
                nonparallel = det.abs()>self.det_tolerance[selected][None,:]
                inv = torch.where(nonparallel,1.0/det,0.0)
            else:
                p = self.cross_direction_e2[:,selected,:]
                inv = self.inverse_det[:,selected]
                nonparallel = self.nonparallel[:,selected]
            delta = origins[:,None,:]-a[None,:,:]
            u = torch.einsum("otc,dtc->odt",delta,p)*inv[None,:,:]
            q = torch.linalg.cross(delta,e1[None,:,:])
            v = torch.einsum("dc,otc->odt",self.directions,q)*inv[None,:,:]
            distance = (e2[None,:,:]*q).sum(-1)[:,None,:]*inv[None,:,:]
            valid = nonparallel[None,:,:] & (u>=-1e-10) & (u<=1+1e-10) & (v>=-1e-10) & (u+v<=1+1e-10) \
                & (distance>=-self.distance_tolerance) & (distance<=MAX_RANGE_M+self.distance_tolerance)
            hits = torch.where(valid,distance.clamp(min=0),float("inf"))
            closest=hits.amin(2)
            if self.surface_info:
                ids=torch.where(torch.isfinite(hits)&(hits<=closest[:,:,None]+self.distance_tolerance),selected[None,None,:],len(self.a)).amin(2)
                update=(closest<nearest-self.distance_tolerance)|((abs(closest-nearest)<=self.distance_tolerance)&(ids<nearest_id))
                nearest_id=torch.where(update,ids,nearest_id)
            nearest = torch.minimum(nearest,closest)
        distances = nearest.reshape(count,4,64).permute(0,2,1).cpu().numpy()
        output = np.empty((count,64,26),dtype="<f4")
        output[:,:,:3] = self.numpy_directions
        output[:,:,23:] = np.asarray(CONTEXT_EXTENT)/MAX_RANGE_M
        for origin,offset in enumerate(r4_ORIGIN_OFFSETS):
            output[:,:,3+origin*5:6+origin*5] = offset
            output[:,:,6+origin*5] = np.minimum(distances[:,:,origin]/MAX_RANGE_M,1.0).round(9)
            output[:,:,7+origin*5] = np.isfinite(distances[:,:,origin])
        if self.surface_info:
            safe=nearest_id.clamp(max=len(self.a)-1);hit=torch.isfinite(nearest)
            normal=self.normals[safe];normal=normal*torch.where((normal*self.directions[None]).sum(-1)>0,-1.,1.)[:,:,None]
            all_centers=centers.repeat_interleave(4,dim=0)[:,None,:]
            projected=all_centers-normal*((all_centers-self.a[safe])*normal).sum(-1,keepdim=True)
            attributes=(torch.maximum(self.attribute_low[safe]-projected,projected-self.attribute_high[safe])/MAX_RANGE_M).clamp(-1,1)
            if self.footprints is not None:
                table=self.footprints.torch_signed_distances(torch,centers)
                patch_ids=self.footprints._device_cache[str(centers.device)]['triangle_patch_ids'][safe]
                center_ids=torch.arange(count,device=self.device).repeat_interleave(4)[:,None]
                distance=(table[center_ids,patch_ids]/MAX_RANGE_M).clamp(-1,1)
                axis=self.footprints._device_cache[str(centers.device)]['dominant_axes'][patch_ids][:,:,None]
                attributes.scatter_(-1,axis,distance[:,:,None])
            attributes=torch.where(hit[:,:,None],attributes,0.).reshape(count,4,64,3).permute(0,2,1,3).cpu().numpy().round(9)
            extra=normal
            extra=torch.where(hit[:,:,None],extra,0.).reshape(count,4,64,3)[:,0].cpu().numpy().round(9)
            for origin in range(4):output[:,:,3+origin*5:6+origin*5]=attributes[:,:,origin]
            output[:,:,23:]=extra
        return output


def _ray_aabb_entry(origin: Sequence[float], direction: Sequence[float],
                    low: Sequence[float], high: Sequence[float],
                    maximum_distance: float) -> float | None:
    """Return the ray's clipped nonnegative AABB entry distance, if intersected."""
    enter = -math.inf
    leave = math.inf
    for axis in range(3):
        component = direction[axis]
        if abs(component) <= 1.0e-15:
            if origin[axis] < low[axis] - tm_EPS or origin[axis] > high[axis] + tm_EPS:
                return None
            continue
        t0 = (low[axis] - origin[axis]) / component
        t1 = (high[axis] - origin[axis]) / component
        enter = max(enter, min(t0, t1))
        leave = min(leave, max(t0, t1))
        if leave + tm_EPS < enter:
            return None
    if leave < -tm_EPS or enter > maximum_distance + tm_EPS:
        return None
    return max(0.0, enter)


def _mesh_first_hit(mesh: Any, origin: Sequence[float], direction: Sequence[float],
                    maximum_distance: float, return_triangle: bool = False) -> Any:
    """Find the exact nearest triangle hit, pruning BVH nodes behind it."""
    root_entry = _ray_aabb_entry(origin, direction, mesh.root.low, mesh.root.high,
                                 maximum_distance)
    if root_entry is None:
        return None
    nearest: float | None = None
    surface_hits=[];tolerance=mesh.distance_tolerance if return_triangle else tm_EPS
    stack = [(root_entry, mesh.root)]
    while stack:
        entry, node = stack.pop()
        if nearest is not None and entry > nearest + tolerance:
            continue
        if node.indices is not None:
            for index in node.indices:
                hit = mesh._ray_triangle(origin, direction, mesh.triangles[index], maximum_distance)
                if return_triangle and hit is not None and (nearest is None or hit<=nearest+tolerance):surface_hits.append((hit,index))
                if hit is not None and (nearest is None or hit < nearest):
                    nearest = hit
            continue
        children: list[tuple[float, Any]] = []
        for child in (node.left, node.right):
            if child is None:
                continue
            child_entry = _ray_aabb_entry(origin, direction, child.low, child.high,
                                          maximum_distance)
            if child_entry is not None and (nearest is None or child_entry <= nearest + tolerance):
                children.append((child_entry, child))
        # Stack is LIFO: push far first so the nearest node is visited first.
        children.sort(key=lambda pair: pair[0], reverse=True)
        stack.extend(children)
    if return_triangle and nearest is not None:return nearest,min(index for hit,index in surface_hits if abs(hit-nearest)<=tolerance)
    return nearest


def _scene_surface_hit(meshes: Sequence[Any], origin: Sequence[float], direction: Sequence[float],
                        center: Sequence[float],patch_bounds: bool=False,actual_footprints: bool=False) -> tuple[Any,Any,Any]:
    nearest=None;chosen=None
    for mesh in meshes:
        hit=_mesh_first_hit(mesh,origin,direction,MAX_RANGE_M,True)
        if hit is not None and (nearest is None or hit[0]<nearest):nearest=hit[0];chosen=(mesh,hit[1])
    if chosen is None:return None,[0.,0.,0.],[0.,0.,0.]
    mesh,index=chosen;vertices=np.asarray([mesh.vertices[i] for i in mesh.triangles[index]],dtype='f8')
    normal=np.cross(vertices[1]-vertices[0],vertices[2]-vertices[0]);normal/=np.linalg.norm(normal)
    if float(normal@direction)>0:normal=-normal
    center=np.asarray(center);projected=center-normal*float(normal@(center-vertices[0]))
    low,high=vertices.min(0),vertices.max(0)
    if patch_bounds:
        if not hasattr(mesh,'_olv_patch_bounds'):mesh._olv_patch_bounds=_coplanar_patch_bounds(np.asarray([mesh.vertices[i] for face in mesh.triangles for i in face],dtype='<f4'))
        low,high=(bounds[index] for bounds in mesh._olv_patch_bounds)
    distances=np.clip(np.maximum(low-projected,projected-high)/MAX_RANGE_M,-1,1)
    if actual_footprints:
        if not hasattr(mesh,'_olv_patch_footprints'):
            from olv_patch_geometry import PatchFootprints
            value,normals,roots=_coplanar_patch_components(np.asarray([mesh.vertices[i] for face in mesh.triangles for i in face],dtype='<f4'))
            mesh._olv_patch_footprints=PatchFootprints(value,normals,roots)
            mesh._olv_footprint_center=None
        if mesh._olv_footprint_center is None or not np.array_equal(mesh._olv_footprint_center,center):
            mesh._olv_footprint_table=mesh._olv_patch_footprints.numpy_signed_distances(center[None])[0]
            mesh._olv_footprint_center=center.copy()
        patch_id=mesh._olv_patch_footprints.triangle_patch_ids[index]
        distances[mesh._olv_patch_footprints.dominant_axes[patch_id]]=np.clip(mesh._olv_footprint_table[patch_id]/MAX_RANGE_M,-1,1)
    return nearest,distances.tolist(),normal.tolist()


def _scene_first_hit(meshes: Sequence[Any], origin: Sequence[float],
                     direction: Sequence[float], maximum_distance: float) -> float | None:
    nearest: float | None = None
    for mesh in meshes:
        hit = _mesh_first_hit(mesh, origin, direction,
                              maximum_distance if nearest is None else min(maximum_distance, nearest))
        if hit is not None and (nearest is None or hit < nearest):
            nearest = hit
    return nearest


def _fast_tokens_for_candidate(candidate: dict[str, Any], meshes: Sequence[Any],
                                ray_layout: str = "octa8") -> np.ndarray:
    """R4 first-hit tokens using nearest-only traversal; values match R4 exactly."""
    center, _low, extent = r4__extent_and_bounds(candidate)
    extent_norm = [round(value / MAX_RANGE_M, 9) for value in extent]
    rows: list[list[Any]] = []
    surface=ray_layout in SURFACE_LAYOUTS
    for direction in ray_directions(ray_layout):
        token: list[Any] = [round(value, 12) for value in direction]
        center_surface=[0.,0.,0.]
        for origin_index,offset in enumerate(r4_ORIGIN_OFFSETS):
            origin = tuple(center[axis] + offset[axis] * extent[axis] for axis in range(3))
            if surface:
                first_hit,attributes,extra=_scene_surface_hit(meshes,origin,direction,center,
                    ray_layout in ("surface_horizon16_v1","surface_patch_horizon16_v2"),ray_layout=="surface_patch_horizon16_v2")
                if origin_index==0:center_surface=extra
            else:first_hit = _scene_first_hit(meshes, origin, direction, MAX_RANGE_M)
            first_distance = MAX_RANGE_M if first_hit is None else first_hit
            range_norm = min(1.0, max(0.0, first_distance / MAX_RANGE_M))
            token.extend((*([round(v,9) for v in attributes] if surface else offset), round(range_norm, 9), first_hit is not None))
        token.extend([round(v,9) for v in center_surface] if surface else extent_norm)
        if len(token) != 26:
            raise InferenceError("internal fast R4 token channel count mismatch")
        rows.append(token)
    values = np.asarray(rows, dtype="<f4")
    if values.shape != (64, 26) or not np.isfinite(values).all():
        raise InferenceError("nearest-only R4 ray path produced invalid tokens")
    return values


def _predict_probs(torch: Any, models: list[tuple[int, Any]], mean_np: np.ndarray,
                   std_np: np.ndarray, base: np.ndarray,
                   device_name: str, cancel_path: Path | None) -> np.ndarray:
    if len(models) != 1:
        raise InferenceError("binary deployment requires exactly one model")
    _check_cancel(cancel_path)
    device = baseline__resolve_device(torch, device_name)
    baseline__configure_determinism(torch)
    mean = torch.as_tensor(mean_np, dtype=torch.float32, device=device)
    std = torch.as_tensor(std_np, dtype=torch.float32, device=device)
    features = torch.as_tensor(base, dtype=torch.float32, device=device)
    model = models[0][1].to(device)
    with torch.inference_mode():
        probabilities = model((features - mean) / std).softmax(dim=1)
    return probabilities.cpu().numpy()


def run_job(job_path: Path, bundle_dir: Path, output_dir: Path, device_name: str,
            cancel_file: Path | None, progress_file: Path | None,
            batch_size: int,
            emit_console_events: bool = True,
            loaded_bundle: tuple[dict[str, Any], str, tuple[Any, Any, Any], list[tuple[int, Any]]] | None = None,
            loaded_bundle_seconds: float | None = None) -> dict[str, Any]:
    global CURRENT_PROGRESS
    CURRENT_PROGRESS = None
    started = time.perf_counter()
    atomic_before = dict(ATOMIC_PUBLISH_METRICS)
    job_read_start = time.perf_counter()
    job, files = _read_job(job_path.resolve())
    job_read_seconds = time.perf_counter() - job_read_start
    job_root = job_path.resolve().parent
    target = output_dir.resolve()
    try:
        target.relative_to(job_root)
    except ValueError as exc:
        raise InferenceError("output directory must be inside this job directory") from exc
    if target == job_root:
        raise InferenceError("output directory must be a new child of the job directory")
    if target.exists():
        raise FileExistsError(f"refusing to overwrite inference output: {target}")
    if batch_size <= 0 or batch_size > 512:
        raise InferenceError("batch_size must be in [1,512]")
    if loaded_bundle is None:
        model_load_start = time.perf_counter()
        bundle, bundle_sha, torch_values, models = _load_bundle(bundle_dir)
        model_load_seconds = time.perf_counter() - model_load_start
    else:
        bundle, bundle_sha, torch_values, models = loaded_bundle
        model_load_seconds = loaded_bundle_seconds
    torch, mean_np, std_np = torch_values
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{target.name}.staging-", dir=target.parent))
    try:
        _check_cancel(cancel_file)
        validity = np.frombuffer(files["source_validity_file"], dtype=np.uint8)
        valid_indices = np.flatnonzero(validity != 0).astype(np.int64)
        label_bytes = bytearray(int(job["probe_count"]))
        total = len(valid_indices)
        _progress("initializing_geometry", 0, total, progress_file,
                  emit_console=emit_console_events,
                  valid_probe_count=total, probe_count=int(job["probe_count"]))
        geometry_start = time.perf_counter()
        selected_device = baseline__resolve_device(torch, device_name)
        original_mesh = _CudaRayFeatures(torch,files["geometry_faces_file"],selected_device,bundle.get("ray_layout","octa8")) \
            if selected_device.type == "cuda" else _make_triangle_ray_soup(files["geometry_faces_file"])
        geometry_bvh_seconds = time.perf_counter() - geometry_start
        _progress("features_and_inference", 0, total, progress_file,
                  emit_console=emit_console_events,
                  valid_probe_count=total,
                  probe_count=int(job["probe_count"]))
        features_seconds = 0.0
        model_forward_seconds = 0.0
        model_forward_batch_seconds: list[float] = []
        last_progress_done = 0
        progress_quantum = max(batch_size, math.ceil(total / 100.0)) if total else batch_size
        # Keep the ray/BVH workspace bounded by the requested geometry batch,
        # but amortize tiny classifier dispatches independently. At most 512
        # [64,26] float32 tensors (3.25 MiB) wait for one model forward.
        classifier_batch_size = 512
        feature_batch_count = 0
        for start in range(0, total, classifier_batch_size):
            _check_cancel(cancel_file)
            batch_indices = valid_indices[start:start + classifier_batch_size]
            feature_parts = []
            for feature_start_index in range(0, len(batch_indices), batch_size):
                _check_cancel(cancel_file)
                feature_indices = batch_indices[feature_start_index:feature_start_index + batch_size]
                feature_start = time.perf_counter()
                feature_parts.append(_generate_batch_features(job, files, feature_indices,
                                                             original_mesh, cancel_file,bundle.get("ray_layout","octa8")))
                features_seconds += time.perf_counter() - feature_start
                feature_batch_count += 1
                featured = start + feature_start_index + len(feature_indices)
                if featured - last_progress_done >= progress_quantum and featured < total:
                    _progress("features_and_inference", featured, total, progress_file,
                              emit_console=emit_console_events,
                              valid_probe_count=total, inferred_probe_count=start)
                    last_progress_done = featured
            base = np.concatenate(feature_parts, axis=0)
            model_start = time.perf_counter()
            probabilities = _predict_probs(torch, models, mean_np, std_np, base,
                                           device_name, cancel_file)
            model_batch_elapsed = time.perf_counter() - model_start
            model_forward_seconds += model_batch_elapsed
            model_forward_batch_seconds.append(model_batch_elapsed)
            if probabilities.shape != (len(batch_indices), 2) or not np.isfinite(probabilities).all():
                raise InferenceError("model produced invalid class probabilities")
            if np.any(probabilities < 0.0) or np.any(probabilities > 1.000001):
                raise InferenceError("model probabilities are outside [0,1]")
            prediction = probabilities.argmax(axis=1).astype(np.uint8) + 1
            if not np.isin(prediction, np.array(CLASS_IDS, dtype=np.uint8)).all():
                raise InferenceError("model returned a class outside the frozen codebook")
            for source_index, label in zip(batch_indices.tolist(), prediction.tolist()):
                label_bytes[source_index] = int(label)
            completed = min(start + len(batch_indices), total)
            if completed - last_progress_done >= progress_quantum or completed == total:
                _progress("features_and_inference", completed, total, progress_file,
                          emit_console=emit_console_events,
                          valid_probe_count=total, inferred_probe_count=completed)
                last_progress_done = completed
        _check_cancel(cancel_file)
        if len(label_bytes) != int(job["probe_count"]):
            raise InferenceError("output byte count differs from logical source probe count")
        for index, status in enumerate(validity.tolist()):
            if status == 0 and label_bytes[index] != 0:
                raise InferenceError(f"invalid source slot was assigned a model label at {index}")
            if status != 0 and label_bytes[index] not in CLASS_IDS:
                raise InferenceError(f"valid source slot lacks a supervised model label at {index}")
        output_io_start = time.perf_counter()
        labels_path = stage / "labels.bin"
        labels_path.write_bytes(label_bytes)
        labels_sha = sha_file(labels_path)
        label_file_write_seconds = time.perf_counter() - output_io_start
        payload_metadata = {
            "scene_id": job["scene_id"],
            "volume_id": job["volume_id"],
            "layout_revision": int(job["layout_revision"]),
            "target_layout_signature": job["target_layout_signature"],
            "target_label_set_sha256": job.get("target_label_set_sha256") or None,
            "geometry_triangles_sha256": job["geometry_triangles_sha256"],
            "model_sha256": bundle_sha,
            "feature_schema_id": ray_layout_schema_id(bundle.get("ray_layout","octa8")),
            "feature_schema_sha256": EXPECTED_CONTRACT_SHA,
            "decision_policy_id": POLICY_ID,
            "supported_probe_spacing_m": float(job["source_spacing_m"]),
            "supported_target_cell_spacings_m": [float(x) for x in job["supported_target_cell_spacings_m"]],
            "feature_context_extent_m": list(CONTEXT_EXTENT),
            "supported_feature_context_extents_m": [list(CONTEXT_EXTENT)],
        }
        result = {
            "format": FORMAT_RESULT, "schema_version": 1, "status": "complete",
            "offline_only": True, "runtime_model_calls": 0,
            "probe_count": int(job["probe_count"]), "valid_probe_count": int(total),
            "label_byte_count": len(label_bytes), "labels_file": "labels.bin",
            "labels_sha256": labels_sha,
            "label_codes": {"unset_invalid_source_only": 0, "exterior": 1,
                            "interior": 2},
            "feature_contract": {"schema_id": ray_layout_schema_id(bundle.get("ray_layout","octa8")),
                                 "document_sha256": EXPECTED_CONTRACT_SHA,
                                 "shape": [64, 26], "max_range_m": MAX_RANGE_M,
                                 "context_extent_m": list(CONTEXT_EXTENT),
                                 **({"extension":ray_layout_extension(bundle["ray_layout"])} if bundle.get("ray_layout","octa8")!="octa8" else {})},
            "model_bundle": {"candidate_id": bundle["candidate_id"],
                             "inference_manifest_sha256": bundle_sha,
                             "seeds": [item["seed"] for item in bundle["seeds"]],
                             "checkpoint_step": bundle["checkpoint_step"],
                             "normalizer_sha256": bundle["normalizer_sha256"],
                             "policy_id": POLICY_ID,
                             "policy": bundle["inference_rule"]},
            "source_binding": {
                "probe_count": int(job["probe_count"]),
                "source_spacing_m": float(job["source_spacing_m"]),
                "source_geometry_signature": int(job["source_geometry_signature"]),
                "source_directional_signature": job["source_directional_signature"],
                "source_layout_sha256": job["source_layout_sha256"],
                "probe_position_sha256": job["probe_position_sha256"],
                "geometry_triangles_sha256": job["geometry_triangles_sha256"],
                "geometry_faces_file_sha256": sha_bytes(files["geometry_faces_file"]),
                "source_positions_file_sha256": sha_bytes(files["source_positions_file"]),
                "source_validity_file_sha256": sha_bytes(files["source_validity_file"]),
            },
            "payload_metadata_for_configure_for_source": payload_metadata,
            "configure_for_source_fields_to_supply_at_commit": [
                "target_label_set_sha256 (final active label set hash)",
                "source_probe_positions (PackedVector3Array from source.cell_position(i) in logical order)",
            ] if not job.get("target_label_set_sha256") else [
                "source_probe_positions (PackedVector3Array from source.cell_position(i) in logical order)",
            ],
            "timing_seconds": {
                "job_and_input_read_sha256": round(job_read_seconds, 6),
                "model_bundle_load_once_worker_startup": None if model_load_seconds is None else round(model_load_seconds, 6),
                "geometry_accelerator_build": round(geometry_bvh_seconds, 6),
                "exact_i_feature_rays": round(features_seconds, 6),
                "single_binary_model_forwards": round(model_forward_seconds, 6),
                "model_forward_batch_count": len(model_forward_batch_seconds),
                "geometry_feature_batch_size": batch_size,
                "geometry_feature_batch_count": feature_batch_count,
                "classifier_batch_size": classifier_batch_size,
                "model_forward_first_batch_seconds": round(model_forward_batch_seconds[0], 6) if model_forward_batch_seconds else 0.0,
                "model_forward_subsequent_batches_mean_seconds": round(
                    sum(model_forward_batch_seconds[1:]) / len(model_forward_batch_seconds[1:]), 6)
                    if len(model_forward_batch_seconds) > 1 else None,
                "labels_file_write_and_hash": round(label_file_write_seconds, 6),
                "atomic_snapshot_replace_calls": ATOMIC_PUBLISH_METRICS["calls"] - atomic_before["calls"],
                "atomic_snapshot_replace_retries": ATOMIC_PUBLISH_METRICS["retries"] - atomic_before["retries"],
                "atomic_snapshot_replace_seconds": round(ATOMIC_PUBLISH_METRICS["seconds"] - atomic_before["seconds"], 6),
            },
            "elapsed_seconds": round(time.perf_counter() - started, 6),
            "inference_disclaimer": "Single-pass binary classification. Softmax scores have not been independently probability-calibrated. No confidence threshold or row filtering is applied; classification errors remain possible.",
        }
        result_bytes = canonical_bytes(result) + b"\n"
        result_write_start = time.perf_counter()
        (stage / "result.json").write_bytes(result_bytes)
        result_metadata_write_seconds = time.perf_counter() - result_write_start
        result["timing_seconds"]["result_metadata_write_first_pass"] = round(result_metadata_write_seconds, 6)
        result["elapsed_seconds"] = round(time.perf_counter() - started, 6)
        result_bytes = canonical_bytes(result) + b"\n"
        (stage / "result.json").write_bytes(result_bytes)
        _check_cancel(cancel_file)
        publish_start = time.perf_counter()
        _atomic_replace_with_retry(stage, target)
        publish_seconds = time.perf_counter() - publish_start
        try:
            _write_progress(progress_file, {"event": "complete", "stage": "published",
                                            "done": total, "total": total,
                                            "probe_count": int(job["probe_count"]),
                                            "valid_probe_count": int(total),
                                            "output_dir": str(target)})
        except OSError:
            # The validated output has already been published atomically. A stale
            # optional progress path must not relabel that successful job as failed.
            pass
        final = dict(result)
        final["output_dir"] = str(target)
        final["atomic_output_dir_publish_seconds"] = round(publish_seconds, 6)
        if emit_console_events:
            print(json.dumps({"event": "complete", "output_dir": str(target),
                              "labels_sha256": labels_sha, "result_sha256": sha_bytes(result_bytes),
                              "probe_count": int(job["probe_count"]), "valid_probe_count": int(total),
                              "elapsed_seconds": result["elapsed_seconds"],
                              "atomic_output_dir_publish_seconds": round(publish_seconds, 6)},
                             ensure_ascii=False, sort_keys=True), flush=True)
        return final
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    # Never replace a file that Godot may have open. Publish a closed,
    # immutable snapshot under a new name; the owner removes the directory
    # only after the request/worker has finished.
    global SNAPSHOT_SEQUENCE
    SNAPSHOT_SEQUENCE += 1
    directory = path.with_name(path.name + ".snapshots")
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{SNAPSHOT_SEQUENCE:020d}.json"
    temp = directory / f".{SNAPSHOT_SEQUENCE:020d}.tmp"
    try:
        with temp.open("wb") as stream:
            stream.write(canonical_bytes(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        _atomic_replace_with_retry(temp, target)
    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def _latest_snapshot(path: Path) -> Path | None:
    directory = path.with_name(path.name + ".snapshots")
    return max(directory.glob("*.json"), default=None)


def _worker_status(worker_dir: Path, status: str, **extra: Any) -> None:
    _atomic_json(worker_dir / "worker_status.json", {
        "format": "feng_magic_gi_olv_inference_worker_status_v1",
        "status": status, "pid": os.getpid(), "updated_unix_time": time.time(), **extra,
    })


def run_worker(worker_dir: Path, bundle_dir: Path, device_name: str,
               batch_size: int, poll_interval_ms: int) -> int:
    """Serve complete per-source-tile jobs while keeping the frozen models resident."""
    global WORKER_SNAPSHOTS
    WORKER_SNAPSHOTS = True
    root = worker_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / "worker.lock"
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise InferenceError(f"another inference worker may already own {root}") from exc
    with os.fdopen(lock_fd, "w", encoding="ascii") as lock_stream:
        lock_stream.write(str(os.getpid()))
        lock_stream.flush()
        os.fsync(lock_stream.fileno())
    jobs_dir = root / "jobs"
    jobs_dir.mkdir(exist_ok=True)
    try:
        if (root / "shutdown").exists() or _latest_snapshot(root / "worker_status.json") is not None:
            raise InferenceError("worker directory must be fresh and have no shutdown/status marker")
        _worker_status(root, "starting", bundle_dir=str(bundle_dir.resolve()))
        bundle_load_start = time.perf_counter()
        loaded_bundle = _load_bundle(bundle_dir)
        bundle_load_seconds = time.perf_counter() - bundle_load_start
    except Exception as exc:
        _worker_status(root, "failed", error=str(exc))
        lock_path.unlink(missing_ok=True)
        raise
    bundle, bundle_sha, _torch_values, _models = loaded_bundle
    _worker_status(root, "ready", bundle_sha256=bundle_sha,
                   candidate_id=bundle["candidate_id"],
                   seeds=[int(item["seed"]) for item in bundle["seeds"]],
                   batch_size=batch_size,
                   bundle_load_seconds=round(bundle_load_seconds, 6))
    while True:
        try:
            request_dirs = sorted((p for p in jobs_dir.iterdir() if p.is_dir() and not p.name.startswith(".")),
                                  key=lambda p: (p.stat().st_mtime_ns, p.name))
        except FileNotFoundError:
            request_dirs = []
        queued: list[Path] = []
        for request_dir in request_dirs:
            request_id = request_dir.name
            if not __import__("re").fullmatch(r"[A-Za-z0-9_-]{1,80}", request_id):
                continue
            status_file = request_dir / "status.json"
            status = None
            snapshot = _latest_snapshot(status_file)
            if snapshot is not None:
                try:
                    status = json.loads(snapshot.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    _atomic_json(status_file, {"status": "failed", "error": "invalid existing request status"})
                    continue
            if status and status.get("status") in {"complete", "failed", "cancelled"}:
                continue
            if not (request_dir / "job.json").is_file():
                _atomic_json(status_file, {"status": "failed", "error": "job.json missing"})
                continue
            queued.append(request_dir)
        if queued:
            request_dir = queued[0]
            try:
                request_dir.resolve().relative_to(jobs_dir.resolve())
            except ValueError:
                continue
            request_id = request_dir.name
            output_dir = request_dir / "output"
            result_path = output_dir / "result.json"
            if output_dir.exists() and result_path.is_file():
                try:
                    result = json.loads(result_path.read_text(encoding="utf-8"))
                    _atomic_json(request_dir / "status.json", {
                        "status": "complete", "request_id": request_id,
                        "output_dir": str(output_dir),
                        "labels_sha256": result.get("labels_sha256"),
                        "probe_count": result.get("probe_count"),
                        "valid_probe_count": result.get("valid_probe_count"),
                        "recovered_published_result": True,
                    })
                    continue
                except (OSError, json.JSONDecodeError):
                    _atomic_json(request_dir / "status.json", {
                        "status": "failed", "request_id": request_id,
                        "error": "published output has invalid result.json"})
                    continue
            _atomic_json(request_dir / "status.json", {
                "status": "running", "request_id": request_id,
                "worker_pid": os.getpid(), "updated_unix_time": time.time(),
            })
            progress_path = request_dir / "progress.json"
            cancel_path = request_dir / "cancel"
            try:
                result = run_job(request_dir / "job.json", bundle_dir, output_dir,
                                 device_name, cancel_path, progress_path, batch_size,
                                 emit_console_events=False,
                                 loaded_bundle=loaded_bundle,
                                 loaded_bundle_seconds=bundle_load_seconds)
                _atomic_json(request_dir / "status.json", {
                    "status": "complete", "request_id": request_id,
                    "output_dir": str(output_dir),
                    "labels_sha256": result["labels_sha256"],
                    "probe_count": result["probe_count"],
                    "valid_probe_count": result["valid_probe_count"],
                    "elapsed_seconds": result["elapsed_seconds"],
                    "timing_seconds": result["timing_seconds"],
                    "atomic_output_dir_publish_seconds": result.get("atomic_output_dir_publish_seconds"),
                })
            except InterruptedError as exc:
                event = dict(CURRENT_PROGRESS or {})
                event.update({"event": "cancelled", "stage": "cancelled",
                              "done": int(event.get("done", 0)),
                              "total": int(event.get("total", 0)), "error": str(exc)})
                try:
                    _write_progress(progress_path, event)
                except OSError as publish_exc:
                    event["progress_publish_warning"] = str(publish_exc)
                _atomic_json(request_dir / "status.json", {
                    "status": "cancelled", "request_id": request_id, "error": str(exc),
                    "progress": event,
                })
            except Exception as exc:
                event = dict(CURRENT_PROGRESS or {})
                event.update({"event": "error", "stage": "failed",
                              "done": int(event.get("done", 0)),
                              "total": int(event.get("total", 0)), "error": str(exc)})
                try:
                    _write_progress(progress_path, event)
                except OSError as publish_exc:
                    event["progress_publish_warning"] = str(publish_exc)
                _atomic_json(request_dir / "status.json", {
                    "status": "failed", "request_id": request_id, "error": str(exc),
                    "progress": event,
                })
            _worker_status(root, "ready", bundle_sha256=bundle_sha,
                           candidate_id=bundle["candidate_id"],
                           seeds=[int(item["seed"]) for item in bundle["seeds"]],
                           active_request_id=None, queued_count=max(0, len(queued) - 1))
            continue
        if (root / "shutdown").exists():
            _worker_status(root, "stopped", bundle_sha256=bundle_sha)
            lock_path.unlink(missing_ok=True)
            return 0
        time.sleep(max(10, poll_interval_ms) / 1000.0)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--job", type=Path,
                      help="strict geometry-only JSON job exported by the MagicGI bake integration")
    mode.add_argument("--worker-dir", type=Path,
                      help="serve per-tile jobs from a fresh filesystem queue and keep the model resident")
    parser.add_argument("--bundle", type=Path, default=HERE.parent / "model")
    parser.add_argument("--out-dir", type=Path,
                        help="new output directory for single-job mode; must not already exist")
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--poll-interval-ms", type=int, default=100)
    parser.add_argument("--cancel-file", type=Path,
                        help="create this file to cancel; staged output is discarded and no result is published")
    parser.add_argument("--progress-file", type=Path,
                        help="atomically replaced JSON progress snapshot for UI polling")
    args = parser.parse_args(argv)
    try:
        if args.worker_dir is not None:
            if args.out_dir is not None or args.cancel_file is not None or args.progress_file is not None:
                raise InferenceError("worker mode uses per-request output/progress/cancel paths; omit those flags")
            if args.batch_size <= 0 or args.batch_size > 512 or args.poll_interval_ms <= 0:
                raise InferenceError("worker batch-size must be in [1,512] and poll interval must be positive")
            return run_worker(args.worker_dir, args.bundle, args.device,
                              args.batch_size, args.poll_interval_ms)
        if args.out_dir is None:
            raise InferenceError("--out-dir is required with --job")
        run_job(args.job, args.bundle, args.out_dir, args.device, args.cancel_file,
                args.progress_file, args.batch_size)
        return 0
    except InterruptedError as exc:
        event = dict(CURRENT_PROGRESS or {})
        event.update({"event": "cancelled", "stage": "cancelled", "done": int(event.get("done", 0)),
                      "total": int(event.get("total", 0)), "error": str(exc)})
        if args.progress_file:
            _write_progress(args.progress_file, event)
        print(json.dumps(event, ensure_ascii=False, sort_keys=True), file=sys.stderr, flush=True)
        return 130
    except (InferenceError, OSError, ValueError, KeyError, TypeError,
            json.JSONDecodeError, tm_GeometryError, r4_R4FeatureError) as exc:
        event = dict(CURRENT_PROGRESS or {})
        event.update({"event": "error", "stage": "failed", "done": int(event.get("done", 0)),
                      "total": int(event.get("total", 0)), "error": str(exc)})
        if args.progress_file:
            try:
                _write_progress(args.progress_file, event)
            except OSError:
                pass
        print(json.dumps(event, ensure_ascii=False, sort_keys=True), file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
