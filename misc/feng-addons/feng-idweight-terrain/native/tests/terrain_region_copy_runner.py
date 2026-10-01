"""Terrain region ownership regression, including blank/partially loaded resources."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-region-copy-",
        project_name="Terrain region copy tests",
        log_name="region_copy.log",
        script="terrain_region_copy.gd",
        marker="PASS terrain region copy preserves metadata and resource ownership",
        resolution="320x240",
        shots=False,
    )


if __name__ == "__main__":
    raise SystemExit(main())
