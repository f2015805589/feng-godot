"""Build only the Box3D addon, using the existing godot-cpp source tree."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("FENG_BUILD_JOBS", "8")))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    native = Path(__file__).resolve().parent
    cmake = shutil.which("cmake")
    options = []
    if os.name == "nt":
        vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        if not vswhere.is_file():
            parser.error("Install Visual Studio 2022 with C++ build tools and CMake")
        installation = subprocess.check_output(
            [str(vswhere), "-latest", "-version", "[17.0,18.0)", "-products", "*",
             "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
            encoding="utf-8").strip()
        if not installation:
            parser.error("Visual Studio 2022 C++ build tools were not found")
        if cmake is None:
            candidate = Path(installation) / "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
            if candidate.is_file():
                cmake = str(candidate)
        options = ["-G", "Visual Studio 17 2022", "-A", "x64", "-DCMAKE_GENERATOR_INSTANCE=" + installation]
    if cmake is None:
        parser.error("CMake 3.22+ was not found")
    build = native / ".build"
    if os.name != "nt":
        options.append("-DCMAKE_BUILD_TYPE=Release")
    subprocess.run([cmake, "-S", str(native), "-B", str(build), *options,
                    "-DPython3_EXECUTABLE=" + sys.executable], check=True)
    subprocess.run([cmake, "--build", str(build), "--config", "Release", "--target", "feng-box3d",
                    "--parallel", str(args.jobs)], check=True)
    print("Box3D built. Restart Godot to load the library in " + str(native.parent / "bin"))


if __name__ == "__main__":
    main()
