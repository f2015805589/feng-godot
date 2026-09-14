"""Isolated project fixtures for the terrain integration tests.

Every script test does the same thing: copy the addon into a throwaway project
under `bin/`, point APPDATA/LOCALAPPDATA at that project, run the engine twice
(a headless import, then a real-driver run of one script), then decide pass/fail
from the exit code, the log's `ERROR:` lines and one required `PASS` marker. That
lives here so a runner only names its script, its log and its marker, and adding
a test is a few lines rather than a copy of fifty.

Import from the tests directory, which is what running `..._runner.py` does.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable, Sequence

ROOT = Path(__file__).resolve().parents[5]
ADDON_SOURCE = ROOT / "misc" / "feng-addons"
TERRAIN_SOURCE = ADDON_SOURCE / "feng-idweight-terrain"
DEFAULT_EDITOR = ROOT / "bin" / "godot.windows.editor.x86_64.exe"


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

    if test in {"input", "vt_idle"}:
        project = fixture / "project.godot"
        # The input fixture extends the production plugin itself.
        project.write_text(project.read_text(encoding="utf-8").replace(
            '"res://addons/feng-idweight-terrain/plugin.cfg", ', ''), encoding="utf-8")

    if test in {"setup", "grid", "vt_idle"}:
        (fixture / "render").mkdir()
        (fixture / "render/test.tscn").write_text(
            '[gd_scene format=3]\n\n[node name="TerrainSetup" type="Node3D"]\n'
            '[node name="Terrain3D" type="Terrain3D" parent="."]\n', encoding="utf-8")


def run_script_test(*, editor: Path, driver: str, fixture_prefix: str, script: str, marker: str,
                    project_name: str, log_name: str, prefixes: Sequence[str] = (),
                    resolution: str = "320x240", shots: bool = False,
                    timeout_import: float = 180, timeout_run: float = 300) -> int:
    """Runs one test script in a fresh project. Returns the process exit status."""
    fixture = Path(tempfile.mkdtemp(prefix=fixture_prefix, dir=ROOT / "bin"))
    write_fixture(fixture)
    (fixture / "project.godot").write_text(
        f'config_version=5\n[application]\nconfig/name="{project_name}"\n', encoding="utf-8")
    shots_directory = None
    if shots:
        shots_directory = fixture / "shots"
        shots_directory.mkdir()
    env = os.environ.copy()
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)
    log = fixture / log_name
    print(f"FIXTURE={fixture}", flush=True)

    base = [str(Path(editor).resolve()), "--path", str(fixture), "--audio-driver", "Dummy"]
    run = base + ["--rendering-method", "frp", "--rendering-driver", driver,
                  "--resolution", resolution, "--position", "-10000,-10000",
                  "--script", str((Path(__file__).parent / script).resolve())]
    if shots_directory is not None:
        run += ["--", "", str(shots_directory)]
    try:
        with log.open("w", encoding="utf-8") as out:
            result = subprocess.run(base + ["--headless", "--editor", "--import"], env=env,
                                    stdout=out, stderr=subprocess.STDOUT, timeout=timeout_import)
            if result.returncode == 0:
                result = subprocess.run(run, env=env, stdout=out, stderr=subprocess.STDOUT,
                                        timeout=timeout_run)
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    wanted: Iterable[str] = ("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", *prefixes)
    for line in output.splitlines():
        if line.startswith(tuple(wanted)):
            print(line)
    print(f"EXIT={result.returncode} ERRORS={len(errors)} LOG={log}")
    return int(result.returncode != 0 or bool(errors) or marker not in output)
