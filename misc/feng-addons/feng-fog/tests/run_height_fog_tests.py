"""Run Unreal-style height-fog unit and optional rendered regressions."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, help="New, nonexistent scratch directory outside the repository")
    parser.add_argument("--physical-units", choices=("true", "false"), default="true")
    parser.add_argument("--gpu-driver", help="Run rendered checks as well, e.g. vulkan or d3d12")
    args = parser.parse_args()
    editor = args.editor.resolve(strict=True)
    if args.work_dir:
        project = args.work_dir.resolve()
        if project == ROOT or ROOT in project.parents:
            raise SystemExit("Scratch project must be outside the repository")
        project.mkdir(parents=True, exist_ok=False)
    else:
        project = Path(tempfile.mkdtemp(prefix="feng-height-fog-"))
    print("Scratch project:", project, flush=True)
    selected = {"feng-render-pipeline", "feng-sky", "feng-fog"}
    for addon in (ROOT / "misc/feng-addons").iterdir():
        if not addon.is_dir() or not (addon / "plugin.cfg").is_file():
            continue
        target = project / "addons" / addon.name
        if addon.name in selected:
            shutil.copytree(addon, target)
        else:
            # Prevent the editor's sibling-addon auto-linking from writing to
            # the source tree or loading unrelated native extensions.
            target.mkdir(parents=True)
            (target / ".gdignore").touch()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Unreal height fog regression"\n'
        '[rendering]\nrenderer/rendering_method="frp"\n'
        f"lights_and_shadows/use_physical_light_units={args.physical_units}\n",
        encoding="utf-8",
    )
    env = dict(os.environ)
    for name, subdir in (
        ("APPDATA", "config"),
        ("LOCALAPPDATA", "cache"),
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_DATA_HOME", "data"),
    ):
        env[name] = str(project / subdir)
        (project / subdir).mkdir(exist_ok=True)
    base = [str(editor), "--path", str(project), "--audio-driver", "Dummy"]

    def run(label, extra, marker=None):
        log = project / (label + ".log")
        with log.open("wb") as output:
            result = subprocess.run(base + extra, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        output = log.read_text(encoding="utf-8", errors="replace")
        print(output[-20000:], end="", flush=True)
        if result.returncode or any(
            error in output for error in ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")
        ):
            raise SystemExit(f"{label} failed: {log}")
        if marker and marker not in output:
            raise SystemExit(f"{label} missed success marker: {log}")
        print("PASS", label, flush=True)

    run("import", ["--headless", "--editor", "--recovery-mode", "--import"])
    run("height_fog_unit", ["--headless", "--script", "res://addons/feng-fog/tests/test_height_fog.gd"], "PASS Unreal height fog")
    run(
        "sky_unit",
        ["--headless", "--script", "res://addons/feng-sky/tests/test_sky_atmosphere.gd"],
        "feng_sky_atmosphere tests passed",
    )
    if args.gpu_driver:
        run(
            "height_fog_gpu",
            [
                "--rendering-method",
                "frp",
                "--rendering-driver",
                args.gpu_driver,
                "--resolution",
                "320x240",
                "--position",
                "-10000,-10000",
                "--script",
                "res://addons/feng-fog/tests/test_height_fog_gpu.gd",
            ],
            "PASS Unreal height fog GPU",
        )


if __name__ == "__main__":
    main()
