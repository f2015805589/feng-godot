"""SVT cell source regression: the cells bake, then reload in a new process."""
from fixture import Followup, runner_parser, run_script_test


if __name__ == "__main__":
    parser = runner_parser()
    parser.add_argument("--mix", action="store_true", help="drive the mixed-source cell script")
    args = parser.parse_args()
    script = "vt_cells_mix.gd" if args.mix else "vt_cells.gd"
    raise SystemExit(run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtcells-",
        project_name="VT render tests",
        log_name="vtrender.log",
        script=script,
        marker=("PASS SVT cell sources bake", "PASS SVT cell sources reload"),
        extra_scripts=(("vt_adaptive.gd", "vt_adaptive_base.gd"),),
        shots=True,
        followups=(Followup(script=script, args=("reload",), timeout=120),),
    ))
