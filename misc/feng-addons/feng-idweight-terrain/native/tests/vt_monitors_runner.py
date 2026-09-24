"""The terrain's `terrain/` monitors: names, types, live readings and withdrawal."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtmonitors-",
        project_name="VT monitor tests",
        log_name="vtmonitors.log",
        script="vt_monitors.gd",
        marker="PASS terrain cost is published under a terrain/ keyword",
        resolution="320x240",
        shots=False,
        prefixes=('VTMONITORS',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
