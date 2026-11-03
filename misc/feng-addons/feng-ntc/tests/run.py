"""Authoring checks plus optional Vulkan/D3D12 portable-runtime tests with no SDK or DLLs."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ADDON = Path(__file__).resolve().parents[1]
ROOT = ADDON.parents[2]
WORK = ADDON / "tests/.work"


def deploy(project, native=False):
    target = project / "addons/feng-ntc"
    target.mkdir(parents=True, exist_ok=True)
    for source in ADDON.glob("*.gd"):
        shutil.copy2(source, target / source.name)
    shutil.copytree(ADDON / "shaders", target / "shaders", dirs_exist_ok=True)
    # Only clean the obsolete descriptor in this runner's owned sandbox.
    old = target / "feng_ntc.gdextension"
    if old.is_file():
        old.unlink()
    if native:
        (target / "tools").mkdir(exist_ok=True)
        (target / "bin").mkdir(exist_ok=True)
        shutil.copy2(ADDON / "tools/feng_ntc.gdextension", target / "tools/feng_ntc.gdextension")
        for name in ("feng_ntc.dll", "ntc.dll"):
            shutil.copy2(ADDON / "bin" / name, target / "bin" / name)
        (project / ".godot").mkdir(exist_ok=True)
        (project / ".godot/extension_list.cfg").write_text("res://addons/feng-ntc/tools/feng_ntc.gdextension\n", encoding="utf-8")
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Feng NTC isolated test"
config/use_custom_user_dir=true
config/custom_user_dir_name="FengNTCIntegrationTest"
[display]
window/size/viewport_width=320
window/size/viewport_height=320
[rendering]
renderer/rendering_method="forward_plus"
''', encoding="utf-8")


def run(godot, project, script, driver=None, marker="PASS"):
    shutil.copy2(ADDON / "tests" / script, project / script)
    cmd = [str(godot.resolve()), "--path", str(project), "--script", "res://" + script]
    if driver:
        cmd += ["--rendering-method", "forward_plus", "--rendering-driver", driver,
                "--position", "-32000,-32000", "--resolution", "320x320"]
    else:
        cmd += ["--headless", "--rendering-method", "gl_compatibility"]
    result = subprocess.run(cmd, capture_output=True, timeout=300,
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    name = Path(script).stem + ("-" + driver if driver else "")
    (project / (name + ".log")).write_text(output, encoding="utf-8")
    print(output, flush=True)
    return result.returncode == 0 and marker in output and not any(s in output for s in ("ERROR:", "leaked at exit", "not have been freed"))


def export_test(godot, runtime, driver):
    """Authoring DLLs present during export, absent from the self-contained game pack."""
    project = WORK / "export-test"
    deploy(project, native=True)
    # The editor plugin loads its SDK explicitly; do not simulate a discovered game extension.
    (project / ".godot/extension_list.cfg").unlink(missing_ok=True)
    addon = project / "addons/feng-ntc"
    shutil.copy2(ADDON / "plugin.cfg", addon / "plugin.cfg")
    shutil.copy2(ADDON / "tools/.gdignore", addon / "tools/.gdignore")
    shutil.copytree(ADDON / "LICENSES", addon / "LICENSES", dirs_exist_ok=True)
    for other in ADDON.parent.iterdir():
        if other.is_dir() and other != ADDON:
            placeholder = project / "addons" / other.name
            placeholder.mkdir(parents=True, exist_ok=True)
            (placeholder / ".gdignore").touch()
    for name in ("runtime_model.res", "runtime_material.tres"):
        shutil.copy2(runtime / name, project / name)
    shutil.copy2(ADDON / "tests/export_smoke.gd", project / "export_smoke.gd")
    (project / "main.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://export_smoke.gd" id="1"]
[node name="RuntimeExportTest" type="Node"]
script = ExtResource("1")
''', encoding="utf-8")
    with (project / "project.godot").open("a", encoding="utf-8") as config:
        config.write('''
[application]
run/main_scene="res://main.tscn"
[editor_plugins]
enabled=PackedStringArray("res://addons/feng-ntc/plugin.cfg")
''')
    (project / "export_presets.cfg").write_text('''[preset.0]
name="Portable"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="*.log,*.pck"
export_path="runtime.pck"
[preset.0.options]
binary_format/architecture="x86_64"
''', encoding="utf-8")
    pack = project / "runtime.pck"
    commands = [
        [str(godot.resolve()), "--headless", "--path", str(project), "--export-pack", "Portable", str(pack)],
        [str(godot.resolve()), "--main-pack", str(pack), "--rendering-method", "forward_plus", "--rendering-driver", driver, "--position", "-32000,-32000", "--quit-after", "600"],
    ]
    for phase, cmd in enumerate(commands):
        result = subprocess.run(cmd, cwd=WORK, capture_output=True, timeout=60,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        (WORK / f"export-{phase}.log").write_text(output, encoding="utf-8")
        print(output, flush=True)
        if result.returncode or "ERROR:" in output or (phase == 1 and "EXPORT_RUNTIME_PASS" not in output):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--gpu", nargs="*", choices=["vulkan", "d3d12"], help="Test generic compute backends sequentially")
    parser.add_argument("--large-asset", type=Path, help="Optional legacy .ntc.res for 2K+ page/gutter/eviction checks")
    parser.add_argument("--export", action="store_true", help="Export and run a self-contained PCK without native SDK; requires --gpu")
    parser.add_argument("--export-only", action="store_true", help="Repeat only export using the prior no-sdk runtime fixture")
    parser.add_argument("--sample-asset", type=Path, help="Test compressed spatial sampling of a 2K+ portable model without SDK")
    args = parser.parse_args()
    if args.sample_asset:
        for driver in args.gpu or ["vulkan", "d3d12"]:
            runtime = WORK / ("sample-" + driver)
            deploy(runtime)
            shutil.copy2(args.sample_asset, runtime / "sample.ntc.res")
            if not run(args.godot, runtime, "sample_runtime.gd", driver, "SAMPLE_RUNTIME_PASS"):
                return 1
        if args.export and not export_test(args.godot, runtime, driver):
            return 1
        print("ALL SAMPLE CHECKS PASSED.")
        return 0
    if args.export_only:
        driver = (args.gpu or ["d3d12"])[-1]
        return 0 if export_test(args.godot, WORK / ("no-sdk-" + driver), driver) else 1
    project = WORK / "集成测试"
    deploy(project, native=True)
    if not run(args.godot, project, "integration.gd", marker="RESULT: PASS"):
        return 1
    if args.gpu is not None:
        for driver in args.gpu or ["vulkan", "d3d12"]:
            if not run(args.godot, project, "gpu_decode.gd", driver, "GPU_DECODE_COMPLETE: true"):
                return 1
            runtime = WORK / ("no-sdk-" + driver)
            deploy(runtime)
            for name in ("portable.bin", "gpu_albedo.png"):
                shutil.copy2(project / name, runtime / name)
            if not run(args.godot, runtime, "runtime_gpu.gd", driver, "RUNTIME_RESULT: PASS"):
                return 1
            if args.large_asset:
                shutil.copy2(args.large_asset, project / "large.ntc.res")
                if not run(args.godot, project, "large_decode.gd", driver, "LARGE_RESULT: PASS"):
                    return 1
                shutil.copy2(project / "large_portable.bin", runtime / "portable.bin")
                shutil.copy2(project / "large_gpu_full.png", runtime / "gpu_albedo.png")
                if not run(args.godot, runtime, "runtime_gpu.gd", driver, "RUNTIME_RESULT: PASS"):
                    return 1
        if args.export and not export_test(args.godot, runtime, driver):
            return 1
    print("ALL CHECKS PASSED. Logs:", WORK)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
