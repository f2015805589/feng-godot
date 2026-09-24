"""GPU regression for the height group delivered by the clipmap ring."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtclipmap-render-",
        project_name="VT clipmap render tests",
        log_name="vtclipmaprender.log",
        script="vt_clipmap_render.gd",
        marker="PASS clipmap height arm",
        prefixes=("VT_CLIPMAP_RENDER",),
        resolution="320x240",
        shots=True,
        timeout_run=360,
    ))
