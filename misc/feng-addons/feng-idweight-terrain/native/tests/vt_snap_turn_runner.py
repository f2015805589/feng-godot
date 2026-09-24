"""Regression for snap-turn motion reset and bounded plan refresh."""

from fixture import run_script_test


if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="terrain-snap-turn-",
        project_name="VT snap turn regression",
        log_name="snap_turn.log",
        script="vt_snap_turn.gd",
        marker="PASS snap/displacement turns discard old retention and preserve slow-turn debounce",
        resolution="320x240",
        timeout_run=120,
    ))
