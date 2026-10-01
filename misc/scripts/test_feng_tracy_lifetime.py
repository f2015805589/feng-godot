#!/usr/bin/env python3
"""Exercise real Tracy ownership while disconnected and with a draining client."""
import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    args = parser.parse_args()
    project = Path(tempfile.mkdtemp(prefix="feng-tracy-lifetime-", dir=ROOT / "bin"))
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Tracy lifetime"\n')
    env = dict(os.environ)
    for key, folder in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("APPDATA", "config"), ("LOCALAPPDATA", "cache")):
        path = project / folder
        path.mkdir(exist_ok=True)
        env[key] = str(path)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    env["TRACY_PORT"] = str(port)
    log_path = project / "runtime.log"
    with log_path.open("wb") as log:
        process = subprocess.Popen([str(args.editor.resolve()), "--headless", "--path", str(project),
            "--audio-driver", "Dummy", "--script", str(ROOT / "modules/feng_godottracy/tests/runtime_lifetime.gd")],
            env=env, stdout=log, stderr=subprocess.STDOUT)
        client = None
        drained = [0]
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and process.poll() is None:
                if "TRACY_READY_TO_CONNECT" in log_path.read_text(errors="replace"):
                    try:
                        client = socket.create_connection(("127.0.0.1", port), timeout=1)
                        break
                    except OSError:
                        pass
                time.sleep(0.05)
            assert client is not None, "real Tracy client never became ready"
            client.sendall(b"TracyPrf" + struct.pack("<I", 69))
            assert client.recv(1) == b"\x01", "vendored protocol-69 handshake was rejected"
            client.settimeout(1)
            def drain():
                while process.poll() is None:
                    try:
                        block = client.recv(65536)
                        if not block:
                            return
                        drained[0] += len(block)
                    except socket.timeout:
                        continue
                    except OSError:
                        return
            worker = threading.Thread(target=drain, daemon=True)
            worker.start()
            # A real profiler performs a termination handshake at application
            # shutdown. This read-only drain client has no UI/query protocol,
            # so disconnect after the script's consumption window, before
            # waiting for the engine's profiler teardown to finish.
            deadline = time.monotonic() + 30
            while process.poll() is None and time.monotonic() < deadline:
                if "PASS Tracy actual client lifetime:" in log_path.read_text(errors="replace"):
                    break
                time.sleep(0.02)
            client.shutdown(socket.SHUT_RDWR)
            process.wait(timeout=30)
            worker.join(timeout=2)
        finally:
            if client is not None:
                client.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    output = log_path.read_text(errors="replace")
    assert process.returncode == 0 and "PASS Tracy actual client lifetime:" in output, output
    assert "ERROR:" not in output and "leaked" not in output.lower(), output
    assert drained[0] > 1178, f"Only {drained[0]} bytes received; no profiler stream consumed"
    print(next(line for line in output.splitlines() if line.startswith("PASS Tracy")))
    print(f"Consumed {drained[0]} profiler bytes; fixture: {project}")


if __name__ == "__main__":
    main()
