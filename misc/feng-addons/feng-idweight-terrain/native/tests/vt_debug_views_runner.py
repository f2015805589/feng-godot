"""Editor-facing regression for the delivery debug views: their order, their gate and their drawing."""
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
        fixture_prefix="terrain-vtdebugviews-",
        project_name="VT delivery debug views",
        log_name="vtdebugviews.log",
        script="vt_debug_views.gd",
        marker="PASS delivery debug views",
        resolution="480x480",
        prefixes=("VT_DEBUG",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
