"""Run the focused dense AVT GPU regression."""

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
        fixture_prefix="terrain-vtavtdense-",
        script="vt_avt_dense.gd",
        marker="PASS dense AVT sector tiers, full local mip chain, sparse fallback, bounded residency and camera reuse",
        project_name="Dense AVT contract tests",
        log_name="vtavtdense.log",
        prefixes=("VT_AVT_DENSE",),
        extra_scripts=(("vt_adaptive.gd", "vt_avt_dense_base.gd"),),
        resolution="320x240",
        timeout_import=120,
        timeout_run=120,
    )


if __name__ == "__main__":
    raise SystemExit(main())
