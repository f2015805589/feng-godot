"""Region layer slot regression: rendered multi-region layers + no array churn."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-slots-",
        project_name="Region slot tests",
        log_name="slots.log",
        script="region_slots.gd",
        marker="PASS region layer slots",
        resolution="480x480",
        shots=False,
        prefixes=('SLOTS',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
