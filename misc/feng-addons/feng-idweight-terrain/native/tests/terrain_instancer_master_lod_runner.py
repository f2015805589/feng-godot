"""Instancer counter regression: the count follows the master LOD when a setting moves it."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-instancer-lod-",
        project_name="Instancer master LOD tests",
        log_name="instancer_master_lod.log",
        script="terrain_instancer_master_lod.gd",
        marker="PASS the instance count follows the master LOD",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
