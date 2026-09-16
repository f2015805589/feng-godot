"""Recovery of a material page whose content is lost while the view is still."""
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
        fixture_prefix="terrain-vtrecover-",
        project_name="VT page recovery tests",
        log_name="vtrecover.log",
        script="vt_recovery.gd",
        marker="PASS a page lost under a still view is produced again",
        resolution="320x240",
        shots=False,
        prefixes=('VTRECOVERY',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
