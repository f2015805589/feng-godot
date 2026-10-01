"""Preserve density-aware painted R16 materials across region merge/split."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-region-resize-surface-",
        project_name="Region resize surface tests",
        log_name="region_resize_surface.log",
        script="terrain_region_resize_surface.gd",
        marker="PASS region resizing preserves authored R16 surface density and bytes",
        shots=False,
    ))
