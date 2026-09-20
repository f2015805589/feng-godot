#!/usr/bin/env python3
"""Run the Terrain editor lifecycle regression in a headless Godot editor.

The assertions live in ``tests/feng_terrain_lifecycle.gd`` and exercise real
nodes, resources and Signals. This runner only builds an isolated project,
imports the addon, and starts the editor script; it intentionally contains no
source-text or mirrored signal model checks.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ADDONS = ROOT / "misc" / "feng-addons"
TEST_SCRIPT = ROOT / "misc" / "scripts" / "tests" / "feng_terrain_lifecycle.gd"
EDITOR = ROOT / "bin" / "godot.windows.editor.x86_64.console.exe"
if not EDITOR.is_file():
    EDITOR = ROOT / "bin" / "godot.windows.editor.x86_64.exe"

# Reuse the fixture's addon copier so the test uses exactly the built extension
# and editor scripts that the existing terrain integration tests exercise.
TEST_HELPERS = ADDONS / "feng-idweight-terrain" / "native" / "tests"
sys.path.insert(0, str(TEST_HELPERS))
from fixture import copy_terrain_addon  # noqa: E402


def make_fixture() -> Path:
    fixture = Path(tempfile.mkdtemp(prefix="terrain_lifecycle_", dir=ROOT / "bin"))
    addon_target = fixture / "addons" / "feng-idweight-terrain"
    copy_terrain_addon(addon_target)

    # Keep other source addons as ordinary placeholders. This prevents the
    # native addon helper from linking a shared source tree into this editor.
    for source in sorted(ADDONS.iterdir()):
        if source.name == "feng-idweight-terrain" or not (source / "plugin.cfg").is_file():
            continue
        placeholder = fixture / "addons" / source.name
        placeholder.mkdir(parents=True)
        (placeholder / ".gdignore").write_text("", encoding="utf-8")

    test_addon = fixture / "addons" / "terrain-lifecycle-test"
    test_addon.mkdir(parents=True)
    shutil.copy2(TEST_SCRIPT, test_addon / "feng_terrain_lifecycle.gd")
    (test_addon / "plugin.cfg").write_text(
        "[plugin]\n"
        "name=\"Terrain lifecycle behaviour\"\n"
        "script=\"feng_terrain_lifecycle.gd\"\n",
        encoding="utf-8",
    )
    (fixture / "project.godot").write_text(
        "; Headless Terrain editor lifecycle fixture.\n"
        "config_version=5\n\n"
        "[application]\n"
        "config/name=\"Terrain editor lifecycle behaviour\"\n\n"
        "[editor_plugins]\n"
        "enabled=PackedStringArray(\"res://addons/terrain-lifecycle-test/plugin.cfg\")\n\n"
        "[rendering]\n"
        "renderer/rendering_method=\"gl_compatibility\"\n"
        "renderer/rendering_method.mobile=\"gl_compatibility\"\n",
        encoding="utf-8",
    )
    return fixture


def run_editor(command: list[str], env: dict[str, str], timeout: float) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return 124, output + "\nTIMEOUT: Godot editor did not exit\n"
    return completed.returncode, completed.stdout


def main() -> int:
    if not EDITOR.is_file():
        print(f"LAUNCH FAILED: editor not found at {EDITOR}")
        return 127

    fixture = make_fixture()
    env = os.environ.copy()
    env["APPDATA"] = str(fixture / "config")
    env["LOCALAPPDATA"] = str(fixture / "cache")
    (fixture / "config").mkdir()
    (fixture / "cache").mkdir()
    base = [
        str(EDITOR.resolve()),
        "--headless",
        "--editor",
        "--path",
        str(fixture),
        "--audio-driver",
        "Dummy",
    ]

    run_code, output = run_editor(base, env, 120.0)
    (fixture / "lifecycle.log").write_text(output, encoding="utf-8")
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "TIMEOUT", "LAUNCH")):
            print(line)
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    leaks = [
        line for line in output.splitlines()
        if "leak" in line.lower() or "still in use at exit" in line.lower()
    ]
    print(f"FIXTURE={fixture}")
    print(f"RUN_EXIT={run_code} ERRORS={len(errors)} LEAKS={len(leaks)}")
    if run_code != 0 or errors or leaks:
        print(output)
        return 1
    if "PASS Terrain editor lifecycle behaviour" not in output:
        print("REGRESSION: behaviour runner did not produce its PASS marker")
        print(output)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
