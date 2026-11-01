#!/usr/bin/env python3
"""Isolated GPU regression for independent OLV partition volumes.

Creates a throwaway Godot project under Temp/, copies the addons it needs, and
runs two SceneTree fixtures with a real RenderingDevice:

  olv_pre_gate    test_magic_gi_olv_preinterpolation.gd   (MAGIC_GI_OLV_GATE)
  legacy_control  test_preinterpolated_clv_sky_ownership.gd, the existing
                  production regression compiled WITHOUT any OLV define, so the
                  undefined-define source path is exercised too

Every run is checked for its final marker, for renderer ERROR lines and for
leaked objects/RIDs. Logs stay next to the project for audit.

Usage:
    python misc/feng-addons/feng-render-pipeline/tests/run_magic_gi_olv.py
    python .../run_magic_gi_olv.py --binary /path/to/godot --driver vulkan
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[3]

parser = argparse.ArgumentParser()
parser.add_argument("--driver", default="vulkan",
                    help="rendering driver (the OLV fixture is documented on vulkan)")
parser.add_argument("--binary", default=None,
                    help="editor binary to run (defaults to the in-tree Windows editor)")
parser.add_argument("--method", default="mobile",
                    help="rendering method (the prepared CLV sampler is not FRP-only)")
args = parser.parse_args()

binary = Path(args.binary) if args.binary else ROOT / "bin/godot.windows.editor.x86_64.console.exe"
if not binary.is_file():
    sys.exit("editor binary not found: %s" % binary)

ADDONS = ("feng-render-pipeline", "feng-magic-gi", "feng-olv", "feng-fog", "feng-sky", "feng-cloud")
(ROOT / "Temp").mkdir(exist_ok=True)
project = Path(tempfile.mkdtemp(prefix="olv-tests-", dir=ROOT / "Temp"))
for name in ADDONS:
    shutil.copytree(ROOT / "misc/feng-addons" / name, project / "addons" / name, ignore=shutil.ignore_patterns("data","model","tools","__pycache__") if name=="feng-olv" else None)
# The editor auto-links sibling addons; keep this regression isolated from their
# native DLL reloads, capture injection and editor tools.
for addon in (ROOT / "misc/feng-addons").iterdir():
    if addon.name not in ADDONS and (addon / "plugin.cfg").is_file():
        placeholder = project / "addons" / addon.name
        placeholder.mkdir()
        (placeholder / ".gdignore").touch()
(project / "project.godot").write_text(
    'config_version=5\n[application]\nconfig/name="OLV GPU tests"\n'
    '[rendering]\nrenderer/rendering_method="%s"\n' % args.method, encoding="utf-8")

env = dict(os.environ, APPDATA=str(project / "config"),
           LOCALAPPDATA=str(project / "cache"), XDG_DATA_HOME=str(project / "data"),
           XDG_CONFIG_HOME=str(project / "config"), XDG_CACHE_HOME=str(project / "cache"),
           FRP_ENGINE_SOURCE_ROOT=str(ROOT))
startup = None
if os.name == "nt":
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0

base = [str(binary), "--path", str(project), "--rendering-method", args.method,
        "--rendering-driver", args.driver, "--audio-driver", "Dummy",
        "--resolution", "320x240", "--position", "-10000,-10000"]

# Host-side noise unrelated to the renderer.
UNRELATED_ERRORS = (
    "Failed to read the root certificate store.",
    'Condition "status < 0" is true. Returning: ERR_CANT_OPEN',
)
LEAK_PATTERNS = (
    "ObjectDB instances were leaked",
    "resources still in use at exit",
)

failures = []


def run(name, extra, marker, minimum_checks, timeout=240):
    log = project / (name + ".log")
    with log.open("wb") as output:
        result = subprocess.run(base + list(extra), env=env, stdout=output,
                                stderr=subprocess.STDOUT, startupinfo=startup,
                                timeout=timeout)
    text = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in text.splitlines()
              if "ERROR:" in line and not any(u in line for u in UNRELATED_ERRORS)]
    leaks = [line for line in text.splitlines()
             if any(p in line for p in LEAK_PATTERNS)
             or ("RID" in line.upper() and re.search(r"\b(leak|leaked|not freed)\b", line, re.I))]
    match = re.search(marker + r" checks=(\d+) failures=(\d+)", text) if marker else None
    problems = []
    if result.returncode != 0:
        problems.append("exit code %d" % result.returncode)
    if errors:
        problems.append("%d renderer error line(s)" % len(errors))
    if leaks:
        problems.append("%d leak line(s)" % len(leaks))
    if marker and not match:
        problems.append("missing marker %r" % marker)
    elif match and int(match.group(2)) != 0:
        problems.append("%s failures=%s" % (marker, match.group(2)))
    elif match and int(match.group(1)) < minimum_checks:
        problems.append("only %s checks, expected >= %d" % (match.group(1), minimum_checks))
    if problems:
        failures.append(name)
        print("FAIL", name, "->", "; ".join(problems))
        for line in (errors + leaks)[-10:]:
            print("   ", line.strip())
        print("    log:", log)
        print("    tail:", text[-1500:].replace("\n", "\n    "))
        return None
    print("PASS", name, "->", match.group(0) if match else "clean exit", "(exit 0)")
    return text


def report_device():
    """Print the renderer/GPU banner so the evidence names the device used."""
    for name in ("olv_pre_gate", "legacy_control"):
        log = project / (name + ".log")
        if not log.is_file():
            continue
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = line.strip()
            if "Vulkan API" in stripped or "Using Vulkan Device" in stripped \
                    or "Direct3D 12" in stripped or stripped.startswith("Vulkan 1"):
                print("GPU:", stripped)
                return


# Each fixture compiles the production includes itself with a local
# RenderingDevice, so no editor import pass is required. Running one avoids the
# editor ShaderFile panel's is_visible_in_tree() thread errors, which come from
# the editor UI rather than from the renderer under test.
report_device_or_run = [
    ("olv_pre_gate",
     ["--script", "res://addons/feng-render-pipeline/tests/"
                 "test_magic_gi_olv_preinterpolation.gd"],
     r"OLV_PREINTERPOLATION_RESULT", 40),
    # The undefined-define control: the same production include, no OLV define.
    ("legacy_control",
     ["--script", "res://addons/feng-render-pipeline/tests/"
                 "test_preinterpolated_clv_sky_ownership.gd"],
     r"PREPARED_CLV_SKY_OWNERSHIP", 30),
]
for name, extra, marker, minimum in report_device_or_run:
    run(name, extra, marker, minimum)
    if name == "olv_pre_gate":
        report_device()

print("Project:", project)
print("Driver:", args.driver, "Method:", args.method, "Binary:", binary)
if failures:
    sys.exit("FAILED: %s" % ", ".join(failures))
print("PASS Magic GI OLV partition interpolation and unpartitioned sky ownership")
