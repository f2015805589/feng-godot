"""Compile production pool and queue code against small engine-boundary doubles.

Headers and complete method bodies are read from --source, never copied algorithms.
Queue tests drive worker transitions deterministically; real worker scheduling and
GPU publication still require the integration runners.
"""
from pathlib import Path
import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "native_helpers"))
from run_tests import block


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=here.parent.parent / "src")
    args = parser.parse_args()
    queue = (args.source / "terrain_3d_page_pipeline.cpp").read_text()
    methods = []
    for name in ("reset", "_index_of", "_count_claimable", "_erase_at", "cancel", "discard",
                 "retain", "prime", "ready_keys", "poll", "_drain_released", "defer_release",
                 "flush_releases", "_defer_result_release", "_lock_queue", "_stage_release"):
        match = re.search(r"^.*Terrain3DPagePipeline::" + name + r"\(", queue, re.M)
        if match:
            methods.append(block(queue, match.group()))
    for file, signature in (("terrain_3d_virtual_texture.cpp", "void Terrain3DVirtualTexture::_invalidate_pool_owner("),
                            ("terrain_3d_virtual_texture_lookup.cpp", "int Terrain3DVirtualTexture::_request_virtual("),
                            ("terrain_3d_virtual_texture.cpp", "void Terrain3DVirtualTexture::protect_page("),
                            ("terrain_3d_virtual_texture.cpp", "bool Terrain3DVirtualTexture::is_page_protected(")):
        methods.append(block((args.source / file).read_text(), signature))
    with tempfile.TemporaryDirectory(prefix="feng-native-state-") as temporary:
        root = Path(temporary)
        for name in ("terrain_3d_vt_page_pool.h", "terrain_3d_vt_page_pool.cpp", "terrain_3d_page_pipeline.h"):
            source = (args.source / name).read_text()
            # The boundary double replaces only engine dependencies. Keep STL includes.
            source = re.sub(r'^#include ["<](?:godot_cpp/|constants.h|generated_texture.h|terrain_3d_)[^\n]*\n', "", source, flags=re.M)
            (root / (name + ".inc")).write_text(source)
        (root / "methods.inc").write_text("\n".join(methods))
        flags = ["-DHAS_POOL_TRANSACTIONS", "-Wno-error=unused-variable"] if "commit_slot" in (args.source / "terrain_3d_vt_page_pool.h").read_text() else []
        binary = root / "native_state_test"
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-pthread", "-Wall", "-Wextra", "-Werror",
                        "-UNDEBUG", *shlex.split(os.environ.get("CXXFLAGS", "")), *flags,
                        "-I", str(root), "-I", str(args.source), str(here / "native_state_test.cpp"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
