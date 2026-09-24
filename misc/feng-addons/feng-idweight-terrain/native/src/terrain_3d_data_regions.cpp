// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's region lifecycle and the region table.

// One of five files that define Terrain3DData. What creates a region, what removes one, and what
// the rest of the addon asks about them: `add_region*()`, `remove_region*()`, `unload_region()`,
// `change_region_size()`, `change_surface_density()`, the modified/deleted flags and the callbacks
// over `_region_locations`. The slot table those regions are assigned lives in
// `terrain_3d_data.cpp`; this half never touches a slot index directly, it goes through
// `_acquire_slot()` / `_release_slot()`.

#include "terrain_3d.h"
#include "terrain_3d_data.h"

#include "logger.h"

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DData::initialize(Terrain3D *p_terrain) {
	if (!p_terrain) {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing data");
	bool prev_initialized = _terrain != nullptr;
	_terrain = p_terrain;
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_vertex_spacing = _terrain->get_vertex_spacing();
	// _region_size must be known before load_directory(): add_region() and
	// update_maps() size the region maps and the blank surface layer from it.
	// Leaving it at 0 until after the load created zero-sized images and crashed.
	// Terrain3D::set_region_size() cannot correct this later either, because it
	// short circuits when the terrain's region size already matches the file.
	_region_size = _terrain->get_region_size();
	_region_sizev = V2I(_region_size);
	if (!prev_initialized && !_terrain->get_data_directory().is_empty()) {
		load_directory(_terrain->get_data_directory());
	}
}

void Terrain3DData::set_region_locations(const TypedArray<Vector2i> &p_locations) {
	SET_IF_DIFF(_region_locations, p_locations);
	LOG(INFO, "Setting _region_locations with array sized: ", p_locations.size());
	_region_map_dirty = true;
	update_maps(TYPE_MAX, false, false); // only rebuild region map
}

// Returns an array of active regions, optionally a shallow or deep copy
TypedArray<Terrain3DRegion> Terrain3DData::get_regions_active(const bool p_copy, const bool p_deep) const {
	TypedArray<Terrain3DRegion> region_arr;
	for (const Vector2i &region_loc : _region_locations) {
		Ref<Terrain3DRegion> region = get_region(region_loc);
		if (region.is_valid()) {
			region_arr.push_back(p_copy ? region->duplicate(p_deep) : region);
		}
	}
	return region_arr;
}

// Calls the callback function for every region within the given (descaled) area
// The callable receives: source Terrain3DRegion, source Rect2i, dest Rect2i, (bindings)
// Used with change_region_size, dest Terrain3DRegion is bound as the 4th parameter
void Terrain3DData::do_for_regions(const Rect2i &p_area, const Callable &p_callback) {
	Rect2i location_bounds(V2I_DIVIDE_FLOOR(p_area.position, _region_size), V2I_DIVIDE_CEIL(p_area.size, _region_size));
	LOG(DEBUG, "Processing global area: ", p_area, " -> ", location_bounds);
	Point2i current_region_loc;
	for (int y = location_bounds.position.y; y < location_bounds.get_end().y; y++) {
		current_region_loc.y = y;
		for (int x = location_bounds.position.x; x < location_bounds.get_end().x; x++) {
			current_region_loc.x = x;
			const Terrain3DRegion *region = get_region_ptr(current_region_loc);
			if (region && !region->is_deleted()) {
				LOG(DEBUG, "Current region: ", current_region_loc);
				Rect2i region_area = p_area.intersection(Rect2i(current_region_loc * _region_size, _region_sizev));
				LOG(DEBUG, "Region bounds: ", Rect2i(current_region_loc * _region_size, _region_sizev));
				LOG(DEBUG, "Region area: ", region_area);
				Rect2i dst_coords(region_area.position - p_area.position, region_area.size);
				Rect2i src_coords(region_area.position - (region->get_location() * _region_sizev), dst_coords.size);
				LOG(DEBUG, "src map coords: ", src_coords);
				LOG(DEBUG, "dst map coords: ", dst_coords);
				p_callback.call(region, src_coords, dst_coords);
			}
		}
	}
}

void Terrain3DData::change_region_size(int p_new_size) {
	LOG(INFO, "Changing region size from: ", _region_size, " to ", p_new_size);
	if (!is_valid_region_size(p_new_size)) {
		LOG(ERROR, "Invalid region size: ", p_new_size, ". Must be power of 2, 64-2048");
		return;
	}
	if (p_new_size == _region_size) {
		return;
	}

	// Get current region corners expressed in new region_size coordinates
	Dictionary new_region_locations;
	Array region_locations = _regions.keys();
	for (const Vector2i &region_loc : region_locations) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (region && !region->is_deleted()) {
			Vector2i region_position = region->get_location() * _region_size;
			Rect2i location_bounds(V2I_DIVIDE_FLOOR(region_position, p_new_size), V2I_DIVIDE_CEIL(_region_sizev, p_new_size));
			for (int y = location_bounds.position.y; y < location_bounds.get_end().y; y++) {
				for (int x = location_bounds.position.x; x < location_bounds.get_end().x; x++) {
					new_region_locations[Vector2i(x, y)] = 1;
				}
			}
		}
	}

	// Make new regions to receive copied data
	TypedArray<Terrain3DRegion> new_regions;
	Array new_locations = new_region_locations.keys();
	for (const Vector2i &region_loc : new_locations) {
		Ref<Terrain3DRegion> new_region;
		new_region.instantiate();
		new_region->set_location(region_loc);
		new_region->set_region_size(p_new_size);
		new_region->set_vertex_spacing(_vertex_spacing);
		new_region->set_modified(true);
		new_region->sanitize_maps();

		// Copy current data from current into new region, up to new region size
		Rect2i area;
		area.position = region_loc * p_new_size;
		area.size = V2I(p_new_size);
		do_for_regions(area, callable_mp(this, &Terrain3DData::_copy_paste_dfr).bind(new_region.ptr()));
		new_regions.push_back(new_region);
	}

	// Remove old data
	_terrain->get_instancer()->destroy();
	TypedArray<Terrain3DRegion> old_regions = get_regions_active();
	for (const Ref<Terrain3DRegion> &region : old_regions) {
		remove_region(region, false);
	}

	// Change region size
	_terrain->set_region_size((Terrain3D::RegionSize)p_new_size);

	// Add new regions and rebuild
	for (const Ref<Terrain3DRegion> &region : new_regions) {
		add_region(region, false);
	}

	calc_height_range(true);
	update_maps(TYPE_MAX, true, true);
	_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
}

// Surface resolution is a terrain-wide setting: the region texture array is a single
// texture whose layers must all be the same size, so regions cannot disagree. Every
// resident payload is resampled to the new density; regions that have no payload yet
// only adopt the setting, and build at it on their first paint.
void Terrain3DData::change_surface_density(int p_density) {
	LOG(INFO, "Changing surface density to: ", p_density);
	if (p_density < Terrain3DRegion::SURFACE_DENSITY_MIN ||
			p_density > Terrain3DRegion::SURFACE_DENSITY_MAX) {
		LOG(ERROR, "Invalid surface density: ", p_density, ". Must be ",
				Terrain3DRegion::SURFACE_DENSITY_MIN, "-", Terrain3DRegion::SURFACE_DENSITY_MAX);
		return;
	}
	int resampled = 0;
	const Array region_locations = _regions.keys();
	for (const Vector2i &region_loc : region_locations) {
		Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region || region->is_deleted()) {
			continue;
		}
		if (region->ensure_surface_density(p_density)) {
			resampled++;
		}
		// Only the surface layer changed, so only that layer is re-uploaded.
		_mark_slot_dirty(get_region_id(region_loc), 1 << SLOT_MAP_SURFACE);
	}
	update_maps(TYPE_MAX, false, false);
	LOG(INFO, "Surface density ", p_density, ": resampled ", resampled, " region payloads");
}

void Terrain3DData::set_region_modified(const Vector2i &p_region_loc, const bool p_modified) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_modified(p_modified);
}

bool Terrain3DData::is_region_modified(const Vector2i &p_region_loc) const {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return false;
	}
	return region->is_modified();
}

void Terrain3DData::set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return;
	}
	return region->set_deleted(p_deleted);
}

bool Terrain3DData::is_region_deleted(const Vector2i &p_region_loc) const {
	const Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(ERROR, "Region not found at: ", p_region_loc);
		return true;
	}
	return region->is_deleted();
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blankp(const Vector3 &p_global_position, const bool p_update) {
	return add_region_blank(get_region_location(p_global_position), p_update);
}

Ref<Terrain3DRegion> Terrain3DData::add_region_blank(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region;
	region.instantiate();
	region->set_location(p_region_loc);
	region->set_region_size(_region_size);
	region->set_vertex_spacing(_vertex_spacing);
	if (add_region(region, p_update) == OK) {
		region->set_modified(true);
		return region;
	}
	return Ref<Terrain3DRegion>();
}

/** Adds a Terrain3DRegion to the terrain
 * Marks region as modified
 *	p_update - rebuild the maps if true. Set to false if bulk adding many regions.
 */
Error Terrain3DData::add_region(const Ref<Terrain3DRegion> &p_region, const bool p_update) {
	if (p_region.is_null()) {
		LOG(ERROR, "Provided region is null. Returning");
		return FAILED;
	}
	Vector2i region_loc = p_region->get_location();
	LOG(INFO, "Adding region at location ", region_loc, ", update maps: ", p_update ? "yes" : "no");

	// Check bounds and slow report errors
	if (get_region_map_index(region_loc) < 0) {
		LOG(ERROR, "Location ", region_loc, " out of bounds. Max: ",
				-REGION_MAP_SIZE / 2, " to ", REGION_MAP_SIZE / 2 - 1);
		return FAILED;
	}
	p_region->sanitize_maps();
	// Every region in memory carries the terrain's surface resolution. A region
	// loaded from an older file, or one saved at another density, is resampled here
	// rather than at first paint, so the shader's density uniform is always right.
	if (_terrain) {
		p_region->ensure_surface_density(_terrain->get_surface_density());
	}
	p_region->set_deleted(false);
	if (!_region_locations.has(region_loc)) {
		_region_locations.push_back(region_loc);
	} else {
		LOG(INFO, "Overwriting ", (_regions.has(region_loc)) ? "deleted" : "existing", " region at ", region_loc);
	}
	_regions[region_loc] = p_region;
	// Publish the region in the map immediately so get_region_id() and has_region()
	// are correct before the next update_maps(), and give it a stable layer slot.
	const int slot = _acquire_slot(region_loc);
	if (slot < 0) {
		LOG(ERROR, "No free map slot for region ", region_loc);
		return FAILED;
	}
	LOG(DEBUG, "Storing region ", region_loc, " version ", vformat("%.3f", p_region->get_version()), " slot: ", slot);
	if (p_update) {
		update_maps(TYPE_MAX, false, false);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
	return OK;
}

void Terrain3DData::remove_regionp(const Vector3 &p_global_position, const bool p_update) {
	Ref<Terrain3DRegion> region = get_region(get_region_location(p_global_position));
	remove_region(region, p_update);
}

void Terrain3DData::remove_regionl(const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region = get_region(p_region_loc);
	remove_region(region, p_update);
}

// Remove region marks the region for deletion, and removes it from the active arrays indexed by ID
// It remains stored in _regions and the file remains on disk until saved, when both are removed
void Terrain3DData::remove_region(const Ref<Terrain3DRegion> &p_region, const bool p_update) {
	if (p_region.is_null()) {
		LOG(ERROR, "Region not found or is null. Returning");
		return;
	}

	Vector2i region_loc = p_region->get_location();
	// Index inside the dense _region_locations list, which is not the layer slot.
	const int list_index = _region_locations.find(region_loc);
	LOG(INFO, "Marking region ", region_loc, " for deletion. update_maps: ", p_update ? "yes" : "no");
	if (list_index < 0) {
		LOG(ERROR, "Region ", region_loc, " not found in region_locations. Returning");
		return;
	}
	p_region->set_deleted(true);
	_region_locations.remove_at(list_index);
	_release_slot(region_loc);
	_region_map_signal_dirty = true;
	LOG(DEBUG, "Removing from region_locations, new size: ", _region_locations.size());
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		update_maps(TYPE_MAX, false, false);
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
}

// Streaming support: drops a region from memory without touching its file.
// Unlike remove_region() the region is not marked deleted and is erased from
// _regions, so the file on disk stays the only copy. Any Ref held elsewhere
// (undo, an editor panel) keeps the resource alive on its own.
void Terrain3DData::unload_region(const Vector2i &p_region_loc, const bool p_update) {
	Terrain3DRegion *region = get_region_ptr(p_region_loc);
	if (!region) {
		LOG(DEBUG, "unload_region: no region at ", p_region_loc);
		return;
	}
	const int list_index = _region_locations.find(p_region_loc);
	LOG(INFO, "Unloading region ", p_region_loc, " from memory, list index: ", list_index);
	if (list_index >= 0) {
		_region_locations.remove_at(list_index);
	}
	_regions.erase(p_region_loc);
	_release_slot(p_region_loc);
	_region_map_signal_dirty = true;
	if (p_update) {
		update_maps(TYPE_MAX, false, false);
		if (_terrain->get_instancer()) {
			_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
		}
	}
}
