#!/usr/bin/env python3
"""Check actual editor-tool lifetimes without launching external tools."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ROOT / "misc/feng-addons"
SELECTED = ("feng-renderdoc-capture", "feng-godottracy")
MARKER = "PASS Feng editor tools lifecycle:"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--driver", help="Use a native graphics driver instead of headless mode")
    args = parser.parse_args()
    (ROOT / "bin").mkdir(exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix="feng-tools-lifecycle-", dir=ROOT / "bin"))
    for name in SELECTED:
        shutil.copytree(ADDONS / name, project / "addons" / name,
                        ignore=shutil.ignore_patterns("native", "tests", "__pycache__"))
    for addon in ADDONS.iterdir():
        if addon.name not in SELECTED and (addon / "plugin.cfg").is_file():
            placeholder = project / "addons" / addon.name
            placeholder.mkdir(parents=True)
            (placeholder / ".gdignore").touch()
    driver = project / "addons/lifecycle-test"
    driver.mkdir()
    shutil.copy2(ROOT / "misc/scripts/tests/feng_tools_lifecycle.gd", driver / "test.gd")
    (driver / "plugin.cfg").write_text('[plugin]\nname="Feng tools lifecycle"\nscript="test.gd"\n')
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Feng tools lifecycle"\n'
        '[editor_plugins]\nenabled=PackedStringArray()\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
    env = dict(os.environ)
    for key, folder in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("APPDATA", "config"), ("LOCALAPPDATA", "cache")):
        path = project / folder
        path.mkdir(exist_ok=True)
        env[key] = str(path)
    binary = str(args.editor.resolve())
    base = [binary, "--editor", "--path", str(project), "--audio-driver", "Dummy"]
    if args.driver:
        base += ["--rendering-method", "frp", "--rendering-driver", args.driver]
    else:
        base += ["--headless"]
    for stage, extra in (("import", ["--import"]), ("lifecycle", [])):
        if stage == "lifecycle":
            config = project / "project.godot"
            config.write_text(config.read_text().replace('enabled=PackedStringArray()',
                'enabled=PackedStringArray("res://addons/lifecycle-test/plugin.cfg")'), encoding="utf-8")
        result = subprocess.run(base + extra, env=env, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        (project / (stage + ".log")).write_text(output, encoding="utf-8")
        errors = [line for line in output.splitlines() if "ERROR:" in line or "leaked" in line.lower()
                  or "still in use at exit" in line.lower()]
        print(f"{stage}: exit={result.returncode} errors/leaks={len(errors)}")
        if result.returncode or errors or (stage == "lifecycle" and MARKER not in output):
            print(output)
            print("Fixture:", project)
            return 1
        if stage == "lifecycle":
            print(next(line for line in output.splitlines() if MARKER in line))
    # Python runs the harmless `launch` script rather than launching an
    # analyzer or another editor. This also works on Windows without a shell.
    shutil.copy2(ROOT / "misc/scripts/tests/feng_renderdoc_arguments.gd", project / "arguments.gd")
    (project / "launch").write_text(
        "import json, os, sys\nfrom pathlib import Path\n"
        "Path(os.environ['FENG_RELAUNCH_ARGUMENTS']).write_text(json.dumps(sys.argv))\n",
        encoding="utf-8")
    env["FENG_RELAUNCH_HELPER"] = sys.executable
    env["FENG_RELAUNCH_ARGUMENTS"] = str(project / "arguments.json")
    result = subprocess.run([binary, "--headless", "--path", str(project),
        "--script", "res://arguments.gd", "--audio-driver", "Dummy", "--",
        "--probe-user-arg", "spaces 中文"], cwd=project, env=env, capture_output=True,
        text=True, timeout=30)
    output = result.stdout + result.stderr
    (project / "arguments.log").write_text(output, encoding="utf-8")
    if result.returncode or "ERROR:" in output or "PASS RenderDoc relaunch" not in output:
        print(output)
        print("Fixture:", project)
        return 1
    print("PASS RenderDoc relaunch preserves engine and user arguments")
    print("Fixture:", project)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
