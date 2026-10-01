#!/usr/bin/env python3
"""Isolated real-GPU HDR pattern regression for optional blur/bloom/FXAA templates."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ADDON = ROOT / "misc/feng-addons/feng-render-pipeline"
BASELINE_FILES = ["library/blur/blur_h.glsl", "library/blur/blur_v.glsl",
                  "library/bloom-lite/bloom_downsample.glsl", "library/fxaa/fxaa.tres",
                  "pipeline/library_manager.gd"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--driver", default="vulkan")
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--baseline", help="Git revision for the five changed optional-template files")
    args = parser.parse_args()
    project = args.work_dir or Path(tempfile.mkdtemp(prefix="frp-optional-", dir=ROOT / "bin"))
    project.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ADDON, project / "addons/feng-render-pipeline", dirs_exist_ok=True)
    for addon in ADDON.parent.iterdir():
        if addon != ADDON and (addon / "plugin.cfg").is_file():
            placeholder = project / "addons" / addon.name
            placeholder.mkdir(parents=True, exist_ok=True)
            (placeholder / ".gdignore").touch()
    if args.baseline:
        for relative in BASELINE_FILES:
            path = "misc/feng-addons/feng-render-pipeline/" + relative
            (project / "addons/feng-render-pipeline" / relative).write_bytes(
                subprocess.check_output(["git", "show", f"{args.baseline}:{path}"], cwd=ROOT))
    shutil.copy2(ROOT / "misc/scripts/tests/frp_optional_library.gd", project / "test.gd")
    shutil.copy2(ROOT / "misc/scripts/tests/frp_optional_pattern.glsl", project / "pattern.glsl")
    shutil.copy2(ADDON / "library/fxaa/fxaa_copy.glsl", project / "readback.glsl")
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Optional library HDR patterns"\n'
                                          '[rendering]\nrenderer/rendering_method="frp"\n')
    env = dict(os.environ)
    for key, folder in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("APPDATA", "config"), ("LOCALAPPDATA", "cache")):
        path = project / folder
        path.mkdir(exist_ok=True)
        env[key] = str(path)
    base = [str(args.editor.resolve()), "--path", str(project), "--audio-driver", "Dummy"]
    print("Fixture:", project, flush=True)
    for name, flags in (("import", ["--headless", "--editor", "--recovery-mode", "--import"]),
                        ("gpu", ["--rendering-method", "frp", "--rendering-driver", args.driver,
                                 "--resolution", "64x48", "--script", "res://test.gd"])):
        result = subprocess.run(base + flags, env=env, capture_output=True, text=True, timeout=180)
        output = result.stdout + result.stderr
        (project / f"{name}.log").write_text(output)
        print(output, flush=True)
        if result.returncode or "ERROR:" in output or "leaked" in output.lower():
            raise SystemExit(f"FAIL {name} exit={result.returncode}; {project / (name+'.log')}")
        if name == "gpu" and "PASS FRP optional library patterned HDR" not in output:
            raise SystemExit("GPU did not report the success marker")
    print("PASS optional library complete", flush=True)


if __name__ == "__main__":
    main()
