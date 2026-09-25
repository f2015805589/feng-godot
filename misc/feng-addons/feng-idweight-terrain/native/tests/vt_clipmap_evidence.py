"""Run clipmap render/settings probes and preserve their logs and PNGs in a named evidence folder."""

from __future__ import annotations

import argparse
import io
import re
import shutil
from contextlib import redirect_stdout
from pathlib import Path

from fixture import ROOT, runner_parser, run_script_test


PROBES = {
    "settings": {
        "prefix": "terrain-vtclipmap-",
        "script": "vt_clipmap.gd",
        "project": "VT clipmap settings evidence",
        "log": "vtclipmap.log",
        "marker": "PASS clipmap ring",
        "prefixes": ("VT_CLIPMAP",),
        "shots": False,
        "timeout": 360,
        "extra": (),
    },
    "render": {
        "prefix": "terrain-vtclipmap-render-",
        "script": "vt_clipmap_render.gd",
        "project": "VT clipmap render evidence",
        "log": "vtclipmaprender.log",
        "marker": "PASS clipmap height arm and material arm",
        "prefixes": ("VT_CLIPMAP_RENDER", "CLIPMAP_MATERIAL"),
        "shots": True,
        "timeout": 900,
        "extra": (("vt_adaptive.gd", "vt_probe_base.gd"),),
    },
    "layer": {
        "prefix": "terrain-vtclipmaplayer-",
        "script": "vt_clipmap_layer.gd",
        "project": "VT clipmap layer 1080p evidence",
        "log": "vtclipmaplayer.log",
        "marker": "PASS clipmap layer implementations evidence",
        "prefixes": ("CLIPMAP_LAYER",),
        "shots": True,
        "timeout": 1200,
        "extra": (("vt_adaptive.gd", "vt_probe_base.gd"),),
    },
    "height-sweep": {
        "prefix": "terrain-vtclipmapheightsweep-",
        "script": "vt_clipmap_height_sweep.gd",
        "project": "VT clipmap height resolution sweep",
        "log": "vtclipmapheightsweep.log",
        "marker": "PASS clipmap height resolution sweep",
        "prefixes": ("CLIPMAP_HEIGHT_SWEEP",),
        "shots": True,
        "timeout": 1200,
        "extra": (),
    },
}


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--probe", choices=sorted(PROBES), required=True)
    parser.add_argument("--evidence-dir", type=Path,
                        default=Path(r"F:\godot\auto-work\clipmap-perf2-evidence"))
    parser.add_argument("--label", required=True,
                        help="new evidence subdirectory name")
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--native-library", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label):
        parser.error("--label may contain only letters, numbers, hyphens and underscores")
    evidence_run = (args.evidence_dir.resolve() / args.probe / args.label)
    if evidence_run.exists():
        parser.error(f"evidence folder already exists; choose a fresh --label: {evidence_run}")
    evidence_run.mkdir(parents=True)
    spec = PROBES[args.probe]
    transcript = io.StringIO()
    fixture_path: Path | None = None
    result = 1
    try:
        with redirect_stdout(transcript):
            result = run_script_test(
                fixture_prefix=spec["prefix"],
                project_name=spec["project"],
                log_name=spec["log"],
                script=spec["script"],
                marker=spec["marker"],
                prefixes=spec["prefixes"],
                extra_scripts=spec["extra"],
                editor=args.editor,
                driver=args.driver,
                resolution=args.resolution,
                shots=spec["shots"],
                timeout_import=180,
                timeout_run=spec["timeout"],
                native_library=args.native_library,
            )
    finally:
        output = transcript.getvalue()
        match = re.search(r"^FIXTURE=(.+)$", output, re.MULTILINE)
        if match:
            fixture_path = Path(match.group(1)).resolve()
            fixture_root = (ROOT / "bin").resolve()
            if fixture_path.parent != fixture_root or not fixture_path.name.startswith(spec["prefix"]):
                raise RuntimeError(f"refusing to copy or remove an unexpected fixture: {fixture_path}")
            log = fixture_path / spec["log"]
            if log.is_file():
                shutil.copy2(log, evidence_run / log.name)
            shots = fixture_path / "shots"
            if shots.is_dir():
                shutil.copytree(shots, evidence_run / "shots")
            shutil.rmtree(fixture_path)
        (evidence_run / "runner.stdout.log").write_text(output, encoding="utf-8")
    print(transcript.getvalue(), end="")
    print(f"EVIDENCE={evidence_run}")
    print(f"FIXTURE_CLEANED={fixture_path is not None and not fixture_path.exists()}")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
