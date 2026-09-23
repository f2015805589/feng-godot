"""Isolated project fixtures for the terrain integration tests.

Every script test does the same thing: copy the addon into a throwaway project
under `bin/`, point APPDATA/LOCALAPPDATA at that project, run the engine twice
(a headless import, then a real-driver run of one script), then decide pass/fail
from the exit code, the log's `ERROR:` lines minus `ENVIRONMENTAL_ERRORS`, and one
required `PASS` marker. That lives here so a runner only names its script, its log
and its marker, and adding a test is a few lines rather than a copy of fifty.

Import from the tests directory, which is what running `..._runner.py` does.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Iterable, Sequence, TextIO

ROOT = Path(__file__).resolve().parents[5]
ADDON_SOURCE = ROOT / "misc" / "feng-addons"
TERRAIN_SOURCE = ADDON_SOURCE / "feng-idweight-terrain"
DEFAULT_EDITOR = ROOT / "bin" / "godot.windows.editor.x86_64.exe"

# Off-desktop position for every engine window. The editor restores its own layout, so
# `--position -10000,-10000` alone still leaves a maximized window covering the screen.
OFFSCREEN_POSITION = -32000

# While starting, the engine asks the OS for its certificate store and prints one `ERROR:` line
# per launch when that read fails. The line describes the machine, not the test - but a runner
# counts `ERROR:` lines and `run_all.py` reads those counts, so one unfiltered line turned every
# test in the suite red. Only this exact text is exempt: every other `ERROR:` line stays fatal.
# `vt_project_lifetime_probe.py` already ignored it locally; this is the shared version.
ENVIRONMENTAL_ERRORS = ("Failed to read the root certificate store.",)


def is_environmental_error(line: str) -> bool:
    """True for a log line the engine emits about the machine rather than about the test."""
    return any(text in line for text in ENVIRONMENTAL_ERRORS)


def log_errors(output: str) -> list[str]:
    """The `ERROR:` lines of `output` that describe the test rather than the machine."""
    return [line for line in output.splitlines() if "ERROR:" in line and not is_environmental_error(line)]


def move_windows_offscreen(pid: int) -> int:
    """Moves every visible top-level window of `pid` off the desktop.

    Windows are moved rather than minimized: a minimized D3D12 window can stop presenting,
    which would stall the test that is reading rendered frames. Returns how many moved.
    """
    if os.name != "nt":
        return 0
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    moved = 0
    swp_nosize, swp_nozorder, swp_noactivate = 0x0001, 0x0004, 0x0010
    visit_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def visit(hwnd, _lparam):
        nonlocal moved
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value != pid or not user32.IsWindowVisible(hwnd):
            return True
        # Move once: moving the window again while the test drives synthetic input makes
        # Windows send a mouse-leave, which clears the hover the test is checking for.
        rect = wintypes.RECT()
        if user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            if rect.left <= OFFSCREEN_POSITION + 100 and rect.top <= OFFSCREEN_POSITION + 100:
                return True
        user32.SetWindowPos(hwnd, None, OFFSCREEN_POSITION, OFFSCREEN_POSITION, 0, 0,
                            swp_nosize | swp_nozorder | swp_noactivate)
        moved += 1
        return True

    try:
        user32.EnumWindows(visit_type(visit), 0)
    except OSError:
        return 0
    return moved


def run_with_offscreen_window(command: Sequence[str], *, env: dict, stream: TextIO,
                              cwd: Path | None = None, timeout: float) -> int | None:
    """Runs `command` while keeping its windows off the desktop. None means it timed out.

    A watcher re-applies the move because the editor positions its window after startup,
    once its layout has loaded.
    """
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    stop = threading.Event()

    def keep_away() -> None:
        while not stop.is_set():
            move_windows_offscreen(process.pid)
            stop.wait(0.5)

    watcher = threading.Thread(target=keep_away, daemon=True)
    watcher.start()
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return None
    finally:
        stop.set()


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
                    forbidden: Sequence[str] = (), extra_scripts: Sequence[tuple[str, str]] = (),
                    resolution: str = "320x240", shots: bool = False,
                    timeout_import: float = 180, timeout_run: float = 300) -> int:
    """Runs one test script in a fresh project. Returns the process exit status.

    `extra_scripts` copies further test scripts into the fixture root under a chosen name,
    which is what a test extending another test (`res://vt_render_base.gd`) needs: the
    engine resolves that path inside the throwaway project, not in the tests directory.
    """
    fixture = Path(tempfile.mkdtemp(prefix=fixture_prefix, dir=ROOT / "bin"))
    write_fixture(fixture)
    for source_name, target_name in extra_scripts:
        (fixture / target_name).write_text(
            (Path(__file__).parent / source_name).read_text(encoding="utf-8"), encoding="utf-8")
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
            status = run_with_offscreen_window(
                base + ["--headless", "--editor", "--import"], env=env, stream=out,
                timeout=timeout_import)
            if status is None:
                print(f"TIMEOUT LOG={log}")
                return 124
            if status == 0:
                status = run_with_offscreen_window(run, env=env, stream=out, timeout=timeout_run)
                if status is None:
                    print(f"TIMEOUT LOG={log}")
                    return 124
        result_code = status
    except OSError as error:
        print(f"LAUNCH FAILED: {error}")
        return 127

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = log_errors(output)
    banned = [text for text in forbidden if text in output]
    wanted: Iterable[str] = ("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", *prefixes)
    for line in output.splitlines():
        if line.startswith(tuple(wanted)) and not is_environmental_error(line):
            print(line)
    for text in banned:
        print(f"FORBIDDEN: {text}")
    print(f"EXIT={result_code} ERRORS={len(errors)} LOG={log}")
    return int(result_code != 0 or bool(errors) or bool(banned) or marker not in output)
