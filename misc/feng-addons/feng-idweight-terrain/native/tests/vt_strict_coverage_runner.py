"""Run the strict feedback-off VT coverage diagnostic in a disposable project.

The source project is read-only.  The runner copies it to ``bin/`` and writes all
screenshots and the JSON report below that temporary copy, so a real test-1 scene
can be used without changing its resources or project settings.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from fixture import ADDON_SOURCE, DEFAULT_EDITOR, ROOT, run_with_offscreen_window, write_fixture


def copy_source_project(source: Path, target: Path) -> None:
    """Copy scene/data content while keeping the fixture's isolated addon setup."""
    for item in source.iterdir():
        if item.name in {
            ".godot",
            ".git",
            "addons",
            "project.godot",
            "config",
            "cache",
            "strict_output",
        }:
            continue
        # Lifetime probes leave their large captures beside the scene.  They are not
        # project inputs and copying them makes the next fixture unnecessarily large.
        if item.is_file() and (item.suffix.lower() == ".log" or item.name.startswith("strict_") or item.name.startswith("turn_")):
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
        help="read-only real project to copy (default: F:/godot/project/test-1)",
    )
    parser.add_argument("--scene", default="render/test.tscn")
    parser.add_argument("--static-ticks", type=int, default=240)
    parser.add_argument("--turn-frames", type=int, default=180)
    parser.add_argument("--post-settle-frames", type=int, default=120)
    parser.add_argument("--turns", type=int, default=4)
    parser.add_argument("--pages", type=int, default=0, help="optional fixed pool size for capacity stress")
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()

    source = args.project.resolve()
    if not source.is_dir():
        parser.error(f"project does not exist: {source}")

    target = Path(tempfile.mkdtemp(prefix="terrain-strict-coverage-", dir=ROOT / "bin"))
    write_fixture(target)
    copy_source_project(source, target)
    output_dir = target / "strict_output"
    output_dir.mkdir()

    scene = args.scene if args.scene.startswith("res://") else "res://" + args.scene
    env = dict(
        os.environ,
        APPDATA=str(target / "config"),
        LOCALAPPDATA=str(target / "cache"),
        VT_TEST_SCENE=scene,
        VT_TEST_OUTPUT=str(output_dir),
        VT_TEST_STATIC_TICKS=str(max(1, args.static_ticks)),
        VT_TEST_TURN_FRAMES=str(max(1, args.turn_frames)),
        VT_TEST_POST_SETTLE_FRAMES=str(max(1, args.post_settle_frames)),
        VT_TEST_TURNS=str(max(1, args.turns)),
        VT_TEST_PAGE_COUNT=str(max(0, args.pages)),
    )
    (target / "config").mkdir(exist_ok=True)
    (target / "cache").mkdir(exist_ok=True)
    (target / "project.godot").write_text(
        "config_version=5\n"
        "[application]\n"
        "config/name=\"VT strict coverage\"\n"
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
    script = Path(__file__).with_name("vt_strict_coverage.gd").resolve()
    import_command = base + ["--headless", "--editor", "--import"]
    run_command = base + ["--script", str(script)]
    log = target / "strict_coverage.log"
    print(f"FIXTURE={target}", flush=True)
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
    errors = [line for line in output.splitlines() if "ERROR:" in line]
    report_paths: list[Path] = []
    for line in output.splitlines():
        if line.startswith(("VT_STRICT", "REGRESSION", "SCRIPT ERROR:", "ERROR:", "PASS ")):
            print(line)
        if line.startswith("VT_STRICT_REPORT path="):
            report_paths.append(Path(line.split("=", 1)[1].strip()))

    report_path = report_paths[-1] if report_paths else output_dir / "vt_strict_coverage.json"
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
            static_final = report.get("static", {}).get("final", {})
            turn_finals = [turn.get("final", {}) for turn in report.get("turns", [])]
            print(
                "VT_STRICT_SUMMARY "
                + json.dumps(
                    {
                        "report": str(report_path),
                        "static_missing": static_final.get("visible_missing_pages"),
                        "static_pending": static_final.get("visible_pending_pages"),
                        "static_magenta_ratio": static_final.get("magenta_ratio"),
                        "turn_missing": [item.get("visible_missing_pages") for item in turn_finals],
                        "turn_pending": [item.get("visible_pending_pages") for item in turn_finals],
                        "turn_magenta_ratio": [item.get("magenta_ratio") for item in turn_finals],
                    },
                    sort_keys=True,
                )
            )
        except (OSError, json.JSONDecodeError) as error:
            print(f"REPORT READ FAILED: {error}")

    print(f"EXIT={status} ERRORS={len(errors)} LOG={log}")
    if status != 0 or errors or "PASS strict VT coverage settles feedback-off static and 180-degree views" not in output:
        print(output[-12000:])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
