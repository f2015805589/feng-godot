"""Run the environment visibility packet checks in a disposable headless project."""

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
    project = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="feng-volume-env-vis-"))
    if args.work_dir:
        if project == ROOT or ROOT in project.parents:
            raise SystemExit("Scratch project must be outside the repository")
        project.mkdir(parents=True, exist_ok=False)
    addons = project / "addons"
    addons.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "misc/feng-addons/feng-fog", addons / "feng-fog")
    shutil.copytree(ROOT / "misc/feng-addons/feng-render-pipeline", addons / "feng-render-pipeline")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Fog environment visibility CPU contract"\n',
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
        "res://addons/feng-fog/tests/test_volume_environment_visibility.gd",
    ]
    log = project / "volume_environment_visibility.log"
    with log.open("wb") as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="")
    if result.returncode or "PASS volume environment visibility" not in text or any(
        marker in text for marker in ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")
    ):
        raise SystemExit(f"Environment visibility CPU checks failed; see {log}")
    print(f"PASS volume environment visibility runner: {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
