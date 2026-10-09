"""Exercise the production signature and decoded-cell cache sections.

Extracts cache-admission code unchanged. Small value/hash doubles replace Godot and file
I/O; deterministic job interleaving checks signature identity while bounded size cases
check decoded-cell cache retention without allocating image-sized payloads.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile


def block(source: str, start: int) -> str:
    opening = source.index("{", start)
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if not depth:
                return source[start:cursor + 1]
    raise ValueError("Unclosed production section")


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path,
                        default=here.parent.parent / "src" / "terrain_3d_page_pipeline.cpp")
    args = parser.parse_args()
    source = args.source.read_text()
    run = block(source, source.index("void Terrain3DPagePipeline::run()"))
    prepare_start = run.find("if (job.request.svt && (_signature_source")
    prepare = block(run, prepare_start) if prepare_start >= 0 else ""
    load = block(source, source.index("void Terrain3DPagePipeline::load_cells("))
    start = load.index("uint32_t hash = 0;")
    end = load.index("const String path =", start)
    section = load[start:end]
    assert "_signatures.find(entry.first)" in section
    bytes_start = load.index("const uint64_t bytes =")
    limit_start = load.index("constexpr uint64_t cell_cache_limit_bytes", bytes_start)
    limit_end = load.index("\n", limit_start)
    admission_start = load.index("if (bytes <= cell_cache_limit_bytes)", limit_end)
    admission = load[limit_start:limit_end] + "\n" + block(load, admission_start)
    assert "_cell_cache[cache_key] = channels" in admission
    assert "_cache_bytes + bytes > cell_cache_limit_bytes" in admission
    with tempfile.TemporaryDirectory(prefix="feng-page-signatures-") as temporary:
        root = Path(temporary)
        (root / "prepare.inc").write_text(prepare)
        (root / "signature.inc").write_text(section)
        (root / "admission.inc").write_text(admission)
        compiler = os.environ.get("CXX", "c++")
        if Path(compiler).name.lower() in {"cl", "cl.exe"}:
            binary = root / "signature_test.exe"
            command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", f"/I{root}", str(here / "signature_test.cpp"), f"/Fe:{binary}"]
        else:
            binary = root / "signature_test"
            command = [compiler, "-std=c++17", "-pthread", "-Wall", "-Wextra", "-Werror",
                       "-I", str(root), str(here / "signature_test.cpp"), "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
