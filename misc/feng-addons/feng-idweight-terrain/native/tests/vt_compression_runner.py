"""Atlas compression resolution regression for the material page arrays."""
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
        fixture_prefix="terrain-vtcomp-",
        project_name="VT compression tests",
        log_name="vtcomp.log",
        script="vt_compression.gd",
        marker="PASS virtual texture atlas compression resolution",
        resolution="320x240",
        shots=False,
        prefixes=('VTCOMPRESSION',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
