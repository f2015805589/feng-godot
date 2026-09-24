"""GPU regression for per-sector AVT density and ready-ancestor refinement."""

import os
import shutil
from pathlib import Path
import subprocess
import tempfile

from fixture import ROOT, is_environmental_error, log_errors, runner_parser, write_fixture



def main() -> int:
    parser = runner_parser()
    parser.add_argument("--sectors", action="store_true", help="Exercise full world-aligned 64 m AVT sectors")
    parser.add_argument("--scale", action="store_true", help="Exercise a 10.24 km world with 25600 sectors")
    parser.add_argument("--metric", action="store_true", help="Verify exact 768/1024 texels per metre, sparse residency and distance mips")
    parser.add_argument("--ownership", action="store_true", help="Verify AVT region ownership, distance cutoffs and SVT result grouping")
    parser.add_argument("--filtering", action="store_true", help="Verify strict missing-page diagnostics and normal mip interpolation")
    parser.add_argument("--async-pages", action="store_true", help="Verify asynchronous source invalidation and teardown")
    parser.add_argument("--navigation", action="store_true", help="Verify uphill and continuously moving AVT/SVT residency")
    parser.add_argument("--stepped-camera", action="store_true", help="Reproduce discontinuous nearest-texel camera height jumps during navigation")
    parser.add_argument("--residency", action="store_true", help="Verify full-frame slope residency after repeated turns")
    parser.add_argument("--rotation", action="store_true", help="Measure repeated camera turns and cache reuse")
    parser.add_argument("--instancer", action="store_true", help="Compare instance transforms, colors, edits and rebuild output")
    parser.add_argument("--blend", action="store_true", help="Compare baked material gradients against direct shading")
    parser.add_argument("--cdlod", action="store_true", help="Verify CDLOD batching, coverage and mode switches")
    parser.add_argument("--profile", action="store_true", help="Profile a hilly 3x3 terrain with vertex-preserving overdraw")
    parser.add_argument("--reference-dll", type=Path, help="Use a preserved native DLL for rotation image comparison")
    args = parser.parse_args()
    if args.reference_dll and not (args.rotation or args.profile or args.instancer or args.ownership or args.blend):
        parser.error("--reference-dll requires --rotation, --profile, --instancer or --ownership")
    if args.stepped_camera and not args.navigation:
        parser.error("--stepped-camera requires --navigation")
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
    env["TERRAIN_VT_STEP_CAMERA"] = "1" if args.stepped_camera else "0"
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
                        "1920x1080" if args.navigation else "1280x720" if args.profile or args.residency else "320x240",
                        "--position",
                        "-10000,-10000",
                        "--script",
                        str(Path(__file__).with_name("vt_navigation.gd" if args.navigation else "vt_async.gd" if args.async_pages else "vt_blend.gd" if args.blend else "terrain_cdlod.gd" if args.cdlod else "terrain_instancer.gd" if args.instancer else "terrain_profile.gd" if args.profile else "vt_residency.gd" if args.residency else "vt_rotation.gd" if args.rotation else "vt_filtering.gd" if args.filtering else "vt_region_ownership.gd" if args.ownership else "vt_metric_density.gd" if args.metric else "vt_sectors_scale.gd" if args.scale else "vt_sectors.gd" if args.sectors else "vt_adaptive.gd").resolve()),
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
    errors = log_errors(output)
    for line in output.splitlines():
        if line.startswith(("PASS", "REGRESSION", "ERROR:", "SCRIPT ERROR:", "VT_ADAPT", "VT_SECTORS", "VT_METRIC", "VT_OWNERSHIP", "VT_ROTATION", "VT_RESIDENCY", "VT_NAVIGATION", "TERRAIN_PROFILE", "TERRAIN_INSTANCER", "CDLOD")) and not is_environmental_error(line):
            print(line)
    print(f"EXIT={result.returncode} ERRORS={len(errors)} LOG={log}")
    return int(
        result.returncode != 0
        or bool(errors)
        or ("PASS uphill and moving VT residency without substitution" if args.navigation else "PASS async edit invalidation, payload sampling and teardown" if args.async_pages else "PASS VT source corner blending" if args.blend else "PASS CDLOD batching and coverage" if args.cdlod else "PASS terrain instancer output and edits" if args.instancer else "PASS terrain rendering profile" if args.profile else "PASS slope residency through repeated camera turns" if args.residency else "PASS AVT camera rotation output and production measurements" if args.rotation else "PASS strict missing-page diagnostics and normal mip interpolation" if args.filtering else "PASS AVT region ownership, automatic mip filtering and grouped SVT results" if args.ownership else "PASS metric VT density, sparse entries and mip reuse" if args.metric else "PASS 10 km AVT visibility and bounded residency" if args.scale else "PASS full procedural AVT sectors, pressure coverage, refinement and edits" if args.sectors else "PASS per-sector AVT density and ready-ancestor refinement") not in output
        or (not args.reference_dll and "PASS independent VT density and explicit mip controls" not in output)
    )



if __name__ == "__main__":
    raise SystemExit(main())
