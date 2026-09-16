"""Storage-level codec check: a stored page must keep its colour."""
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
        fixture_prefix="terrain-vtcodec-colors-",
        script="vt_codec_colors.gd",
        marker="PASS stored pages keep their colour in every codec",
        project_name="VT codec colour tests",
        log_name="vtcodec_colors.log",
        prefixes=("VTCODEC_COLORS",),
        shots=False,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
