"""Surface virtual texture page production regression."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtsurf-",
        project_name="Surface VT tests",
        log_name="vtsurf.log",
        script="vt_surface.gd",
        marker="PASS surface virtual texture page production",
        resolution="320x240",
        shots=False,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
