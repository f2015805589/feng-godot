#!/usr/bin/env python3
"""Verify the feng_godottracy engine module against a running editor.

Three checks, all against the built editor:
1. The FengGodotTracy class is part of the engine's extension API.
2. A driver plugin exercises the script API and the Debug menu item in a real editor.
3. The Tracy client compiled into the engine answers the Tracy protocol
   handshake, and rejects a mismatching protocol version like a real client.

The editor has to be built with module_feng_godottracy_enabled=yes.
"""

import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "bin/godot.windows.editor.x86_64.exe"
CLIENT_SOURCE = ROOT / "thirdparty/tracy/public/TracyClient.cpp"
DRIVER_SCRIPT = ROOT / "misc/feng-addons/feng-godottracy/tests/editor_menu.gd"
DRIVER_PLUGIN = "res://addons/tracy_driver/plugin.cfg"
DRIVER_RESULT = "PASS feng-godottracy API, script zones and profiler menu item"

# An editor that quits from an editor plugin reports its remaining UI resources
# and objects at exit. Those diagnostics are engine bookkeeping, not addon
# failures, so they are reported but never fail this test.
TEARDOWN_NOISE = (
    "RID allocations of type",
    "RIDs of type",
    "resources still in use at exit",
    "ObjectDB instances were leaked",
    "ObjectDB instances leaked at exit",
    "Orphan StringName",
)

# Values from thirdparty/tracy/public/common/TracyProtocol.hpp.
HANDSHAKE_SHIBBOLETH = b"TracyPrf"
PROTOCOL_VERSION = 69
HANDSHAKE_WELCOME = 1
HANDSHAKE_PROTOCOL_MISMATCH = 2
# WelcomeMessage is packed, so the offsets are stable: nine 8-byte fields, then
# flags, cpuArch, cpuManufacturer[12] and cpuId, then the program name.
WELCOME_MESSAGE_SIZE = 1178
FLAGS_OFFSET = 72
CPU_ARCH_OFFSET = 73
PROGRAM_NAME_OFFSET = 90
PROGRAM_NAME_SIZE = 64
CPU_ARCH_X64 = 2
WELCOME_FLAG_ON_DEMAND = 1
PORT = 8086
CONNECT_TIMEOUT = 60.0


def handshake(port, protocol):
    """Return the client's handshake status and, when welcome, its welcome message."""
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as sock:
        sock.sendall(HANDSHAKE_SHIBBOLETH + struct.pack("<I", protocol))
        status = sock.recv(1)
        if not status or status[0] != HANDSHAKE_WELCOME:
            return (status[0] if status else None), b""
        payload = b""
        while len(payload) < WELCOME_MESSAGE_SIZE:
            chunk = sock.recv(WELCOME_MESSAGE_SIZE - len(payload))
            if not chunk:
                break
            payload += chunk
        return HANDSHAKE_WELCOME, payload


def wait_for_client(editor, log_path):
    deadline = time.monotonic() + CONNECT_TIMEOUT
    while time.monotonic() < deadline:
        if editor.poll() is not None:
            print(f"ERROR: the editor exited early; read {log_path}")
            return False
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.25)
    print(f"ERROR: nothing listened on port {PORT} within {CONNECT_TIMEOUT:.0f}s; read {log_path}")
    return False


def run_editor(args, project, environment, timeout):
    result = subprocess.run(
        [str(EDITOR), *args, "--path", str(project)],
        cwd=project,
        env=environment,
        capture_output=True,
        timeout=timeout,
    )
    return result.returncode, (result.stdout + result.stderr).decode("utf-8", errors="replace")


def errors(output):
    """ERROR lines that are not the editor's exit-time teardown diagnostics."""
    return [
        line.strip()
        for line in output.splitlines()
        if "ERROR:" in line and not any(noise in line for noise in TEARDOWN_NOISE)
    ]


def main() -> int:
    if not CLIENT_SOURCE.is_file():
        print("ERROR: thirdparty/tracy is missing, run: python misc/scripts/install_tracy.py")
        return 1
    if not EDITOR.is_file():
        print(f"ERROR: {EDITOR} does not exist, build the editor first.")
        return 1

    fixtures = Path(tempfile.mkdtemp(prefix="feng-godottracy-test-", dir=ROOT / "bin"))
    (fixtures / "config").mkdir()
    (fixtures / "cache").mkdir()
    environment = dict(os.environ, APPDATA=str(fixtures / "config"), LOCALAPPDATA=str(fixtures / "cache"))
    project = fixtures / "project"
    project.mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Tracy test"\n'
        f'[editor_plugins]\nenabled=PackedStringArray("{DRIVER_PLUGIN}")\n',
        encoding="utf-8",
    )
    driver = project / "addons" / "tracy_driver"
    driver.mkdir(parents=True)
    shutil.copyfile(DRIVER_SCRIPT, driver / "editor_menu.gd")
    (driver / "plugin.cfg").write_text(
        '[plugin]\nname="Tracy driver"\nscript="editor_menu.gd"\n', encoding="utf-8"
    )

    # 1. The module has to be part of the engine.
    code, output = run_editor(["--headless", "--editor", "--dump-extension-api"], project, environment, 300)
    (fixtures / "dump.log").write_text(output, encoding="utf-8")
    if code != 0 or errors(output):
        print(f"ERROR: the editor could not dump its extension API, read {fixtures / 'dump.log'}")
        return 1
    api_dump = json.loads((project / "extension_api.json").read_text(encoding="utf-8"))
    if "FengGodotTracy" not in {entry["name"] for entry in api_dump["classes"]}:
        print("ERROR: this editor was built without the feng_godottracy module.")
        print("       Rebuild with module_feng_godottracy_enabled=yes (see modules/feng_godottracy/README.md).")
        return 1
    print("PASS: the built editor registers the FengGodotTracy class")

    # Import first, so the driver run starts from a project that is already warm.
    code, output = run_editor(["--headless", "--editor", "--import"], project, environment, 300)
    (fixtures / "import.log").write_text(output, encoding="utf-8")
    if code != 0 or errors(output):
        print(f"ERROR: the editor could not import the fixture project, read {fixtures / 'import.log'}")
        return 1

    # 2. The script API and the profiler menu item, exercised inside a live editor.
    code, output = run_editor(["--headless", "--editor"], project, environment, 300)
    (fixtures / "driver.log").write_text(output, encoding="utf-8")
    if DRIVER_RESULT not in output or code != 0 or errors(output) or "SCRIPT ERROR" in output:
        print(f"ERROR: the driver plugin failed, read {fixtures / 'driver.log'}")
        return 1
    print("PASS: script zones, markers and the profiler menu item work in a live editor")

    # 3. The Tracy client itself, through the profiler protocol.
    log_path = fixtures / "editor.log"
    with log_path.open("wb") as log:
        editor = subprocess.Popen(
            [str(EDITOR), "--headless", "--editor", "--path", str(project)],
            cwd=project,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            if not wait_for_client(editor, log_path):
                return 1

            status, payload = handshake(PORT, PROTOCOL_VERSION)
            if status != HANDSHAKE_WELCOME:
                print(f"ERROR: the client answered handshake status {status} instead of {HANDSHAKE_WELCOME}")
                return 1
            if len(payload) < WELCOME_MESSAGE_SIZE:
                print(f"ERROR: the client sent {len(payload)} of {WELCOME_MESSAGE_SIZE} welcome bytes")
                return 1
            program = payload[PROGRAM_NAME_OFFSET : PROGRAM_NAME_OFFSET + PROGRAM_NAME_SIZE]
            program_name = program.split(b"\0")[0].decode("utf-8", errors="replace")
            if "godot" not in program_name.lower():
                print(f"ERROR: the client is '{program_name}', not this editor (another profiled process holds port {PORT}?)")
                return 1
            arch = payload[CPU_ARCH_OFFSET]
            if arch != CPU_ARCH_X64:
                print(f"ERROR: the client reported cpu architecture {arch}, expected {CPU_ARCH_X64} (x64)")
                return 1
            on_demand = bool(payload[FLAGS_OFFSET] & WELCOME_FLAG_ON_DEMAND)
            print(f"PASS: Tracy client handshake from '{program_name}' (protocol {PROTOCOL_VERSION}, x64)")
            print(f"      recording: {'on demand' if on_demand else 'always'}")

            mismatch, _ = handshake(PORT, PROTOCOL_VERSION - 1)
            if mismatch != HANDSHAKE_PROTOCOL_MISMATCH:
                print(f"ERROR: protocol {PROTOCOL_VERSION - 1} got status {mismatch}, expected {HANDSHAKE_PROTOCOL_MISMATCH}")
                return 1
            print(f"PASS: protocol {PROTOCOL_VERSION - 1} is rejected as a mismatch, as a real Tracy client does")
        finally:
            editor.terminate()
            try:
                editor.wait(timeout=60)
            except subprocess.TimeoutExpired:
                editor.kill()
                editor.wait(timeout=60)

    print("PASS: feng_godottracy is built into the editor and accepts profiler connections")
    print(f"Fixtures and logs: {fixtures}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
