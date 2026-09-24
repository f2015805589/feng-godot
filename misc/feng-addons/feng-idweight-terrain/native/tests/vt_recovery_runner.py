"""Recovery of a material page whose content is lost while the view is still."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtrecover-",
        project_name="VT page recovery tests",
        log_name="vtrecover.log",
        script="vt_recovery.gd",
        marker="PASS a page lost under a still view is produced again",
        resolution="320x240",
        shots=False,
        prefixes=('VTRECOVERY',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
