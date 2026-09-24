"""Virtual texture runtime regression: indirection, atlas and slot allocator on the GPU."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vt-",
        project_name="VT runtime tests",
        log_name="vt.log",
        script="vt_runtime.gd",
        marker="PASS virtual texture runtime",
        resolution="320x240",
        shots=False,
        prefixes=(),
    )


if __name__ == "__main__":
    raise SystemExit(main())
