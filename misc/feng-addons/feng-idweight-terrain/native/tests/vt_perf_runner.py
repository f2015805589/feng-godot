"""Virtual texture demand cost: per-page production time at the shipped defaults."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtperf-",
        project_name="VT perf tests",
        log_name="vtperf.log",
        script="vt_perf.gd",
        marker="PASS virtual texture demand cost",
        resolution="320x240",
        shots=False,
        prefixes=('VTPERF',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
