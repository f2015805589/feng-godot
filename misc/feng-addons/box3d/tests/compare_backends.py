"""Compare the installed Godot Jolt backend with feng-box3d on identical rigid bodies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time

ADDON = Path(__file__).resolve().parents[1]
ROOT = ADDON.parents[2]
BACKENDS = {"box3d": ("Box3D Physics", "Box3DPhysicsDirectBodyState3D"),
            "jolt": ("Jolt Physics", "JoltPhysicsDirectBodyState3D")}


def link_directory(target, source):
    if os.name == "nt":
        # Windows junctions need no developer-mode/admin symlink permission.
        quote = lambda path: "'" + str(path.resolve()).replace("'", "''") + "'"
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        f"New-Item -ItemType Junction -Path {quote(target)} -Target {quote(source)} -ErrorAction Stop | Out-Null"],
                       check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    else:
        target.symlink_to(source.resolve(), target_is_directory=True)


def create_project(path, backend, args):
    addon = path / "addons/box3d"
    (addon / "bin").mkdir(parents=True)
    (addon / "examples").mkdir()
    shutil.copy2(args.library, addon / "bin/box3d.dll")
    shutil.copy2(ADDON / "box3d.gdextension", addon)
    for name in ["rigid_stress_60k.gd", "rigid_stress_60k.tscn"]:
        shutil.copy2(ADDON / "examples" / name, addon / "examples" / name)
    (path / ".godot").mkdir()
    (path / ".godot/extension_list.cfg").write_text("res://addons/box3d/box3d.gdextension\n", encoding="utf-8")
    renderer = "frp" if args.render else "gl_compatibility"
    settings = f'''config_version=5
[application]
config/name="Rigid stress - {backend}"
run/main_scene="res://addons/box3d/examples/rigid_stress_60k.tscn"
[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/vsync/vsync_mode=0
[physics]
3d/physics_engine="{BACKENDS[backend][0]}"
3d/run_on_separate_thread=false
common/physics_ticks_per_second=120
box3d/worker_count={args.box3d_workers}
jolt_physics_3d/limits/max_bodies=131072
jolt_physics_3d/limits/max_body_pairs={max(262144, max(args.count or [10000]) * 16)}
jolt_physics_3d/limits/max_contact_constraints={max(131072, max(args.count or [10000]) * 8)}
jolt_physics_3d/limits/temporary_memory_buffer_size=512
[threading]
worker_pool/max_threads={args.godot_workers}
[rendering]
renderer/rendering_method="{renderer}"
rendering_device/driver.windows="d3d12"
'''
    if args.render_project:
        source = args.render_project
        # Reuse the real renderer and autoloads, without changing the open project
        # or replacing its backend. Only the workload/worker settings are overridden.
        shutil.copy2(source / "project.godot", path / "project.godot")
        settings = settings[:settings.index("[display]")] + settings[settings.index("[physics]"):]
        (path / "override.cfg").write_text(settings, encoding="utf-8")
        shutil.copytree(source / "render", path / "render")
        for item in (source / "addons").iterdir():
            if item.is_dir() and item.name != "box3d":
                link_directory(path / "addons" / item.name, item)
        for name in ["global_script_class_cache.cfg", "uid_cache.bin", "extension_list.cfg"]:
            cached = source / ".godot" / name
            if cached.exists():
                shutil.copy2(cached, path / ".godot" / name)
        if (source / ".godot/imported").is_dir():
            shutil.copytree(source / ".godot/imported", path / ".godot/imported")
        for item in ADDON.glob("*.gd*"):
            shutil.copy2(item, addon / item.name)
    else:
        (path / "project.godot").write_text(settings, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--backend", action="append", choices=BACKENDS)
    parser.add_argument("--library", type=Path, default=ADDON / "bin/box3d.dll", help="Alternate build for before/after comparisons")
    parser.add_argument("--count", action="append", type=int)
    parser.add_argument("--case", action="append", choices=["pile", "stir"])
    parser.add_argument("--box3d-workers", type=int, choices=range(0, 33), default=0,
                        help="Box3D participants, including caller; 0 uses physical-core detection (default)")
    parser.add_argument("--godot-workers", type=int, choices=range(-1, 257), default=-1,
                        help="Godot worker pool used by Jolt; -1 keeps the engine's automatic default")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=240)
    parser.add_argument("--samples", type=int, default=600)
    parser.add_argument("--render", action="store_true", help="Also render the identical FRP view; report sync/GPU separately")
    parser.add_argument("--render-project", type=Path, help="Reuse a project's FRP render/ and addon dependencies in isolated copies")
    parser.add_argument("--realtime", action="store_true", help="Use the interactive wall clock, not accelerated fixed-fps simulation")
    parser.add_argument("--core-profile", action="store_true", help="Collect Box3D's internal phase timers; leave off for final timing comparisons")
    parser.add_argument("--timeout", type=float, default=360)
    args = parser.parse_args()
    if args.render_project and (not args.render or not (args.render_project / "project.godot").is_file()):
        parser.error("--render-project requires --render and an existing Godot project")
    counts = args.count or [10000]
    if min(counts) < 1 or max(counts) > 60000 or args.repeats < 1 or args.samples < 1 or args.warmup < 1:
        parser.error("Invalid workload size or run length")
    work = ADDON / "tests/.work"
    work.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="rigid-compare-", dir=work))
    backends = args.backend or list(BACKENDS)
    for backend in backends:
        create_project(output / backend, backend, args)
    records = []
    print("Logs:", output, flush=True)
    for count in counts:
        for case in args.case or ["pile", "stir"]:
            for repeat in range(args.repeats):
                # Alternate which backend goes first to reduce thermal/order bias.
                for backend in backends if repeat % 2 == 0 else list(reversed(backends)):
                    tag = f"{backend}-{count}-{case}-{repeat}"
                    project = output / backend
                    command = [str(args.godot.resolve()), "--path", str(project)]
                    if not args.realtime:
                        command += ["--fixed-fps", "120"]
                    command += ["--position", "-32000,-32000"] if args.render else ["--headless"]
                    command += ["--", "--stress-benchmark", f"--count={count}", f"--case={case}",
                                f"--warmup={args.warmup}", f"--samples={args.samples}"]
                    if args.render:
                        command.append("--snapshot=" + str(output / (tag + ".png")))
                    if args.core_profile:
                        command.append("--core-profile")
                    print("START", tag, flush=True)
                    started = time.monotonic()
                    with (output / (tag + ".log")).open("wb") as log:
                        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                        try:
                            process.wait(timeout=args.timeout)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                            raise RuntimeError(f"Timed out: {tag}; see its log")
                    text = (output / (tag + ".log")).read_text(encoding="utf-8", errors="replace")
                    if process.returncode or "ERROR:" in text or "WARNING:" in text:
                        raise RuntimeError(f"{tag} exit={process.returncode}\n{text[-8000:]}")
                    record = next(json.loads(line.removeprefix("RIGID_STRESS_RESULT ")) for line in text.splitlines()
                                  if line.startswith("RIGID_STRESS_RESULT "))
                    assert record["validation"]["backend_body_state"] == BACKENDS[backend][1], "Wrong backend activated"
                    assert record["validation"]["awake"] == count, "Sleep reduced the stress load"
                    assert record["validation"].get("transform_mismatches", 0) == 0, "Cached direct state returned a stale pose"
                    record.update(backend=backend, repeat=repeat, process_wall_seconds=time.monotonic() - started)
                    records.append(record)
                    (output / "results.json").write_text(json.dumps({"runs": records}, indent=2), encoding="utf-8")
                    print("DONE", tag, json.dumps({"physics": record["physics_step_window"], "frame": record["frame_interval"],
                                                  "validation": record["validation"]}), flush=True)
    for count in counts:
        assert len({r["initial_sha256"] for r in records if r["count"] == count}) == 1, "Different initial scenes"
    summary = {}
    for backend in backends:
        for count in counts:
            for case in args.case or ["pile", "stir"]:
                rows = [r for r in records if (r["backend"], r["count"], r["case"]) == (backend, count, case)]
                summary[f"{backend}/{count}/{case}"] = {
                    field: {stat: statistics.median(r[field][stat] for r in rows) for stat in ["median_ms", "mean_ms", "p95_ms"]}
                    for field in ["physics_step_window", "frame_interval", "visual_sync", "viewport_gpu"] if rows[0][field]}
    result = {"runs": records, "median_across_runs": summary,
              "clock": "realtime" if args.realtime else "fixed_fps_120",
              "render_project": str(args.render_project.resolve()) if args.render_project else None,
              "thread_settings": {"box3d_workers": args.box3d_workers, "godot_workers": args.godot_workers},
              "engine_sha256": hashlib.file_digest(args.godot.open("rb"), "sha256").hexdigest(),
              "box3d_sha256": hashlib.file_digest(args.library.open("rb"), "sha256").hexdigest()}
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)
    print("Logs:", output, flush=True)


if __name__ == "__main__":
    main()
