"""GPU regression for the far-field distance -> mip table."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtmipbands-",
        project_name="VT mip band tests",
        log_name="vtmipbands.log",
        script="vt_mip_bands.gd",
        marker="PASS far-field distance -> mip bands are produced, resident and stable",
        prefixes=("VT_MIP_BANDS",),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    ))
