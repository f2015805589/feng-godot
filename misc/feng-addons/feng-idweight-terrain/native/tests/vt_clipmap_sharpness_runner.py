"""Evidence runner for the near-material Clipmap sharpness fix.

`vt_clipmap_density_runner.py` measures the *delivered density at the focus* through the layer's own
report, and that reading was 1024/1.000 even in the state the user called blurry: the report's
`delivered_density` is the density at the last demand walk's focus, so it says nothing about the rest
of the visible near field. This runner drives `vt_clipmap_sharpness.gd`, which selects `Clipmap` on
the near material group and changes nothing else - the user's path - and then reads the point-wise
density at every visible ground point within 8 m through `Terrain3D.sample_vt_detail()`, the CPU
mirror of the shader's directory lookup. It saves the same patch with the detail layer on and off so
the fix can be looked at as well as counted.

A `SHARPNESS` line is printed per state and the pictures land in the fixture's `shots/` directory.
"""

from __future__ import annotations

from fixture import runner_parser, run_script_test


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--resolution", default="1920x1080")
    args = parser.parse_args()
    return run_script_test(
        fixture_prefix="terrain-vtclipmapsharpness-",
        project_name="Clipmap near material sharpness evidence",
        log_name="vtclipmapsharpness.log",
        script="vt_clipmap_sharpness.gd",
        marker="PASS clipmap near material sharpness evidence",
        prefixes=("SHARPNESS",),
        # The point-wise readings use the same screen probe base the density runner uses.
        extra_scripts=(("vt_adaptive.gd", "vt_probe_base.gd"),),
        resolution=args.resolution,
        shots=True,
        timeout_import=180,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
