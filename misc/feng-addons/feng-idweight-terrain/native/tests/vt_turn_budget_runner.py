"""Camera turn painting and CPU budget: far-field misses and the two 0.1 ms peaks."""
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
        fixture_prefix="terrain-turbudget-",
        project_name="VT turn budget tests",
        log_name="turbudget.log",
        script="vt_turn_budget.gd",
        marker="PASS camera turn painting and CPU budget",
        resolution="1280x720",
        shots=True,
        prefixes=("VT_TURNBUDGET",),
        timeout_run=420,
    )


if __name__ == "__main__":
    raise SystemExit(main())
