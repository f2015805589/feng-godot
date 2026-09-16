"""The terrain's `terrain/` monitors: names, types, live readings and withdrawal."""
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
        fixture_prefix="terrain-vtmonitors-",
        project_name="VT monitor tests",
        log_name="vtmonitors.log",
        script="vt_monitors.gd",
        marker="PASS terrain cost is published under a terrain/ keyword",
        resolution="320x240",
        shots=False,
        prefixes=('VTMONITORS',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
