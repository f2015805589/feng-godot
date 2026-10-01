"""Compile the actual production helper against deterministic GPU boundary doubles.

No engine, GPU, generated godot-cpp bindings or repository build artifacts required.
This exercises lifecycle behavior and injected failures; real GPU integration is
covered separately by the clipmap/lifetime runners.
"""
from pathlib import Path
import os
import subprocess
import tempfile


def main() -> None:
    here = Path(__file__).resolve().parent
    source = here.parent.parent / "src"
    with tempfile.TemporaryDirectory(prefix="feng-baked-arrays-") as temporary:
        root = Path(temporary)
        for header in (
            "variant/rid.hpp", "variant/string.hpp", "variant/packed_byte_array.hpp",
            "classes/rd_texture_format.hpp", "classes/rd_texture_view.hpp",
            "classes/rendering_device.hpp", "classes/rendering_server.hpp",
        ):
            target = root / "godot_cpp" / header
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('#include "device_double.h"\n')
        binary = root / "baked_texture_arrays_test"
        subprocess.run([
            os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror", "-UNDEBUG",
            "-I", str(root), "-I", str(here), "-I", str(source),
            str(source / "terrain_3d_baked_texture_arrays.cpp"),
            str(here / "baked_texture_arrays_test.cpp"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
