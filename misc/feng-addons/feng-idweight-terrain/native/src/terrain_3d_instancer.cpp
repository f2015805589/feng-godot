// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DInstancer's MMI table: the update queue, the pass that materialises it, and the
// MMI/MultiMesh pairs themselves.

// One of three files that define Terrain3DInstancer. `_mmi_rids` is the only place an MMI or a
// MultiMesh RID lives, and this half owns all of it: `_process_updates()` drains
// `_queued_updates` through `_update_mmi_by_region()`, which creates, reconfigures and destroys the
// pairs cell by cell through `_create_multimesh()`, `_set_mmi_lod_ranges()` and the two
// `_destroy_mmi_by_location()` / `_destroy_mmi_by_cell()` teardown paths. The lifetime entry points -
// `initialize()`, `destroy()`, `clear_by_mesh()`, `clear_by_location()`, `clear_by_region()` and
// `set_mode()` - are here for the same reason, and `update_mmis()` is here because it is the only
// writer of the queue.
//
// Every teardown path walks `_mmi_rids` rather than the data's regions, and
// `_release_orphaned_regions()` keeps that possible: a region that has been unloaded or removed is
// still in this map while it is gone from the data.
//
// The other halves: `terrain_3d_instancer_place.cpp` (what a caller writes into a region's
// instance dictionary, and what it asks of it) and `terrain_3d_instancer_transfer.cpp` (moving
// that data between regions and between mesh ids).

#include "constants.h"
#include "logger.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d.h"
#include "terrain_3d_region.h"

#include <godot_cpp/classes/world3d.hpp>

///////////////////////////
// Private Functions
///////////////////////////

// Creates MMIs based on Multimesh data stored in Terrain3DRegions
void Terrain3DInstancer::_process_updates() {
	if (_queued_updates.empty()) {
		if (RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
			LOG(DEBUG, "Disconnect from RS::frame_pre_draw signal");
			RS->disconnect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
		}
		return;
	}
	IS_DATA_INIT(VOID);
	if (!_terrain->is_inside_tree()) {
		return;
	}
	const Terrain3DData *data = _terrain->get_data();
	TypedArray<Vector2i> region_locations = data->get_region_locations();
	int mesh_count = _terrain->get_assets()->get_mesh_count();

	// Both sentinels mean "everything", and they differ in what happens to what is already built:
	// `(V2I_MAX, -2)` destroys first, `(V2I_MAX, -1)` refreshes in place. The second is what
	// `update_mmis()` with no arguments queues, and `initialize()` is one of its callers - so it is the
	// pair that materialises instances after a scene loads.
	//
	// This arm and the guard in the loop below were removed once as "unreachable, since `update_mmis()`
	// writes `(V2I_MAX, -2)`" - which is true only of a rebuild. With them gone the pair fell through to
	// the per-region expansion, where V2I_MAX is not a region: the refresh built nothing and every mesh
	// id logged "Errant null region found at: (2147483647, 2147483647)".
	bool update_all = _queued_updates.find({ V2I_MAX, -2 }) != _queued_updates.end();
	if (update_all) {
		destroy();
	} else if (_queued_updates.find({ V2I_MAX, -1 }) != _queued_updates.end()) {
		update_all = true;
	}

	if (update_all) {
		LOG(DEBUG, "Updating all regions, all mesh_ids");
		std::unordered_set<int> touched;
		for (const Vector2i &region_loc : region_locations) {
			const Terrain3DRegion *region = data->get_region_ptr(region_loc);
			if (!region) {
				LOG(WARN, "Errant null region found at: ", region_loc);
				continue;
			}
			for (int mesh_id = 0; mesh_id < mesh_count; mesh_id++) {
				if (region->get_instances().has(mesh_id)) {
					_update_mmi_by_region(region, mesh_id);
					touched.insert(mesh_id);
				}
			}
		}
		_queued_updates.clear();
		_terrain->get_assets()->load_pending_meshes();
		_release_orphaned_regions();
		_recount_master_lods(touched);
		return;
	}

	// Identify pairs to process in a de-duplicating Set
	V2IIntPair to_process;

	// Process queued pairs with at least one specific element. A sentinel that reaches here is one the
	// arms above did not claim, and V2I_MAX is not a region location, so it is skipped; what is left to
	// skip as well is a pair whose mesh no longer exists - a mesh deleted after its update was queued.
	for (const auto &[queued_loc, queued_mesh] : _queued_updates) {
		if ((queued_loc == V2I_MAX && queued_mesh < 0) || queued_mesh >= mesh_count) {
			continue;
		}
		// If all regions for specific mesh_id
		if (queued_loc == V2I_MAX && queued_mesh >= 0) {
			for (const Vector2i &region_loc : region_locations) {
				auto pair = std::make_pair(region_loc, queued_mesh);
				to_process.emplace(pair);
			}
		} else {
			// Else one specific region
			if (queued_mesh == -1) {
				// All mesh_ids for this region
				for (int mesh_id = 0; mesh_id < mesh_count; mesh_id++) {
					auto pair = std::make_pair(queued_loc, mesh_id);
					to_process.emplace(pair);
				}
			} else {
				// Specific region + mesh - most common case
				auto pair = std::make_pair(queued_loc, queued_mesh);
				to_process.emplace(pair);
			}
		}
	}
	LOG(DEBUG, "Processing ", (int)to_process.size(), " queued updates");
	std::unordered_set<int> touched;
	for (const auto &[region_loc, mesh_id] : to_process) {
		const Terrain3DRegion *region = data->get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}
		if (!region->get_instances().has(mesh_id)) {
			continue;
		}
		_update_mmi_by_region(region, mesh_id);
		touched.insert(mesh_id);
	}
	_queued_updates.clear();
	_terrain->get_assets()->load_pending_meshes();
	// A queued pair whose region left the data is skipped above ("Errant null region found"), which
	// left its MMIs behind until this pass existed.
	_release_orphaned_regions();
	_recount_master_lods(touched);
}

// Recomputes the instance counter of every mesh this pass touched, from the master LOD's multimeshes.
//
// The counter has to describe one LOD, and `_get_master_lod()` decides which: lod 0 for an ordinary
// asset, the shadow impostor for a shadows-only one. A setting that moves it cannot be followed by the
// incremental accounting in `_update_mmi_by_region()` and `_destroy_mmi_by_cell()` - they adjust the
// count only where `lod == _get_master_lod()` *at that moment*, and a LOD's multimesh is created or
// destroyed while it is not the master (the shadows-only filter skips the others), so its instances
// enter or leave the count without ever being added or subtracted. Switching a three-LOD asset ON ->
// SHADOWS_ONLY -> ON left the count at double the placed instances.
//
// Summing the master LOD's multimeshes makes the count correct after every pass, whatever moved and in
// whatever order, which is worth the walk over the touched meshes: the map holds only resident regions.
void Terrain3DInstancer::_recount_master_lods(const std::unordered_set<int> &p_meshes) {
	for (const int mesh_id : p_meshes) {
		if (mesh_id < 0 || mesh_id >= _terrain->get_assets()->get_mesh_count()) {
			continue;
		}
		Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(mesh_id);
		if (ma.is_null()) {
			continue;
		}
		const Vector2i mesh_key(mesh_id, _get_master_lod(ma));
		int64_t total = 0;
		for (const auto &region_entry : _mmi_rids) {
			const auto mesh_found = region_entry.second.find(mesh_key);
			if (mesh_found == region_entry.second.end()) {
				continue;
			}
			for (const auto &cell_entry : mesh_found->second) {
				const RID &mm = cell_entry.second.second;
				if (mm.is_valid()) {
					total += RS->multimesh_get_instance_count(mm);
				}
			}
		}
		if (ma->get_instance_count() != int(total)) {
			LOG(DEBUG, "Mesh ", mesh_id, ": instance count ", ma->get_instance_count(), " -> ", (int)total,
					" (master LOD ", mesh_key.y, ")");
			ma->set_instance_count(int(total));
		}
	}
}

void Terrain3DInstancer::_update_mmi_by_region(const Terrain3DRegion *p_region, const int p_mesh_id) {
	if (!p_region) {
		LOG(ERROR, "p_region is null");
		return;
	}
	if (p_mesh_id < 0 || p_mesh_id >= Terrain3DAssets::MAX_MESHES) {
		LOG(ERROR, "p_mesh_id is out of bounds");
		return;
	}
	Vector2i region_loc = p_region->get_location();
	Dictionary mesh_inst_dict = p_region->get_instances();

	// Verify mesh id is valid, enabled, and has MeshInstance3Ds
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	if (!ma.is_valid()) {
		LOG(WARN, "MeshAsset ", p_mesh_id, " is null, destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id); // Clean up if orphaned
		return;
	}
	if (!ma->is_enabled()) {
		LOG(DEBUG, "Disabling mesh ", p_mesh_id, " in region ", region_loc, ": destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id);
		return;
	}
	if (ma->get_lod_count() == 0) {
		LOG(WARN, "MeshAsset ", p_mesh_id, " valid but has no meshes, destroying MMIs");
		_destroy_mmi_by_location(region_loc, p_mesh_id);
		return;
	}

	// Process cells
	Dictionary cell_inst_dict = mesh_inst_dict[p_mesh_id];
	Array cell_locations = cell_inst_dict.keys();

	for (const Vector2i &cell : cell_locations) {
		Array triple = cell_inst_dict[cell];
		if (triple.size() < 3) {
			LOG(WARN, "Triple is empty for region, ", region_loc, ", cell ", cell);
			continue;
		}
		TypedArray<Transform3D> xforms = triple[0];
		PackedColorArray colors = triple[1];
		bool modified = triple[2];

		// Clean MMIs if xforms have been removed
		if (xforms.size() == 0) {
			LOG(EXTREME, "Empty cell in region ", region_loc, " mesh ", p_mesh_id, " cell ", cell, ": destroying MMIs");
			_destroy_mmi_by_cell(region_loc, p_mesh_id, cell);
			continue;
		}
		// Clean MMIs f/ LODs not used
		for (int lod = 0; lod < Terrain3DMeshAsset::MAX_LOD_COUNT; lod++) {
			if (lod > ma->get_last_lod() || (ma->get_cast_shadows() == SHADOWS_ONLY && (lod > ma->get_last_shadow_lod() || lod < ma->get_shadow_impostor()))) {
				_destroy_mmi_by_cell(region_loc, p_mesh_id, cell, lod);
				LOG(EXTREME, "Destroyed old MMIs mesh ", p_mesh_id, " cell ", cell, ", LOD ", lod);
			}
		}

		// Clean Shadow MMIs
		bool shadow_lod_disabled = (ma->get_shadow_impostor() == 0 ||
				ma->get_cast_shadows() == SHADOWS_OFF);
		if (shadow_lod_disabled) {
			_destroy_mmi_by_cell(region_loc, p_mesh_id, cell, Terrain3DMeshAsset::SHADOW_LOD_ID);
			LOG(EXTREME, "Destroyed stale shadow MMI mesh ", p_mesh_id, " for disabled impostor in cell ", cell);
		}

		// Setup MMIs for each LOD + shadows

		// Get or create mesh dict (defined here as cleanup above might invalidate it)
		MeshMMIDict &mesh_mmi_dict = _mmi_rids[region_loc];
		RID shadow_impostor_source_mm;

		for (int lod = ma->get_last_lod(); lod >= Terrain3DMeshAsset::SHADOW_LOD_ID; lod--) {
			// Don't create shadow MMI if not needed
			if (lod == Terrain3DMeshAsset::SHADOW_LOD_ID && shadow_lod_disabled) {
				continue;
			}
			// Don't create MMIs for certain lods in Shadows only
			if (ma->get_cast_shadows() == SHADOWS_ONLY &&
					lod >= 0 && (lod > ma->get_last_shadow_lod() || lod < ma->get_shadow_impostor())) {
				continue;
			}

			// Get or create MMI - [] creates key if missing
			Vector2i mesh_key(p_mesh_id, lod);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			RID &mmi = cell_mmi_dict[cell].first; // null if missing
			if (!mmi.is_valid()) {
				mmi = RS->instance_create();
				RS->instance_set_scenario(mmi, _terrain->get_world_3d()->get_scenario());
				modified = true; // New MMI needs full update
			}

			// Always update MMI propertiess
			if (ma->is_highlighted()) {
				RS->instance_geometry_set_material_override(mmi, ma->get_highlight_material().is_valid() ? ma->get_highlight_material()->get_rid() : RID());
				RS->instance_geometry_set_material_overlay(mmi, RID());
			} else {
				RS->instance_geometry_set_material_override(mmi, ma->get_material_override().is_valid() ? ma->get_material_override()->get_rid() : RID());
				RS->instance_geometry_set_material_overlay(mmi, ma->get_material_overlay().is_valid() ? ma->get_material_overlay()->get_rid() : RID());
			}
			RS->instance_geometry_set_cast_shadows_setting(mmi, ma->get_lod_cast_shadows(lod));
			RS->instance_set_layer_mask(mmi, ma->get_visibility_layers());
			_set_mmi_lod_ranges(mmi, ma, lod);

			// Reposition MMI to region location
			Transform3D t = Transform3D();
			int region_size = p_region->get_region_size();
			real_t vertex_spacing = _terrain->get_vertex_spacing();
			t.origin.x += region_loc.x * region_size * vertex_spacing;
			t.origin.z += region_loc.y * region_size * vertex_spacing;
			RS->instance_set_transform(mmi, t);

			RID &mm = cell_mmi_dict[cell].second;
			// Only recreate MultiMesh if modified/no existing (with override for shadow)
			// Always update shadow MMI (source may have changed)
			if (modified || !mm.is_valid() || lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
				// Subtract previous instance count for this cell
				int instance_count_mod = 0;
				if (mm.is_valid() && lod == _get_master_lod(ma)) {
					instance_count_mod = -RS->multimesh_get_instance_count(mm);
				}
				if (lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
					// Reuse impostor LOD MM as shadow impostor
					mm = shadow_impostor_source_mm;
					if (!mm.is_valid()) {
						LOG(ERROR, "Shadow MM is null for cell ", cell, " lod ", lod, " xforms: ", xforms.size());
						continue;
					}
				} else {
					if (mm.is_valid()) {
						RS->free_rid(mm);
					}
					mm = _create_multimesh(p_mesh_id, lod, xforms, colors);
				}
				if (!mm.is_valid()) {
					LOG(ERROR, "Null MM for cell ", cell, " lod ", lod, " xforms: ", xforms.size());
					continue;
				}
				RS->instance_set_base(mmi, mm);

				// Add current instance count for this cell
				if (lod == _get_master_lod(ma)) {
					ma->update_instance_count(instance_count_mod + RS->multimesh_get_instance_count(mm));
				}

				// Clear modified only for visible LODs
				if (lod != Terrain3DMeshAsset::SHADOW_LOD_ID) {
					triple[2] = false;
				}
			} else {
				// Needed to update generated mesh changes
				Ref<Mesh> mesh = ma->get_mesh(lod);
				if (!mesh.is_valid()) {
					LOG(ERROR, "Mesh is null for LOD ", lod);
					RS->free_rid(mmi);
					RS->free_rid(mm);
					continue;
				}
				RS->multimesh_set_mesh(mm, mesh->get_rid());
			}
			// Capture source MM from shadow impostor LOD
			if (lod == ma->get_shadow_impostor()) {
				shadow_impostor_source_mm = mm;
			}
		} // End for LOD loop

		// Set all LOD mmi AABB to match the master LOD to ensure no gaps between transitions.
		// The master is the shadow impostor for a shadows-only asset, where there is no LOD0.
		AABB mm_custom_aabb;
		for (int lod = 0; lod <= ma->get_last_lod(); lod++) {
			Vector2i mesh_key(p_mesh_id, lod);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			RID &mmi = cell_mmi_dict[cell].first;
			RID &mm = cell_mmi_dict[cell].second;
			if (mm.is_valid() && mmi.is_valid()) {
				if (lod == _get_master_lod(ma)) {
					mm_custom_aabb = RS->multimesh_get_aabb(mm);
				} else {
					RS->multimesh_set_custom_aabb(mm, mm_custom_aabb);
				}
				RS->instance_set_custom_aabb(mmi, mm_custom_aabb);
			}
		}
		if (ma->get_shadow_impostor() > 0) {
			Vector2i mesh_key(p_mesh_id, Terrain3DMeshAsset::SHADOW_LOD_ID);
			CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
			RID &mmi = cell_mmi_dict[cell].first;
			if (mmi.is_valid()) {
				RS->instance_set_custom_aabb(mmi, mm_custom_aabb);
			}
		}
	}
}

void Terrain3DInstancer::_set_mmi_lod_ranges(RID p_mmi, const Ref<Terrain3DMeshAsset> &p_ma, const int p_lod) {
	if (!p_mmi || p_ma.is_null()) {
		return;
	}
	int source_lod = p_lod;
	real_t lod_begin = p_ma->get_lod_range_begin(source_lod);
	real_t lod_end = p_ma->get_lod_range_end(source_lod);
	if (source_lod == Terrain3DMeshAsset::SHADOW_LOD_ID) {
		source_lod = p_ma->get_shadow_impostor();
		lod_begin = 0.f;
		lod_end = p_ma->get_lod_range_begin(source_lod);
	}
	real_t margin = p_ma->get_fade_margin();
	if (margin > 0.f) {
		lod_begin = MAX(lod_begin < 0.001f ? 0.f : lod_begin - margin, 0.f);
		lod_end = MAX(lod_end < 0.001f ? 0.f : lod_end + margin, 0.f);
		real_t begin_margin = lod_begin < 0.001f ? 0.f : margin;
		real_t end_margin = lod_end < 0.001f ? 0.f : margin;
		RS->instance_geometry_set_visibility_range(p_mmi, lod_begin, lod_end, begin_margin, end_margin, RenderingServer::VISIBILITY_RANGE_FADE_SELF);
	} else {
		RS->instance_geometry_set_visibility_range(p_mmi, lod_begin, lod_end, 0.f, 0.f, RenderingServer::VISIBILITY_RANGE_FADE_DISABLED);
	}
}

void Terrain3DInstancer::_update_vertex_spacing(const real_t p_vertex_spacing) {
	IS_DATA_INIT(VOID);
	TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
	for (int r = 0; r < region_locations.size(); r++) {
		Vector2i region_loc = region_locations[r];
		Terrain3DRegion *region = _terrain->get_data()->get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "Errant null region found at: ", region_loc);
			continue;
		}
		real_t old_spacing = region->get_vertex_spacing();
		if (old_spacing == p_vertex_spacing) {
			LOG(DEBUG, "region vertex spacing == vertex spacing, skipping update transform spacing for region at: ", region_loc);
			continue;
		}

		// For all mesh_ids in region
		Dictionary mesh_inst_dict = region->get_instances();
		LOG(DEBUG, "Updating MMIs from: ", region_loc);
		Array mesh_types = mesh_inst_dict.keys();
		for (int m = 0; m < mesh_types.size(); m++) {
			int mesh_id = mesh_types[m];
			Dictionary cell_inst_dict = mesh_inst_dict[mesh_id];
			Array cell_locations = cell_inst_dict.keys();
			for (int c = 0; c < cell_locations.size(); c++) {
				// Get instances
				Vector2i cell = cell_locations[c];
				Array triple = cell_inst_dict[cell];
				TypedArray<Transform3D> xforms = triple[0];
				// Descale, then Scale to the new value
				for (int i = 0; i < xforms.size(); i++) {
					Transform3D t = xforms[i];
					t.origin.x /= old_spacing;
					t.origin.x *= p_vertex_spacing;
					t.origin.z /= old_spacing;
					t.origin.z *= p_vertex_spacing;
					xforms[i] = t;
				}
				triple[0] = xforms;
				triple[2] = true;
				cell_inst_dict[cell] = triple;
			}
		}
		// After all transforms are updated, set the new region vertex spacing value
		region->set_vertex_spacing(p_vertex_spacing);
		region->set_modified(true);
	}
	update_mmis(-1, V2I_MAX, true);
}

// The mesh ids this instancer holds MMIs for at p_region_loc, as a copy: freeing one erases entries
// from the map this is read from.
std::vector<int> Terrain3DInstancer::_mesh_ids_at(const Vector2i &p_region_loc) {
	std::vector<int> mesh_ids;
	const auto found = _mmi_rids.find(p_region_loc);
	if (found == _mmi_rids.end()) {
		return mesh_ids;
	}
	for (const auto &mesh_entry : found->second) {
		mesh_ids.push_back(mesh_entry.first.x);
	}
	return mesh_ids;
}

// A region can leave the data without this instancer being told to clean up after it: the streamer
// unloads one that left the active range, and remove_region() drops one. Both then ask for an update,
// and an update walks the data's *current* regions - so the MMI and multimesh RIDs this map holds for
// the region that left are never visited, stay allocated for the lifetime of the process, and leave the
// mesh asset's instance count raised for a region that no longer exists. Free them here, so that
// `_mmi_rids` only ever holds regions the data still has.
void Terrain3DInstancer::_release_orphaned_regions() {
	std::vector<Vector2i> orphaned;
	for (const auto &entry : _mmi_rids) {
		if (!_terrain->get_data()->get_region_ptr(entry.first)) {
			orphaned.push_back(entry.first);
		}
	}
	if (orphaned.empty()) {
		return;
	}
	LOG(DEBUG, "Releasing MMIs of ", (int)orphaned.size(), " region(s) that left the data");
	for (const Vector2i &region_loc : orphaned) {
		for (const int mesh_id : _mesh_ids_at(region_loc)) {
			_destroy_mmi_by_location(region_loc, mesh_id);
		}
		_mmi_rids.erase(region_loc);
	}
}

void Terrain3DInstancer::_destroy_mmi_by_location(const Vector2i &p_region_loc, const int p_mesh_id) {
	LOG(DEBUG, "Deleting all MMIs in region: ", p_region_loc, " for mesh_id: ", p_mesh_id);
	// Identify cells with matching mesh_id
	std::unordered_set<Vector2i, Vector2iHash> cells;
	if (_mmi_rids.count(p_region_loc) > 0) {
		MeshMMIDict &mesh_mmi_dict = _mmi_rids[p_region_loc];
		for (const auto &mesh_entry : mesh_mmi_dict) {
			const Vector2i &mesh_key = mesh_entry.first;
			if (mesh_key.x != p_mesh_id) {
				continue;
			}
			const CellMMIDict &cell_mmi_dict = mesh_entry.second;
			for (const auto &cell_entry : cell_mmi_dict) {
				cells.insert(cell_entry.first);
			}
		}
	}
	// Iterate over unique matching cells; each _destroy_mmi_by_cell will handle all LODs
	for (const Vector2i &cell : cells) {
		_destroy_mmi_by_cell(p_region_loc, p_mesh_id, cell);
	}
	// After all cells are destroyed, if the region is now empty, erase it
	if (_mmi_rids.count(p_region_loc) > 0 && _mmi_rids[p_region_loc].empty()) {
		_mmi_rids.erase(p_region_loc);
	}
}

void Terrain3DInstancer::_destroy_mmi_by_cell(const Vector2i &p_region_loc, const int p_mesh_id, const Vector2i p_cell, const int p_lod) {
	if (_mmi_rids.count(p_region_loc) == 0) {
		return;
	}
	MeshMMIDict &mesh_mmi_dict = _mmi_rids[p_region_loc];
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);

	for (int lod = Terrain3DMeshAsset::SHADOW_LOD_ID; lod < Terrain3DMeshAsset::MAX_LOD_COUNT; lod++) {
		// Skip if not all lods, or not matching lod
		if (p_lod != INT32_MAX && lod != p_lod) {
			continue;
		}
		Vector2i mesh_key(p_mesh_id, lod);
		if (mesh_mmi_dict.count(mesh_key) == 0) {
			continue;
		}
		CellMMIDict &cell_mmi_dict = mesh_mmi_dict[mesh_key];
		if (cell_mmi_dict.count(p_cell) == 0) {
			continue;
		}

		RID &mmi = cell_mmi_dict[p_cell].first;
		RID &mm = cell_mmi_dict[p_cell].second;
		if (ma.is_valid() && mm.is_valid()) {
			if (lod == _get_master_lod(ma)) {
				ma->update_instance_count(-RS->multimesh_get_instance_count(mm));
			}
		}
		LOG(EXTREME, "Freeing mmi:", mmi, ", mm:", mm, " and erasing mmi cell ", p_cell);
		if (mmi.is_valid()) {
			RS->free_rid(mmi);
		}
		// Unlike the Shadow MMI, the Shadow MM is a copy of another lod, not a unique RID to be freed
		if (lod != Terrain3DMeshAsset::SHADOW_LOD_ID) {
			if (mm.is_valid()) {
				RS->free_rid(mm);
			}
		}
		cell_mmi_dict.erase(p_cell);

		// If the cell is empty of all MMIs, remove it
		if (cell_mmi_dict.empty()) {
			LOG(EXTREME, "Removing mesh ", mesh_key, " from cell MMI dictionary");
			mesh_mmi_dict.erase(mesh_key); // invalidates cell_mmi_dict
		}
	}

	// Clean up region if we've removed the last MMI and cell
	if (mesh_mmi_dict.empty()) {
		LOG(EXTREME, "Removing region ", p_region_loc, " from mesh MMI dictionary");
		// This invalidates mesh_mmi_dict here and for calling functions
		_mmi_rids.erase(p_region_loc);
	}
}

void Terrain3DInstancer::_backup_region(const Ref<Terrain3DRegion> &p_region) {
	if (p_region.is_null()) {
		return;
	}
	if (_terrain && _terrain->get_editor() && _terrain->get_editor()->is_operating()) {
		_terrain->get_editor()->backup_region(p_region);
	} else {
		p_region->set_modified(true);
	}
}

RID Terrain3DInstancer::_create_multimesh(const int p_mesh_id, const int p_lod, const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors) const {
	RID mm;
	IS_INIT(mm);
	if (p_xforms.size() == 0) {
		return mm;
	}
	Ref<Terrain3DMeshAsset> mesh_asset = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	if (mesh_asset.is_null()) {
		LOG(ERROR, "No mesh id ", p_mesh_id, " found");
		return mm;
	}
	Ref<Mesh> mesh = mesh_asset->get_mesh(p_lod);
	if (mesh.is_null()) {
		LOG(ERROR, "No LOD ", p_lod, " for mesh id ", p_mesh_id, " found. Max: ", mesh_asset->get_lod_count());
		return mm;
	}
	mm = RS->multimesh_create();
	RS->multimesh_allocate_data(mm, p_xforms.size(), RenderingServer::MULTIMESH_TRANSFORM_3D, true, false, false);
	RS->multimesh_set_mesh(mm, mesh->get_rid());
	// RenderingServer's 3D layout is three transform rows followed by RGBA.
	// One buffer submission replaces two server calls for every instance.
	PackedFloat32Array buffer;
	buffer.resize(p_xforms.size() * 16);
	float *output = buffer.ptrw();
	for (int i = 0; i < p_xforms.size(); i++) {
		const Transform3D transform = p_xforms[i];
		float *instance = output + int64_t(i) * 16;
		for (int row = 0; row < 3; row++) {
			for (int column = 0; column < 3; column++) {
				instance[row * 4 + column] = transform.basis[row][column];
			}
			instance[row * 4 + 3] = transform.origin[row];
		}
		if (i < p_colors.size()) {
			const Color color = p_colors[i];
			instance[12] = color.r;
			instance[13] = color.g;
			instance[14] = color.b;
			instance[15] = color.a;
		}
		// Missing colors retain the engine's zero-filled allocation default.
	}
	RS->multimesh_set_buffer(mm, buffer);
	return mm;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DInstancer::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	}
	IS_DATA_INIT_MESG("Terrain3D not initialized yet", VOID);
	LOG(INFO, "Initializing Instancer");
	update_mmis();
}

void Terrain3DInstancer::destroy() {
	IS_DATA_INIT(VOID);
	_queued_updates.clear();
	LOG(INFO, "Destroying all MMIs");
	// Walk this instancer's own map, not the data's regions. The map is what owns the RIDs, and a
	// region that has been unloaded or removed is still in it: unload_region() and remove_region()
	// drop the region from the data and *then* ask for an update, which reaches here through the
	// rebuild sentinel. Iterating the data's regions left those MMIs allocated for the lifetime of the
	// process - the destructor calls this too, so they were reported as leaked at exit.
	std::vector<Vector2i> locations;
	locations.reserve(_mmi_rids.size());
	for (const auto &entry : _mmi_rids) {
		locations.push_back(entry.first);
	}
	for (const Vector2i &region_loc : locations) {
		for (const int mesh_id : _mesh_ids_at(region_loc)) {
			_destroy_mmi_by_location(region_loc, mesh_id);
		}
	}
	// Every MMI is gone, so no asset has instances. This also settles a count that was raised for a
	// multimesh which no longer exists.
	const int mesh_count = _terrain->get_assets()->get_mesh_count();
	for (int m = 0; m < mesh_count; m++) {
		Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(m);
		if (ma.is_valid()) {
			ma->set_instance_count(0);
		}
	}
}

void Terrain3DInstancer::clear_by_mesh(const int p_mesh_id) {
	LOG(INFO, "Deleting Multimeshes in all regions with mesh_id: ", p_mesh_id);
	TypedArray<Vector2i> region_locations = _terrain->get_data()->get_region_locations();
	for (const Vector2i &region_loc : region_locations) {
		clear_by_location(region_loc, p_mesh_id);
	}
	// A region the data has dropped is not in that list, and its MMIs are still this instancer's.
	_release_orphaned_regions();
	Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(p_mesh_id);
	ma.is_valid() ? ma->set_instance_count(0) : void(); // Reset count for this mesh
}

void Terrain3DInstancer::clear_by_location(const Vector2i &p_region_loc, const int p_mesh_id) {
	LOG(INFO, "Deleting Multimeshes w/ mesh_id: ", p_mesh_id, " in region: ", p_region_loc);
	Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(p_region_loc);
	clear_by_region(region, p_mesh_id);
}

void Terrain3DInstancer::clear_by_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id) {
	if (p_region.is_null()) {
		LOG(ERROR, "Region is null");
		return;
	}
	Vector2i region_loc = p_region->get_location();
	LOG(INFO, "Deleting Multimeshes w/ mesh_id: ", p_mesh_id, " in region: ", region_loc);
	Dictionary mesh_inst_dict = p_region->get_instances();
	if (mesh_inst_dict.has(p_mesh_id)) {
		_backup_region(p_region);
		mesh_inst_dict.erase(p_mesh_id);
	}
	_destroy_mmi_by_location(region_loc, p_mesh_id);
}

void Terrain3DInstancer::set_mode(const InstancerMode p_mode) {
	LOG(INFO, "Setting instancer mode: ", p_mode);
	if (p_mode != _mode) {
		_mode = p_mode;
		switch (_mode) {
			case NORMAL:
				update_mmis(-1, V2I_MAX, true);
				break;
			//case PLACEHOLDER:
			//	break;
			default:
				destroy();
				break;
		}
	}
}

// Defaults to update all regions, all meshes
// If rebuild is true, will destroy all MMIs, then build everything
// If region_loc == V2I_MAX, will do all regions for meshes specified
// If mesh_id < 0, will do all meshes in the specified region
// You safely can call multiple times per frame, and select any combo of options without fillling up the queue.
void Terrain3DInstancer::update_mmis(const int p_mesh_id, const Vector2i &p_region_loc, const bool p_rebuild) {
	if (_mode == DISABLED) {
		LOG(INFO, "Instancer is disabled");
		return;
	}
	LOG(INFO, "Queueing MMI update for mesh id: ", p_mesh_id < 0 ? "all" : String::num_int64(p_mesh_id),
			", region: ", p_region_loc == V2I_MAX ? "all" : String(p_region_loc),
			p_rebuild ? ", destroying first" : "");
	// Set to destroy and rebuild everything
	if (p_rebuild) {
		_queued_updates.clear();
		_queued_updates.emplace(V2I_MAX, -2);
		if (!RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
			LOG(DEBUG, "Connecting to RS::frame_pre_draw signal");
			RS->connect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
		}
		return;
	}
	// If already set to destroy, build all, quit
	if (_queued_updates.find({ V2I_MAX, -2 }) != _queued_updates.end()) {
		return;
	}
	// If already set to build all, quit
	if (_queued_updates.find({ V2I_MAX, -1 }) != _queued_updates.end()) {
		return;
	}
	// If all meshes for region are queued, quit
	if (_queued_updates.find({ p_region_loc, -1 }) != _queued_updates.end()) {
		return;
	}
	// If all regions for mesh_id are queued, quit
	int mesh_id = CLAMP(p_mesh_id, -1, Terrain3DAssets::MAX_MESHES - 1);
	if (_queued_updates.find({ V2I_MAX, mesh_id }) != _queued_updates.end()) {
		return;
	}
	// Else queue up this region/mesh combo
	_queued_updates.emplace(p_region_loc, mesh_id);
	if (!RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates))) {
		LOG(DEBUG, "Connecting to RS::frame_pre_draw signal");
		RS->connect("frame_pre_draw", callable_mp(this, &Terrain3DInstancer::_process_updates));
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DInstancer::_bind_methods() {
	BIND_ENUM_CONSTANT(NORMAL);
	//BIND_ENUM_CONSTANT(PLACEHOLDER);
	BIND_ENUM_CONSTANT(DISABLED);

	ClassDB::bind_method(D_METHOD("clear_by_mesh", "mesh_id"), &Terrain3DInstancer::clear_by_mesh);
	ClassDB::bind_method(D_METHOD("clear_by_location", "region_location", "mesh_id"), &Terrain3DInstancer::clear_by_location);
	ClassDB::bind_method(D_METHOD("clear_by_region", "region", "mesh_id"), &Terrain3DInstancer::clear_by_region);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &Terrain3DInstancer::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &Terrain3DInstancer::get_mode);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DInstancer::is_enabled);
	ClassDB::bind_method(D_METHOD("add_instances", "global_position", "params"), &Terrain3DInstancer::add_instances);
	ClassDB::bind_method(D_METHOD("remove_instances", "global_position", "params"), &Terrain3DInstancer::remove_instances);
	ClassDB::bind_method(D_METHOD("add_multimesh", "mesh_id", "multimesh", "transform", "update"), &Terrain3DInstancer::add_multimesh, DEFVAL(Transform3D()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_transforms", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::add_transforms, DEFVAL(PackedColorArray()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("append_location", "region_location", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::append_location, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("append_region", "region", "mesh_id", "transforms", "colors", "update"), &Terrain3DInstancer::append_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("update_transforms", "aabb"), &Terrain3DInstancer::update_transforms);
	ClassDB::bind_method(D_METHOD("get_closest_mesh_id", "global_position"), &Terrain3DInstancer::get_closest_mesh_id);
	ClassDB::bind_method(D_METHOD("update_mmis", "mesh_id", "region_location", "rebuild_all"), &Terrain3DInstancer::update_mmis, DEFVAL(-1), DEFVAL(V2I_MAX), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("swap_ids", "src_id", "dest_id"), &Terrain3DInstancer::swap_ids);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disabled,Normal"), "set_mode", "get_mode");
}
