#!/usr/bin/env python3
"""Compile actual module against deterministic lifetime-boundary doubles; no GPU."""
from pathlib import Path
import os
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent
HEADERS = (
    "core/math/color.h", "core/object/object.h", "core/string/string_name.h", "core/variant/dictionary.h",
    "core/config/engine.h", "core/object/class_db.h", "core/os/mutex.h", "core/os/os.h", "core/os/thread.h",
    "core/profiling/profiling.h", "core/templates/hash_map.h", "common/TracyProtocol.hpp",
    "common/TracyVersion.hpp", "tracy/TracyC.h",
)


def main():
    with tempfile.TemporaryDirectory(prefix="feng-tracy-lifetime-") as temporary:
        root = Path(temporary)
        for header in HEADERS:
            target = root / header
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('#include "lifetime_double.h"\n')
        binary = root / "lifetime-test"
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-pthread", "-DGODOT_USE_TRACY", "-DTRACY_ON_DEMAND", "-UNDEBUG",
                        "-I", str(root), "-I", str(HERE), "-I", str(SOURCE),
                        str(SOURCE / "feng_godottracy.cpp"), str(HERE / "lifetime_test.cpp"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
