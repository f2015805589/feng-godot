"""Atlas compression resolution regression for the material page arrays."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtcomp-",
        project_name="VT compression tests",
        log_name="vtcomp.log",
        script="vt_compression.gd",
        marker="PASS virtual texture atlas compression resolution",
        resolution="320x240",
        shots=False,
        prefixes=('VTCOMPRESSION',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
