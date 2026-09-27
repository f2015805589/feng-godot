#!/usr/bin/env python3
"""Isolated FRP + Magic GI GPU integration test; fixtures and logs stay under bin/."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
project = Path(tempfile.mkdtemp(prefix="magic-gi-tests-", dir=ROOT / "bin"))
addons = project / "addons"
addons.mkdir()
for name in ("feng-render-pipeline", "feng-magic-gi"):
    shutil.copytree(ROOT / "misc/feng-addons" / name, addons / name)
for addon in (ROOT / "misc/feng-addons").iterdir():
    if addon.name not in {"feng-render-pipeline", "feng-magic-gi"} and (addon / "plugin.cfg").is_file():
        placeholder = addons / addon.name
        placeholder.mkdir()
        (placeholder / ".gdignore").touch()

(project / "project.godot").write_text(
    'config_version=5\n[application]\nconfig/name="Magic GI GPU tests"\n'
    '[rendering]\nrenderer/rendering_method="frp"\n', encoding="utf-8"
)
env = dict(os.environ, APPDATA=str(project / "config"), LOCALAPPDATA=str(project / "cache"))
startup = None
if os.name == "nt":
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
binary = ROOT / "bin/godot.windows.editor.x86_64.exe"
base = [str(binary), "--path", str(project), "--rendering-method", "frp",
        "--rendering-driver", "d3d12", "--resolution", "320x240", "--position", "-10000,-10000"]


def run(name, extra, marker=None):
    log = project / (name + ".log")
    with log.open("wb") as output:
        result = subprocess.run(base + list(extra), env=env, stdout=output,
                                stderr=subprocess.STDOUT, startupinfo=startup, timeout=240)
    text = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in text.splitlines() if "ERROR:" in line]
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
