"""Evidence runner for the near-material Clipmap *load* measurement.

The user's report is that the near material group on `Clipmap` has a very long load time. This runs
`vt_clipmap_load.gd`, which drives the user's own path - near material on `Clipmap`, 256 texels,
four rings, `base_world = 256`, shipped budget - and records the clipmap phase's cost, the detail
layer's cost, the produced channel texels and the published bytes for every tick of the first fill,
the detail fill and a scroll. The `CLIPMAP_LOAD` lines are the table; the `CLIPMAP_LOAD_ROW` lines
are the per-tick timeline.

It is a *mechanism* test as well as a measurement: when the build carries the atlas
(`has_vt_clipmap_atlas()`), the same windows are run against the atlas's own counters, so the
before/after comparison comes from one script on one binary.
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
        fixture_prefix="terrain-vtclipmapload-",
        project_name="Clipmap near material load evidence",
        log_name="vtclipmapload.log",
        script="vt_clipmap_load.gd",
        marker="PASS clipmap load evidence",
        prefixes=("CLIPMAP_LOAD",),
        extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
        resolution=args.resolution,
        timeout_import=180,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
