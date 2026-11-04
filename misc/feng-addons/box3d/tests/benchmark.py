"""Measure headless physics-frame cost; no rendering, fixed timestep and workload."""
import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

ADDON = Path(__file__).resolve().parents[1]
ROOT = ADDON.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--library", type=Path, default=ADDON / "bin/box3d.dll")
    parser.add_argument("--case", action="append", choices=["rigid", "soft", "soft_contacts", "soft_stack", "cloth4096", "cloth2048", "cloth_ground", "cloth_ground_no_balls", "cloth_ground_no_self", "cloth_reimpact", "cloth_reimpact_create", "soft_balls", "soft_rest", "ragdolls", "ragdolls_rest"])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--workers", type=int, default=4, choices=range(1, 33))
    args = parser.parse_args()
    if args.repeats < 1 or not args.library.is_file():
        parser.error("Provide an existing native library and at least one repeat")
    base = ADDON / "tests/.work"
    base.mkdir(exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix="benchmark-", dir=base))
    target = project / "addons/box3d"
    (target / "bin").mkdir(parents=True)
    shutil.copy2(args.library, target / "bin" / "box3d.dll")
    shutil.copy2(ADDON / "box3d.gdextension", target)
    shutil.copy2(ADDON / "tests/physics_benchmark.gd", project)
    (target / "examples").mkdir()
    for name in ["ragdoll_actor.gd", "ragdoll_actor.tscn"]:
        shutil.copy2(ADDON / "examples" / name, target / "examples")
    (project / ".godot").mkdir()
    (project / ".godot/extension_list.cfg").write_text("res://addons/box3d/box3d.gdextension\n", encoding="utf-8")
    (project / "project.godot").write_text(f'''config_version=5
[physics]
3d/physics_engine="Box3D Physics"
box3d/worker_count={args.workers}
common/physics_ticks_per_second=120
[rendering]
renderer/rendering_method="gl_compatibility"
''', encoding="utf-8")
    records = []
    for case in args.case or ["rigid", "soft", "soft_contacts", "soft_stack"]:
        for repeat in range(args.repeats):
            result = subprocess.run([
                str(args.godot.resolve()), "--headless", "--path", str(project),
                "--fixed-fps", "120", "--script", "res://physics_benchmark.gd", "--", "--case=" + case,
            ], capture_output=True, timeout=120,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            (project / f"{case}-{repeat}.log").write_text(output, encoding="utf-8")
            if result.returncode or "ERROR:" in output:
                raise RuntimeError(output)
            record = next(json.loads(line.removeprefix("BOX3D_PERF ")) for line in output.splitlines() if line.startswith("BOX3D_PERF "))
            if record["backend"] != "Box3DPhysicsServer3D":
                raise RuntimeError("Benchmark did not activate Box3D")
            records.append(record)
            print(json.dumps(record), flush=True)
    summary = {}
    for case in sorted({record["case"] for record in records}):
        rows = [r for r in records if r["case"] == case]
        summary[case] = {key: statistics.median(row[key] for row in rows)
                         for key in rows[0] if key.startswith("headless_frame_")}
    (project / "results.json").write_text(json.dumps({"runs": records, "median_across_runs": summary}, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    print("Logs:", project)


if __name__ == "__main__":
    main()
