"""Regression runner for the clipmap *atlas* mechanism.

`vt_clipmap_atlas.gd` drives `Terrain3DClipmapAtlas` through the mechanism's one entry
(`debug_update_vt_clipmap()` with `vt_clipmap_implementation` naming the atlas) with every delivery
cell `Direct`, exactly as `vt_clipmap_runner.py` drives the ring: the structure, the packing, the
block-granular upload, the rolling counters and the anti-gap identity are what it asserts, and none
of them depends on a rendering.
"""

from __future__ import annotations

from fixture import runner_parser, run_script_test


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--resolution", default="320x240")
    args = parser.parse_args()
    return run_script_test(
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
