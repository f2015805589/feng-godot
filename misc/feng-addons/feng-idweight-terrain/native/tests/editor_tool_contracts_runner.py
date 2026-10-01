"""Run pure terrain editor-tool contracts without its optional GDExtension."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--native-library", type=Path,
                        help="Also test owner bindings through this Linux x86_64 GDExtension library")
    args = parser.parse_args()
    editor = args.editor.resolve(strict=True)
    addon = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="terrain-editor-tool-contracts-") as temporary:
        project = Path(temporary)
        target = project / "addons/feng-idweight-terrain"
        for relative in [
            "menu/channel_packer.gd",
            "menu/channel_packer_support.gd",
            "src/editor_plugin.gd",
            "src/terrain_editor_binding.gd",
            "src/ui.gd",
            "tools/region_move_transaction.gd",
            "native/tests/editor_tool_contracts.gd",
            "native/tests/editor_binding_native.gd",
        ]:
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(addon / relative, destination)
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Terrain editor-tool contracts"\n',
            encoding="utf-8",
        )
        env = dict(os.environ)
        for variable, directory in [
            ("XDG_CONFIG_HOME", "config"),
            ("XDG_CACHE_HOME", "cache"),
            ("XDG_DATA_HOME", "data"),
            ("APPDATA", "config"),
            ("LOCALAPPDATA", "cache"),
        ]:
            env[variable] = str(project / directory)
        result = subprocess.run(
            [str(editor), "--headless", "--path", str(project), "--script",
             "res://addons/feng-idweight-terrain/native/tests/editor_tool_contracts.gd"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            check=False, timeout=120, env=env,
        )
        print(result.stdout, end="")
        if result.returncode or "ERROR:" in result.stdout or "TERRAIN EDITOR TOOL CONTRACTS PASS" not in result.stdout:
            return 1
        if args.native_library:
            shutil.copyfile(args.native_library.resolve(strict=True), project / "terrain_test.so")
            (project / "terrain_test.gdextension").write_text(
                '[configuration]\nentry_symbol="terrain_3d_init"\ncompatibility_minimum="4.5"\n'
                '[libraries]\nlinux.debug.x86_64="res://terrain_test.so"\n', encoding="utf-8")
            result = subprocess.run(
                [str(editor), "--headless", "--path", str(project), "--script",
                 "res://addons/feng-idweight-terrain/native/tests/editor_binding_native.gd"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                check=False, timeout=120, env=env,
            )
            print(result.stdout, end="")
            if result.returncode or "ERROR:" in result.stdout or "TERRAIN NATIVE EDITOR BINDING PASS" not in result.stdout:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
