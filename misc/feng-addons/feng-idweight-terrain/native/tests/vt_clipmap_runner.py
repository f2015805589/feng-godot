"""GPU regression for the clipmap ring: its addressing, its strips, its budget and its content."""
from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtclipmap-",
        project_name="VT clipmap tests",
        log_name="vtclipmap.log",
        script="vt_clipmap.gd",
        marker="PASS clipmap ring",
        prefixes=("VT_CLIPMAP",),
        resolution="320x240",
        timeout_run=360,
    ))
