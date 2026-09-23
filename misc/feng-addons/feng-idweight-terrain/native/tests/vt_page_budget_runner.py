"""Settings-clamp regression for the adaptive AVT page budget. See `vt_page_budget.gd`."""

from __future__ import annotations

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vt-page-budget-",
        script="vt_page_budget.gd",
        marker="PASS AVT page budget clamps and cross-constraints",
        project_name="VT page budget",
        log_name="vtpagebudget.log",
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
