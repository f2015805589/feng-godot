"""A TAA camera turn followed by enough idle frames to exercise float underflow."""

from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-motion-decay-",
        project_name="VT motion decay regression",
        log_name="motion_decay.log",
        script="vt_motion_decay.gd",
        marker="PASS stopped TAA camera motion prediction decays without invalid rotation axes",
        resolution="320x240",
        timeout_run=120,
    ))
