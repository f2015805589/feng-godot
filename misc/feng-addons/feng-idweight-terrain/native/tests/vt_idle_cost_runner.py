"""Settled-view cost regression: a static camera must be near free."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
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
