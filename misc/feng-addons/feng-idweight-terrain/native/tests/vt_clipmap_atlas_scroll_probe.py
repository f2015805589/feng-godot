"""1080p stress probe for stale Atlas slots during continuous focus movement.

The fixture is copied out to the requested evidence folder before its temporary ``bin/terrain-*``
directory is removed. Pass ``--native-library`` to pin a before or after DLL without replacing the
worktree's normal extension binary.
"""

from __future__ import annotations

import argparse
import io
import re
import shutil
from contextlib import redirect_stdout
from pathlib import Path

from fixture import ROOT, run_script_test, runner_parser


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--evidence-dir", type=Path,
                        default=Path(r"F:\godot\auto-work\clipmap-perf-evidence\task-c-atlas-scroll"))
    parser.add_argument("--label", required=True,
                        help="new evidence subdirectory name, such as baseline-01 or fixed")
    parser.add_argument("--native-library", type=Path,
                        help="extension DLL copied into the temporary fixture")
    parser.add_argument("--moves", type=int, default=12,
                        help="consecutive focus moves made while the one-block-per-tick queue drains")
    parser.add_argument("--move-step", type=float, default=64.0,
                        help="metres moved per tick; default is one 64 m Atlas block")
    parser.add_argument("--expect-zero-mismatch", action="store_true",
                        help="fail after capture if a current cell's wanted block differs from its slot block")
    args = parser.parse_args()

    if args.moves <= 0 or args.move_step <= 0:
        parser.error("--moves and --move-step must be positive")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label):
        parser.error("--label may contain only letters, numbers, hyphens and underscores")
    evidence_run = args.evidence_dir.resolve() / args.label
    if evidence_run.exists():
        parser.error(f"evidence folder already exists; choose a fresh --label: {evidence_run}")
    evidence_run.mkdir(parents=True)

    run_output = io.StringIO()
    fixture_path: Path | None = None
    result = 1
    try:
        with redirect_stdout(run_output):
            result = run_script_test(
                fixture_prefix="terrain-vtclipmap-atlas-scroll-",
                project_name="Clipmap Atlas continuous scroll evidence",
                log_name="vtclipmapatlasscroll.log",
                script="vt_clipmap_atlas_scroll.gd",
                marker="PASS clipmap atlas scroll probe",
                prefixes=("CLIPMAP_ATLAS_SCROLL",),
                editor=args.editor,
                driver=args.driver,
                native_library=args.native_library,
                env={
                    "CLIPMAP_ATLAS_SCROLL_LABEL": args.label,
                    "CLIPMAP_ATLAS_SCROLL_MOVES": str(args.moves),
                    "CLIPMAP_ATLAS_SCROLL_MOVE_STEP": str(args.move_step),
                    "CLIPMAP_ATLAS_SCROLL_EXPECT_ZERO": "1" if args.expect_zero_mismatch else "0",
                },
                resolution=args.resolution,
                shots=True,
                timeout_import=240,
                timeout_run=1200,
            )
    finally:
        transcript = run_output.getvalue()
        match = re.search(r"^FIXTURE=(.+)$", transcript, re.MULTILINE)
        if match:
            fixture_path = Path(match.group(1)).resolve()
            fixture_root = (ROOT / "bin").resolve()
            if fixture_path.parent != fixture_root or not fixture_path.name.startswith(
                    "terrain-vtclipmap-atlas-scroll-"):
                raise RuntimeError(f"refusing to copy or remove an unexpected fixture: {fixture_path}")
            log = fixture_path / "vtclipmapatlasscroll.log"
            if log.is_file():
                shutil.copy2(log, evidence_run / log.name)
            shots = fixture_path / "shots"
            if shots.is_dir():
                shutil.copytree(shots, evidence_run / "shots")
            shutil.rmtree(fixture_path)
        (evidence_run / "runner.stdout.log").write_text(transcript, encoding="utf-8")

    print(transcript, end="")
    print(f"EVIDENCE={evidence_run}")
    print(f"FIXTURE_CLEANED={fixture_path is not None and not fixture_path.exists()}")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
