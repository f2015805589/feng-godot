#!/usr/bin/env python3
"""Headless ownership and lighting contracts for optional Feng runtime producers."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ROOT / "misc/feng-addons"
SELECTED = {"feng-render-pipeline", "feng-fog", "feng-magic-gi"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    args = parser.parse_args()
    project = Path(tempfile.mkdtemp(prefix="feng-runtime-contracts-", dir=ROOT / "bin"))
    for addon in ADDONS.iterdir():
        if not (addon / "plugin.cfg").is_file():
            continue
        destination = project / "addons" / addon.name
        if addon.name in SELECTED:
            shutil.copytree(addon, destination, ignore=shutil.ignore_patterns("tests", "__pycache__"))
        else:
            destination.mkdir(parents=True)
            (destination / ".gdignore").touch()
    shutil.copy2(ROOT / "misc/scripts/tests/feng_runtime_contracts.gd", project / "contracts.gd")
    env = dict(os.environ)
    for key, folder in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("APPDATA", "config"), ("LOCALAPPDATA", "cache")):
        path = project / folder
        path.mkdir(exist_ok=True)
        env[key] = str(path)
    base = [str(args.editor.resolve()), "--headless", "--path", str(project), "--audio-driver", "Dummy"]
    for physical in (False, True):
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Feng runtime contracts"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
            f'lights_and_shadows/use_physical_light_units={str(physical).lower()}\n', encoding="utf-8")
        stages = [("contracts", ["--script", "res://contracts.gd"])]
        if not physical:
            stages.insert(0, ("import", ["--editor", "--recovery-mode", "--import"]))
        for stage, extra in stages:
            result = subprocess.run(base + extra, env=env, capture_output=True, text=True, timeout=120)
            output = result.stdout + result.stderr
            (project / f"{stage}-{physical}.log").write_text(output, encoding="utf-8")
            errors = [line for line in output.splitlines() if "ERROR:" in line or "leaked" in line.lower()
                      or "still in use at exit" in line.lower()]
            if result.returncode or errors or (stage == "contracts" and "FENG_RUNTIME_CONTRACTS failures=0" not in output):
                print(output)
                print("Fixture:", project)
                return 1
            print(f"PASS {stage} physical={physical}")
    print("Fixture:", project)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
