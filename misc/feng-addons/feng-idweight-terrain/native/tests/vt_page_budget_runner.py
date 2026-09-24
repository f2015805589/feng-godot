"""Settings-clamp regression for the adaptive AVT page budget. See `vt_page_budget.gd`."""

from __future__ import annotations

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vt-page-budget-",
        script="vt_page_budget.gd",
        marker="PASS AVT page budget clamps and cross-constraints",
        project_name="VT page budget",
        log_name="vtpagebudget.log",
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
