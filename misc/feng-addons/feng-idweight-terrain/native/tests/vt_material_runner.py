"""Real AVT GPU material baking and SVT persistence integration."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtmaterial-",
        project_name="VT material tests",
        log_name="vtmaterial.log",
        script="vt_material.gd",
        marker="PASS AVT material and SVT persistence integration",
        resolution="320x240",
        shots=True,
        prefixes=("VT_FINAL_STATS", "VTSVT"),
        # vt_material.gd extends the shared base, which has to exist inside the fixture.
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
    )


if __name__ == "__main__":
    raise SystemExit(main())
