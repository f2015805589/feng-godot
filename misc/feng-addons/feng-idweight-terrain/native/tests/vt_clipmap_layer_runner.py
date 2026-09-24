"""Evidence runner for the *unified* clipmap layer: one delivery, two implementations.

`vt_clipmap.gd` drives the LOD ring through the mechanism's own entry and `vt_clipmap_atlas.gd` used
to drive the atlas through a second entry; after the task that made the two one delivery with an
implementation selector, there is one entry - `debug_update_vt_clipmap()` - and it drives whichever
implementation `vt_clipmap_implementation` names. This runner drives `vt_clipmap_layer.gd`, which
renders the **same scene with the same camera** once per implementation at 1080p, reads the layer's own
density/reach curve and the debug schema in both states, and saves both frames plus the region-array
frame the two are compared against.

`CLIPMAP_LAYER` lines carry the density ladder, the schema and the cost readings; the pictures land in
the fixture's `shots/` directory.
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
        fixture_prefix="terrain-vtclipmaplayer-",
        project_name="Clipmap layer implementations evidence",
        log_name="vtclipmaplayer.log",
        script="vt_clipmap_layer.gd",
        marker="PASS clipmap layer implementations evidence",
        prefixes=("CLIPMAP_LAYER",),
        extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
        resolution=args.resolution,
        shots=True,
        timeout_import=180,
        timeout_run=1200,
    )


if __name__ == "__main__":
    raise SystemExit(main())
