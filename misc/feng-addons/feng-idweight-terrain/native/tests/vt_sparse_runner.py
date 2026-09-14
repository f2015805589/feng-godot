"""Far-field sparse virtual texture regression: world page grid, borders, mip chain."""
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
        fixture_prefix="terrain-vtsvt-",
        project_name="Sparse VT tests",
        log_name="vtsvt.log",
        script="vt_sparse.gd",
        marker="PASS sparse virtual texture far field",
        resolution="320x240",
        shots=False,
        prefixes=('VTSVT',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
