#!/usr/bin/env python3
"""Isolated FRP + Magic GI GPU integration test; fixtures and logs stay under bin/."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--driver", default="d3d12" if os.name == "nt" else "vulkan")
parser.add_argument("--binary", default=None,
                    help="editor binary to run (defaults to the in-tree editor for this platform)")
parser.add_argument("--xvfb", action="store_true", help="run under xvfb-run (Linux headless)")
args = parser.parse_args()
project = Path(tempfile.mkdtemp(prefix="magic-gi-tests-", dir=ROOT / "bin"))
addons = project / "addons"
addons.mkdir()
selected_addons = ("feng-render-pipeline", "feng-magic-gi", "feng-fog", "feng-sky", "feng-cloud")
for name in selected_addons:
    shutil.copytree(ROOT / "misc/feng-addons" / name, addons / name)
for addon in (ROOT / "misc/feng-addons").iterdir():
    if addon.name not in selected_addons and (addon / "plugin.cfg").is_file():
        placeholder = addons / addon.name
        placeholder.mkdir()
        (placeholder / ".gdignore").touch()

(project / "project.godot").write_text(
    'config_version=5\n[application]\nconfig/name="Magic GI GPU tests"\n'
    '[rendering]\nrenderer/rendering_method="frp"\n', encoding="utf-8"
)
env = dict(os.environ, APPDATA=str(project / "config"), LOCALAPPDATA=str(project / "cache"))
if os.name != "nt":
    # Linux/Mac fixtures stay out of the user's real config dirs as well.
    env["XDG_CONFIG_HOME"] = str(project / "config")
    env["XDG_CACHE_HOME"] = str(project / "cache")
startup = None
if os.name == "nt":
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
if args.binary:
    binary = Path(args.binary)
elif os.name == "nt":
    binary = ROOT / "bin/godot.windows.editor.x86_64.exe"
else:
    binary = ROOT / "bin/godot.linuxbsd.editor.x86_64"
base = [str(binary), "--path", str(project), "--rendering-method", "frp",
        "--rendering-driver", args.driver, "--audio-driver", "Dummy", "--resolution", "320x240",
        "--position", "-10000,-10000"]
if args.xvfb:
    base = ["xvfb-run", "-a"] + base


# Host-side noise unrelated to the renderer: a headless box has no audio device
# and a Linux CI machine may lack a readable root certificate store.
UNRELATED_ERRORS = (
    "Failed to read the root certificate store.",
    'Condition "status < 0" is true. Returning: ERR_CANT_OPEN',
)


def run(name, extra, marker=None):
    log = project / (name + ".log")
    with log.open("wb") as output:
        result = subprocess.run(base + list(extra), env=env, stdout=output,
                                stderr=subprocess.STDOUT, startupinfo=startup, timeout=240)
    text = log.read_text(encoding="utf-8", errors="replace")
    errors = [
        line for line in text.splitlines()
        if "ERROR:" in line and not any(unrelated in line for unrelated in UNRELATED_ERRORS)
    ]
    lifecycle_leaks = [
        line for line in text.splitlines()
        if "ObjectDB instances were leaked" in line
        or "resources still in use at exit" in line
        or ("RID" in line.upper() and re.search(r"\b(leak|leaked|still in use|not freed)\b", line, re.I))
    ]
    assert result.returncode == 0 and not errors and not lifecycle_leaks, (
        "\n".join((errors + lifecycle_leaks)[-20:]) + "\n" + text[-8000:]
    )
    if marker:
        assert marker in text, text[-12000:]
    print("PASS", name)


run("import", ["--editor", "--recovery-mode", "--import"])
run("prt", ["--script", str(ROOT / "misc/scripts/tests/magic_gi_prt.gd")],
    "MAGIC_GI_PRT_RESULT failures=0")
run("gpu", ["--script", str(ROOT / "misc/scripts/tests/frp_magic_gi.gd")],
    "PASS Magic GI dynamic lighting, camera transform, seven debug channels and viewport routing")
print("Logs:", project)
