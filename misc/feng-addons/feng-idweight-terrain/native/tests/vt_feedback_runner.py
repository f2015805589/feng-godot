"""Surface virtual texture GPU feedback: R32_UInt demand pass with async readback."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtfb-",
        project_name="VT feedback tests",
        log_name="vtfb.log",
        script="vt_feedback.gd",
        marker="PASS virtual texture GPU feedback",
        resolution="320x240",
        shots=False,
        prefixes=('FEEDBACK',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
