#!/usr/bin/env python3
"""Real GPU regression; isolated projects and logs are kept under bin/."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--driver", default="d3d12")
parser.add_argument("--binary", default=None,
                    help="editor binary to run (defaults to the in-tree Windows editor)")
args = parser.parse_args()
project = Path(tempfile.mkdtemp(prefix="deferred-tests-", dir=ROOT / "bin"))
shutil.copytree(ROOT / "misc/feng-addons/feng-render-pipeline", project / "addons/feng-render-pipeline")
(project / "project.godot").write_text(
    'config_version=5\n[application]\nconfig/name="Deferred tests"\n'
    '[rendering]\nrenderer/rendering_method="frp"\n', encoding="utf-8"
)
env = dict(os.environ, APPDATA=str(project / "config"), LOCALAPPDATA=str(project / "cache"))
startup = None
if os.name == "nt":
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
binary = Path(args.binary) if args.binary else ROOT / "bin/godot.windows.editor.x86_64.exe"
base = [str(binary), "--path", str(project),
        "--rendering-method", "frp", "--rendering-driver", args.driver,
        "--resolution", "320x240", "--position", "-10000,-10000"]


# Errors that come from the host rather than the renderer. A machine without a
# readable Windows root certificate store makes Godot report an ERROR at startup;
# it is unrelated to FRP and would otherwise fail every run.
UNRELATED_ERRORS = (
    "Failed to read the root certificate store.",
)


def significant_errors(text):
    return [
        line
        for line in text.splitlines()
        if "ERROR:" in line and not any(unrelated in line for unrelated in UNRELATED_ERRORS)
    ]


def run(name, extra, marker=None, method=None):
    log = project / (name + ".log")
    args = list(extra)
    if method:
        # A later --rendering-method wins over the one baked into `base`.
        args += ["--rendering-method", method]
    with log.open("wb") as output:
        result = subprocess.run(base + args, env=env, stdout=output,
                                stderr=subprocess.STDOUT, startupinfo=startup, timeout=180)
    text = log.read_text(encoding="utf-8", errors="replace")
    errors = significant_errors(text)
    assert result.returncode == 0 and not errors, "\n".join(errors[-20:]) + "\n" + text[-6000:]
    if marker:
        assert marker in text, text[-10000:]
    print("PASS", name)


# Recovery skips loading editor plugins, including capture injection. Import
# still registers scripts and compiles the reusable compute pass shader.
run("import", ["--editor", "--recovery-mode", "--import"])
run("gpu", ["--script", str(ROOT / "misc/scripts/tests/frp_passes.gd")],
    "PASS configurable compute pass shader, bindings, parameters and enabled state")
# Every frame that needs motion vectors without 3D upscaling: TAA, the motion
# debug view and upscaling itself. FRP produces motion vectors in the G-buffer
# pass. The Temporal AA entry is the TAA switch, and the viewport jitter follows it.
run("taa", ["--script", str(ROOT / "misc/scripts/tests/frp_taa.gd")],
    "PASS TAA, motion debug view and FSR2 upscaling all keep the FRP frame lit; the Temporal AA entry is the switch")
# The background has no motion vector: only the G-buffer pass writes the velocity
# attachment, so the sky (and the clear colour) keeps the engine's "no data" marker
# and TAA has to resolve it instead of reading the marker as a velocity. A static
# frame has to converge: a silhouette against the background must not flicker.
run("taa_background", ["--script", str(ROOT / "misc/scripts/tests/frp_taa_background.gd")],
    "PASS the background is temporally resolved with TAA on: a static frame converges instead of showing a fresh jittered sample")
# One place to set the renderer's pipeline, for the editor's Scene view and the running
# game alike (Rendering > Frp > Compositor): the setting reaches the world the viewport
# renders, its Temporal AA entry is the switch, and a scene's own compositor still wins.
run("project_pipeline", ["--script", str(ROOT / "misc/scripts/tests/frp_project_pipeline.gd")],
    "PASS the project setting is the pipeline a running game renders, its Temporal AA entry is the switch, and a scene compositor wins")
# FRP has no screen space effects and no global illumination: the Environment's
# SSAO/SSIL/SSR switches must not change an FRP frame at all, the removed entries
# must not be authorable, Sky is a real conditional toggle, and a plugin pass can
# provide a native pass through provides_native_ids.
run("toggles", ["--script", str(ROOT / "misc/scripts/tests/frp_lighting_toggles.gd")],
    "PASS FRP ignores Environment SSAO/SSIL/SSR/SDFGI and the Sky entry is a real toggle")
# Transparent geometry is forward-shaded per object from the frame's clustered light
# list: one draw call per object, no second geometry pass and no second lighting pass.
run("transparent", ["--script", str(ROOT / "misc/scripts/tests/frp_transparent.gd")],
    "PASS transparent geometry is forward-shaded per object from the frame's light list")
# Post effects run before or after the tone mapping, selected by a per-pass parameter
# and signalled to the overlay shader as a shader keyword (specialization constant).
run("post", ["--script", str(ROOT / "misc/scripts/tests/frp_post.gd")],
    "PASS post effects run before or after tone mapping, selected by a shader keyword")
# The Core surface a plugin pass runs on: a scripted pass takes over an engine pass
# and then drives a whole frame through the granular primitives.
run("context", ["--script", str(ROOT / "misc/scripts/tests/frp_context.gd")],
    "PASS FRP Core primitives drive an engine pass from a plugin pass")
# Exercise actual inspector resource selection and editor undo/redo as well.
editor_test = project / "addons/frp-editor-tests"
editor_test.mkdir()
shutil.copyfile(ROOT / "misc/scripts/tests/frp_editor.gd", editor_test / "test.gd")
(editor_test / "plugin.cfg").write_text(
    '[plugin]\nname="FRP Editor Tests"\ndescription="Isolated regression"\n'
    'author="Feng"\nversion="1"\nscript="test.gd"\n', encoding="utf-8"
)
with (project / "project.godot").open("a", encoding="utf-8") as config:
    config.write('\n[editor_plugins]\nenabled=PackedStringArray("res://addons/frp-editor-tests/plugin.cfg")\n')
run("editor", ["--editor", "--quit-after", "120"],
    "PASS FRP editor resource selection, names, add, move, undo and redo")
# The other direction: forward_plus must be unaffected by FRP. The probe attaches a
# compositor carrying an FRP schedule while forward_plus renders and requires
# forward_plus to keep its own jitter (the FRP jitter rule stays behind its
# rendering-method guard), then records the four lighting configurations.
run("forward_plus", ["--script", str(ROOT / "misc/scripts/tests/frp_forward_plus_probe.gd")],
    "PASS forward_plus keeps its own jitter with an FRP schedule attached and stays lit in every configuration",
    method="forward_plus")
print("Logs:", project)
