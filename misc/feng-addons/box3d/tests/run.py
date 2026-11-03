"""Run Box3D physics checks in an isolated project with the real engine."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ADDON = Path(__file__).resolve().parents[1]
ROOT = ADDON.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--test", action="append", help="Run selected test stems only")
    parser.add_argument("--library", type=Path, help="Alternate Box3D build for regression comparisons")
    args = parser.parse_args()
    suffix = ".dll" if os.name == "nt" else ".so"
    library = args.library or ADDON / "bin" / ("box3d" + suffix)
    if not library.is_file():
        parser.error("Build the Box3D native extension first")
    work_root = ADDON / "tests/.work"
    work_root.mkdir(exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix="physics-", dir=work_root))
    target = project / "addons/box3d"
    (target / "bin").mkdir(parents=True)
    shutil.copy2(library, target / "bin" / library.name)
    shutil.copy2(ADDON / "box3d.gdextension", target)
    shutil.copy2(ADDON / "soft_body_3d.gd", target)
    shutil.copytree(ADDON / "examples", target / "examples")
    (project / ".godot").mkdir()
    (project / ".godot/extension_list.cfg").write_text("res://addons/box3d/box3d.gdextension\n", encoding="utf-8")
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Box3D integration tests"
[physics]
3d/physics_engine="Box3D Physics"
box3d/worker_count=2
[rendering]
renderer/rendering_method="gl_compatibility"
''', encoding="utf-8")
    shutil.copytree(ADDON / "tests/upstream", project / "tests")
    for script in (ADDON / "tests").glob("*_test.gd"):
        shutil.copy2(script, project / "tests")
    tests = sorted((project / "tests").glob("*_test.gd"))
    gate = project / "tests/backend_activation_test.gd"
    tests.remove(gate)
    if args.test:
        tests = [script for script in tests if script.stem in args.test]
        if not tests:
            parser.error("No requested test found")
    tests.insert(0, gate)
    results = []
    for script in tests:
        command = [str(args.godot.resolve()), "--headless", "--path", str(project),
                   "--fixed-fps", "60", "--script", "res://tests/" + script.name]
        try:
            run = subprocess.run(command, capture_output=True, timeout=45,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            output = (run.stdout + run.stderr).decode("utf-8", errors="replace")
            passed = run.returncode == 0 and "RESULT: PASS" in output and not any(
                marker in output for marker in ("ERROR:", "RESULT: FAIL", "not have been freed", "leaked at exit"))
        except subprocess.TimeoutExpired as error:
            output = "TIMEOUT\n" + str(error) + "\n" + ((error.stdout or b"") + (error.stderr or b"")).decode("utf-8", errors="replace")
            passed = False
        (project / (script.stem + ".log")).write_text(output, encoding="utf-8")
        results.append({"test": script.stem, "passed": passed})
        print(("PASS " if passed else "FAIL ") + script.stem, flush=True)
        if not passed:
            print(output[-6000:], flush=True)
            if script == gate:
                break
    (project / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"{sum(r['passed'] for r in results)}/{len(results)} passed. Logs: {project}")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
