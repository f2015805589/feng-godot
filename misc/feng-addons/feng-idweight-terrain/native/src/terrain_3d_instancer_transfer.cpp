// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DInstancer's two data transfers: one region's instance blocks to another, and one mesh
// id's to another.

// One of three files that define Terrain3DInstancer. `copy_paste_dfr()` is the editor's
// copy/paste, and `swap_ids()` is what keeps the instance dictionaries consistent when a mesh id
// is removed or reordered - both take an id or a block rather than a position, and both leave the
// MMI table stale: the contract is that the caller calls `update_mmis()` afterwards, which is
// documented at each definition.
//
// The other halves: `terrain_3d_instancer.cpp` (the MMI table and the lifetime) and
// `terrain_3d_instancer_place.cpp` (the placement API).

#include "terrain_3d.h"
#include "constants.h"
#include "logger.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_region.h"

///////////////////////////
// Public Functions
///////////////////////////

// Transfer foliage data from one region to another
// p_src_rect is the vertex/pixel offset into the region data, NOT a global position
// Need to update_mmis() after
void Terrain3DInstancer::copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Terrain3DRegion *p_dst_region) {
	if (!p_src_region || !p_dst_region) {
		LOG(ERROR, "Source (", p_src_region, ") or destination (", p_dst_region, ") regions are null");
		return;
	}
	LOG(INFO, "Copying foliage data from src ", p_src_region->get_location(), " to dest ", p_dst_region->get_location());

	real_t vertex_spacing = _terrain->get_vertex_spacing();
	// Offset to dst from src
	Vector2i src_region_loc = p_src_region->get_location();
	int src_region_size = p_src_region->get_region_size();
	Vector2i src_offset = Vector2i(src_region_loc.x * src_region_size, src_region_loc.y * src_region_size);
	Vector2i dst_region_loc = p_dst_region->get_location();
	int dst_region_size = p_dst_region->get_region_size();
	Vector2i dst_offset = src_offset - Vector2i(dst_region_loc.x * dst_region_size, dst_region_loc.y * dst_region_size);
	Vector3 dst_translate = Vector3(dst_offset.x, 0.f, dst_offset.y) * vertex_spacing;

	// Get all Cell locations in rect, which is already in region space.
	Vector2i cell_start = p_src_rect.get_position() / CELL_SIZE;
	Vector2i steps = p_src_rect.get_size() / CELL_SIZE;
	Dictionary cells_to_copy;
	for (int x = cell_start.x; x < cell_start.x + steps.x; x++) {
		for (int y = cell_start.y; y < cell_start.y + steps.y; y++) {
			cells_to_copy[Vector2i(x, y)] = 0;
		}
	}

	// For each mesh, for each cell, if in rect, convert xforms to target region space, append to target region.
	Dictionary mesh_inst_dict = p_src_region->get_instances();
	Array mesh_types = mesh_inst_dict.keys();
	for (const int &mesh_id : mesh_types) {
		TypedArray<Transform3D> xforms;
		PackedColorArray colors;
		Dictionary cell_inst_dict = p_src_region->get_instances()[mesh_id];
		Array cell_locs = cell_inst_dict.keys();
		for (const Vector2i &cell : cell_locs) {
			if (cells_to_copy.has(cell)) {
				Array triple = cell_inst_dict[cell];
				TypedArray<Transform3D> cell_xforms = triple[0];
				PackedColorArray cell_colors = triple[1];
				for (int i = 0; i < cell_xforms.size(); i++) {
					Transform3D t = cell_xforms[i];
					t.origin += dst_translate;
					xforms.push_back(t);
					colors.push_back(cell_colors[i]);
				}
			}
		}
		if (xforms.size() == 0) {
			continue;
		}
		append_region(Ref<Terrain3DRegion>(p_dst_region), mesh_id, xforms, colors, false);
	}
}

// Changes the ID of a mesh, without changing the mesh on the ground
// Called when the mesh asset id has changed. Updates Multimeshes and MMIs dictionary keys
void Terrain3DInstancer::swap_ids(const int p_src_id, const int p_dst_id) {
	IS_DATA_INIT_MESG("Instancer isn't initialized.", VOID);
	Ref<Terrain3DAssets> assets = _terrain->get_assets();
	int mesh_count = assets->get_mesh_count();
	LOG(INFO, "Swapping IDs of multimeshes: ", p_src_id, " and ", p_dst_id);
	if (p_src_id >= 0 && p_src_id < mesh_count && p_dst_id >= 0 && p_dst_id < mesh_count) {
		TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
		for (const Vector2i &region_loc : region_locations) {
			Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(region_loc);
			if (region.is_null()) {
				LOG(WARN, "No region found at: ", region_loc);
				continue;
			}

			// mesh_inst_dict could have src, src+dst, dst or nothing. All 4 must be considered
			Dictionary mesh_inst_dict = region->get_instances();
			Dictionary cells_inst_dict_src;
			Dictionary cells_inst_dict_dst;
			// Extract src dict
			if (mesh_inst_dict.has(p_src_id)) {
				_backup_region(region);
				cells_inst_dict_src = mesh_inst_dict[p_src_id];
				mesh_inst_dict.erase(p_src_id);
			}
			// Extract dest dict
			if (mesh_inst_dict.has(p_dst_id)) {
				_backup_region(region);
				cells_inst_dict_dst = mesh_inst_dict[p_dst_id];
				mesh_inst_dict.erase(p_dst_id);
			}
			// If src exists, insert into dst slot
			if (!cells_inst_dict_src.is_empty()) {
				_backup_region(region);
				mesh_inst_dict[p_dst_id] = cells_inst_dict_src;
			}
			// If dst exists, insert into src slot
			if (!cells_inst_dict_dst.is_empty()) {
				_backup_region(region);
				mesh_inst_dict[p_src_id] = cells_inst_dict_dst;
			}
			LOG(DEBUG, "Swapped mesh_ids for region: ", region_loc);
		}
		update_mmis(-1, V2I_MAX, true);
	}
}
