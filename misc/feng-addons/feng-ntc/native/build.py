"""Build the independent Feng NTC extension; never rebuild the engine."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--godot-cpp", type=Path)
    parser.add_argument("--cvtt", type=Path)
    args = parser.parse_args()
    if os.name != "nt" or args.jobs < 1:
        parser.error("Windows x64 and a positive --jobs value are required")
    native = Path(__file__).resolve().parent
    vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    installation = subprocess.check_output([str(vswhere), "-latest", "-version", "[17.0,18.0)",
        "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "-property", "installationPath"], encoding="utf-8").strip()
    if not installation:
        parser.error("Visual Studio 2022 C++ build tools were not found")
    cmake = shutil.which("cmake") or str(Path(installation) / "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe")
    options = ["-G", "Visual Studio 17 2022", "-A", "x64", "-DCMAKE_GENERATOR_INSTANCE=" + installation,
               "-DPython3_EXECUTABLE=" + sys.executable]
    if args.godot_cpp:
        options.append("-DFENG_GODOT_CPP=" + str(args.godot_cpp.resolve()))
    if args.cvtt:
        options.append("-DFENG_CVTT=" + str(args.cvtt.resolve()))
    subprocess.run([cmake, "-S", str(native), "-B", str(native / ".build"), *options], check=True)
    subprocess.run([cmake, "--build", str(native / ".build"), "--config", "Release",
                    "--target", "feng-ntc", "--parallel", str(args.jobs)], check=True)


if __name__ == "__main__":
    main()
