"""Graphical codec/upload regression with an isolated physical addon copy."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-codecs-",
        project_name="Compression tests",
        log_name="compression.log",
        script="texture_compression.gd",
        marker="PASS all array compression formats",
        resolution="320x240",
        timeout_import=180,
        timeout_run=180,
        shots=False,
        prefixes=('CODEC=',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
