"""Surface density regression: dense payload, coarse array, migration, render."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtdens-",
        project_name="Surface density tests",
        log_name="vtdens.log",
        script="vt_density.gd",
        marker="PASS surface density",
        resolution="320x240",
        shots=False,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
