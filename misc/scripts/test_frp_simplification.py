#!/usr/bin/env python3
"""Check FRP's fixed internal contracts in an isolated project, without rendering scenes."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MARKER = "PASS FRP fixed schedule contracts, custom parameter layers, texture dependencies and binding fallback"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin" / (
        "godot.windows.editor.x86_64.exe" if os.name == "nt" else "godot.linuxbsd.editor.x86_64"))
    parser.add_argument("--driver", default="d3d12" if os.name == "nt" else "vulkan")
    parser.add_argument("--headless", action="store_true", help="use the dummy display for CPU-only contract checks")
    args = parser.parse_args()
    project = Path(tempfile.mkdtemp(prefix="frp-contract-tests-", dir=ROOT / "bin"))
    shutil.copytree(ROOT / "misc/feng-addons/feng-render-pipeline", project / "addons/feng-render-pipeline")
    # The editor's sibling linker must not bring unrelated editor plugins into the test.
    for addon in (ROOT / "misc/feng-addons").iterdir():
        if addon.name != "feng-render-pipeline" and (addon / "plugin.cfg").is_file():
            placeholder = project / "addons" / addon.name
            placeholder.mkdir()
            (placeholder / ".gdignore").touch()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="FRP contract tests"\n'
        '[rendering]\nrenderer/rendering_method="frp"\n', encoding="utf-8")
    env = dict(os.environ, APPDATA=str(project / "config"), LOCALAPPDATA=str(project / "cache"),
               XDG_DATA_HOME=str(project / "data"), XDG_CONFIG_HOME=str(project / "config"),
               XDG_CACHE_HOME=str(project / "cache"))
    base = [str(args.binary.resolve()), "--path", str(project), "--rendering-method", "frp",
            "--rendering-driver", args.driver, "--audio-driver", "Dummy",
            "--resolution", "320x240", "--position", "-10000,-10000"]
    if args.headless:
        base.append("--headless")
    print("Logs:", project, flush=True)
    runs = [
        ("import", ["--editor", "--recovery-mode", "--import"], None),
        ("contracts", ["--script", str(ROOT / "misc/scripts/tests/frp_simplification.gd")], MARKER),
    ]
    for name, extra, marker in runs:
        log = project / (name + ".log")
        with log.open("wb") as output:
            result = subprocess.run(base + extra, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text(encoding="utf-8", errors="replace")
        errors = [line for line in text.splitlines()
                  if "ERROR:" in line and "Failed to read the root certificate store." not in line]
        if result.returncode or errors or (marker and marker not in text):
            raise RuntimeError(f"{name} failed (exit {result.returncode}):\n{text[-12000:]}")
        print("PASS", name, flush=True)


if __name__ == "__main__":
    main()
