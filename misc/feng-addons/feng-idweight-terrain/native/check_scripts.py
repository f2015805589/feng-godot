#!/usr/bin/env python3
"""Parse-check every addon script with the engine, without running the test suite.

A GDScript parse error - a typo in a `preload` path, a base class that does not resolve, a call to a
method no class in the chain defines - is invisible to every static reader in this directory and only
shows up when the editor loads the script. The full suite would find it eventually, but it takes
sixteen minutes; this takes about a second per file:

    python native/check_scripts.py                       every .gd in the addon
    python native/check_scripts.py asset_dock_45.gd      by file name, from anywhere in the addon

The script is checked *in a project context*, because the addon's `res://` paths (`addons/...`) only
resolve where the addon is installed. `--project` defaults to the pass's test project, which has the
addon as a junction; `--engine` defaults to the checkout's editor console binary.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent
# native/ sits four levels below the checkout, the same depth run_all.py computes its ROOT from.
CHECKOUT = HERE.parents[3]

DEFAULT_PROJECT = Path(r"F:\godot\project\test-1")
DEFAULT_ENGINE = CHECKOUT / "bin" / "godot.windows.editor.x86_64.console.exe"
RES_ROOT = "res://addons/feng-idweight-terrain"
# `native/tests` is skipped on purpose: its scripts are copied into a fixture project root by the
# runner before they run, so their `res://` paths do not resolve under the addon and every one of them
# would report a parse error that is not one.
SKIP_DIRS = ("godot-cpp", "bin", ".git", "tests")


def scripts() -> list[Path]:
    found = []
    for path in sorted(ADDON.rglob("*.gd")):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        found.append(path)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="file names to check; default is every script")
    parser.add_argument("--project", type=Path, default=DEFAULT_PROJECT)
    parser.add_argument("--engine", type=Path, default=DEFAULT_ENGINE)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not args.engine.is_file():
        print("no engine binary at %s" % args.engine)
        return 2
    if not (args.project / "project.godot").is_file():
        print("no project at %s" % args.project)
        return 2

    wanted = args.names or None
    checked = 0
    failures = []
    for path in scripts():
        if wanted and path.name not in wanted and path.relative_to(ADDON).as_posix() not in wanted:
            continue
        checked += 1
        res_path = "%s/%s" % (RES_ROOT, path.relative_to(ADDON).as_posix())
        result = subprocess.run(
            [str(args.engine), "--headless", "--check-only", "--script", res_path],
            cwd=args.project, capture_output=True, text=True, errors="replace")
        output = (result.stdout + result.stderr).strip()
        # The banner every run prints is the only expected output; anything else is the parse.
        noise = [line for line in output.splitlines()
                 if line.strip() and not line.startswith("Godot Engine v")]
        if result.returncode != 0 or noise:
            failures.append((res_path, result.returncode, noise[:6]))
        elif not args.quiet:
            print("  ok   %s" % path.relative_to(ADDON).as_posix())

    print("%d/%d script(s) parse" % (checked - len(failures), checked))
    for res_path, code, noise in failures:
        print("  FAIL %s (exit %s)" % (res_path, code))
        for line in noise:
            print("       " + line)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
