"""Headless native resize bounds, persisted-data preservation and surface roundtrip."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

from fixture import ROOT, runner_parser, write_fixture


def main() -> int:
    args = runner_parser().parse_args()
    project = Path(tempfile.mkdtemp(prefix="terrain-resize-bounds-", dir=ROOT / "bin"))
    write_fixture(project)
    (project / "project.godot").write_text('config_version=5\n[application]\n'
                                          'config/name="Terrain resize native contracts"\n')
    env = dict(os.environ)
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache"),
                        ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")]:
        (project / folder).mkdir(exist_ok=True)
        env[key] = str(project / folder)
    base = [str(args.editor.resolve()), "--headless", "--path", str(project), "--audio-driver", "Dummy"]
    phases = [("import", ["--editor", "--recovery-mode", "--import"], "", 0)]
    for name, marker, expected in [
        ("terrain_region_resize_bounds.gd", "PASS terrain region resize bounds preserve original data", 2),
        ("terrain_region_resize_surface.gd", "PASS region resizing preserves authored R16 surface density and bytes", 0),
    ]:
        shutil.copy2(Path(__file__).with_name(name), project / name)
        phases.append((name, ["--script", "res://" + name], marker, expected))
    print(f"FIXTURE={project}", flush=True)
    for name, flags, marker, expected in phases:
        run = subprocess.run(base + flags, env=env, capture_output=True, text=True, timeout=180)
        output = run.stdout + run.stderr
        (project / (name + ".log")).write_text(output)
        print(output, flush=True)
        errors = [line for line in output.splitlines() if "ERROR:" in line]
        known = "Region resize would exceed world bounds or resident capacity; original data is unchanged."
        if run.returncode or (marker and marker not in output) or len(errors) != expected \
                or any(known not in line for line in errors) or "leaked" in output.lower():
            print(f"FAIL {name} exit={run.returncode} errors={len(errors)}")
            return 1
    print("PASS native region resize bounds and authored surface regression")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
