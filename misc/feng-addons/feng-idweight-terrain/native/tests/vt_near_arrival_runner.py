"""Run the near-field page-arrival image diagnostic in a disposable project.

The source project is always treated as read-only.  By default the runner creates a fresh
temporary fixture below ``bin/`` and writes screenshots, JSON, and logs only below that fixture.
Use ``--existing-fixture`` to run directly against the already prepared fixture at
``bin/terrain-project-lifetime-ke6fwkn0`` (or pass a path after the option); the run output then
lives in a separate temporary ``bin/`` directory, so no source project is overwritten.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from fixture import ADDON_SOURCE, DEFAULT_EDITOR, ROOT, is_environmental_error, log_errors, run_with_offscreen_window, write_fixture


DEFAULT_FIXTURE = ROOT / "bin" / "terrain-project-lifetime-ke6fwkn0"


def copy_source_project(source: Path, target: Path) -> None:
    """Copy scene and resource content while leaving fixture-owned addons isolated."""
    excluded = {
        ".godot",
        ".git",
        "addons",
        "project.godot",
        "config",
        "cache",
        "near_arrival_output",
        "strict_output",
    }
    for item in source.iterdir():
        if item.name in excluded:
            continue
        if item.is_file() and (
            item.suffix.lower() == ".log"
            or item.name.startswith("arrival-")
            or item.name.startswith("turn_")
            or item.name.startswith("strict_")
        ):
            continue
        destination = target / item.name
        if item.is_dir():
            shutil.copytree(item, destination)
        elif item.is_file():
            shutil.copy2(item, destination)

    frp = target / "addons" / "feng-render-pipeline"
    (frp / ".gdignore").unlink(missing_ok=True)
    shutil.copytree(ADDON_SOURCE / "feng-render-pipeline", frp, dirs_exist_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project",
        type=Path,
        default=ROOT.parent / "project" / "test-1",
        help="read-only project to copy; defaults to the same real project vt_strict_coverage uses",
    )
    parser.add_argument(
        "--existing-fixture",
        nargs="?",
        const=DEFAULT_FIXTURE,
        type=Path,
        help="run in read-only prepared fixture (optionally followed by its path) without copying it",
    )
    parser.add_argument("--scene", default="render/test.tscn")
    parser.add_argument("--warm-ticks", type=int, default=240)
    parser.add_argument("--arrival-frames", type=int, default=96)
    parser.add_argument("--settle-frames", type=int, default=120)
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()

    if args.project is not None and args.existing_fixture is not None:
        parser.error("use either --project or --existing-fixture, not both")
    # `DEFAULT_FIXTURE` below is a leftover from `vt_project_lifetime_probe.py`, whose directory name
    # carries a random suffix (`mkdtemp(prefix="terrain-project-lifetime-")`). Pinning that exact name
    # as the default meant the runner exited 2 in 0.1 s - with no `PASS`, `REGRESSION` or `ERROR:` line
    # for `run_all.py` to report - as soon as `run_all.py --prune` removed the leftover, which is what
    # the pruner exists to do. The default is the real project the sibling real-scene runner copies;
    # `--existing-fixture` still selects a prepared fixture.
    source = (args.existing_fixture or args.project).resolve()
    if not source.is_dir():
        parser.error(f"read-only source project does not exist: {source}")

    use_existing_fixture = args.existing_fixture is not None
    if use_existing_fixture:
        # The prepared fixture already has its addon and renderer setup.  Keep it as the
        # engine project, but put all output and per-run editor state in a sibling temp dir.
        target = source
        run_dir = Path(tempfile.mkdtemp(prefix="terrain-near-arrival-run-", dir=ROOT / "bin"))
    else:
        target = Path(tempfile.mkdtemp(prefix="terrain-near-arrival-", dir=ROOT / "bin"))
        write_fixture(target)
        copy_source_project(source, target)
        run_dir = target
    output_dir = run_dir / "near_arrival_output"
    output_dir.mkdir()

    scene = args.scene if args.scene.startswith("res://") else "res://" + args.scene
    env = dict(
        os.environ,
        APPDATA=str(run_dir / "config"),
        LOCALAPPDATA=str(run_dir / "cache"),
        VT_TEST_SCENE=scene,
        VT_TEST_OUTPUT=str(output_dir),
        VT_NEAR_WARM_TICKS=str(max(1, args.warm_ticks)),
        VT_NEAR_ARRIVAL_FRAMES=str(max(1, args.arrival_frames)),
        VT_NEAR_SETTLE_FRAMES=str(max(1, args.settle_frames)),
    )
    (run_dir / "config").mkdir(exist_ok=True)
    (run_dir / "cache").mkdir(exist_ok=True)
    if not use_existing_fixture:
        (target / "project.godot").write_text(
            "config_version=5\n"
            "[application]\n"
            "config/name=\"VT near arrival\"\n"
            "[autoload]\n"
            'FengProjectPipeline="*res://addons/feng-render-pipeline/project_pipeline.gd"\n'
            "[rendering]\n"
            'renderer/rendering_method="frp"\n'
            'renderer/compositor="res://render/test_compositor.tres"\n',
            encoding="utf-8",
        )

    base = [
        str(args.editor.resolve()),
        "--path",
        str(target),
        "--audio-driver",
        "Dummy",
        "--rendering-method",
        "frp",
        "--rendering-driver",
        args.driver,
        "--resolution",
        args.resolution,
        "--position",
        "-32000,-32000",
    ]
    script = Path(__file__).with_name("vt_near_arrival.gd").resolve()
    import_command = base + ["--headless", "--editor", "--import"]
    run_command = base + ["--script", str(script)]
    log = run_dir / "near_arrival.log"
    print(f"SOURCE_READ_ONLY={source}", flush=True)
    print(f"FIXTURE={target}", flush=True)
    print(f"RUN_DIR={run_dir}", flush=True)
    print(f"OUTPUT={output_dir}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        import_status = run_with_offscreen_window(
            import_command, env=env, stream=stream, timeout=args.timeout
        )
        status = import_status
        if import_status == 0:
            status = run_with_offscreen_window(
                run_command, env=env, stream=stream, timeout=args.timeout
            )

    output = log.read_text(encoding="utf-8", errors="replace")
    errors = log_errors(output)
    report_path: Path | None = None
    for line in output.splitlines():
        if line.startswith(("VT_NEAR", "REGRESSION", "SCRIPT ERROR:", "ERROR:", "PASS ")) and not is_environmental_error(line):
            print(line)
        if line.startswith("VT_NEAR_REPORT path="):
            report_path = Path(line.split("=", 1)[1].strip())

    if report_path is None:
        report_path = output_dir / "vt_near_arrival.json"
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
            arrival = report.get("arrival", [])
            final = report.get("final", {})
            print(
                "VT_NEAR_SUMMARY "
                + json.dumps(
                    {
                        "report": str(report_path),
                        "frames": len(arrival),
                        "first_mean_abs_rgb_error": arrival[0].get("mean_abs_rgb_error") if arrival else None,
                        "last_mean_abs_rgb_error": arrival[-1].get("mean_abs_rgb_error") if arrival else None,
                        "max_large_difference_ratio": max(
                            (item.get("large_difference_pixel_ratio", 0.0) for item in arrival),
                            default=0.0,
                        ),
                        "final_vt_cpu": final.get("vt_cpu"),
                        "final_fadequeue": final.get("fadequeue"),
                        "final_active": final.get("active"),
                        "final_missing": final.get("missing"),
                        "final_pending": final.get("pending"),
                        "final_produced": final.get("produced"),
                    },
                    sort_keys=True,
                )
            )
        except (OSError, json.JSONDecodeError) as error:
            print(f"REPORT READ FAILED: {error}")

    print(f"EXIT={status} ERRORS={len(errors)} LOG={log}")
    marker = "PASS near-arrival frame sequence captured for baseline comparison"
    if status != 0 or errors or marker not in output:
        print(output[-12000:])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
