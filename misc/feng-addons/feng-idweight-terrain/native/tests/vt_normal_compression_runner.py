"""GPU regression for independent diffuse and signed-normal VT codecs."""

import argparse
from pathlib import Path

from fixture import DEFAULT_EDITOR, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-vtnormal-compression-",
        project_name="VT normal compression tests",
        log_name="vtnormal_compression.log",
        script="vt_normal_compression.gd",
        marker="PASS GPU AVT/SVT diffuse and signed-normal compression preserve rendered normal and roughness",
        prefixes=("VT_NORMAL", "VT_ROUGHNESS"),
        resolution="320x240",
        shots=True,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
