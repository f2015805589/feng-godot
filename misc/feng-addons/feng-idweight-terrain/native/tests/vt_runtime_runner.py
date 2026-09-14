"""Virtual texture runtime regression: indirection, atlas and slot allocator on the GPU."""
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
        fixture_prefix="terrain-vt-",
        project_name="VT runtime tests",
        log_name="vt.log",
        script="vt_runtime.gd",
        marker="PASS virtual texture runtime",
        resolution="320x240",
        shots=False,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
