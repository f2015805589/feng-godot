"""Run the Feng Sky resource and World3D lifecycle checks with a Godot editor binary."""

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-sky"
PIPELINE_ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-render-pipeline"
FOG_ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-fog"
WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT = 0x400


def assert_scratch_addon_target(project: Path, addons: Path, target: Path) -> None:
    """Refuse to import or write through an auto-linked addon directory."""
    project_real = project.resolve()
    addons_real = addons.resolve()
    target_real = target.resolve()
    try:
        project_real.relative_to(REPO_ROOT.resolve())
    except ValueError:
        pass
    else:
        raise SystemExit(f"Scratch project must be outside the repository: {project_real}")
    if addons_real != project_real / "addons":
        raise SystemExit(f"Scratch addons directory resolves outside the project: {addons_real}")
    if target_real.parent != addons_real:
        raise SystemExit(f"Scratch addon resolves outside the addons directory: {target_real}")
    if target.is_symlink() or (hasattr(target, "is_junction") and target.is_junction()):
        raise SystemExit(f"Refusing to follow a scratch addon link: {target}")


def validate_scratch_tree(project: Path) -> None:
    """Reject nested junctions, symlinks, hardlinks, and scratch-path escapes."""
    project_real = project.resolve(strict=True)
    temp_root_real = Path(tempfile.gettempdir()).resolve(strict=True)
    try:
        project_real.relative_to(temp_root_real)
    except ValueError:
        raise SystemExit(f"Scratch project must be under the temp directory: {project_real}")
    if is_reparse_point(project):
        raise SystemExit(f"Refusing a reparse-point scratch project: {project}")
    for directory, child_directories, files in os.walk(project, followlinks=False):
        current = Path(directory)
        for name in [*child_directories, *files]:
            entry = current / name
            if is_reparse_point(entry):
                raise SystemExit(f"Refusing a scratch reparse point: {entry}")
            if entry.is_file() and entry.stat().st_nlink > 1:
                raise SystemExit(f"Refusing a hard-linked scratch file: {entry}")


def is_reparse_point(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False
    if path.is_symlink():
        return True
    attributes = getattr(metadata, "st_file_attributes", 0)
    return bool(attributes & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT)


def run(command: list[str], label: str, project: Path, env: dict[str, str], expected_marker: str = "") -> None:
    print(f"== {label} ==", flush=True)
    log = project / f"{label.replace(' ', '_')}.log"
    with log.open("wb") as output:
        result = subprocess.run(
            command,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=300,
        )
    output_text = log.read_text(encoding="utf-8", errors="replace")
    print(output_text[-12000:], end="")
    if result.returncode:
        raise SystemExit(f"{label} failed with exit code {result.returncode}; see {log}")
    if "REGRESSION:" in output_text or "SCRIPT ERROR:" in output_text or "Parse Error:" in output_text or "ERROR:" in output_text:
        raise SystemExit(f"{label} reported an engine or script error; see {log}")
    if expected_marker:
        if expected_marker not in output_text:
            raise SystemExit(f"{label} did not report expected marker: {expected_marker}; see {log}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True, help="Path to a Godot editor executable")
    parser.add_argument("--work-dir", type=Path, help="Persistent scratch project directory for logs and user data")
    parser.add_argument("--physical-units", choices=("true", "false"), default="true")
    parser.add_argument("--gpu-driver", help="Also run the GPU scene probe with this driver, e.g. d3d12")
    args = parser.parse_args()
    editor = args.editor.resolve()
    if not editor.is_file():
        raise SystemExit(f"Godot editor not found: {editor}")

    project = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix="feng-sky-tests-"))
    project.mkdir(parents=True, exist_ok=True)
    validate_scratch_tree(project)
    addons = project / "addons"
    addons.mkdir(exist_ok=True)
    assert_scratch_addon_target(project, addons, addons / "feng-sky")
    selected = {"feng-sky", "feng-render-pipeline", "feng-fog"}
    for name, source in (
        ("feng-sky", ADDON_SOURCE),
        ("feng-render-pipeline", PIPELINE_ADDON_SOURCE),
        ("feng-fog", FOG_ADDON_SOURCE),
    ):
        destination = addons / name
        validate_scratch_tree(project)
        assert_scratch_addon_target(project, addons, destination)
        shutil.copytree(source, destination, dirs_exist_ok=True)
        validate_scratch_tree(project)
        assert_scratch_addon_target(project, addons, destination)
        # A previous run may have left a placeholder marker before this addon
        # became part of the selected test project.
        placeholder_marker = destination / ".gdignore"
        if placeholder_marker.is_file():
            placeholder_marker.unlink()
    # Godot desktop profiles can auto-link the currently opened project's
    # sibling addons into scratch projects. Placeholder directories keep those
    # links out of this test project and prevent imports writing into the repo.
    for addon in sorted((REPO_ROOT / "misc/feng-addons").iterdir()):
        if addon.is_dir() and addon.name not in selected and (addon / "plugin.cfg").is_file():
            placeholder = addons / addon.name
            assert_scratch_addon_target(project, addons, placeholder)
            placeholder.mkdir(exist_ok=True)
            assert_scratch_addon_target(project, addons, placeholder)
            (placeholder / ".gdignore").touch()
    validate_scratch_tree(project)

    (project / "project.godot").write_text(
        'config_version=5\n'
        '[application]\n'
        'config/name="Feng Sky tests"\n'
        '[rendering]\n'
        'renderer/rendering_method="frp"\n'
        f'lights_and_shadows/use_physical_light_units={args.physical_units}\n'
        '[editor_plugins]\n'
        'enabled=PackedStringArray("res://addons/feng-sky/plugin.cfg", '
        '"res://addons/feng-fog/plugin.cfg")\n',
        encoding="utf-8",
    )
    env = dict(os.environ)
    env["APPDATA"] = str(project / "config")
    env["LOCALAPPDATA"] = str(project / "cache")
    env["XDG_CONFIG_HOME"] = str(project / "config")
    env["XDG_CACHE_HOME"] = str(project / "cache")
    env["XDG_DATA_HOME"] = str(project / "data")
    print(f"Persistent scratch project: {project}")
    validate_scratch_tree(project)
    run(
        [str(editor), "--headless", "--editor", "--path", str(project), "--recovery-mode", "--import"],
        "headless editor plugin import",
        project,
        env,
    )
    validate_scratch_tree(project)
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
        project,
        env,
        "feng_sky_atmosphere tests passed",
    )
    validate_scratch_tree(project)
    run(
        [str(editor), "--headless", "--path", str(project), "--script",
         "res://addons/feng-sky/tests/test_sky_numerics.gd"],
        "headless Sky numerical tests", project, env, "SKY NUMERICS PASS",
    )
    validate_scratch_tree(project)
    run(
        [str(editor), "--headless", "--path", str(project), "--script",
         "res://addons/feng-sky/tests/test_sky_optimization.gd"],
        "headless Sky optimization tests", project, env, "SKY OPTIMIZATION PASS",
    )
    validate_scratch_tree(project)
    if args.gpu_driver:
        run(
            [str(editor), "--path", str(project), "--rendering-method", "frp",
             "--rendering-driver", args.gpu_driver, "--audio-driver", "Dummy", "--resolution", "64x64",
             "--position", "-10000,-10000", "--script",
             "res://addons/feng-sky/tests/test_sky_numerics.gd", "--", "--gpu"],
            "GPU Sky numerical tests", project, env, "SKY NUMERICS PASS",
        )
        validate_scratch_tree(project)
        startup = None
        if os.name == "nt":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        gpu_log = project / f"gpu_probe_{args.physical_units}_{args.gpu_driver}.log"
        command = [
            str(editor),
            "--path",
            str(project),
            "--rendering-method",
            "frp",
            "--rendering-driver",
            args.gpu_driver,
            "--audio-driver",
            "Dummy",
            "--resolution",
            "320x240",
            "--position",
            "-10000,-10000",
            "--script",
            "res://addons/feng-sky/tests/atmosphere_gpu_probe.gd",
        ]
        with gpu_log.open("wb") as output:
            result = subprocess.run(
                command,
                env=env,
                stdout=output,
                stderr=subprocess.STDOUT,
                startupinfo=startup,
                check=False,
                timeout=300,
            )
        output_text = gpu_log.read_text(encoding="utf-8", errors="replace")
        print(f"== hidden/offscreen GPU probe exit={result.returncode} ==")
        print(output_text[-18000:], end="")
        if result.returncode:
            raise SystemExit(f"GPU probe failed; see {gpu_log}")
        if "SCRIPT ERROR:" in output_text or "Parse Error:" in output_text or "ERROR:" in output_text:
            raise SystemExit(f"GPU probe reported an engine or script error; see {gpu_log}")
        if "SKY GPU PASS" not in output_text:
            raise SystemExit(f"GPU probe missed its success marker; see {gpu_log}")
        validate_scratch_tree(project)
        run(
            [str(editor), "--path", str(project), "--rendering-method", "frp",
             "--rendering-driver", args.gpu_driver, "--audio-driver", "Dummy", "--resolution", "160x160",
             "--position", "-10000,-10000", "--script",
             "res://addons/feng-sky/tests/test_sky_motion_gpu.gd"],
            "GPU Sky motion tests", project, env, "SKY MOTION GPU PASS",
        )
        validate_scratch_tree(project)


if __name__ == "__main__":
    main()
