"""Windows GPU integration test; requires the built engine, RenderDoc and psutil."""

import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import psutil

from validate_capture import validate_capture


REPO = Path(__file__).resolve().parents[4]
BASE = Path(tempfile.mkdtemp(prefix="renderdoc-smoke-", dir=REPO / "bin"))
PROJECT = BASE / "ui-project"
shutil.copytree(Path(__file__).resolve().parent / "fixture", PROJECT)


def stage_addons() -> None:
    """Copy only the fixture's runtime addons into the isolated project.

    The custom engine normally creates junctions for every addon in the
    checkout.  A concurrent native-addon rebuild can then expose a temporary
    ``~lib...`` DLL or half-written editor script to this smoke process.  Keep
    this test's addon inputs physically isolated and leave unrelated terrain
    addon names occupied so the engine does not create those junctions.
    """
    source_root = REPO / "misc" / "feng-addons"
    target_root = PROJECT / "addons"
    ignore = shutil.ignore_patterns("native", "bin", "tests", ".godot", "__pycache__", "~*")
    for name in ("feng-render-pipeline", "feng-renderdoc-capture"):
        shutil.copytree(source_root / name, target_root / name, ignore=ignore)
    extension_source = source_root / "feng-renderdoc-capture" / "bin" / "libfeng-renderdoc-capture.windows.debug.x86_64.dll"
    extension_target = target_root / "feng-renderdoc-capture" / "bin" / extension_source.name
    extension_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(extension_source, extension_target)
    # The engine's addon linker sees this directory as user-owned and leaves
    # the unrelated terrain addon out of the fixture entirely.
    terrain_target = target_root / "feng-idweight-terrain"
    terrain_target.mkdir(parents=True, exist_ok=True)
    if os.environ.get("FENG_TEST_VT_WORK") == "1":
        for extension in (source_root / "feng-idweight-terrain").glob("*.gdextension"):
            shutil.copy2(extension, terrain_target / extension.name)
        (terrain_target / "bin").mkdir()
        shutil.copy2(source_root / "feng-idweight-terrain/bin/libfeng-idweight-terrain.windows.debug.x86_64.dll",
                     terrain_target / "bin/libfeng-idweight-terrain.windows.debug.x86_64.dll")
    else:
        (terrain_target / ".gdignore").write_text("", encoding="utf-8")


stage_addons()

# Verify the analyzer's actual UI filter, not only the markers in the RDC file.
view_script = PROJECT / "addons/feng-renderdoc-capture/src/renderdoc_view.py"
with view_script.open("a", encoding="utf-8") as script:
    script.write("\n" + '''
from pathlib import Path
browser = pyrenderdoc.GetEventBrowser()
pending = list(pyrenderdoc.CurRootActions())
visible_vt = []
while pending:
    action = pending.pop()
    pending.extend(action.children)
    if "VT Idle Marker" in browser.GetEventName(action.eventId) or browser.GetEventName(action.eventId) == "VT Pass":
        visible_vt.append(browser.IsAPIEventVisible(action.eventId))
assert visible_vt and all(visible_vt), "Idle VT pass is hidden by the analyzer"
''' + "Path(" + repr(str(BASE / "idle-vt-visible.txt")) + ").write_text('PASS visible idle VT marker', encoding='utf-8')\n")
for name in ["config", "cache"]:
    (BASE / name).mkdir()
ENV = dict(os.environ, APPDATA=str(BASE / "config"), LOCALAPPDATA=str(BASE / "cache"))

PSAPI = ctypes.WinDLL("psapi")
KERNEL = ctypes.WinDLL("kernel32")
KERNEL.OpenProcess.restype = wintypes.HANDLE
KERNEL.CloseHandle.argtypes = [wintypes.HANDLE]
PSAPI.EnumProcessModulesEx.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD), wintypes.DWORD,
]
PSAPI.GetModuleFileNameExW.argtypes = [
    wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD,
]


def assert_attached(pid, timeout=8):
    """Wait for PSAPI to expose the injected RenderDoc module.

    The editor can print its completion marker before Windows has finished
    publishing the module list to a second process.  Retry that read-only
    query instead of turning a valid capture into a timing failure.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        handle = KERNEL.OpenProcess(0x410, False, pid)
        if handle:
            try:
                modules = (wintypes.HMODULE * 4096)()
                size = wintypes.DWORD()
                if PSAPI.EnumProcessModulesEx(handle, modules, ctypes.sizeof(modules), ctypes.byref(size), 3):
                    found = False
                    count = min(size.value, ctypes.sizeof(modules)) // ctypes.sizeof(wintypes.HMODULE)
                    for module in modules[:count]:
                        name = ctypes.create_unicode_buffer(32768)
                        if PSAPI.GetModuleFileNameExW(handle, module, name, len(name)):
                            found |= name.value.lower().endswith("renderdoc.dll")
                    if found:
                        return
            finally:
                KERNEL.CloseHandle(handle)
        time.sleep(0.1)
    assert psutil.pid_exists(pid), "Original editor must still be alive"
    raise AssertionError("Current editor rendering device must have RenderDoc attached")


def close_test_gui(pid):
    user = ctypes.WinDLL("user32")
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]

    def close_owned(hwnd, unused):
        owner = wintypes.DWORD()
        user.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            user.PostMessageW(hwnd, 0x10, 0, 0)  # WM_CLOSE, only our analyzer.
        return True

    user.EnumWindows(callback_type(close_owned), 0)
    try:
        psutil.Process(pid).wait(timeout=5)
    except psutil.NoSuchProcess:
        pass
    except psutil.TimeoutExpired:
        # This is the analyzer process found from our capture path.  Give it
        # a bounded cleanup fallback so a slow qrenderdoc shutdown cannot
        # leave the smoke run holding the next build's executable.
        process = psutil.Process(pid)
        process.terminate()
        try:
            process.wait(timeout=5)
        except psutil.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


startup = subprocess.STARTUPINFO()
startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
startup.wShowWindow = 0
checked = False
analyzer = None
with (BASE / "ui.log").open("wb") as log:
    editor = subprocess.Popen([
        os.environ.get("FENG_TEST_EDITOR", str(REPO / "bin/godot.windows.editor.x86_64.exe")),
        "--editor", "--path", str(PROJECT), "--resolution", "800x600",
        "--position", "-32000,-32000",
    ], env=ENV, stdout=log, stderr=log, startupinfo=startup)
    try:
        deadline = time.monotonic() + 65
        while editor.poll() is None and time.monotonic() < deadline:
            time.sleep(0.5)
            if editor.poll() is None:
                assert not any(child.name().lower().startswith("godot.") for child in psutil.Process(editor.pid).children(recursive=True)), "Capture must not launch another Godot process"
            output = (BASE / "ui.log").read_text(encoding="utf-8", errors="replace")
            if checked or "UI_TEST_AFTER" not in output:
                continue
            assert_attached(editor.pid)
            for process in psutil.process_iter(["pid", "name", "cmdline"]):
                args = process.info["cmdline"] or []
                if (process.info["name"] or "").lower() != "qrenderdoc.exe":
                    continue
                captures = [Path(arg) for arg in args[1:] if arg.endswith(".rdc")]
                if not any(path.is_relative_to(PROJECT) for path in captures):
                    continue
                analyzer = process.pid
                assert all(path.is_file() and path.stat().st_size > 0 for path in captures)
                gui_exe = Path(args[0])
                subprocess.run([str(gui_exe.with_name("renderdoccmd.exe")), "thumb", "--out=" + str(BASE / "current_editor.png"), str(captures[0])], check=True, capture_output=True)
                events = validate_capture(captures[0], gui_exe.with_name("renderdoccmd.exe"), BASE,
                                          explicit=ENV.get("FENG_TEST_VT_WORK") != "1")
                if ENV.get("FENG_TEST_VT_WORK") == "1":
                    assert any("::Dispatch" in draw["operation"]
                               and any("Bake / Invalidate Pages" in label for label in draw["path"])
                               and any("VT Idle Marker" in label for label in draw["path"])
                               for draw in events["scene_draws"]), "VT page baker dispatch missing"
                # Replay may compile the VT compute shader on first open.
                ui_deadline = time.monotonic() + 25
                while not (BASE / "idle-vt-visible.txt").is_file() and time.monotonic() < ui_deadline:
                    time.sleep(0.1)
                close_test_gui(analyzer)
                assert_attached(editor.pid)
                checked = True
                print("PASS: real editor frame captured without another Godot process; closing analyzer keeps original editor alive", flush=True)
                break
        assert editor.poll() == 0, "Editor did not exit cleanly"
    finally:
        if editor.poll() is None:
            editor.terminate()
            editor.wait(5)

output = (BASE / "ui.log").read_text(encoding="utf-8", errors="replace")
assert checked and analyzer is not None, output
assert (BASE / "idle-vt-visible.txt").is_file(), "Analyzer did not verify the idle VT marker is visible"
assert "SCRIPT ERROR" not in output, output
assert "ERROR:" not in output, output
result = (PROJECT / "capture_result.cfg").read_text(encoding="utf-8")
assert "overlay=0" in result and "pid=" + str(editor.pid) in result, result
assert not (PROJECT / ".godot/renderdoc/sessions").exists(), "No snapshot jobs should be created"
print("PASS: EXE setting, original PID, disabled overlay, and no background captures")
print("Fixtures and logs:", BASE)
