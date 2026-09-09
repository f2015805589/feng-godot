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


REPO = Path(__file__).resolve().parents[4]
BASE = Path(tempfile.mkdtemp(prefix="renderdoc-smoke-", dir=REPO / "bin"))
PROJECT = BASE / "ui-project"
shutil.copytree(Path(__file__).resolve().parent / "fixture", PROJECT)
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


def assert_attached(pid):
    handle = KERNEL.OpenProcess(0x410, False, pid)
    assert handle, "Original editor must still be alive"
    try:
        modules = (wintypes.HMODULE * 4096)()
        size = wintypes.DWORD()
        assert PSAPI.EnumProcessModulesEx(handle, modules, ctypes.sizeof(modules), ctypes.byref(size), 3)
        assert size.value <= ctypes.sizeof(modules)
        found = False
        for module in modules[:size.value // ctypes.sizeof(wintypes.HMODULE)]:
            name = ctypes.create_unicode_buffer(32768)
            assert PSAPI.GetModuleFileNameExW(handle, module, name, len(name))
            found |= name.value.lower().endswith("renderdoc.dll")
        assert found, "Current editor rendering device must have RenderDoc attached"
    finally:
        KERNEL.CloseHandle(handle)


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
            output = (BASE / "ui.log").read_text(errors="replace")
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
                time.sleep(2)
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

output = (BASE / "ui.log").read_text(errors="replace")
assert checked and analyzer is not None, output
assert "SCRIPT ERROR" not in output, output
result = (PROJECT / "capture_result.cfg").read_text()
assert "overlay=0" in result and "pid=" + str(editor.pid) in result, result
assert not (PROJECT / ".godot/renderdoc/sessions").exists(), "No snapshot jobs should be created"
print("PASS: EXE setting, original PID, disabled overlay, and no background captures")
print("Fixtures and logs:", BASE)
