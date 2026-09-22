"""P0: report the far-field world mip cap's change history under a scripted view.

The probe asserts nothing about the numbers - it prints them. See
`vt_cap_probe.gd` and `docs/vt_reference_avt_alignment.md` section 7.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
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
