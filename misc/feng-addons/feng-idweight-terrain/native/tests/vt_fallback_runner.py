"""GPU regression for strict AVT/SVT material misses and cached far pages."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtfallback-",
        project_name="VT fallback tests",
        log_name="vtfallback.log",
        script="vt_fallback.gd",
        marker="PASS strict AVT/SVT material residency GPU regression",
        prefixes=("VT_FALLBACK",),
        resolution="320x240",
        shots=True,
        timeout_run=360,
    ))
