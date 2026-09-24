"""Real AVT GPU material baking and SVT persistence integration: bake, then reload in a new process."""
from fixture import Followup, run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-vtautobake-",
        project_name="VT render tests",
        log_name="vtrender.log",
        script="vt_auto_bake.gd",
        marker=("PASS automatic incremental SVT baking", "PASS cross-process SVT content identity"),
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
        shots=True,
        followups=(Followup(script="vt_auto_bake.gd", args=("reload",), timeout=120),),
    ))
