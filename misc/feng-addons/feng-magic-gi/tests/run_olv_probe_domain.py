#!/usr/bin/env python3
"""Run the byte-payload/CLV-gate contract in an isolated headless Godot project."""

import argparse
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
DEFAULT_EDITOR = ROOT / "bin/godot.windows.editor.x86_64.exe"
TEST_SCRIPT = "res://addons/feng-magic-gi/tests/test_olv_probe_domain_payload.gd"
RESULT_RE = re.compile(r"^MAGIC_GI_OLV_PROBE_DOMAIN_RESULT failures=(\d+) checks=(\d+)[ \t]*$",
                       re.MULTILINE)
FAILURE_MARKERS = ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--work-dir", type=Path)
    args = parser.parse_args()
    editor = args.editor.resolve()
    if not editor.is_file():
        raise SystemExit(f"Godot editor binary not found: {editor}")
    project = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(
        prefix="olv-probe-domain-", dir=ROOT / "Temp"))
    addons = project / "addons"
    addons.mkdir(parents=True, exist_ok=True)
    target = addons / "feng-magic-gi"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ROOT / "misc/feng-addons/feng-magic-gi", target)
    shutil.copytree(ROOT / "misc/feng-addons/feng-olv", addons / "feng-olv", ignore=shutil.ignore_patterns("data","model","tools","__pycache__"))
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="OLV probe-domain CPU contract"\n',
        encoding="utf-8",
    )
    env = dict(os.environ)
    for name, leaf in (("APPDATA", "config"), ("LOCALAPPDATA", "cache"),
                       ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                       ("XDG_DATA_HOME", "data")):
        env[name] = str(project / leaf)
        (project / leaf).mkdir(exist_ok=True)
    log_path = project / "olv_probe_domain.log"
    command = [str(editor), "--headless", "--verbose", "--quit-after", "300", "--path", str(project),
               "--audio-driver", "Dummy", "--script", TEST_SCRIPT]
    with log_path.open("wb") as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                timeout=300)
    output = log_path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
    print(output, end="" if output.endswith("\n") else "\n")
    errors = [line for line in output.splitlines()
              if any(marker in line for marker in FAILURE_MARKERS)
              and "Failed to read the root certificate store." not in line]
    matches = RESULT_RE.findall(output)
    if result.returncode != 0 or errors or len(matches) != 1:
        raise SystemExit(f"OLV probe-domain contract failed; inspect {log_path}")
    failures, checks = map(int, matches[0])
    if failures != 0 or checks < 15:
        raise SystemExit(f"OLV probe-domain result rejected: failures={failures} checks={checks}")
    print(f"PASS OLV probe-domain payload contract: checks={checks} project={project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
