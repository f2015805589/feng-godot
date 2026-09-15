# config.py - Feng Godot Tracy engine module.
#
# The module vendors the Tracy client in `thirdparty/tracy` and selects the
# engine's Tracy profiler backend, so the GodotProfileZone /
# GodotProfileFrameMark instrumentation that is already compiled into the engine
# becomes real Tracy zones. It is built by default: a plain build of this engine
# keeps the profiler available, and the client discards events until a profiler
# attaches (see `profiler_record_on_demand`). Use
# module_feng_godottracy_enabled=no to leave it out.


def can_build(env, platform):
    return True


def is_enabled():
    # Built unless explicitly disabled with module_feng_godottracy_enabled=no.
    return True


def get_opts(platform):
    from SCons.Variables import BoolVariable

    # On-demand recording is intentionally not offered here: the engine option
    # `profiler_record_on_demand` already defaults to on, and the module leaves
    # that choice to the build.
    return [
        BoolVariable("feng_godottracy_callstack", "Sample call stacks for Tracy zones (Windows, Linux, Android).", False),
        BoolVariable("feng_godottracy_track_memory", "Report engine allocations to Tracy.", False),
    ]


def configure(env):
    import os

    from SCons.Script import ARGUMENTS

    # Module options are a short spelling of the engine's own profiler options,
    # and only ever turn them on; an explicit engine option is never disabled.
    if env.get("feng_godottracy_callstack"):
        env["profiler_sample_callstack"] = True
    if env.get("feng_godottracy_track_memory"):
        env["profiler_track_memory"] = True

    # Keep the flag used by the original GodotTracy module working.
    legacy_on_demand = ARGUMENTS.get("tracy_on_demand", "none")
    if legacy_on_demand != "none":
        env["profiler_record_on_demand"] = str(legacy_on_demand).lower() not in ("", "0", "no", "false")

    # `profiler` is an enum whose "no profiler" value is the string "none".
    selected = str(env.get("profiler", "")).lower()
    if selected not in ("", "none", "tracy"):
        # Refuse to fight over the engine's single profiler slot.
        print(f"[feng_godottracy] The '{selected}' profiler is already selected; the Tracy client will not be built.")
        return

    env["profiler"] = "tracy"
    if env.get("profiler_path", ""):
        # An explicitly configured Tracy checkout takes precedence.
        return

    module_dir = os.path.dirname(os.path.abspath(__file__))
    tracy_root = os.path.normpath(os.path.join(module_dir, "..", "..", "thirdparty", "tracy"))
    if not os.path.isfile(os.path.join(tracy_root, "public", "TracyClient.cpp")):
        print("[feng_godottracy] Tracy sources are missing, run: python misc/scripts/install_tracy.py")
        return
    env["profiler_path"] = tracy_root
