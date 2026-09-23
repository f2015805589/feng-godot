"""Regression runner for the clipmap *atlas* mechanism.

`vt_clipmap_atlas.gd` drives `Terrain3DClipmapAtlas` through the mechanism's own entry
(`debug_update_vt_clipmap_atlas()`) with every delivery cell `Direct`, exactly as
`vt_clipmap_runner.py` drives the ring: the structure, the packing, the block-granular upload, the
rolling counters and the anti-gap identity are what it asserts, and none of them depends on a
rendering.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--resolution", default="320x240")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtclipmapatlas-",
        project_name="Clipmap atlas mechanism",
        log_name="vtclipmapatlas.log",
        script="vt_clipmap_atlas.gd",
        marker="PASS clipmap atlas",
        prefixes=("VT_CLIPMAP_ATLAS",),
        resolution=args.resolution,
        timeout_import=180,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
