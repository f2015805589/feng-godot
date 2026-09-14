"""Real AVT GPU material baking and SVT persistence integration."""
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
        fixture_prefix="terrain-vtmaterial-",
        project_name="VT render tests",
        log_name="vtrender.log",
        script="vt_render.gd",
        marker="PASS AVT material and SVT persistence integration",
        resolution="320x240",
        shots=True,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
