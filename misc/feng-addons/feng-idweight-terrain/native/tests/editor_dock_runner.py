#!/usr/bin/env python3
"""Run the graphical Terrain3D asset-dock regression in an isolated project."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
ADDON_SOURCE = ROOT / "misc" / "feng-addons"
TERRAIN_SOURCE = ADDON_SOURCE / "feng-idweight-terrain"


def copy_terrain_addon(target: Path) -> None:
    excluded_directories = {"native", ".godot"}
    for source_path in TERRAIN_SOURCE.rglob("*"):
        relative_path = source_path.relative_to(TERRAIN_SOURCE)
        if any(part in excluded_directories for part in relative_path.parts):
            continue
        if source_path.name.startswith("~"):
            continue
        target_path = target / relative_path
        if source_path.is_dir():
            target_path.mkdir(parents=True, exist_ok=True)
        else:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, target_path)


def write_fixture(fixture: Path, test: str = "dock") -> None:
    addons = fixture / "addons"
    addons.mkdir(parents=True)
    copy_terrain_addon(addons / "feng-idweight-terrain")

    # feng_addons.cpp links every source addon that is absent. Keep ordinary
    # placeholder directories for the other source addons so this test never
    # shares a junction with a concurrently running editor or its temp DLL.
    for source in sorted(ADDON_SOURCE.iterdir()):
        if source.name == "feng-idweight-terrain" or not (source / "plugin.cfg").is_file():
            continue
        placeholder = addons / source.name
        placeholder.mkdir()
        (placeholder / ".gdignore").write_text("", encoding="utf-8")

    test_addon = addons / "editor-dock-test"
    test_addon.mkdir()
    shutil.copy2(Path(__file__).with_name(f"editor_{test}.gd"), test_addon / "editor_dock.gd")
    (test_addon / "plugin.cfg").write_text(
        "[plugin]\n"
        "name=\"Editor dock regression\"\n"
        "script=\"editor_dock.gd\"\n",
        encoding="utf-8",
    )
    (fixture / "project.godot").write_text(
        "; Engine configuration file.\n"
        "config_version=5\n\n"
        "[application]\n"
        "config/name=\"Terrain editor dock test\"\n"
        "config/features=PackedStringArray(\"4.7\")\n\n"
        "[editor_plugins]\n"
        "enabled=PackedStringArray(\"res://addons/feng-idweight-terrain/plugin.cfg\", "
        "\"res://addons/editor-dock-test/plugin.cfg\")\n",
        encoding="utf-8",
    )

    if test == "input":
        project = fixture / "project.godot"
        # The input fixture extends the production plugin itself.
        project.write_text(project.read_text(encoding="utf-8").replace(
            '"res://addons/feng-idweight-terrain/plugin.cfg", ', ''), encoding="utf-8")

    if test == "setup":
        (fixture / "render").mkdir()
        (fixture / "render/test.tscn").write_text(
            '[gd_scene format=3]\n\n[node name="TerrainSetup" type="Node3D"]\n'
            '[node name="Terrain3D" type="Terrain3D" parent="."]\n', encoding="utf-8")


def run(editor: Path, fixture: Path, driver: str, test: str = "dock") -> int:
    log = fixture / "editor_dock_graphical.log"
    env = os.environ.copy()
    env["APPDATA"] = str(fixture / "config")
    env["LOCALAPPDATA"] = str(fixture / "cache")
    (fixture / "config").mkdir()
    (fixture / "cache").mkdir()
    command = [
        str(editor),
        "--editor",
        "--path",
        str(fixture),
        "--rendering-method",
        "frp",
        "--rendering-driver",
        driver,
        "--resolution",
        "640x480",
        "--position",
        "-10000,-10000",
        "--audio-driver",
        "Dummy",
    ]
    try:
        with log.open("w", encoding="utf-8") as stream:
            result = subprocess.run(
                command,
                cwd=fixture,
                env=env,
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT=180 LOG={log}")
        return 124

    output = log.read_text(encoding="utf-8", errors="replace")
    error_lines = [line for line in output.splitlines() if "ERROR:" in line]
    print(f"EXIT={result.returncode} ERROR_LINES={len(error_lines)} LOG={log}")
    print(output, end="")
    if result.returncode != 0 or error_lines:
        return 1
    marker = "PASS graphical Terrain3D asset dock layout and management menu actions" if test == "dock" else "PASS editor brush first GPU miss -> CPU fallback -> R16 CPU/GPU ID 1 -> outside release -> right navigation"
    if test == "setup":
        marker = "PASS terrain setup, Scene texture/mesh painting, Add Region, and saved reload"
    if marker not in output:
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--editor",
        type=Path,
        default=ROOT / "bin" / "godot.windows.editor.x86_64.console.exe",
        help="graphical Godot editor executable (the console build still creates a window)",
    )
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--test", choices=["dock", "input", "setup"], default="dock")
    args = parser.parse_args()
    editor = args.editor.resolve()
    if not editor.is_file():
        print(f"Editor executable not found: {editor}", file=sys.stderr)
        return 2
    fixture = Path(tempfile.mkdtemp(prefix="feng-editor-dock-clean-", dir=ROOT / "bin"))
    write_fixture(fixture, args.test)
    print(f"FIXTURE={fixture}")
    return run(editor, fixture, args.driver, args.test)


if __name__ == "__main__":
    raise SystemExit(main())
