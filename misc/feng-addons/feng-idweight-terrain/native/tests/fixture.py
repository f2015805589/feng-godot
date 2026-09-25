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

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence, TextIO

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

# The skeleton every script test that drives its own SceneTree shares: the failure flag a run() ends
# on, the assertion it reports with, the terrain and camera it builds, and the images a codec or
# coverage test feeds the material. Forty of them carried their own copy of the assertion alone, and
# the helpers below were copied into five files each. It is written rather than kept as a file in this
# directory because a test's `extends "res://..."` resolves inside the throwaway project, which is
# what this fixture is.
SCENE_BASE = """extends SceneTree

var terrain: Terrain3D
var camera: Camera3D
var failed := false


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


func material_word(id: int) -> int:
	return (id << 11) | (id << 6)


func make_pattern(size: int, a: Color, b: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var checker := ((x / 8 + y / 8) & 1) == 0
			var gradient := float(x + y) / float(maxi(1, (size - 1) * 2))
			var color := a.lerp(b, 0.25 + gradient * 0.45)
			if not checker:
				color = color.lerp(b, 0.35)
			image.set_pixel(x, y, color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func make_normal(size: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var n := 0.5 + 0.08 * sin(float(x) * 0.35) * cos(float(y) * 0.27)
			image.set_pixel(x, y, Color(n, 0.5, 1.0, 1.0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func make_texture(color: Color) -> ImageTexture:
	return texture(32, color)


func classify(color: Color) -> String:
	var peak := maxf(color.r, maxf(color.g, color.b))
	if peak <= 0.001:
		return "black"
	var result := ""
	if color.r / peak > 0.4:
		result += "r"
	if color.g / peak > 0.4:
		result += "g"
	if color.b / peak > 0.4:
		result += "b"
	return result
"""


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
    (fixture / "vt_scene_base.gd").write_text(SCENE_BASE, encoding="utf-8")

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


def runner_parser() -> argparse.ArgumentParser:
    """The command line every `*_runner.py` starts from: an editor and a rendering driver.

    A runner whose test has no flag of its own never builds one - `run_script_test()` parses
    this itself when it is not handed an editor and a driver. A runner with a flag of its own
    calls this, adds the flag, parses, and passes what `run_script_test()` needs.
    """
    parser = argparse.ArgumentParser(description=sys.modules["__main__"].__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR,
                        help="the editor binary to drive")
    parser.add_argument("--driver", default="d3d12", help="rendering driver")
    return parser


@dataclass(frozen=True)
class Followup:
    """A second (or third) engine invocation of one script test.

    `vt_auto_bake` and `vt_cells` run their script again with `reload` so the second process
    reads what the first persisted, and `vt_adaptive` runs `vt_resolution_controls.gd` after a
    successful scenario. Each is the same import/run pair with its own script, arguments,
    timeout and marker, so the runner names it and shares the rest.
    """
    script: str
    args: tuple[str, ...] = ()
    marker: str = ""
    timeout: float = 300.0
    shotted: bool = True


def run_script_test(*, fixture_prefix: str, script: str, marker: str | Sequence[str],
                    project_name: str, log_name: str, editor: Path | None = None,
                    driver: str | None = None, prefixes: Sequence[str] = (),
                    forbidden: Sequence[str] = (), extra_scripts: Sequence[tuple[str, str]] = (),
                    env: Mapping[str, str] | None = None, resolution: str = "320x240",
                    shots: bool = False, timeout_import: float = 180, timeout_run: float = 300,
                    followups: Sequence[Followup] = (),
                    script_args: Sequence[str] = (),
                    native_library: Path | None = None) -> int:
    """Runs one test script in a fresh project and returns its verdict.

    `editor` and `driver` default to the runner's own command line, so a runner only names its
    test; pass them explicitly only to override the parsed value.

    `extra_scripts` copies further test scripts into the fixture root under a chosen name,
    which is what a test extending another test (`res://vt_render_base.gd`) needs: the
    engine resolves that path inside the throwaway project, not in the tests directory.

    `native_library` replaces the fixture's built extension DLL, which is how a before/after or
    reference run drives a preserved build without touching the checkout's own.

    `marker` is every `PASS` line the log must carry - a test that runs twice needs both its
    own and its `Followup`'s, and a test whose second run is a different script names it there.
    """
    if editor is None or driver is None:
        parsed = runner_parser().parse_args()
        editor = editor if editor is not None else parsed.editor
        driver = driver if driver is not None else parsed.driver

    markers = (marker,) if isinstance(marker, str) else tuple(marker)
    phases = [(script, tuple(script_args), timeout_run, shots)]
    phases += [(item.script, tuple(item.args), item.timeout, item.shotted) for item in followups]

    fixture = Path(tempfile.mkdtemp(prefix=fixture_prefix, dir=ROOT / "bin"))
    write_fixture(fixture)
    for source_name, target_name in extra_scripts:
        (fixture / target_name).write_text(
            (Path(__file__).parent / source_name).read_text(encoding="utf-8"), encoding="utf-8")
    (fixture / "project.godot").write_text(
        f'config_version=5\n[application]\nconfig/name="{project_name}"\n', encoding="utf-8")
    if native_library is not None:
        shutil.copy2(native_library.resolve(),
                     fixture / "addons" / "feng-idweight-terrain" / "bin"
                     / "libfeng-idweight-terrain.windows.debug.x86_64.dll")
    shots_directory = fixture / "shots"
    if any(phase[3] for phase in phases):
        shots_directory.mkdir()
    environment = os.environ.copy()
    environment.update(env or {})
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        environment[key] = str(fixture / folder)
    log = fixture / log_name
    print(f"FIXTURE={fixture}", flush=True)

    base = [str(Path(editor).resolve()), "--path", str(fixture), "--audio-driver", "Dummy"]
    result_code = 1
    try:
        with log.open("w", encoding="utf-8") as out:
            result_code = run_with_offscreen_window(
                base + ["--headless", "--editor", "--import"], env=environment, stream=out,
                timeout=timeout_import)
            if result_code is None:
                print(f"TIMEOUT LOG={log}")
                return 124
            for phase_script, phase_args, phase_timeout, shotted in phases:
                if result_code != 0:
                    break
                run = base + ["--rendering-method", "frp", "--rendering-driver", driver,
                              "--resolution", resolution, "--position", "-10000,-10000",
                              "--script",
                              str((Path(__file__).parent / phase_script).resolve())]
                if shotted:
                    run += ["--", "", str(shots_directory), *phase_args]
                result_code = run_with_offscreen_window(run, env=environment, stream=out,
                                                        timeout=phase_timeout)
                if result_code is None:
                    print(f"TIMEOUT LOG={log}")
                    return 124
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
    required = markers + tuple(item.marker for item in followups if item.marker)
    missing = [text for text in required if text not in output]
    return int(result_code != 0 or bool(errors) or bool(banned) or bool(missing))
