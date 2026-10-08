#!/usr/bin/env python3
"""Parse-check addon scripts with the engine's --check-only mode, outside the test suite.

    python native/check_scripts.py                every addon .gd except test fixtures
    python native/check_scripts.py asset_dock.gd  select by basename or addon-relative path

Use --project for an imported disposable project with the addon installed so res:// paths resolve.
The default is F:/godot/project/test-1; --engine defaults to the checkout's Windows editor console
binary. Native test scripts are excluded because their runners use different resource paths.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent
# native/ sits four levels below the checkout.
CHECKOUT = HERE.parents[3]

DEFAULT_PROJECT = Path(r"F:\godot\project\test-1")
DEFAULT_ENGINE = CHECKOUT / "bin" / "godot.windows.editor.x86_64.console.exe"
RES_ROOT = "res://addons/feng-idweight-terrain"
# Test runners relocate scripts into fixture roots, with different res:// paths.
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
        # Treat all output except the engine banner as a failure.
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
