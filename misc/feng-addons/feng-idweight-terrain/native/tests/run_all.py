#!/usr/bin/env python3
"""Run every terrain integration test and print one summary.

Each test is a `<name>_runner.py` beside this file; the runner scripts build
their own isolated project fixture under bin/ and decide pass/fail. This script
only schedules them, collects their output, and cleans up the fixture the
runner reports, so a full regression is one command:

    python misc/feng-addons/feng-idweight-terrain/native/tests/run_all.py

Use --driver vulkan on machines where the D3D12 device is unstable, --only to
run a subset, and --prune to delete fixtures leaked by earlier runs.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# HERE is already the tests directory, so the checkout is four levels up.
ROOT = HERE.parents[4]
BIN = ROOT / "bin"

FIXTURE_PREFIXES = ("terrain-", "feng-editor-dock-clean-")
FIXTURE_PATTERN = re.compile(r"^FIXTURE=(.+)$", re.MULTILINE)

# name -> (runner script, extra arguments). Every *_runner.py is picked up
# automatically; this table only documents the extra argument sets.
EDITOR_DOCK_TESTS = ("dock", "input", "setup", "grid", "pairroles", "svt_inspector", "vt_idle", "slider")

# Modes of a multi-mode runner. Discovery without extra arguments runs only a runner's *default*
# mode, and `vt_adaptive_runner.py` is one entry point for fourteen scenarios: it takes a flag per
# scenario and otherwise always runs `vt_adaptive.gd`. Every scenario it can select is a test script
# of its own, so a full regression that skipped the flags left thirteen scripts - camera rotation,
# source blending, 10 km sectors, metric density, region ownership, strict filtering, async pages,
# navigation, residency, instancer, CDLOD, profile and full sectors - with no way to be run at all,
# and a fourth (`vt_resolution_controls.gd`, which the runner executes after a successful scenario)
# with it.
ADAPTIVE_TESTS = ("scale", "metric", "ownership", "filtering", "async-pages", "navigation",
                  "residency", "rotation", "instancer", "blend", "cdlod", "profile", "sectors")


def discover() -> list[tuple[str, list[str]]]:
    """Every runnable test, in a stable order."""
    tests: list[tuple[str, list[str]]] = []
    for test in EDITOR_DOCK_TESTS:
        tests.append((f"editor_dock:{test}", ["editor_dock_runner.py", "--test", test]))
    for mode in ADAPTIVE_TESTS:
        tests.append((f"vt_adaptive:{mode}", ["vt_adaptive_runner.py", f"--{mode}"]))
    for runner in sorted(HERE.glob("*_runner.py")):
        if runner.name in {"editor_dock_runner.py", "run_all.py"}:
            continue
        tests.append((runner.stem.removesuffix("_runner"), [runner.name]))
    return tests


def prune() -> int:
    """Delete fixtures leaked by earlier runs. Returns the count removed."""
    removed = 0
    for path in BIN.glob("*"):
        if path.is_dir() and path.name.startswith(FIXTURE_PREFIXES):
            shutil.rmtree(path, ignore_errors=True)
            removed += 1
    return removed


def run_one(name: str, argv: list[str], driver: str, keep: bool, timeout: float) -> dict:
    command = [sys.executable, str(HERE / argv[0]), "--driver", driver, *argv[1:]]
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        code, output = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as expired:
        code = 124
        output = (expired.stdout or "") + (expired.stderr or "")
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
    elapsed = time.monotonic() - started

    marker = FIXTURE_PATTERN.search(output)
    fixture = Path(marker.group(1).strip()) if marker else None
    if fixture and not keep and fixture.is_dir():
        shutil.rmtree(fixture, ignore_errors=True)

    lines = [line for line in output.splitlines()
             if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "TIMEOUT"))]
    failures = [line for line in lines if not line.startswith("PASS")]
    if code == 0 and not failures:
        status = "pass"
    elif failures:
        status = "fail"
    else:
        status = f"exit {code}"
    return {"name": name, "status": status, "seconds": round(elapsed, 1),
            "lines": lines, "log": str(fixture or "")}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--driver", default="vulkan", help="rendering driver (default: vulkan)")
    parser.add_argument("--only", default="", help="substring filter on the test name")
    parser.add_argument("--list", action="store_true", help="list the tests and exit")
    parser.add_argument("--keep", action="store_true", help="keep each test's fixture")
    parser.add_argument("--prune", action="store_true", help="delete leaked fixtures first")
    parser.add_argument("--prune-only", action="store_true", help="delete leaked fixtures and exit")
    parser.add_argument("--timeout", type=float, default=900.0, help="per test timeout in seconds")
    parser.add_argument("--json", type=Path, default=None, help="write the summary as JSON here")
    args = parser.parse_args()

    if args.prune_only:
        print(f"pruned {prune()} leaked fixtures from {BIN}", flush=True)
        return 0
    tests = discover()
    if args.only:
        tests = [test for test in tests if args.only in test[0]]
    if args.list:
        for name, _ in tests:
            print(name)
        return 0
    if not tests:
        print("no tests matched", file=sys.stderr)
        return 2
    if args.prune:
        print(f"pruned {prune()} leaked fixtures from {BIN}", flush=True)

    results = []
    for index, (name, argv) in enumerate(tests, 1):
        print(f"[{index}/{len(tests)}] {name} ...", flush=True)
        result = run_one(name, argv, args.driver, args.keep, args.timeout)
        results.append(result)
        print(f"    {result['status'].upper()} in {result['seconds']}s", flush=True)
        for line in result["lines"]:
            print(f"      {line}", flush=True)

    failed = [result for result in results if result["status"] != "pass"]
    print("\n=== summary ===")
    for result in results:
        print(f"{result['status']:>8}  {result['seconds']:>7.1f}s  {result['name']}")
    print(f"\n{len(results) - len(failed)}/{len(results)} passed (driver {args.driver})")
    if args.json:
        args.json.write_text(json.dumps(results, indent=2), encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
