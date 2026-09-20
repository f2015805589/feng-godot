"""Run the long-lived AVT fade/queue regression in one real rendering process."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    parser.add_argument(
        "--ticks",
        type=int,
        default=2000,
        help="ticks per static and ping-pong window (the script enforces a 2000 tick minimum)",
    )
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()
    if args.ticks < 2000:
        parser.error("--ticks must be at least 2000")
    os.environ["VT_LIFETIME_TICKS"] = str(args.ticks)
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtlifetime-",
        script="vt_lifetime.gd",
        marker="PASS VT fade lifetime keeps CPU diagnostics and page-arrival FIFO bounded over static and ping-pong windows",
        project_name="VT fade lifetime tests",
        log_name="vtlifetime.log",
        prefixes=("VTLIFETIME",),
        extra_scripts=(("vt_render.gd", "vt_render_base.gd"),),
        shots=False,
        timeout_run=args.timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
