"""GPU regression for the complete 48-bit BC3/BC4 alpha index stream."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtbc3alpha-",
        project_name="VT BC3 alpha tests",
        log_name="vtbc3alpha.log",
        script="vt_bc3_alpha.gd",
        marker="PASS GPU BC3 alpha preserves the full 48-bit index stream",
        prefixes=("VT_BC3_ALPHA",),
        resolution="320x240",
        shots=False,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
