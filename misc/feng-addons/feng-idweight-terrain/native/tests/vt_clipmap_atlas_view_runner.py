"""Evidence runner for the clipmap atlas debug view.

`vt_clipmap_atlas_view.gd` renders `vt_clipmap_preview.gd` at 1080p with an atlas built and saves the
PNG, so "the debug shows the atlas's region" is a picture. It also asserts the snapshot the view draws
from carries the layout (one rect a slot, nine cells a unit) and that the render is not an empty panel.
"""

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
        fixture_prefix="terrain-vtclipmapatlasview-",
        project_name="Clipmap atlas debug view",
        log_name="vtclipmapatlasview.log",
        script="vt_clipmap_atlas_view.gd",
        marker="PASS clipmap atlas debug view",
        prefixes=("VT_CLIPMAP_ATLAS_VIEW",),
        resolution=args.resolution,
        shots=True,
        timeout_import=180,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
