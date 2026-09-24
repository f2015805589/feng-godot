"""Run the persisted-material SVT coverage regression with a real GPU renderer."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vt-svt-coverage-",
        project_name="SVT coverage tests",
        log_name="vtsvtcoverage.log",
        script="vt_svt_coverage.gd",
        marker="PASS persisted SVT covers visible non-AVT regions under eight-page shared-pool pressure",
        prefixes=("VTSVTCOVER",),
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
        resolution="320x240",
        shots=True,
        timeout_run=900,
    ))
