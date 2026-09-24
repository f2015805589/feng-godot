"""P0: report the far-field world mip cap's change history under a scripted view.

The probe asserts nothing about the numbers - it prints them. See
`vt_cap_probe.gd` and `docs/vt_reference_avt_alignment.md` section 7.
"""

from __future__ import annotations

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vt-cap-probe-",
        script="vt_cap_probe.gd",
        marker="VTCAP summary",
        project_name="VT mip cap probe",
        log_name="vtcapprobe.log",
        prefixes=("VTCAP",),
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
