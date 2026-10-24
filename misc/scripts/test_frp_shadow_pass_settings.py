#!/usr/bin/env python3
"""Exercise native Shadow Pass settings with real GPU image comparisons.

Uses the existing in-tree editor; no build, addon import, or binary copy is needed.
The isolated project, PNG pairs, measurement JSON and log remain under bin/.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PASS_MARKER = "PASS FRP Shadow Pass settings before culling, live cascade distances"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", "--binary", type=Path,
                        default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    editor = args.editor.resolve()
    if not editor.is_file():
        parser.error(f"editor binary does not exist: {editor}")
    fixture = Path(tempfile.mkdtemp(prefix="frp-shadow-settings-", dir=ROOT / "bin"))
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Shadow Pass settings regression"\n'
        '[display]\nwindow/size/viewport_width=320\nwindow/size/viewport_height=240\n'
        'window/size/resizable=false\n[rendering]\nrenderer/rendering_method="frp"\n'
        'frp/shadows/directional_shadow/cascade_size=4096\n', encoding="utf-8")
    # Keep editor/cache writes out of the real user's settings, as in test_frp_pipeline.py.
    env = dict(os.environ, APPDATA=str(fixture / "config"), LOCALAPPDATA=str(fixture / "cache"),
               XDG_DATA_HOME=str(fixture / "data"), XDG_CONFIG_HOME=str(fixture / "config"),
               XDG_CACHE_HOME=str(fixture / "cache"))
    startup = None
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
    log = fixture / "test.log"
    command = [str(editor), "--path", str(fixture), "--rendering-method", "frp",
               "--rendering-driver", args.driver, "--audio-driver", "Dummy",
               "--resolution", "320x240", "--position", "-10000,-10000",
               "--script", str(ROOT / "misc/scripts/tests/frp_shadow_pass_settings.gd"),
               "--", str(fixture)]
    print(f"FIXTURE={fixture}", flush=True)
    try:
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                                    startupinfo=startup, timeout=args.timeout)
        exit_code = result.returncode
    except subprocess.TimeoutExpired:
        exit_code = 1
        print(f"ERROR: GPU regression exceeded {args.timeout} seconds")
    text = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in text.splitlines()
              if "ERROR:" in line and "Failed to read the root certificate store." not in line]
    for line in text.splitlines():
        if line.startswith(("SHADOW_SETTINGS", "PASS", "ERROR:", "SCRIPT ERROR:")):
            print(line)
    print(f"EXIT={exit_code} LOG={log}")
    return int(exit_code != 0 or bool(errors) or PASS_MARKER not in text)


if __name__ == "__main__":
    raise SystemExit(main())
