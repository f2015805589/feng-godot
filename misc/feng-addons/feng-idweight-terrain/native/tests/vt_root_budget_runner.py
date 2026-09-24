"""Bounded SVT root and detail scheduler regression."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtroot-",
        project_name="VT root budget tests",
        log_name="vtroot.log",
        script="vt_root_budget.gd",
        marker="PASS bounded SVT root and detail scheduling",
        prefixes=("VTROOT",),
        resolution="320x240",
        timeout_run=300,
    ))
