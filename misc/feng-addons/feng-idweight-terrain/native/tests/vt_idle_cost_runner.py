"""Settled-view cost regression: a static camera must be near free."""
import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="vulkan")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtidle-cost-",
        script="vt_idle_cost.gd",
        marker="PASS a settled view costs almost nothing",
        project_name="VT idle cost tests",
        log_name="vtidle_cost.log",
        prefixes=("VT_IDLE_COST",),
        shots=False,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
