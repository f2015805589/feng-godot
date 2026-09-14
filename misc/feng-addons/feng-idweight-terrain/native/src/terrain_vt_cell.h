// The .vtcell on-disk contract, shared by the baker that writes the files
// (terrain_3d_surface_vt.cpp) and the runtime reader that consumes them
// (terrain_3d_page_pipeline.cpp).
//
// The version, the file name and the source signature must agree exactly between
// the two sides: a reader that computes a different name or signature reports
// every baked cell as missing, and the signature is what invalidates a stale bake
// after an edit. Defining them once is the only way to keep that true.
//
// No state and no file IO here, so either side can use it on its own thread.

#ifndef TERRAIN_VT_CELL_H
#define TERRAIN_VT_CELL_H

#include <cstdint>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace TerrainVTCell {
using namespace godot;

// Written into the header and required by every reader.
constexpr int FORMAT_VERSION = 3;

// <data_directory>/svt_cells/<cell_x>_<cell_y>_<mip>.vtcell
inline String path(const String &p_data_directory, const Vector2i &p_cell, const int p_mip) {
	return p_data_directory.path_join("svt_cells").path_join(
			String::num_int64(p_cell.x) + String("_") + String::num_int64(p_cell.y) + String("_") +
			String::num_int64(p_mip) + String(".vtcell"));
}

// The one definition of a cell's source signature: the materials and density it was
// baked from, plus the control/surface/height hash of the cell and of each
// neighbour, because neighbour heights affect the normals at a cell edge.
//
// p_neighbour_hashes(x, y) returns those three hashes for one neighbour cell, or an
// empty array when it is absent. Each caller reads its own source: the baker reads
// live regions, the runtime reads an immutable snapshot of them.
template <typename NeighbourHashes>
inline uint32_t signature(const int64_t p_materials, const real_t p_density,
		const real_t p_spacing, const int p_region_size, NeighbourHashes p_neighbour_hashes) {
	Dictionary signature;
	signature["materials"] = p_materials;
	signature["density"] = p_density;
	signature["source_corner_interpolation"] = 1;
	signature["spacing"] = p_spacing;
	signature["region_size"] = p_region_size;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			const Array hashes = p_neighbour_hashes(x, y);
			if (hashes.is_empty()) {
				continue;
			}
			signature[Vector2i(x, y)] = hashes;
		}
	}
	return uint32_t(signature.hash());
}

} // namespace TerrainVTCell

#endif // TERRAIN_VT_CELL_H
