"""GPU regression: the compressed page arrays must render the same material."""
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
        fixture_prefix="terrain-vtcompress-render-",
        script="vt_compressed_render.gd",
        marker="PASS compressed material pages render and keep the production rate",
        project_name="VT compressed render tests",
        log_name="vtcompress_render.log",
        prefixes=("VTCOMPRESS_RENDER",),
        shots=True,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
