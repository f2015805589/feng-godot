"""Atlas format change keeps the page pool regression."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtfmt-",
        project_name="VT format change tests",
        log_name="vtfmt.log",
        script="vt_format.gd",
        marker="PASS virtual texture format change keeps the page pool",
        resolution="320x240",
        shots=False,
        prefixes=('VTFMT',),
        # The regression this test exists for: a property change that reports resident
        # pages being released, which means the pool was rebuilt behind the caller's back.
        forbidden=("resident pages were released",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
