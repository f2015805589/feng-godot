"""Compile the real CPU packing methods unchanged, with minimal Godot value types.

The extraction is by exact method signature and brace matching. There is no copied
algorithm in the test, and no engine build or GPU context is required. Public native
get_layout_report integration is covered by vt_clipmap_atlas_layout_runner.py.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile


def extract(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return source[start:cursor + 1]
    raise ValueError(f"Unclosed method {signature}")


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path,
                        default=here.parent.parent / "src" / "terrain_3d_clipmap_atlas.cpp")
    args = parser.parse_args()
    source = args.source.read_text()
    methods = [extract(source, signature) for signature in (
        "int Terrain3DClipmapAtlas::get_ring_block_count(",
        "int Terrain3DClipmapAtlas::_texels_of_ring(",
        "bool Terrain3DClipmapAtlas::_pack_quadtree(",
        "void Terrain3DClipmapAtlas::_pack_scheme(",
    )]
    with tempfile.TemporaryDirectory(prefix="feng-clipmap-packing-") as temporary:
        root = Path(temporary)
        (root / "packing_methods.inc").write_text("\n\n".join(methods))
        binary = root / "packing_test"
        subprocess.run([
            os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
            "-I", str(root), str(here / "packing_test.cpp"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
