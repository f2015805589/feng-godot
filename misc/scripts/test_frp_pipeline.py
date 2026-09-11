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
base = [str(ROOT / "bin/godot.windows.editor.x86_64.exe"), "--path", str(project),
        "--rendering-method", "frp", "--rendering-driver", args.driver,
        "--resolution", "320x240", "--position", "-10000,-10000"]


def run(name, extra, marker=None):
    log = project / (name + ".log")
    with log.open("wb") as output:
        result = subprocess.run(base + extra, env=env, stdout=output,
                                stderr=subprocess.STDOUT, startupinfo=startup, timeout=180)
    text = log.read_text(encoding="utf-8", errors="replace")
    assert result.returncode == 0 and "ERROR:" not in text, text[-10000:]
    if marker:
        assert marker in text, text[-10000:]
    print("PASS", name)


# Recovery skips loading editor plugins, including capture injection. Import
# still registers scripts and compiles the reusable compute pass shader.
run("import", ["--editor", "--recovery-mode", "--import"])
run("gpu", ["--script", str(ROOT / "misc/scripts/tests/frp_passes.gd")],
    "PASS configurable compute pass shader, bindings, parameters and enabled state")
# GI is the only consumer that decodes roughness from a different G-buffer
# target, and process_gi() only runs with SDFGI or VoxelGI enabled.
run("gi", ["--script", str(ROOT / "misc/scripts/tests/frp_gi.gd")],
    "PASS SDFGI runs with FRP split roughness and produces indirect light")
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
print("Logs:", project)
