"""Surface virtual texture GPU feedback: R32_UInt demand pass with async readback."""
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
        fixture_prefix="terrain-vtfb-",
        project_name="VT feedback tests",
        log_name="vtfb.log",
        script="vt_feedback.gd",
        marker="PASS virtual texture GPU feedback",
        resolution="320x240",
        shots=False,
        prefixes=('FEEDBACK',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
