"""Instancer release regression: a region that leaves the data releases its instances."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-instancer-release-",
        project_name="Instancer release tests",
        log_name="instancer_release.log",
        script="terrain_instancer_release.gd",
        marker="PASS unloaded or removed regions release their instances",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
