"""Run the Feng Sky resource and World3D lifecycle checks with a Godot editor binary."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-sky"
PIPELINE_ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-render-pipeline"


def run(command: list[str], label: str) -> None:
    print(f"== {label} ==", flush=True)
    result = subprocess.run(
        command,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
        timeout=300,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(f"{label} failed with exit code {result.returncode}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True, help="Path to a Godot editor executable")
    args = parser.parse_args()
    editor = args.editor.resolve()
    if not editor.is_file():
        raise SystemExit(f"Godot editor not found: {editor}")

    with tempfile.TemporaryDirectory(prefix="feng-sky-tests-") as temp_dir:
        project = Path(temp_dir)
        shutil.copytree(ADDON_SOURCE, project / "addons/feng-sky")
        shutil.copytree(PIPELINE_ADDON_SOURCE, project / "addons/feng-render-pipeline")
        (project / "project.godot").write_text(
            'config_version=5\n'
            '[application]\n'
            'config/name="Feng Sky tests"\n'
            '[rendering]\n'
            'renderer/rendering_method="frp"\n'
            '[editor_plugins]\n'
            'enabled=PackedStringArray("res://addons/feng-sky/plugin.cfg")\n',
            encoding="utf-8",
        )

        run(
            [str(editor), "--headless", "--editor", "--path", str(project), "--quit-after", "1"],
            "headless editor plugin import",
        )
        run(
            [
                str(editor),
                "--headless",
                "--path",
                str(project),
                "--script",
                "res://addons/feng-sky/tests/test_sky_atmosphere.gd",
            ],
            "headless Sky component tests",
        )


if __name__ == "__main__":
    main()
