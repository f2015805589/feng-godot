"""Measure the near field's delivered texel density at a gameplay view."""

from __future__ import annotations

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--resolution", default="1920x1080")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtneardensity-",
        script="vt_near_density.gd",
        marker="PASS near field delivers the density its view asks for",
        project_name="Near field density diagnosis",
        log_name="vtnearthdensity.log",
        prefixes=("NEAR_DENSITY",),
        extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
        resolution=args.resolution,
        timeout_import=180,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
