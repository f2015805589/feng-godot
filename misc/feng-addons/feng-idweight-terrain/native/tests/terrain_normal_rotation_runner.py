"""GPU regression for world-normal invariance under camera roll."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-normal-rotation-",
        project_name="Terrain normal rotation tests",
        log_name="terrain_normal_rotation.log",
        script="terrain_normal_rotation.gd",
        marker="PASS terrain world normals and fixed-light shading are invariant to camera roll",
        prefixes=("TERRAIN_NORMAL_ROTATION",),
        resolution="321x241",
        shots=True,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
