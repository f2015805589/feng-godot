"""Instancer refresh regression: update_mmis() with no arguments refreshes every region."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-instancer-refresh-",
        project_name="Instancer refresh tests",
        log_name="instancer_refresh.log",
        script="terrain_instancer_refresh.gd",
        marker="PASS update_mmis() with no arguments refreshes every region",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
