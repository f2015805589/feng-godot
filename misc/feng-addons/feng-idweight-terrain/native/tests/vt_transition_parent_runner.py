"""GPU regression for AVT fade transitions over a missing direct parent."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vttransition-",
        project_name="VT transition parent tests",
        log_name="vttransitionparent.log",
        script="vt_transition_parent.gd",
        marker="PASS AVT transition skips a missing direct parent while strict fine misses stay diagnostic",
        prefixes=("VT_TRANSITION_PARENT",),
        extra_scripts=(("vt_adaptive.gd", "vt_adaptive_base.gd"),),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
