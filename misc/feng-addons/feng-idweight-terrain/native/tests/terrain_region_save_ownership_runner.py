"""Ensure quantized region saving never mutates the live shared height image."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-region-save-ownership-",
        project_name="Region save ownership tests",
        log_name="region_save_ownership.log",
        script="terrain_region_save_ownership.gd",
        marker="PASS 16-bit region save preserves live shared height images",
        shots=False,
    ))
