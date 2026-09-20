"""Regression for snap-turn motion reset and bounded plan refresh."""
import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    raise SystemExit(run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-snap-turn-",
        project_name="VT snap turn regression",
        log_name="snap_turn.log",
        script="vt_snap_turn.gd",
        marker="PASS snap/displacement turns discard old retention and preserve slow-turn debounce",
        resolution="320x240",
        timeout_run=120,
    ))
