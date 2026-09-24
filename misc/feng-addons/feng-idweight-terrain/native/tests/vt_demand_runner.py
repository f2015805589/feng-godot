"""Per-page virtual texture demand regression."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtdemand-",
        project_name="VT demand tests",
        log_name="vtdemand.log",
        script="vt_demand.gd",
        marker="PASS virtual texture per-page demand",
        resolution="320x240",
        shots=False,
        prefixes=('VTDEMAND',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
