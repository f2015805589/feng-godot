"""GPU regression for per-sector AVT density and ready-ancestor refinement."""

import argparse
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

from editor_dock_runner import ROOT, write_fixture


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=ROOT / "bin" / "godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--sectors", action="store_true", help="Exercise full world-aligned 64 m AVT sectors")
    parser.add_argument("--scale", action="store_true", help="Exercise a 10.24 km world with 25600 sectors")
    parser.add_argument("--metric", action="store_true", help="Verify exact 768/1024 texels per metre, sparse residency and distance mips")
    parser.add_argument("--ownership", action="store_true", help="Verify AVT region ownership, distance cutoffs and SVT result grouping")
    parser.add_argument("--filtering", action="store_true", help="Verify parent retention and continuity at missing-page boundaries")
    parser.add_argument("--rotation", action="store_true", help="Measure repeated camera turns and cache reuse")
    parser.add_argument("--instancer", action="store_true", help="Compare instance transforms, colors, edits and rebuild output")
    parser.add_argument("--profile", action="store_true", help="Profile a hilly 3x3 terrain with vertex-preserving overdraw")
    parser.add_argument("--reference-dll", type=Path, help="Use a preserved native DLL for rotation image comparison")
    args = parser.parse_args()
    if args.reference_dll and not (args.rotation or args.profile or args.instancer or args.ownership):
        parser.error("--reference-dll requires --rotation, --profile, --instancer or --ownership")
    editor = args.editor.resolve()
    if not editor.is_file():
        print(f"Editor executable not found: {editor}")
        return 2

    fixture = Path(tempfile.mkdtemp(prefix="terrain-vtadaptive-", dir=ROOT / "bin"))
    write_fixture(fixture)
    if args.reference_dll:
        shutil.copy2(args.reference_dll, fixture / "addons/feng-idweight-terrain/bin/libfeng-idweight-terrain.windows.debug.x86_64.dll")
    (fixture / "vt_adaptive_base.gd").write_text(Path(__file__).with_name("vt_adaptive.gd").read_text(encoding="utf-8"), encoding="utf-8")
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="VT adaptive tests"\n',
        encoding="utf-8",
    )
    shots = fixture / "shots"
    shots.mkdir()
    env = os.environ.copy()
    env["TERRAIN_VT_REFERENCE"] = "1" if args.reference_dll else "0"
    for key, folder in [("APPDATA", "config"), ("LOCALAPPDATA", "cache")]:
        (fixture / folder).mkdir()
        env[key] = str(fixture / folder)
    log = fixture / "vtadaptive.log"
    print(f"FIXTURE={fixture}", flush=True)
    base = [str(editor), "--path", str(fixture), "--audio-driver", "Dummy"]
    try:
        with log.open("w", encoding="utf-8") as out:
            result = subprocess.run(
                base + ["--headless", "--editor", "--import"],
                env=env,
                stdout=out,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
            if result.returncode == 0:
                result = subprocess.run(
                    base
                    + [
                        "--rendering-method",
                        "frp",
                        "--rendering-driver",
                        args.driver,
                        "--resolution",
                        "1280x720" if args.profile else "320x240",
                        "--position",
                        "-10000,-10000",
                        "--script",
                        str(Path(__file__).with_name("terrain_instancer.gd" if args.instancer else "terrain_profile.gd" if args.profile else "vt_rotation.gd" if args.rotation else "vt_filtering.gd" if args.filtering else "vt_region_ownership.gd" if args.ownership else "vt_metric_density.gd" if args.metric else "vt_sectors_scale.gd" if args.scale else "vt_sectors.gd" if args.sectors else "vt_adaptive.gd").resolve()),
                        "--",
                        "",
                        str(shots),
                    ],
                    env=env,
                    stdout=out,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                )
            if result.returncode == 0 and not args.reference_dll:
                result = subprocess.run(
                    base + ["--headless", "--script", str(Path(__file__).with_name("vt_resolution_controls.gd").resolve())],
                    env=env,
                    stdout=out,
                    stderr=subprocess.STDOUT,
                    timeout=60,
                )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT LOG={log}")
        return 124

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "VT_ADAPT", "VT_SECTORS", "VT_METRIC", "VT_OWNERSHIP", "VT_ROTATION", "TERRAIN_PROFILE", "TERRAIN_INSTANCER")):
            print(line)
    print(f"EXIT={result.returncode} ERRORS={len(errors)} LOG={log}")
    return int(
        result.returncode != 0
        or bool(errors)
        or ("PASS terrain instancer output and edits" if args.instancer else "PASS terrain rendering profile" if args.profile else "PASS AVT camera rotation output and production measurements" if args.rotation else "PASS AVT retained parents, seamless page boundaries and arrival blending" if args.filtering else "PASS AVT region ownership, automatic mip filtering and grouped SVT results" if args.ownership else "PASS metric VT density, sparse entries and mip reuse" if args.metric else "PASS 10 km AVT visibility and bounded residency" if args.scale else "PASS full procedural AVT sectors, pressure coverage, refinement and edits" if args.sectors else "PASS per-sector AVT density and ready-ancestor refinement") not in output
        or (not args.reference_dll and "PASS independent VT density and automatic mip controls" not in output)
    )


if __name__ == "__main__":
    raise SystemExit(main())
