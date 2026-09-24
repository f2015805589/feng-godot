"""GPU regression for camera-visible AVT focus and nearest SVT page demand."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtvisibility-",
        project_name="VT visibility tests",
        log_name="vtvisibility.log",
        script="vt_visibility.gd",
        marker="PASS camera-visible AVT focus and nearest SVT page demand",
        prefixes=("VT_VISIBILITY",),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    ))
