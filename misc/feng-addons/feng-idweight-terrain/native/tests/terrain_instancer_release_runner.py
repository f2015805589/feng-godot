"""Instancer release regression: a region that leaves the data releases its instances."""
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
        fixture_prefix="terrain-instancer-release-",
        project_name="Instancer release tests",
        log_name="instancer_release.log",
        script="terrain_instancer_release.gd",
        marker="PASS unloaded or removed regions release their instances",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
