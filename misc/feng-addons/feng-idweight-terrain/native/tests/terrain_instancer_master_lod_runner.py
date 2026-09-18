"""Instancer counter regression: the count follows the master LOD when a setting moves it."""
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
        fixture_prefix="terrain-instancer-lod-",
        project_name="Instancer master LOD tests",
        log_name="instancer_master_lod.log",
        script="terrain_instancer_master_lod.gd",
        marker="PASS the instance count follows the master LOD",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
