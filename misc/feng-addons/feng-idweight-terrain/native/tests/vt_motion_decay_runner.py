"""A TAA camera turn followed by enough idle frames to exercise float underflow."""
import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    raise SystemExit(run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-motion-decay-",
        project_name="VT motion decay regression",
        log_name="motion_decay.log",
        script="vt_motion_decay.gd",
        marker="PASS stopped TAA camera motion prediction decays without invalid rotation axes",
        resolution="320x240",
        timeout_run=120,
    ))
