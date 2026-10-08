"""Exercise unchanged production CPU helpers with deterministic boundary doubles.

Extract methods/blocks instead of maintaining copies of their algorithms. This
does not replace RenderingServer/GPU integration coverage. --source selects a
snapshot directory for a same-harness red/green comparison.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile


def block(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if not depth:
                return source[start:cursor + 1]
    raise ValueError(f"Unclosed block: {signature}")


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=here.parent.parent / "src")
    args = parser.parse_args()
    cdlod = (args.source / "terrain_3d_cdlod.cpp").read_text()
    util = (args.source / "terrain_3d_util.cpp").read_text()
    transfer = (args.source / "terrain_3d_instancer_transfer.cpp").read_text()
    # The real per-batch dispatch decides whether _upload (and RID cleanup) runs.
    dispatch = block(cdlod.split("void Terrain3DCDLOD::_snap_impl()", 1)[1],
                     "for (int i = 0; i < 2; ++i)")
    methods = block(cdlod, "void Terrain3DCDLOD::_upload(") + "\n"
    methods += "void Terrain3DCDLOD::submit(const Lists &lists, const Bounds &bounds) {\n" + dispatch + "\n}\n"
    methods += block(util, "Ref<Image> Terrain3DUtil::pack_image(") + "\n"
    methods += block(util, "Ref<Image> Terrain3DUtil::luminance_to_height(") + "\n"
    # Compile the actual rectangle setup and membership expression, including
    # the old Dictionary enumeration when running a baseline snapshot.
    setup = transfer.split("Vector2i cell_start =", 1)[1].split("// For each mesh", 1)[0]
    membership = transfer.split("if (cells_to_copy.", 1)[1].split(") {", 1)[0]
    methods += ("bool copied_cell(const Rect2i &p_src_rect, Vector2i cell) {\n"
                "Vector2i cell_start =" + setup + "return cells_to_copy." + membership + ";\n}\n")
    with tempfile.TemporaryDirectory(prefix="feng-native-helpers-") as temporary:
        root = Path(temporary)
        (root / "methods.inc").write_text(methods)
        binary = root / "native_helpers_test"
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-UNDEBUG", "-I", str(root), str(here / "native_helpers_test.cpp"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
