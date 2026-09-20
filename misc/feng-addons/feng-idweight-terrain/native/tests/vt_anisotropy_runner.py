"""GPU regression for AVT anisotropic mip selection at a grazing view."""

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtaniso-",
        project_name="VT anisotropic footprint tests",
        log_name="vtanisotropy.log",
        script="vt_anisotropy.gd",
        marker="PASS AVT anisotropic footprint keeps the fine page at grazing angles",
        prefixes=("VT_ANISO",),
        extra_scripts=(("vt_adaptive.gd", "vt_adaptive_base.gd"),),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
