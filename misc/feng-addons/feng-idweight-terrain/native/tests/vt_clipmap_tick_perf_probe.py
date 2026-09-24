"""Record the near-material clipmap's real per-physics-tick cost under continuous movement."""

from __future__ import annotations

import argparse
import io
import re
import shutil
from contextlib import redirect_stdout
from pathlib import Path

from fixture import ROOT, runner_parser, run_script_test


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--native-library", type=Path)
    parser.add_argument("--evidence-dir", type=Path,
                        default=Path(r"F:\godot\auto-work\clipmap-perf-evidence\task-a-continuous-tick"))
    parser.add_argument("--label", required=True,
                        help="new evidence subdirectory name, such as after-batch-poll-01")
    args = parser.parse_args()
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
                fixture_prefix="terrain-vtclipmaptickperf-",
                project_name="Clipmap continuous tick performance evidence",
                log_name="vtclipmaptickperf.log",
                script="vt_clipmap_tick_perf.gd",
                marker="PASS clipmap continuous tick perf",
                prefixes=("CLIPMAP_TICK",),
                extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
                editor=args.editor,
                driver=args.driver,
                resolution=args.resolution,
                timeout_import=180,
                timeout_run=900,
                native_library=args.native_library,
            )
    finally:
        transcript = run_output.getvalue()
        match = re.search(r"^FIXTURE=(.+)$", transcript, re.MULTILINE)
        if match:
            fixture_path = Path(match.group(1)).resolve()
            fixture_root = (ROOT / "bin").resolve()
            if fixture_path.parent != fixture_root or not fixture_path.name.startswith(
                    "terrain-vtclipmaptickperf-"):
                raise RuntimeError(f"refusing to copy or remove an unexpected fixture: {fixture_path}")
            log = fixture_path / "vtclipmaptickperf.log"
            if log.is_file():
                shutil.copy2(log, evidence_run / log.name)
            shutil.rmtree(fixture_path)
        (evidence_run / "runner.stdout.log").write_text(transcript, encoding="utf-8")

    print(transcript, end="")
    print(f"EVIDENCE={evidence_run}")
    print(f"FIXTURE_CLEANED={fixture_path is not None and not fixture_path.exists()}")
    return result


if __name__ == "__main__":
	raise SystemExit(main())
