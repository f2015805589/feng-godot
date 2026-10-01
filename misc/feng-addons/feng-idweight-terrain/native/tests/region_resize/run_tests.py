"""Run the production region planner/commit contract without engine dependencies."""
from pathlib import Path
import os
import subprocess
import tempfile


def main() -> None:
    here = Path(__file__).resolve().parent
    source = here.parent.parent / "src/terrain_3d_data_regions.cpp"
    body = source.read_text().split("void Terrain3DData::change_region_size", 1)[1].split(
        "void Terrain3DData::change_surface_density", 1)[0]
    assert body.index("plan.error") < body.index("remove_region(region, false)")
    assert "return add_region(new_regions[int(index)], false) == OK" in body
    assert "_regions = old_table" in body and "_region_locations = old_locations" in body
    assert "region->set_deleted(old_deleted[size_t(i)])" in body
    with tempfile.TemporaryDirectory(prefix="feng-region-resize-") as temporary:
        binary = Path(temporary) / "region_resize_test"
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        "-UNDEBUG", str(here / "region_resize_test.cpp"), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
