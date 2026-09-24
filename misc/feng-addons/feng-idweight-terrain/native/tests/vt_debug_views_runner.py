"""Editor-facing regression for the delivery debug views: their order, their gate and their drawing."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtdebugviews-",
        project_name="VT delivery debug views",
        log_name="vtdebugviews.log",
        script="vt_debug_views.gd",
        marker="PASS delivery debug views",
        resolution="480x480",
        prefixes=("VT_DEBUG",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
