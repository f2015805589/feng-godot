"""GPU regression for the delivery matrix: what a configuration assembles, and what it does not."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtdelivery-",
        project_name="VT delivery tests",
        log_name="vtdelivery.log",
        script="vt_delivery.gd",
        marker="PASS delivery matrix assembly",
        prefixes=("VT_DELIVERY",),
        resolution="320x240",
        timeout_run=360,
    ))
