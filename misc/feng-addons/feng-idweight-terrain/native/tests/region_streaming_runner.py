"""Region chunk streaming regression with an isolated physical addon copy."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-streaming-",
        project_name="Region streaming tests",
        log_name="streaming.log",
        script="region_streaming.gd",
        marker="PASS region streaming",
        resolution="320x240",
        shots=False,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
