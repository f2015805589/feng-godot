"""Run the automatic real-material AVT/SVT pressure regression."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from fixture import ROOT, is_environmental_error, log_errors, write_fixture


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--editor",
        type=Path,
        default=ROOT / "bin" / "godot.windows.editor.x86_64.exe",
    )
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument(
        "--extension",
        type=Path,
        help="optional Terrain3D DLL to copy into the fixture (useful for before/after runs)",
    )
    args = parser.parse_args()

    fixture = Path(tempfile.mkdtemp(prefix="terrain-vtpressure-", dir=ROOT / "bin"))
    write_fixture(fixture)
    (fixture / "vt_render_base.gd").write_text(
        Path(__file__).with_name("vt_render.gd").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="VT pressure tests"\n',
        encoding="utf-8",
    )
    if args.extension:
        extension = args.extension.resolve()
        if not extension.is_file():
            print(f"Extension DLL not found: {extension}")
            return 2
        destination = (
            fixture
            / "addons"
            / "feng-idweight-terrain"
            / "bin"
            / "libfeng-idweight-terrain.windows.debug.x86_64.dll"
        )
        shutil.copy2(extension, destination)

    env = os.environ.copy()
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)
    log = fixture / "vtpressure.log"
    print(f"FIXTURE={fixture}", flush=True)
    base = [str(args.editor.resolve()), "--path", str(fixture), "--audio-driver", "Dummy"]
    result: subprocess.CompletedProcess[str] | None = None
    try:
        with log.open("w", encoding="utf-8") as out:
            result = subprocess.run(
                base + ["--headless", "--editor", "--import"],
                env=env,
                stdout=out,
                stderr=subprocess.STDOUT,
                timeout=180,
                text=True,
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
                        str(Path(__file__).with_name("vt_pressure.gd").resolve()),
                    ],
                    env=env,
                    stdout=out,
                    stderr=subprocess.STDOUT,
                    timeout=600,
                    text=True,
                )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = log_errors(output)
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "VTPRESSURE")) and not is_environmental_error(line):
            print(line)
    exit_code = result.returncode if result is not None else 1
    marker = "PASS VT pressure remains stable for automatic real-material AVT/SVT and re-produces after move/edit"
    print(f"EXIT={exit_code} ERRORS={len(errors)} LOG={log}")
    return int(exit_code != 0 or bool(errors) or marker not in output)


if __name__ == "__main__":
    raise SystemExit(main())
