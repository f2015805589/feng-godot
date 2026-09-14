#!/usr/bin/env python3
"""Run the graphical Terrain3D asset-dock regression in an isolated project."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path


# The fixture and the two-phase invocation live in fixture.py, shared with every
# script runner. This file owns the graphical-editor tests only.
from fixture import ROOT, run_with_offscreen_window, write_fixture


def run(editor: Path, fixture: Path, driver: str, test: str = "dock") -> int:
    log = fixture / "editor_dock_graphical.log"
    env = os.environ.copy()
    env["APPDATA"] = str(fixture / "config")
    env["LOCALAPPDATA"] = str(fixture / "cache")
    (fixture / "config").mkdir()
    (fixture / "cache").mkdir()
    # Editor thumbnails are transient files, not project assets to reimport.
    for folder in ("config", "cache"):
        (fixture / folder / ".gdignore").write_text("", encoding="utf-8")
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
            status = run_with_offscreen_window(command, cwd=fixture, env=env, stream=stream,
                                               timeout=180)
    except OSError as error:
        print(f"LAUNCH FAILED: {error}")
        return 127
    if status is None:
        print(f"TIMEOUT=180 LOG={log}")
        return 124
    result_code = status

    output = log.read_text(encoding="utf-8", errors="replace")
    error_lines = [line for line in output.splitlines() if "ERROR:" in line]
    print(f"EXIT={result_code} ERROR_LINES={len(error_lines)} LOG={log}")
    print(output, end="")
    if result_code != 0 or error_lines:
        return 1
    marker = {
        "dock": "PASS graphical Terrain3D asset dock layout and management menu actions",
        "input": "PASS editor brush first GPU miss -> CPU fallback -> R16 CPU/GPU ID 1 -> outside release -> right navigation",
        "setup": "PASS terrain setup, Scene texture/mesh painting, Add Region, and saved reload",
        "grid": "PASS 20x20 terrain grid creation, cancellation, limits and reload",
        "pairroles": "PASS IdWeight pair role readout shown for the texture tool and the click mapping matches the pair fields",
        "svt_inspector": "PASS native SVT Inspector full-bake action and progress",
        "vt_idle": "PASS editor stationary VT completion",
    }[test]
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
    parser.add_argument("--test", choices=["dock", "input", "setup", "grid", "pairroles", "svt_inspector", "vt_idle"], default="dock")
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
