"""Per-page virtual texture demand regression."""
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
        fixture_prefix="terrain-vtdemand-",
        project_name="VT demand tests",
        log_name="vtdemand.log",
        script="vt_demand.gd",
        marker="PASS virtual texture per-page demand",
        resolution="320x240",
        shots=False,
        prefixes=('VTDEMAND',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
