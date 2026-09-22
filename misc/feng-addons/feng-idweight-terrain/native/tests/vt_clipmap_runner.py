"""GPU regression for the clipmap ring: its addressing, its strips, its budget and its content."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from fixture import ROOT, write_fixture


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    fixture = Path(tempfile.mkdtemp(prefix="terrain-vtclipmap-", dir=ROOT / "bin"))
    write_fixture(fixture)
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="VT clipmap tests"\n',
        encoding="utf-8",
    )
    env = os.environ.copy()
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)
    log = fixture / "vtclipmap.log"
    print(f"FIXTURE={fixture}", flush=True)
    base = [str(args.editor.resolve()), "--path", str(fixture), "--audio-driver", "Dummy"]
    try:
        with log.open("w", encoding="utf-8") as out:
            result = subprocess.run(
                base + ["--headless", "--editor", "--import"],
                env=env,
                stdout=out,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
            if result.returncode == 0:
                result = subprocess.run(
                    base
                    + [
                        "--rendering-method",
                        "frp",
                        "--rendering-driver",
                        args.driver,
                        "--resolution",
                        "320x240",
                        "--position",
                        "-10000,-10000",
                        "--script",
                        str(Path(__file__).with_name("vt_clipmap.gd").resolve()),
                    ],
                    env=env,
                    stdout=out,
                    stderr=subprocess.STDOUT,
                    timeout=360,
                )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124
    output = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "VT_CLIPMAP")):
            print(line)
    print(f"EXIT={result.returncode} ERRORS={len(errors)} LOG={log}")
    return int(result.returncode != 0 or bool(errors) or "PASS clipmap ring" not in output)


if __name__ == "__main__":
    raise SystemExit(main())
