"""GPU regression for AVT fade transitions over a missing direct parent."""

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vttransition-",
        project_name="VT transition parent tests",
        log_name="vttransitionparent.log",
        script="vt_transition_parent.gd",
        marker="PASS AVT transition skips a missing direct parent while strict fine misses stay diagnostic",
        prefixes=("VT_TRANSITION_PARENT",),
        extra_scripts=(("vt_adaptive.gd", "vt_adaptive_base.gd"),),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
