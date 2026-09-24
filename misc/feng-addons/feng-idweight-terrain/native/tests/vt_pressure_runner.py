"""Run the automatic real-material AVT/SVT pressure regression."""
from pathlib import Path

from fixture import runner_parser, run_script_test


if __name__ == "__main__":
    parser = runner_parser()
    parser.add_argument(
        "--extension",
        type=Path,
        help="optional Terrain3D DLL to copy into the fixture (useful for before/after runs)",
    )
    args = parser.parse_args()
    if args.extension and not args.extension.resolve().is_file():
        print(f"Extension DLL not found: {args.extension.resolve()}")
        raise SystemExit(2)
    raise SystemExit(run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtpressure-",
        project_name="VT pressure tests",
        log_name="vtpressure.log",
        script="vt_pressure.gd",
        marker="PASS VT pressure remains stable for automatic real-material AVT/SVT and re-produces after move/edit",
        prefixes=("VTPRESSURE",),
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
        resolution="320x240",
        timeout_run=600,
        native_library=args.extension,
    ))
