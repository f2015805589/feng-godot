"""GPU regression: the far field's root pyramid must cover the visible field."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtrootcover-",
        script="vt_root_coverage.gd",
        marker="PASS far-field root pyramid covers the visible field",
        project_name="VT root coverage tests",
        log_name="vtrootcover.log",
        prefixes=("VTROOTCOVER",),
        shots=True,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
