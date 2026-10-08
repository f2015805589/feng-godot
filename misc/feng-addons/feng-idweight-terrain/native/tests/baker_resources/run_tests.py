"""Run the actual baker construction/ownership methods against injected GPU failures.

The production structs and complete methods are extracted unchanged, so both the
baseline and current source can be tested without Godot or a graphics context.
The boundary double models RID dependencies and rejects leaks or double frees;
it does not compile GLSL, record GPU work, or validate thread scheduling.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile


def extract(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return source[start:cursor + 1]
    raise ValueError(f"Unclosed production definition: {signature}")


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=here.parent.parent / "src")
    parser.add_argument("--case", choices=("all", "encoder_failure", "stale_readback", "queue_lock_order"), default="all")
    args = parser.parse_args()
    header = (args.source_dir / "terrain_3d_surface_baker.h").read_text()
    sources = {suffix: (args.source_dir / f"terrain_3d_surface_baker{suffix}.cpp").read_text()
               for suffix in ("", "_bundle", "_pipelines", "_storage")}
    methods = []
    groups = {
        "": ("bool _acquire_device", "bool _ensure_resources"),
        "_bundle": ("void _collect_bundle_rids", "void _free_rids", "void _free_bundle",
                    "uint64_t _take_resources", "bool _adopt_grown_pages", "void _adopt_bundle",
                    "bool _create_bake_core_resources", "bool _create_page_resources"),
        "_pipelines": ("bool _compile_pipeline", "bool _compile_encode_pipeline",
                       "bool _compile_source_upload_pipeline", "bool _rebuild_uniform_set"),
        "_storage": ("RID _staging_rd_of", "bool _tier_uses_sampled", "uint8_t _tier_channel_mask",
                     "bool _any_tier_uses_sampled", "bool _staging_is_scratch", "RID _sampled_rd",
                     "bool _tier_channel_uses_sampled", "void _mark_encode_failed", "void _on_encode_readback"),
    }
    if "bool Terrain3DSurfaceBaker::_compile_compute_pipeline(" in sources["_pipelines"]:
        groups["_pipelines"] = ("bool _compile_compute_pipeline",) + groups["_pipelines"]
    if "void Terrain3DSurfaceBaker::_release_encode_page(" in sources["_storage"]:
        groups["_storage"] = ("void _release_encode_page",) + groups["_storage"]
    for suffix, signatures in groups.items():
        for signature in signatures:
            result, name = signature.split()
            methods.append(extract(sources[suffix], f"{result} Terrain3DSurfaceBaker::{name}("))
    with tempfile.TemporaryDirectory(prefix="feng-baker-resources-") as temporary:
        root = Path(temporary)
        (root / "baker_types.inc").write_text("\n\n".join(
            extract(header, f"struct {name} {{") + ";" for name in ("SampledSet", "ResourceBundle", "TierState", "EncodedLayer")))
        has_buffer_token = "const RID &p_buffer" in extract(sources["_storage"], "void Terrain3DSurfaceBaker::_on_encode_readback(")
        (root / "baker_features.inc").write_text(f"#define BAKER_READBACK_BUFFER_TOKEN {int(has_buffer_token)}\n")
        (root / "baker_methods.inc").write_text("\n\n".join(methods))
        binary = root / "baker_resources_test"
        subprocess.run([
            os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
            "-I", str(root), str(here / "baker_resources_test.cpp"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), args.case], check=True)


if __name__ == "__main__":
    main()
