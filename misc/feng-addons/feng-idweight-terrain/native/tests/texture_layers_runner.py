"""Texture array, material and slope regression with an isolated physical addon copy.

This is the runner for texture_layers.gd, which renders the terrain off-screen and
reads the frame back, so it needs a real graphics driver.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from editor_dock_runner import ROOT, write_fixture

MARKER = "PASS height/ID/weight/slope debug shaders"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    fixture = Path(tempfile.mkdtemp(prefix="feng-texlayers-", dir=ROOT / "bin"))
    write_fixture(fixture)
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Texture layer tests"\n', encoding="utf-8")
    shots = fixture / "shots"
    shots.mkdir()
    env = os.environ.copy()
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)
    log = fixture / "texlayers.log"
    print(f"FIXTURE={fixture}", flush=True)
    base = [str(args.editor.resolve()), "--path", str(fixture), "--audio-driver", "Dummy"]
    try:
        with log.open("w", encoding="utf-8") as out:
            result = subprocess.run(base + ["--headless", "--editor", "--import"], env=env, stdout=out, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode == 0:
                result = subprocess.run(base + ["--rendering-method", "frp", "--rendering-driver", args.driver,
                    "--resolution", "320x240", "--position", "-10000,-10000", "--script",
                    str(Path(__file__).with_name("texture_layers.gd").resolve()),
                    "--", "", str(shots)],
                    env=env, stdout=out, stderr=subprocess.STDOUT, timeout=300)
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124
    output = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    passes = [line for line in output.splitlines() if line.startswith("PASS")]
    for line in output.splitlines():
        if line.startswith(("PASS", "SLOPE", "REGRESSION", "ERROR:", "SCRIPT ERROR:")):
            print(line)
    print(f"EXIT={result.returncode} PASSES={len(passes)} ERRORS={len(errors)} LOG={log}")
    return int(result.returncode != 0 or bool(errors) or MARKER not in output)


if __name__ == "__main__":
    raise SystemExit(main())
