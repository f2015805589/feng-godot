"""GPU regression for the height and material groups delivered by the clipmap block atlas."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtclipmap-atlas-render-",
        project_name="VT clipmap atlas render tests",
        log_name="vtclipmapatlasrender.log",
        script="vt_clipmap_atlas_render.gd",
        marker="PASS clipmap atlas render",
        prefixes=("CLIPMAP_ATLAS_RENDER",),
        resolution="320x240",
        shots=True,
        timeout_run=600,
    ))
