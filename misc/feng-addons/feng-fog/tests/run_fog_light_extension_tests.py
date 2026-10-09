"""Run per-light extension CPU contract checks in a disposable project."""

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
    project = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="feng-fog-light-ext-"))
    if args.work_dir:
        if project == ROOT or ROOT in project.parents:
            raise SystemExit("Scratch project must be outside the repository")
        project.mkdir(parents=True, exist_ok=False)
    addon_root = ROOT / "misc/feng-addons"
    shutil.copytree(addon_root / "feng-fog", project / "addons/feng-fog")
    shutil.copytree(addon_root / "feng-sky", project / "addons/feng-sky")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Fog light extension CPU contract"\n',
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
        str(editor), "--headless", "--quit-after", "120", "--path", str(project),
        "--audio-driver", "Dummy", "--script",
        "res://addons/feng-fog/tests/test_fog_light_extensions.gd",
    ]
    log = project / "fog_light_extensions.log"
    with log.open("wb") as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    if result.returncode or "PASS fog light extensions" not in text or any(
        marker in text for marker in ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")
    ):
        raise SystemExit(f"Fog light extension CPU contract failed; see {log}")
    print(f"PASS fog light extension runner: {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

