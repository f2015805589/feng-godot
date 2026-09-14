"""Virtual texture demand cost: per-page production time at the shipped defaults."""
import argparse
from pathlib import Path

from fixture import ROOT, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtperf-",
        project_name="VT perf tests",
        log_name="vtperf.log",
        script="vt_perf.gd",
        marker="PASS virtual texture demand cost",
        resolution="320x240",
        shots=False,
        prefixes=('VTPERF',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
