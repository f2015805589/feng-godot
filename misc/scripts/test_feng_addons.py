#!/usr/bin/env python3
"""Exercise addon startup using the built editor; keep fixtures/logs under bin/."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "bin/godot.windows.editor.x86_64.exe"
SOURCE = ROOT / "misc/feng-addons"
ADDONS = sorted(p.name for p in SOURCE.iterdir() if (p / "plugin.cfg").is_file())
FIXTURES = Path(tempfile.mkdtemp(prefix="feng-addons-test-", dir=ROOT / "bin"))
TEST_ENV = dict(os.environ, APPDATA=str(FIXTURES / "config"), LOCALAPPDATA=str(FIXTURES / "cache"))
(FIXTURES / "config").mkdir()
(FIXTURES / "cache").mkdir()


def project(name, enabled=()):
    path = FIXTURES / name
    path.mkdir()
    write_settings(path, enabled)
    return path


def write_settings(path, enabled):
    plugins = ", ".join(f'"{p}"' for p in enabled)
    (path / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Addon test"\n'
        f"[editor_plugins]\nenabled=PackedStringArray({plugins})\n",
        encoding="utf-8",
    )


def start(path, recovery=False):
    # The interface dump exits after engine setup, without instantiating an
    # editor UI or importing shared source assets. This still executes the
    # real project startup/mount code. Full --import is tested separately.
    args = [str(EDITOR), "--headless", "--editor", "--path", str(path), "--dump-gdextension-interface"]
    if recovery:
        args.append("--recovery-mode")
    result = subprocess.run(args, cwd=path, env=TEST_ENV, capture_output=True, timeout=90)
    output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    (path / "startup.log").write_text(output, encoding="utf-8")
    assert result.returncode == 0, output
    assert "ERROR:" not in output, output
    assert "[f_renderdoc] RenderDoc mounted" not in output, output
    return (path / "project.godot").read_text(encoding="utf-8")


def check_links(path, names=ADDONS):
    for name in names:
        assert os.path.samefile(path / "addons" / name, SOURCE / name), name


def junction(target, source):
    env = dict(os.environ, FENG_TEST_LINK=str(target), FENG_TEST_SOURCE=str(source))
    subprocess.run(
        [
            "powershell", "-NoProfile", "-NonInteractive", "-Command",
            "New-Item -ItemType Junction -Path $env:FENG_TEST_LINK -Value $env:FENG_TEST_SOURCE | Out-Null",
        ],
        env=env,
        check=True,
        capture_output=True,
    )


fresh = project("new project 中文 & path")
settings = start(fresh)
check_links(fresh)
for name in ADDONS:
    assert f"res://addons/{name}/plugin.cfg" in settings
print("PASS: new project links all addons, including Unicode and shell characters")

write_settings(fresh, [])
settings = start(fresh)
check_links(fresh)
assert "res://addons/" not in settings
print("PASS: reopening preserves disabled plugins")

existing = project("existing", ["res://addons/local/plugin.cfg"])
(existing / "addons/local").mkdir(parents=True)
settings = start(existing)
check_links(existing)
assert "res://addons/local/plugin.cfg" in settings
print("PASS: existing addons and enabled-plugin list are preserved")

conflict = project("local copy")
local_copy = conflict / "addons" / ADDONS[0]
local_copy.mkdir(parents=True)
(local_copy / "local.txt").write_text("keep this", encoding="utf-8")
start(conflict)
assert (local_copy / "local.txt").read_text(encoding="utf-8") == "keep this"
assert not os.path.samefile(local_copy, SOURCE / ADDONS[0])
check_links(conflict, ADDONS[1:])
print("PASS: conflicting local copies are not overwritten")

recovery = project("recovery")
start(recovery, recovery=True)
assert not (recovery / "addons").exists()
print("PASS: recovery mode leaves project untouched")

legacy_source = ROOT / "bin/addons" / ADDONS[0]
if legacy_source.is_dir():
    legacy = project("legacy junction")
    (legacy / "addons").mkdir()
    junction(legacy / "addons" / ADDONS[0], legacy_source)
    settings = start(legacy)
    check_links(legacy)
    assert legacy_source.is_dir()
    assert f"res://addons/{ADDONS[0]}/plugin.cfg" not in settings
    print("PASS: legacy junction migrates, preserving target and disabled state")
else:
    print("SKIP: legacy junction migration (no old bin/addons copy)")

full = project("full import")
for operation in ("--import", "--dump-extension-api"):
    result = subprocess.run(
        [str(EDITOR), "--headless", "--editor", "--path", str(full), operation],
        cwd=full, env=TEST_ENV, capture_output=True, timeout=120,
    )
    output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    (full / f"{operation[2:]}.log").write_text(output, encoding="utf-8")
    assert result.returncode == 0 and "ERROR:" not in output, output
    assert "[f_renderdoc] RenderDoc mounted" not in output, output
check_links(full)
classes = {c["name"] for c in json.loads((full / "extension_api.json").read_text(encoding="utf-8"))["classes"]}
assert {"Terrain3D", "RenderDocCapture"} <= classes
print("PASS: full editor import and native Terrain3D/RenderDocCapture classes")

slider_plugin = full / "addons/slider-regression"
slider_plugin.mkdir()
shutil.copyfile(SOURCE / "feng-idweight-terrain/native/tests/editor_slider.gd", slider_plugin / "editor_slider.gd")
(slider_plugin / "plugin.cfg").write_text(
    '[plugin]\nname="Slider regression"\nscript="editor_slider.gd"\n', encoding="utf-8"
)
write_settings(full, [f"res://addons/{name}/plugin.cfg" for name in ADDONS] + ["res://addons/slider-regression/plugin.cfg"])
result = subprocess.run([str(EDITOR), "--headless", "--editor", "--path", str(full)],
                        cwd=full, env=TEST_ENV, capture_output=True, timeout=120)
output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
(full / "slider.log").write_text(output, encoding="utf-8")
assert result.returncode == 0 and "ERROR:" not in output, output
assert "PASS real slope slider identity" in output, output
print("PASS: actual editor slope slider and silent synchronization")

print(f"Fixtures and logs: {FIXTURES}")
