"""GPU regression: the far field's root pyramid must cover the visible field."""
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
        fixture_prefix="terrain-vtrootcover-",
        script="vt_root_coverage.gd",
        marker="PASS far-field root pyramid covers the visible field",
        project_name="VT root coverage tests",
        log_name="vtrootcover.log",
        prefixes=("VTROOTCOVER",),
        shots=True,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
