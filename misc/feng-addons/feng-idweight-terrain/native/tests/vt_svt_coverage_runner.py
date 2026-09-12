"""Run the persisted-material SVT coverage regression with a real GPU renderer."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from editor_dock_runner import ROOT, write_fixture


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=ROOT / "bin" / "godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()

    editor = args.editor.resolve()
    if not editor.is_file():
        print(f"Editor executable not found: {editor}")
        return 2

    fixture = Path(tempfile.mkdtemp(prefix="terrain-vt-svt-coverage-", dir=ROOT / "bin"))
    write_fixture(fixture)
    (fixture / "vt_render_base.gd").write_text(
        Path(__file__).with_name("vt_render.gd").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="SVT coverage tests"\n',
        encoding="utf-8",
    )
    shots = fixture / "shots"
    shots.mkdir()
    env = os.environ.copy()
    for key, folder in (("APPDATA", "config"), ("LOCALAPPDATA", "cache")):
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)

    log = fixture / "vtsvtcoverage.log"
    print(f"FIXTURE={fixture}", flush=True)
    base = [str(editor), "--path", str(fixture), "--audio-driver", "Dummy"]
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
                        str(Path(__file__).with_name("vt_svt_coverage.gd").resolve()),
                        "--",
                        "",
                        str(shots),
                    ],
                    env=env,
                    stdout=out,
                    stderr=subprocess.STDOUT,
                    timeout=900,
                    text=True,
                )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "VTSVTCOVER")):
            print(line)
    exit_code = result.returncode if result is not None else 1
    marker = "PASS persisted SVT covers visible non-AVT regions under eight-page shared-pool pressure"
    print(f"EXIT={exit_code} ERRORS={len(errors)} LOG={log}")
    return int(exit_code != 0 or bool(errors) or marker not in output)


if __name__ == "__main__":
    raise SystemExit(main())
