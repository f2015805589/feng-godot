"""Run the long-lived AVT fade/queue regression in one real rendering process."""
from fixture import runner_parser, run_script_test


if __name__ == "__main__":
    parser = runner_parser()
    parser.add_argument(
        "--ticks",
        type=int,
        default=2000,
        help="ticks per static and ping-pong window (the script enforces a 2000 tick minimum)",
    )
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()
    if args.ticks < 2000:
        parser.error("--ticks must be at least 2000")
    raise SystemExit(run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtlifetime-",
        project_name="VT fade lifetime tests",
        log_name="vtlifetime.log",
        script="vt_lifetime.gd",
        marker="PASS VT fade lifetime keeps CPU diagnostics and page-arrival FIFO bounded over static and ping-pong windows",
        prefixes=("VTLIFETIME",),
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
        env={"VT_LIFETIME_TICKS": str(args.ticks)},
        resolution="320x240",
        timeout_run=args.timeout,
    ))
