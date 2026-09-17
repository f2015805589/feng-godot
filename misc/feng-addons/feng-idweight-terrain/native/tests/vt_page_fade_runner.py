"""Page-arrival fade: a page that arrives must be a ramp, not a rectangular step."""
import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="vulkan")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtpagefade-",
        script="vt_page_fade.gd",
        marker="PASS a page arrival publishes a ramp instead of a step",
        project_name="VT page fade tests",
        log_name="vtpagefade.log",
        prefixes=("VTPAGEFADE",),
        shots=False,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
