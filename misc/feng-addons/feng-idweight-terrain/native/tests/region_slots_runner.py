"""Region layer slot regression: rendered multi-region layers + no array churn."""
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
        fixture_prefix="terrain-slots-",
        project_name="Region slot tests",
        log_name="slots.log",
        script="region_slots.gd",
        marker="PASS region layer slots",
        resolution="480x480",
        shots=False,
        prefixes=('SLOTS',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
