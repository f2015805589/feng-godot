"""Shared godot-cpp build and output layout for Feng native addons."""

# SCons injects script globals and imports config into this scope.
# ruff: noqa: F821
from pathlib import Path

Import("config")
native = Path(Dir("#").abspath)
addon = native.parent
bindings = addon.parent / "feng-idweight-terrain/native/godot-cpp"
env = SConscript(str(bindings / "SConstruct"))
if env["platform"] == "linux":
    # Absolute binding object paths can exceed Linux's per-argument limit.
    env["ARCOM_ORIG"] = env["ARCOM"]
    env["ARCOM"] = "${TEMPFILE('$ARCOM_ORIG', '$ARCOMSTR')}"
env = env.Clone()
env.Append(CPPPATH=[str(native / "src"), str(bindings / "gdextension")])
env.Append(LIBS=config.get("libraries", {}).get(env["platform"], []))
if config.get("exceptions", False):
    # Only worker extensions need stack unwinding; leave godot-cpp unchanged.
    env.Append(
        CXXFLAGS=["/EHsc" if env["platform"] == "windows" and not env.get("use_mingw", False) else "-fexceptions"]
    )
sources = Glob(str(native / "src/*.cpp"))
if config.get("docs", False) and env["target"] in ("editor", "template_debug"):
    sources.append(
        env.GodotCPPDocData(
            str(native / "src/gen/doc_data.gen.cpp"), source=Glob(str(native / "doc/doc_classes/*.xml"))
        )
    )
(extension,) = addon.glob("*.gdextension")
variant = "release" if env["target"] == "template_release" else "debug"
name = f"lib{extension.stem}.{env['platform']}.{variant}"
if env["platform"] == "macos":
    target = addon / "bin" / f"{name}.framework" / name[3:]
else:
    target = addon / "bin" / f"{name}.{env['arch']}{env['SHLIBSUFFIX']}"
Default(env.SharedLibrary(str(target), source=sources))
