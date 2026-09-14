"""Atlas format change keeps the page pool regression."""
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
        fixture_prefix="terrain-vtfmt-",
        project_name="VT format change tests",
        log_name="vtfmt.log",
        script="vt_format.gd",
        marker="PASS virtual texture format change keeps the page pool",
        resolution="320x240",
        shots=False,
        prefixes=('VTFMT',),
        # The regression this test exists for: a property change that reports resident
        # pages being released, which means the pool was rebuilt behind the caller's back.
        forbidden=("resident pages were released",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
