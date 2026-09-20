"""GPU regression for the complete 48-bit BC3/BC4 alpha index stream."""

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
        fixture_prefix="terrain-vtbc3alpha-",
        project_name="VT BC3 alpha tests",
        log_name="vtbc3alpha.log",
        script="vt_bc3_alpha.gd",
        marker="PASS GPU BC3 alpha preserves the full 48-bit index stream",
        prefixes=("VT_BC3_ALPHA",),
        resolution="320x240",
        shots=False,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
