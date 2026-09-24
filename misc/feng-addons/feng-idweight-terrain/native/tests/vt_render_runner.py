"""Surface virtual texture render integration: equivalence with the array path."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtrender-",
        project_name="VT render tests",
        log_name="vtrender.log",
        script="vt_render.gd",
        marker="PASS surface virtual texture render integration",
        resolution="320x240",
        shots=True,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
