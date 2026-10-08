#!/usr/bin/env python3
"""Real GPU regression; isolated projects and logs are kept under bin/."""
import argparse
import os
import re
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
# Exercise the complete stock manifest, including the optional cloud templates.
# Fog's acceptance scripts also reference Sky's atmosphere types during import.
selected_addons = ("feng-render-pipeline", "feng-fog", "feng-sky", "feng-cloud")
for name in selected_addons:
    shutil.copytree(ROOT / "misc/feng-addons" / name, project / "addons" / name)
# The editor auto-links sibling addons. Keep this regression isolated from their
# native DLL reloads, capture injection and editor tools, including concurrent runs.
for addon in (ROOT / "misc/feng-addons").iterdir():
    if addon.name not in selected_addons and (addon / "plugin.cfg").is_file():
        placeholder = project / "addons" / addon.name
        placeholder.mkdir()
        (placeholder / ".gdignore").touch()
(project / "project.godot").write_text(
    'config_version=5\n[application]\nconfig/name="Deferred tests"\n'
    '[display]\nwindow/size/viewport_width=320\nwindow/size/viewport_height=240\n'
    'window/size/resizable=false\nwindow/size/maximize_disabled=true\n'
    'window/stretch/mode="viewport"\nwindow/stretch/aspect="keep"\n'
    '[rendering]\nrenderer/rendering_method="frp"\n', encoding="utf-8"
)
env = dict(os.environ, APPDATA=str(project / "config"), LOCALAPPDATA=str(project / "cache"),
           XDG_DATA_HOME=str(project / "data"), XDG_CONFIG_HOME=str(project / "config"),
           XDG_CACHE_HOME=str(project / "cache"), FRP_ENGINE_SOURCE_ROOT=str(ROOT))
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
    # Hosts without an audio card report ALSA's open failure at startup.
    'Condition "status < 0" is true. Returning: ERR_CANT_OPEN',
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
run("volume", ["--script", str(ROOT / "misc/scripts/tests/frp_volume.gd")],
    "PASS FRP author-defined Volume modules, typed fields, priority, persistence, custom frame parameters and compositor isolation")
run("volume_metrics", ["--script", str(ROOT / "misc/scripts/tests/frp_volume_metrics.gd")],
    "PASS volume CPU monitors: frame totals, units, idle reset and registration lifetime")
run("lighting_cache", ["--script", str(ROOT / "misc/scripts/tests/frp_lighting_cache.gd")],
    "PASS FRP bounded lighting pipeline cache survives alternating camera fog, soft-shadow and area-light variants")
run("architecture", ["--script", str(ROOT / "misc/scripts/tests/frp_architecture.gd")],
    "PASS FRP contract resource notifications, view invalidation and detached dependency lifetime")
run("library_placement", ["--script", str(ROOT / "misc/scripts/tests/frp_library_placement.gd")],
    "PASS FRP managed-library placement matrix:")
run("fog_packet", ["--script", str(ROOT / "misc/scripts/tests/frp_fog_packet.gd")],
    "PASS FRP fog packet equivalence:")
run("snapshot_world_switch", ["--script", str(ROOT / "misc/scripts/tests/frp_snapshot_world_switch.gd")],
    "PASS FRP snapshot target cache follows live/inherited world switches, detach/reenter and weak removal")
run("view_state", ["--script", str(ROOT / "misc/scripts/tests/frp_view_state.gd")],
    "PASS FRP shared view definitions, two-camera pixels, independent TAA switches, stateful plugin isolation and shader reuse")
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
# The Sky-anchored full-screen pass stays in place; HeightFog's immutable
# snapshot also reaches per-fragment transparent and opaque fallback shading.
run("height_fog", ["--script", str(ROOT / "misc/scripts/tests/frp_height_fog.gd")],
    "PASS FRP Height Fog nodes, world isolation, height falloff, start/cutoff distance, transparent/fallback fragments and sun radiance units")
# Post effects run before or after the tone mapping, selected by a per-pass parameter
# and signalled to the overlay shader as a shader keyword (specialization constant).
run("post", ["--script", str(ROOT / "misc/scripts/tests/frp_post.gd")],
    "PASS post effects run before or after tone mapping, selected by a shader keyword")
# Native Bloom is an engine scheduled pass, but its Environment Glow parameters
# and final composite remain on Environment/Tonemap. It must follow exposure and
# Transparent even when TAA is disabled, and disabling it suppresses stale Glow.
run("bloom", ["--script", str(ROOT / "misc/scripts/tests/frp_bloom.gd")],
    "PASS FRP native Bloom schedule, migration, dependencies and glow switch")
# The built-in Eye Adaptation pass meters the frame's luminance (64-bin log
# histogram), adapts temporally and folds the colour buffer by scale / adapted,
# the addon equivalent of UE's pre-exposure.
run("eye_adaptation", ["--script", str(ROOT / "misc/scripts/tests/frp_eye_adaptation.gd")],
    "PASS FRP eye adaptation meters and tonemaps in both directions")
# Production-shader numerical controls isolate exposure rebasing from the scene.
run("exposure_history", ["--script", str(ROOT / "misc/scripts/tests/frp_exposure_history.gd")],
    "PASS FRP GPU exposure history rebasing and bounded adaptation")
# Retired frame contexts must never update a reconfigured viewport's exposure.
run("hdr_sun", ["--script", str(ROOT / "misc/scripts/tests/frp_hdr_sun.gd")],
    "PASS FRP GPU moving HDR sun and post-process stability")
run("exposure_lifecycle", ["--script", str(ROOT / "misc/scripts/tests/frp_exposure_lifecycle.gd")],
    "PASS FRP exposure readback retirement, pre-exposure toggle, TAA restart, resize and compositor switch")
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
for name, marker in (
    ("volume_editor", "PASS FRP editor viewport Volume preview, live parameter changes, disable and leaving restore authored values"),
    ("volume_gizmo", "PASS FRP Volume gizmo boxes, corresponding corner connectors and boundary semantics"),
):
    plugin = project / "addons" / ("frp-" + name + "-tests")
    plugin.mkdir()
    shutil.copyfile(ROOT / "misc/scripts/tests" / ("frp_" + name + ".gd"), plugin / "test.gd")
    (plugin / "plugin.cfg").write_text(
        '[plugin]\nname="FRP Volume Tests"\ndescription="Isolated regression"\n'
        'author="Feng"\nversion="1"\nscript="test.gd"\n', encoding="utf-8"
    )
    config_path = project / "project.godot"
    config = config_path.read_text(encoding="utf-8")
    config = re.sub(r'enabled=PackedStringArray\([^\n]*\)',
                    'enabled=PackedStringArray("res://addons/' + plugin.name + '/plugin.cfg")', config)
    config_path.write_text(config, encoding="utf-8")
    run(name, ["--editor", "--quit-after", "600" if name == "volume_editor" else "180"], marker)
# The other direction: forward_plus must be unaffected by FRP. The probe attaches a
# compositor carrying an FRP schedule while forward_plus renders and requires
# forward_plus to keep its own jitter (the FRP jitter rule stays behind its
# rendering-method guard), then records the four lighting configurations.
run("forward_plus", ["--script", str(ROOT / "misc/scripts/tests/frp_forward_plus_probe.gd")],
    "PASS forward_plus keeps its own jitter with an FRP schedule attached and stays lit in every configuration",
    method="forward_plus")
print("Logs:", project)
