"""Run the RT any-hit accepted/rejected source contract in a CPU-only project."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, help="New scratch directory; it must not already exist")
    args = parser.parse_args()
    editor = args.editor.resolve(strict=True)
    project = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="feng-rt-any-hit-contract-"))
    if args.work_dir:
        project.mkdir(parents=True, exist_ok=False)
    addon_src = ROOT / "misc/feng-addons/feng-fog"
    addon_dst = project / "addons/feng-fog"
    addon_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(addon_src, addon_dst)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Fog RT any-hit CPU contract"\n',
        encoding="utf-8",
    )
    env = dict(os.environ)
    for name, leaf in (
        ("APPDATA", "config"),
        ("LOCALAPPDATA", "cache"),
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_DATA_HOME", "data"),
    ):
        env[name] = str(project / leaf)
        (project / leaf).mkdir(exist_ok=True)
    command = [
        str(editor), "--headless", "--quit-after", "120", "--path", str(project), "--audio-driver", "Dummy",
        "--script", "res://addons/feng-fog/tests/test_raytracing_any_hit_contract.gd",
    ]
    log = project / "raytracing_any_hit_contract.log"
    with log.open("wb") as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=60)
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    if result.returncode or "PASS RT any-hit accepted/rejected contract" not in text or any(
        marker in text for marker in ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")
    ):
        raise SystemExit(f"RT any-hit contract test failed; see {log}")
    print(f"PASS RT any-hit contract runner: {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
