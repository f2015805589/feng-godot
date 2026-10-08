"""Check terrain editor helpers in an isolated editor without the native library."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from fixture import runner_parser


ADDON = Path(__file__).resolve().parents[2]
MARKER = "PASS terrain editor VT helpers:"


def main() -> int:
    parser = runner_parser()
    args = parser.parse_args()
    editor = args.editor.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="terrain-vt-helpers-") as temporary:
        project = Path(temporary)
        target = project / "addons" / ADDON.name
        for relative in (
            "menu/directory_setup.gd",
            "src/vt_terrain_bridge.gd",
            "src/vt_editor_page_rows.gd",
            "src/vt_overview_image.gd",
            "src/vt_layout_preview.gd",
            "src/vt_avt_layout_preview.gd",
            "src/vt_clipmap_preview.gd",
        ):
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ADDON / relative, destination)
        # Prevent source-addon discovery from linking unrelated native plugins.
        for source in ADDON.parent.iterdir():
            if source.name != ADDON.name and (source / "plugin.cfg").is_file():
                placeholder = project / "addons" / source.name
                placeholder.mkdir(parents=True)
                (placeholder / ".gdignore").touch()
        driver = project / "addons" / "vt-helper-test"
        driver.mkdir()
        shutil.copyfile(Path(__file__).with_name("editor_vt_helpers.gd"), driver / "test.gd")
        (driver / "plugin.cfg").write_text(
            '[plugin]\nname="VT helper tests"\nscript="test.gd"\n', encoding="utf-8")
        config = project / "project.godot"
        config.write_text(
            'config_version=5\n[application]\nconfig/name="Terrain VT helpers"\n'
            '[editor_plugins]\nenabled=PackedStringArray()\n', encoding="utf-8")
        env = dict(os.environ)
        for variable, directory in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                                    ("XDG_DATA_HOME", "data"), ("APPDATA", "config"),
                                    ("LOCALAPPDATA", "cache")):
            path = project / directory
            path.mkdir(exist_ok=True)
            (path / ".gdignore").touch()
            env[variable] = str(path)
        command = [str(editor), "--headless", "--editor", "--path", str(project), "--audio-driver", "Dummy"]
        for stage, extra in (("import", ["--import"]), ("helpers", [])):
            if stage == "helpers":
                config.write_text(config.read_text().replace(
                    "enabled=PackedStringArray()",
                    'enabled=PackedStringArray("res://addons/vt-helper-test/plugin.cfg")'), encoding="utf-8")
            result = subprocess.run(command + extra, env=env, capture_output=True, text=True, timeout=120)
            output = result.stdout + result.stderr
            print(output, end="")
            if result.returncode or "ERROR:" in output or "leaked" in output.lower():
                return 1
            if stage == "helpers" and MARKER not in output:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
