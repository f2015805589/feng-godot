"""VT setting scope regression: a demand-side setting must not rebuild the shared pool."""
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
        fixture_prefix="terrain-vt-root-mips-",
        project_name="VT root mips tests",
        log_name="vt_svt_root_mips.log",
        script="vt_svt_root_mips.gd",
        marker="PASS a demand-side setting leaves the shared pool alone",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
