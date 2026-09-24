"""Acceptance test for the clipmap material path's delivered texel density.

The plan (`F:/godot/auto-work/plan_final.md`) accepts `vt_delivery_near_material = Clipmap` only
when the near ground a 1080p gameplay view samples actually delivers 1024 texels/m through the
shader. This runner drives `vt_clipmap_density.gd` at that pose. The feature does not exist yet, so
a run before the merge is expected to fail; the failure lines say which half is missing and every
reading (density, hit rate, source, per-operation picture) is printed under `CLIPMAP_DENSITY`.
"""

from __future__ import annotations

from fixture import runner_parser, run_script_test


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--resolution", default="1920x1080")
    args = parser.parse_args()
    return run_script_test(
        fixture_prefix="terrain-vtclipmapdensity-",
        project_name="Clipmap material density acceptance",
        log_name="vtclipmapdensity.log",
        script="vt_clipmap_density.gd",
        marker="PASS clipmap material density acceptance",
        prefixes=("CLIPMAP_DENSITY",),
        # `vt_clipmap_density.gd` extends `res://vt_probe_base.gd`, which the fixture writes from
        # `vt_adaptive.gd` - the same base `vt_near_density.gd` uses for its screen readings.
        extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
        resolution=args.resolution,
        timeout_import=180,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
