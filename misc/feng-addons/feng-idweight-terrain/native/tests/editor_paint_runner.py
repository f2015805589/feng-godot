"""Editor paint regression: every tool/operation pair writes the right map."""
import argparse
from pathlib import Path

from fixture import ROOT, run_script_test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
    parser.add_argument("--driver", default="d3d12")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor,
        driver=args.driver,
        fixture_prefix="terrain-paint-",
        project_name="Editor paint tests",
        log_name="paint.log",
        script="editor_paint.gd",
        marker="PASS editor paint",
        resolution="480x480",
        shots=False,
        prefixes=("PAINT",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
