#!/usr/bin/env python3
"""Run the focused FRP pre-exposure GPU regression in physical and legacy units."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[3]
ADDONS = ROOT / "misc" / "feng-addons"
TEST = ROOT / "misc" / "scripts" / "tests" / "frp_exposure_balance.gd"
SELECTED_ADDONS = ("feng-render-pipeline", "feng-magic-gi", "feng-fog")


def default_binary() -> Path:
    candidates = (
        ROOT / "bin" / "godot.windows.editor.x86_64.exe",
        ROOT / "bin" / "godot.windows.editor.x86_64.console.exe",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


def run(binary: Path, driver: str, mode: str, physical: bool) -> Path:
    # Test outputs and projects are ignored build artifacts under bin/.
    (ROOT / "bin").mkdir(exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix=f"frp-exposure-{mode}-", dir=ROOT / "bin"))
    addons = project / "addons"
    addons.mkdir()
    for name in SELECTED_ADDONS:
        shutil.copytree(ADDONS / name, addons / name)
    # Keep sibling addons out of Godot's auto-link scan for an isolated run.
    for addon in ADDONS.iterdir():
        if addon.name not in SELECTED_ADDONS and (addon / "plugin.cfg").is_file():
            placeholder = addons / addon.name
            placeholder.mkdir()
            (placeholder / ".gdignore").touch()

    setting = "true" if physical else "false"
    (project / "project.godot").write_text(
        "config_version=5\n[application]\nconfig/name=\"FRP exposure balance tests\"\n"
        "[rendering]\nrenderer/rendering_method=\"frp\"\n"
        f"lights_and_shadows/use_physical_light_units={setting}\n",
        encoding="utf-8",
    )
    env = dict(os.environ)
    env["APPDATA"] = str(project / "config")
    env["LOCALAPPDATA"] = str(project / "cache")
    env["FRP_EXPOSURE_DUMP_DIR"] = str(project)
    env["FRP_EXPOSURE_LIGHT_MODE"] = mode
    startup = None
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0

    base = [
        str(binary), "--path", str(project), "--rendering-method", "frp",
        "--rendering-driver", driver, "--resolution", "320x240",
        "--position", "-10000,-10000",
    ]
    for name, extra in (
        ("import", ["--editor", "--recovery-mode", "--import"]),
        ("gpu", ["--script", str(TEST)]),
    ):
        log = project / f"{name}.log"
        with log.open("wb") as output:
            result = subprocess.run(
                base + extra,
                env=env,
                stdout=output,
                stderr=subprocess.STDOUT,
                startupinfo=startup,
                timeout=300,
                check=False,
            )
        text = log.read_text(encoding="utf-8", errors="replace")
        print(f"--- {mode} / {name} exit={result.returncode} ---")
        print(text[-16000:])
        if result.returncode != 0:
            raise RuntimeError(f"{mode}/{name} failed; see {log}")
        if name == "gpu":
            expected = (
                "PASS FRP PE-on/off keeps Sky, Magic GI and Height Fog"
                if physical
                else "INCONCLUSIVE PE threshold check for non-physical energy=60000"
            )
            if expected not in text:
                raise RuntimeError(f"{mode} did not report expected result; see {log}")
    print("Fixture:", project)
    return project


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", default="vulkan")
    parser.add_argument("--binary", type=Path, default=default_binary())
    args = parser.parse_args()
    if not args.binary.is_file():
        print(f"Godot editor binary not found: {args.binary}; pass --binary", file=sys.stderr)
        return 2

    run(args.binary, args.driver, "nonphysical_energy", False)
    run(args.binary, args.driver, "physical_lux", True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
