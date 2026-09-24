"""Camera turn painting and CPU budget: far-field misses and the two 0.1 ms peaks."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
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
