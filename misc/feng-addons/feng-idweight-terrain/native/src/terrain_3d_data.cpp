// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's slots, region maps and data queries.
//
// One of three files that define Terrain3DData: this one owns the slot allocator and
// the region directory/`_region_locations` table the shader reads, the map arrays and
// their GPU synchronization, region lifecycle, painting, height/normal/texture queries
// and the ClassDB bindings. `terrain_3d_data_surface.cpp` turns a region's R16 surface
// payload into virtual texture pages, and `terrain_3d_data_io.cpp` moves regions and
// images in and out of the project on disk. Every file carries the same include block
// so each one compiles and reads on its own; no logic lives outside the definitions.

#include "terrain_3d_data.h"

#include "logger.h"
#include "terrain_surface_idweight.h"

#include <algorithm>
#include <unordered_map>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DData::_clear() {
	LOG(INFO, "Clearing data");
	_region_map_dirty = true;
	_region_map_signal_dirty = true;
	_region_map.clear();
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_regions.clear();
	_region_locations.clear();
	_master_height_range = V2_ZERO;
	_slot_capacity = 0;
	_slot_locations.clear();
	_slot_dirty.clear();
	_free_slots.clear();
	_region_slots.clear();
	_height_maps.clear();
	_control_maps.clear();
	_color_maps.clear();
	_surface_maps.clear();
	for (int i = 0; i < SLOT_MAP_MAX; i++) {
		_slot_map_full[i] = true;
		_blank_slot_maps[i].unref();
	}
	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
	_generated_surface_maps.clear();
	_region_directory.clear();
	_region_directory_image.unref();
	_region_directory_dirty = true;
}

///////////////////////////
// Stable layer slots
///////////////////////////

// Grows the slot table by doubling. The capacity never shrinks: free slots are
// reused first, and keeping the arrays sized for the peak resident count is what
// stops steady streaming from reallocating the texture arrays every step.
void Terrain3DData::_grow_slot_capacity(const int p_needed) {
	if (p_needed <= _slot_capacity) {
		return;
	}
	int capacity = MAX(_slot_capacity, 4);
	while (capacity < p_needed) {
		capacity *= 2;
	}
	// Bounded by MAX_REGIONS, not by the world grid: the shader drops layer indices
	// at or above it, so a larger slot table would silently fail to render.
	capacity = MIN(capacity, MAX_MAP_SLOTS);
	if (capacity < p_needed) {
		LOG(ERROR, "Slot capacity ", capacity, " cannot hold ", p_needed,
				" resident regions. Raise the material's max_regions or lower the streamer radius.");
		return;
	}
	LOG(DEBUG, "Growing map slot capacity from ", _slot_capacity, " to ", capacity);
	const int previous = _slot_capacity;
	_slot_locations.resize(capacity, V2I_MAX);
	_slot_dirty.resize(capacity, 0);
	// The new slots have to join the free list, otherwise every allocation would
	// land above the old capacity and the table would double on every region.
	for (int slot = capacity - 1; slot >= previous; slot--) {
		_free_slots.push_back(slot);
	}
	// A resized array has blank layers, so every resident slot must be uploaded
	// again for every map type.
	for (int i = 0; i < SLOT_MAP_MAX; i++) {
		_slot_map_full[i] = true;
	}
	_slot_capacity = capacity;
	_slot_grow_count++;
}

void Terrain3DData::_mark_slot_dirty(const int p_slot, const int p_maps) {
	if (p_slot >= 0 && p_slot < (int)_slot_dirty.size()) {
		_slot_dirty[p_slot] |= uint8_t(p_maps);
	}
}

///////////////////////////
// Chunk directory texture
///////////////////////////

// The shader reads the chunk -> layer map from a texture instead of a uniform
// array, so the world grid is no longer limited by the uniform buffer size.
// Single-entry update: one region entering or leaving memory touches one texel.
void Terrain3DData::_set_directory_entry(const int p_index, const int p_value) {
	if (_region_directory_image.is_null()) {
		return;
	}
	if (p_index < 0 || p_index >= REGION_MAP_SIZE * REGION_MAP_SIZE) {
		return;
	}
	_region_directory_image->set_pixel(p_index % REGION_MAP_SIZE, p_index / REGION_MAP_SIZE,
			Color(real_t(p_value), 0.f, 0.f, 1.f));
	_region_directory_dirty = true;
}

// Bulk path: rebuilds the whole directory image from `_region_map`.
void Terrain3DData::_rebuild_region_directory() {
	_region_directory_image = region_map_to_image(_region_map);
	_region_directory_dirty = true;
}

// The shader samples this as `_region_map`: R32F, slot + 1, 0.0 = no region. Negative
// values are the editor's "dummy region" preview encoding and are preserved.
Ref<Image> Terrain3DData::region_map_to_image(const PackedInt32Array &p_region_map) {
	const int count = REGION_MAP_SIZE * REGION_MAP_SIZE;
	if (p_region_map.size() != count) {
		LOG(ERROR, "region_map_to_image expects ", count, " entries, got ", p_region_map.size());
		return Ref<Image>();
	}
	PackedByteArray bytes;
	bytes.resize(int64_t(count) * 4);
	for (int i = 0; i < count; i++) {
		bytes.encode_float(int64_t(i) * 4, real_t(p_region_map[i]));
	}
	return Image::create_from_data(REGION_MAP_SIZE, REGION_MAP_SIZE, false, Image::FORMAT_RF, bytes);
}

// Uploads the directory if it changed. Called once per update_maps().
void Terrain3DData::_update_region_directory() {
	if (_region_directory_image.is_null()) {
		_rebuild_region_directory();
	}
	if (_region_directory_image.is_null() || !_region_directory_dirty) {
		return;
	}
	// A texture is created once and then updated in place; only the first upload
	// allocates, so a paint step costs one 64 KB texel upload.
	if (_region_directory.get_rid().is_valid() &&
			_region_directory.get_layer_size() == REGION_MAP_VSIZE) {
		_region_directory.update(_region_directory_image, 0);
	} else {
		_region_directory.create(_region_directory_image);
	}
	_region_directory_dirty = false;
}

// Assigns a stable layer slot to a region location and publishes it in the region
// map. Re-adding a region that is already resident keeps the slot it already had.
int Terrain3DData::_acquire_slot(const Vector2i &p_region_loc) {
	const int map_index = get_region_map_index(p_region_loc);
	if (map_index < 0) {
		LOG(ERROR, "Location ", p_region_loc, " is out of bounds for the region map");
		return -1;
	}
	int slot = -1;
	if (_region_slots.has(p_region_loc)) {
		slot = int(_region_slots[p_region_loc]);
	} else {
		if (_free_slots.empty()) {
			_grow_slot_capacity(_slot_capacity + 1);
		}
		if (_free_slots.empty()) {
			LOG(ERROR, "No free map slot for ", p_region_loc, ", capacity: ", _slot_capacity);
			return -1;
		}
		slot = _free_slots.back();
		_free_slots.pop_back();
	}
	_slot_locations[slot] = p_region_loc;
	_region_slots[p_region_loc] = slot;
	// slot + 1 keeps 0 meaning "no region", the same encoding region_id used.
	_region_map[map_index] = slot + 1;
	_set_directory_entry(map_index, slot + 1);
	_mark_slot_dirty(slot, 0xF);
	return slot;
}

void Terrain3DData::_release_slot(const Vector2i &p_region_loc) {
	if (!_region_slots.has(p_region_loc)) {
		return;
	}
	const int slot = int(_region_slots[p_region_loc]);
	_region_slots.erase(p_region_loc);
	if (slot >= 0 && slot < _slot_capacity) {
		_slot_locations[slot] = V2I_MAX;
		_slot_dirty[slot] = 0;
		_free_slots.push_back(slot);
	}
	const int map_index = get_region_map_index(p_region_loc);
	if (map_index >= 0) {
		_region_map[map_index] = 0;
		_set_directory_entry(map_index, 0);
	}
}

// Drops every slot assignment and frees the slots from the top down, so a fresh
// assignment is dense and starts at 0.
void Terrain3DData::_reset_slots() {
	std::fill(_slot_locations.begin(), _slot_locations.end(), V2I_MAX);
	std::fill(_slot_dirty.begin(), _slot_dirty.end(), uint8_t(0));
	_free_slots.clear();
	_region_slots.clear();
	for (int slot = _slot_capacity - 1; slot >= 0; slot--) {
		_free_slots.push_back(slot);
	}
}

// Bulk path: recomputes the region map and the slot table from `_regions`. Used
// when the whole region set is replaced (load_directory, change_region_size,
// set_region_locations) rather than one region entering or leaving memory.
void Terrain3DData::_rebuild_region_map() {
	LOG(EXTREME, "Regenerating ", REGION_MAP_VSIZE, " region map array from active regions");
	_region_map.clear();
	_region_map.resize(REGION_MAP_SIZE * REGION_MAP_SIZE);
	_region_locations = TypedArray<Vector2i>(); // enforce new pointer
	_reset_slots();
	for (const Vector2i &region_loc : _regions.keys()) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (region && !region->is_deleted()) {
			if (_acquire_slot(region_loc) < 0) {
				continue;
			}
			_region_locations.push_back(region_loc);
		}
	}
	_region_map_dirty = false;
	_region_map_signal_dirty = true;
	_region_map_rebuild_count++;
	_rebuild_region_directory();
}

// The blank layer is cached per slot map: it is only needed when an array is
// (re)created and as the placeholder for a region without a surface map, but
// building it is a full region-sized image fill, which must not happen on every
// update_maps() call. The cache follows the region size.
Ref<Image> Terrain3DData::_get_blank_slot_map(const int p_slot_map) {
	if (_region_size <= 0 || p_slot_map < 0 || p_slot_map >= SLOT_MAP_MAX) {
		return Ref<Image>();
	}
	Ref<Image> &blank = _blank_slot_maps[p_slot_map];
	if (blank.is_valid() && blank->get_width() == _region_size) {
		return blank;
	}
	switch (p_slot_map) {
		case SLOT_MAP_HEIGHT:
			blank = Util::get_filled_image(_region_sizev, Terrain3DRegion::COLOR[Terrain3DRegion::TYPE_HEIGHT], false,
					Terrain3DRegion::FORMAT[Terrain3DRegion::TYPE_HEIGHT]);
			break;
		case SLOT_MAP_CONTROL:
			blank = Util::get_filled_image(_region_sizev, Terrain3DRegion::COLOR[Terrain3DRegion::TYPE_CONTROL], false,
					Terrain3DRegion::FORMAT[Terrain3DRegion::TYPE_CONTROL]);
			break;
		case SLOT_MAP_COLOR:
			blank = Util::get_filled_image(_region_sizev, Terrain3DRegion::COLOR[Terrain3DRegion::TYPE_COLOR], true,
					Terrain3DRegion::FORMAT[Terrain3DRegion::TYPE_COLOR]);
			break;
		case SLOT_MAP_SURFACE: {
			// A blank R16 layer is all-zero packed values = single material 0.
			// FORMAT_R16 (39) is not named in this godot-cpp binding.
			PackedByteArray zeros;
			zeros.resize(int64_t(_region_size) * _region_size * 2);
			blank = Image::create_from_data(_region_size, _region_size, false, Image::Format(39), zeros);
			break;
		}
		default:
			break;
	}
	return blank;
}

// Samples the payload of whichever region owns a world position, on that region's own
// density grid. Returns 0 when no region covers it.
uint16_t Terrain3DData::_sample_payload_world(const real_t p_world_x, const real_t p_world_z) const {
	if (_region_size <= 0) {
		return 0;
	}
	const real_t vertex_spacing = MAX(0.0001f, _vertex_spacing);
	const real_t region_world = real_t(_region_size) * vertex_spacing;
	const Vector2i region_loc(int(Math::floor(p_world_x / region_world)),
			int(Math::floor(p_world_z / region_world)));
	const Terrain3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted() || region->get_surface_map().is_null()) {
		return 0;
	}
	const int density = MAX(1, region->get_surface_density());
	const real_t payload_texel = vertex_spacing / real_t(density);
	const int size = region->get_surface_map()->get_width();
	const int x = CLAMP(int(Math::floor((p_world_x - real_t(region_loc.x) * region_world) / payload_texel)), 0, size - 1);
	const int y = CLAMP(int(Math::floor((p_world_z - real_t(region_loc.y) * region_world) / payload_texel)), 0, size - 1);
	// `get_data()` shares the image's buffer rather than copying it, so reading the two
	// bytes through a pointer costs one call instead of one per texel.
	const PackedByteArray payload = region->get_surface_map()->get_data();
	if (payload.size() < int64_t(size) * size * 2) {
		return 0;
	}
	const uint8_t *texel = payload.ptr() + (int64_t(y) * size + x) * 2;
	return uint16_t(texel[0]) | (uint16_t(texel[1]) << 8);
}

Ref<Image> Terrain3DData::_get_slot_map_image(const Terrain3DRegion *p_region, const int p_slot_map) const {
	if (!p_region) {
		return Ref<Image>();
	}
	switch (p_slot_map) {
		case SLOT_MAP_HEIGHT:
			return p_region->get_height_map();
		case SLOT_MAP_CONTROL:
			return p_region->get_control_map();
		case SLOT_MAP_COLOR:
			return p_region->get_color_map();
		case SLOT_MAP_SURFACE:
			// The array layer stays at region_size even when the region's stored
			// payload is denser; the virtual texture serves the extra detail.
			return p_region->get_surface_map_array_image();
		default:
			return Ref<Image>();
	}
}

// Uploads one of the four slot maps. Only layers that are actually stale are
// touched, unless the whole map was marked full (capacity change, bulk rebuild, or
// an explicit update_maps(all_regions = true)). Returns true if anything changed.
bool Terrain3DData::_sync_slot_map(const int p_slot_map) {
	GeneratedTexture *gen = nullptr;
	TypedArray<Image> *images = nullptr;
	const char *signal = nullptr;
	switch (p_slot_map) {
		case SLOT_MAP_HEIGHT:
			gen = &_generated_height_maps;
			images = &_height_maps;
			signal = "height_maps_changed";
			break;
		case SLOT_MAP_CONTROL:
			gen = &_generated_control_maps;
			images = &_control_maps;
			signal = "control_maps_changed";
			break;
		case SLOT_MAP_COLOR:
			gen = &_generated_color_maps;
			images = &_color_maps;
			signal = "color_maps_changed";
			break;
		case SLOT_MAP_SURFACE:
			gen = &_generated_surface_maps;
			images = &_surface_maps;
			signal = "surface_maps_changed";
			break;
		default:
			return false;
	}
	if (_slot_capacity <= 0) {
		gen->clear();
		images->clear();
		_slot_map_full[p_slot_map] = false;
		return false;
	}
	const Ref<Image> blank = _get_blank_slot_map(p_slot_map);
	if (blank.is_null()) {
		return false;
	}
	// Keep the CPU side array slot indexed so get_surface_maps() and
	// update_surface_region() agree with the uploaded layers. Free slots hold the
	// blank layer rather than null, because callers iterate these arrays as images.
	if (images->size() != _slot_capacity) {
		const int64_t previous = images->size();
		images->resize(_slot_capacity);
		for (int64_t slot = previous; slot < _slot_capacity; slot++) {
			(*images)[slot] = blank;
		}
	}
	const bool created = gen->ensure_layers(blank, _slot_capacity);
	const bool full = created || _slot_map_full[p_slot_map];
	if (full) {
		_slot_full_sync_count++;
	}
	const uint8_t bit = uint8_t(1 << p_slot_map);
	const bool use_surface_payload = p_slot_map != SLOT_MAP_SURFACE || !_terrain ||
			_terrain->is_surface_array_upload_needed();
	bool changed = false;
	for (int slot = 0; slot < _slot_capacity; slot++) {
		if (_slot_locations[slot] == V2I_MAX) {
			// Free slot: release the unloaded region's image so streaming actually
			// frees CPU memory. The layer is never sampled through the region map,
			// and the entry must stay a real image for callers that iterate it.
			Ref<Image> current = (*images)[slot];
			if (current != blank) {
				(*images)[slot] = blank;
			}
			continue;
		}
		if (!full && !(_slot_dirty[slot] & bit)) {
			continue;
		}
		// Avoid resampling dense surface payloads when VT only needs a blank binding.
		Ref<Image> image = use_surface_payload ?
				_get_slot_map_image(get_region_ptr(_slot_locations[slot]), p_slot_map) : Ref<Image>();
		if (image.is_null()) {
			// Regions without a surface map keep the blank layer, and so does the surface
			// map itself once the virtual textures serve the channel: the array stays
			// allocated for a valid binding, but no payload is uploaded.
			image = blank;
		}
		(*images)[slot] = image;
		gen->update(image, slot);
		// Clear this map's bit. Without this the slot stays dirty and is uploaded
		// again on every later sync, which is exactly the cost the slot table exists
		// to avoid: a settled ring would re-upload every resident layer per step.
		_slot_dirty[slot] &= uint8_t(~bit);
		changed = true;
	}
	_slot_map_full[p_slot_map] = false;
	if (changed) {
		LOG(DEBUG, "Emitting ", signal);
		emit_signal(signal);
	}
	return changed;
}

// Maps a public MapType request onto the internal slot maps. The surface map has no
// MapType of its own and is only refreshed by a full TYPE_MAX pass, as before.
bool Terrain3DData::_slot_map_requested(const MapType p_map_type, const int p_slot_map) {
	switch (p_slot_map) {
		case SLOT_MAP_HEIGHT:
			return p_map_type == TYPE_HEIGHT || p_map_type == TYPE_MAX;
		case SLOT_MAP_CONTROL:
			return p_map_type == TYPE_CONTROL || p_map_type == TYPE_MAX;
		case SLOT_MAP_COLOR:
			return p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX;
		case SLOT_MAP_SURFACE:
			return p_map_type == TYPE_MAX;
		default:
			return false;
	}
}

int Terrain3DData::_slot_map_mask(const MapType p_map_type) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return 1 << SLOT_MAP_HEIGHT;
		case TYPE_CONTROL:
			return 1 << SLOT_MAP_CONTROL;
		case TYPE_COLOR:
			return 1 << SLOT_MAP_COLOR;
		default:
			return 0xF;
	}
}

// Structured to work with do_for_regions. Should be renamed when copy_paste is expanded
void Terrain3DData::_copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Rect2i &p_dst_rect, const Terrain3DRegion *p_dst_region) {
	if (!p_src_region || !p_dst_region) {
		return;
	}
	TypedArray<Image> src_maps = p_src_region->get_maps();
	TypedArray<Image> dst_maps = p_dst_region->get_maps();
	for (int i = 0; i < dst_maps.size(); i++) {
		Image *img = cast_to<Image>(dst_maps[i]);
		if (img) {
			img->blit_rect(src_maps[i], p_src_rect, p_dst_rect.position);
		}
	}
	_terrain->get_instancer()->copy_paste_dfr(p_src_region, p_src_rect, p_dst_region);
}

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
	return add_region_blank(get_region_location(p_global_position));
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

// The layer -> region location table the shader reads as `_region_locations`.
// Free slots are V2I_MAX; the region map never points at them, so the shader never
// indexes one. Padded to the material's max_regions by Terrain3DMaterial.
PackedVector2Array Terrain3DData::get_slot_locations() const {
	PackedVector2Array locations;
	locations.resize(_slot_capacity);
	for (int slot = 0; slot < _slot_capacity; slot++) {
		locations[slot] = (_slot_locations[slot] == V2I_MAX) ? Vector2() : Vector2(_slot_locations[slot]);
	}
	return locations;
}

// Diagnostics for the slot table and the texture arrays. `map_create_count` counts
// GPU array allocations, `map_update_count` counts single layer uploads: steady
// streaming should grow the second and leave the first alone.
Dictionary Terrain3DData::get_map_stats() const {
	Dictionary stats;
	stats["slot_capacity"] = _slot_capacity;
	stats["slot_count"] = int(_region_slots.size());
	stats["free_slots"] = int(_free_slots.size());
	stats["region_count"] = _region_locations.size();
	stats["map_create_count"] = _generated_height_maps.get_create_count() +
			_generated_control_maps.get_create_count() +
			_generated_color_maps.get_create_count() +
			_generated_surface_maps.get_create_count();
	stats["map_update_count"] = _generated_height_maps.get_update_count() +
			_generated_control_maps.get_update_count() +
			_generated_color_maps.get_update_count() +
			_generated_surface_maps.get_update_count();
	stats["height_layers"] = _generated_height_maps.get_layer_count();
	stats["control_layers"] = _generated_control_maps.get_layer_count();
	stats["color_layers"] = _generated_color_maps.get_layer_count();
	stats["surface_layers"] = _generated_surface_maps.get_layer_count();
	stats["slot_grow_count"] = _slot_grow_count;
	stats["region_map_rebuild_count"] = _region_map_rebuild_count;
	stats["slot_full_sync_count"] = _slot_full_sync_count;
	stats["region_map_size"] = REGION_MAP_SIZE;
	stats["directory_valid"] = _region_directory.get_rid().is_valid();
	return stats;
}

void Terrain3DData::reset_map_stats() {
	_generated_height_maps.reset_counters();
	_generated_control_maps.reset_counters();
	_generated_color_maps.reset_counters();
	_generated_surface_maps.reset_counters();
	_slot_grow_count = 0;
	_region_map_rebuild_count = 0;
	_slot_full_sync_count = 0;
}

TypedArray<Image> Terrain3DData::get_maps(const MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return get_height_maps();
			break;
		case TYPE_CONTROL:
			return get_control_maps();
			break;
		case TYPE_COLOR:
			return get_color_maps();
			break;
		default:
			break;
	}
	return TypedArray<Image>();
}

void Terrain3DData::update_maps(const MapType p_map_type, const bool p_all_regions, const bool p_generate_mipmaps) {
	// Generate region color mipmaps
	if (p_generate_mipmaps && (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX)) {
		LOG(EXTREME, "Regenerating color mipmaps");
		for (const Vector2i &region_loc : _regions.keys()) {
			Terrain3DRegion *region = get_region_ptr(region_loc);
			// Generate all or only those marked edited
			if (region && !region->is_deleted() && (p_all_regions || region->is_edited())) {
				region->get_color_map()->generate_mipmaps();
			}
		}
	}

	// p_all_regions means "assume every region changed". It no longer throws the GPU
	// arrays away: the layer layout belongs to the slot table, so the arrays are only
	// recreated when the slot capacity changes.
	if (p_all_regions) {
		LOG(EXTREME, "Marking dirty maps of type: ", p_map_type);
		switch (p_map_type) {
			case TYPE_HEIGHT:
				_slot_map_full[SLOT_MAP_HEIGHT] = true;
				break;
			case TYPE_CONTROL:
				_slot_map_full[SLOT_MAP_CONTROL] = true;
				break;
			case TYPE_COLOR:
				_slot_map_full[SLOT_MAP_COLOR] = true;
				break;
			default:
				for (int i = 0; i < SLOT_MAP_MAX; i++) {
					_slot_map_full[i] = true;
				}
				_region_map_dirty = true;
				break;
		}
	}

	// A structural change (a region entering or leaving memory, a bulk rebuild, or a
	// capacity change) has to reach the material, because the array RIDs and the
	// region/layer mapping it holds may have moved. Content edits do not, and the old
	// code relied on a full rebuild to tell the two apart.
	bool structural = _region_map_dirty || _region_map_signal_dirty;
	for (int i = 0; i < SLOT_MAP_MAX && !structural; i++) {
		structural = _slot_map_full[i];
	}
	for (int slot = 0; slot < (int)_slot_dirty.size() && !structural; slot++) {
		structural = _slot_dirty[slot] != 0;
	}

	if (_region_map_dirty) {
		_rebuild_region_map();
	}

	// Fold content edits into the slot dirtiness so one upload pass covers both
	// structural and edited changes: a region can be edited in the same call that
	// adds or unloads another one.
	const int edit_mask = _slot_map_mask(p_map_type);
	for (const Vector2i &region_loc : _region_locations) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (region && region->is_edited()) {
			_mark_slot_dirty(get_region_id(region_loc), edit_mask);
		}
	}

	bool any_changed = false;
	for (int slot_map = 0; slot_map < SLOT_MAP_MAX; slot_map++) {
		if (!_slot_map_requested(p_map_type, slot_map)) {
			continue;
		}
		const bool changed = _sync_slot_map(slot_map);
		any_changed = any_changed || changed;
		if (changed && slot_map == SLOT_MAP_HEIGHT) {
			calc_height_range();
		}
	}

	// The directory has to reach the shader whenever it changed, not only when the
	// region map signal fires: adding a region patches one texel without touching
	// `_region_map_signal_dirty`.
	const bool directory_changed = _region_directory_dirty;
	if (directory_changed) {
		_update_region_directory();
	}

	if (_region_map_signal_dirty) {
		_region_map_signal_dirty = false;
		LOG(DEBUG, "Emitting region_map_changed");
		emit_signal("region_map_changed");
	}

	if (any_changed || structural || directory_changed) {
		LOG(DEBUG, "Emitting maps_changed");
		emit_signal("maps_changed");
		_terrain->snap();
	}
}

void Terrain3DData::update_surface_region(Image *p_surface_map, const int p_region_id) {
	if (_terrain && !_terrain->is_surface_array_upload_needed()) {
		// The array does not carry the surface channel in this configuration; the
		// virtual textures are refreshed through invalidate_surface_pages() instead.
		return;
	}
	if (p_surface_map && p_region_id >= 0 && p_region_id < _surface_maps.size()) {
		// A first paint can replace the blank placeholder with a newly created
		// region surface map. Keep CPU queries aligned with the uploaded layer.
		_surface_maps[p_region_id] = Ref<Image>(p_surface_map);
		_generated_surface_maps.update(Ref<Image>(p_surface_map), p_region_id);
		LOG(DEBUG, "Emitting surface_maps_changed");
		emit_signal("surface_maps_changed");
	}
}

void Terrain3DData::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	Vector2i vgrid = world_to_vgrid(p_global_position);
	Vector2i region_loc = V2I_DIVIDE_FLOOR(vgrid, _region_size);
	Terrain3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		LOG(ERROR, "No active region found at: ", p_global_position);
		return;
	}
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		// Local pixel in the region is always [0, region_size)
		Vector2i img_pos(Math::posmod(vgrid.x, _region_size), Math::posmod(vgrid.y, _region_size));
		map->set_pixelv(img_pos, p_pixel);
		region->set_modified(true);
	}
}

// Expects descaled, snapped/floored, global position - vertex grid
Color Terrain3DData::get_pixel_descaled(const MapType p_map_type, const Vector2i &p_vgrid) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	Vector2i region_loc = V2I_DIVIDE_FLOOR(p_vgrid, _region_size);
	const Terrain3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return COLOR_NAN;
	}
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		// Local pixel in the region is always [0, region_size)
		Vector2i img_pos(Math::posmod(p_vgrid.x, _region_size), Math::posmod(p_vgrid.y, _region_size));
		return map->get_pixelv(img_pos);
	} else {
		return COLOR_NAN;
	}
}

real_t Terrain3DData::get_surface_height(const Vector3 &p_global_position) const {
	Vector3 pos = p_global_position;
	const real_t &step = _vertex_spacing;
	pos.y = 0.f;
	// Compare position to nearest vertex, and if close don't interpolate
	Vector3 pos_round = pos.snapped(Vector3(step, 0.f, step));
	if ((pos - pos_round).length_squared() < 0.0001f) {
		return get_modified_height(world_to_vgrid(pos_round));
	} else {
		// Otherwise, bilinearly interpolate 4 surrounding vertices
		Vector2i v00 = world_to_vgrid(pos);
		real_t ht00 = get_modified_height(v00);
		Vector2i v01 = v00 + Vector2i(0, 1);
		real_t ht01 = get_modified_height(v01);
		Vector2i v10 = v00 + Vector2i(1, 0);
		real_t ht10 = get_modified_height(v10);
		Vector2i v11 = v00 + Vector2i(1, 1);
		real_t ht11 = get_modified_height(v11);
		return bilerp(ht00, ht01, ht10, ht11, Vector2(v00), Vector2(v11), v3v2(pos / step));
	}
}

// Expects descaled, snapped/floored global position - vertex grid
// Returns height modified by world background region blend, ground level
real_t Terrain3DData::get_modified_height(const Vector2i &p_vgrid) const {
	// Control map is always packed as a float32 Color component, regardless
	// of engine precision, so this must stay float, not real_t.
	float control = get_pixel_descaled(TYPE_CONTROL, p_vgrid).r;
	if (is_hole(control)) {
		return NAN;
	}
	real_t height = get_pixel_descaled(TYPE_HEIGHT, p_vgrid).r;
	const Ref<Terrain3DMaterial> material = _terrain->get_material();
	if (material.is_valid()) {
		const Terrain3DMaterial::WorldBackground bg_mode = material->get_world_background();
		if (bg_mode == Terrain3DMaterial::WorldBackground::FLAT || bg_mode == Terrain3DMaterial::WorldBackground::NOISE) {
			Variant var_gl = material->get("ground_level");
			Variant var_rb = material->get("region_blend");
			if (var_gl.get_type() == Variant::NIL || var_rb.get_type() == Variant::NIL) {
				return height;
			}
			const real_t ground_level = var_gl;
			const real_t region_texel_size = 1.f / real_t(_region_size);
			Vector2 uv2 = Vector2(p_vgrid) * region_texel_size;
			height = Math::lerp(height, ground_level, smoothstep(0.f, 1.f, get_region_blend(uv2)));
		}
	}
	return height;
}

real_t Terrain3DData::get_region_blend(const Vector2 &p_uv2) const {
	const Ref<Terrain3DMaterial> material = _terrain->get_material();
	if (!material.is_valid()) {
		return 0.f;
	}
	Variant var_rb = material->get("region_blend");
	if (var_rb.get_type() == Variant::NIL) {
		return 0.f;
	}
	const real_t region_blend = var_rb;

	auto check_region = [&](const Vector2 &uv2) -> real_t {
		int idx = get_region_map_index(Vector2i(Math::floor(uv2.x), Math::floor(uv2.y)));
		return (idx >= 0 && _region_map[idx] > 0) ? 1.f : 0.f;
	};

	// Floating point bias (must match shader)
	Vector2 uv2 = p_uv2 - Vector2(0.5011f, 0.5011f);

	real_t a = check_region(uv2 + Vector2(0.0f, 1.0f));
	real_t b = check_region(uv2 + Vector2(1.0f, 1.0f));
	real_t c = check_region(uv2 + Vector2(1.0f, 0.0f));
	real_t d = check_region(uv2 + Vector2(0.0f, 0.0f));

	real_t blend_factor = 2.0f + 126.0f * (1.0f - region_blend);
	Vector2 f = Vector2(uv2.x - Math::floor(uv2.x), uv2.y - Math::floor(uv2.y));
	f.x = Math::clamp(f.x, real_t(1e-8f), real_t(1.0f - 1e-8f));
	f.y = Math::clamp(f.y, real_t(1e-8f), real_t(1.0f - 1e-8f));
	Vector2 w = Vector2(1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.x) / f.x))),
			1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.y) / f.y))));
	real_t blend = Math::lerp(Math::lerp(d, c, w.x), Math::lerp(a, b, w.x), w.y);

	return (1.f - blend) * 2.f;
}

Vector3 Terrain3DData::get_normal(const Vector3 &p_global_position) const {
	if (get_region_idp(p_global_position) < 0 || is_hole(get_control(p_global_position))) {
		return V3_NAN;
	}
	const real_t step = _vertex_spacing;
	real_t h = get_surface_height(p_global_position);
	if (!std::isfinite(h)) {
		return V3_NAN;
	}
	real_t hx = get_surface_height(p_global_position + Vector3(step, 0.f, 0.f));
	if (!std::isfinite(hx)) {
		return V3_NAN;
	}
	real_t hz = get_surface_height(p_global_position + Vector3(0.f, 0.f, step));
	if (!std::isfinite(hx)) {
		return V3_NAN;
	}
	Vector3 normal(h - hx, step, h - hz);
	normal.normalize();
	return normal;
}

bool Terrain3DData::is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal) const {
	// If slope is full range, nothing to do here
	const Vector2 slope_range = CLAMP(p_slope_range, V2_ZERO, V2(90.f));
	if (slope_range.y - slope_range.x > 89.99f) {
		return true;
	}

	// Use custom normal if provided
	Vector3 slope_normal = p_normal;
	if (!slope_normal.is_zero_approx()) {
		slope_normal.normalize();
	} else {
		// Else, compute terrain normal
		slope_normal = get_normal(p_global_position);
		if (!slope_normal.is_finite()) {
			return false;
		}
	}

	const real_t slope_angle = slope_normal.angle_to(V3_UP);
	const real_t slope_angle_degrees = Math::rad_to_deg(slope_angle);
	return (slope_range.x <= slope_angle_degrees) && (slope_angle_degrees <= slope_range.y);
}

/**
 * Returns:
 * X = base index
 * Y = overlay index
 * Z = percentage blend between X and Y. Limited to the fixed values in RANGE.
 * Interpretation of this data is up to the gamedev. Unfortunately due to blending, this isn't
 * pixel perfect. I would have your player print this location as you walk around to see how the
 * blending values look, then consider that the overlay texture is visible starting at a blend
 * value of .3-.5, otherwise it's the base texture.
 **/
Vector3 Terrain3DData::get_texture_id(const Vector3 &p_global_position) const {
	Vector2i vgrid = world_to_vgrid(p_global_position);

	// Region + hole check. See get_modified_height() above for why this is float, not real_t.
	float control = get_pixel_descaled(TYPE_CONTROL, vgrid).r;
	if (std::isnan(control) || is_hole(control)) {
		return V3_NAN;
	}

	// Material painting writes the R16 ID/weight map, not the legacy control
	// map. Picking and live info must read the same data as the shader.
	Ref<Terrain3DRegion> region = get_regionp(p_global_position);
	if (region.is_valid() && region->get_surface_map().is_valid()) {
		// The stored payload is region_size * surface_density squared, while vgrid
		// is in region texels.
		const int density = MAX(1, region->get_surface_density());
		Vector2i pixel = (vgrid - region->get_location() * region->get_region_size()) * density;
		const int surface_size = region->get_surface_map()->get_width();
		pixel.x = CLAMP(pixel.x, 0, surface_size - 1);
		pixel.y = CLAMP(pixel.y, 0, surface_size - 1);
		float value = region->get_surface_map()->get_pixelv(pixel).r;
		uint16_t packed = uint16_t(CLAMP(Math::round(value * 65535.0f), 0.0f, 65535.0f));
		TerrainSurfaceIdWeight::Pair pair = TerrainSurfaceIdWeight::decode(packed);
		return Vector3(pair.background, pair.overlay, TerrainSurfaceIdWeight::contribution(packed));
	}

	// If material available, autoshader enabled, and pixel set to auto
	if (_terrain) {
		Ref<Terrain3DMaterial> mat = _terrain->get_material();
		if (mat.is_valid() && mat->get_auto_shader_enabled() && is_auto(control)) {
			real_t auto_slope = real_t(mat->get_shader_param("auto_slope"));
			real_t auto_height_reduction = real_t(mat->get_shader_param("auto_height_reduction"));
			real_t height = get_modified_height(vgrid);
			Vector3 normal = get_normal(p_global_position);
			uint32_t base_id = mat->get_shader_param("auto_base_texture");
			uint32_t overlay_id = mat->get_shader_param("auto_overlay_texture");
			real_t blend = CLAMP((auto_slope * 2.f * (normal.y - 1.f) + 1.f) - auto_height_reduction * .01f * height, 0.f, 1.f);
			return Vector3(real_t(base_id), real_t(overlay_id), blend);
		}
	}

	// Else, just get textures from control map
	uint32_t base_id = get_base(control);
	uint32_t overlay_id = get_overlay(control);
	real_t blend = real_t(get_blend(control)) / 255.f;
	return Vector3(real_t(base_id), real_t(overlay_id), blend);
}

/**
 * Returns the location of a terrain vertex at a certain LOD. If there is a hole at the position, it returns
 * NAN in the vector's Y coordinate.
 * p_lod (0-8): Determines how many heights around the given global position will be sampled.
 * p_filter:
 *  HEIGHT_FILTER_NEAREST: Samples the height map at the exact coordinates given.
 *  HEIGHT_FILTER_MINIMUM: Samples (1 << p_lod) ** 2 heights around the given coordinates and returns the lowest.
 * p_global_position: X and Z coordinates of the vertex. Heights will be sampled around these coordinates.
 */
Vector3 Terrain3DData::get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const {
	LOG(INFO, "Calculating vertex location");
	Vector2i vgrid = world_to_vgrid(p_global_position);
	real_t height = get_mesh_vertex_height(p_lod, p_filter, vgrid);
	return Vector3(p_global_position.x, height, p_global_position.z);
}

real_t Terrain3DData::get_mesh_vertex_height(const int32_t p_lod, const HeightFilter p_filter, const Vector2i &p_vgrid) const {
	const int32_t lod_step = 1 << CLAMP(p_lod, 0, 8);
	real_t height = 0.f;
	switch (p_filter) {
		case HEIGHT_FILTER_NEAREST: {
			height = get_modified_height(p_vgrid);
		} break;

		case HEIGHT_FILTER_MINIMUM: {
			height = get_modified_height(p_vgrid);
			if (std::isnan(height)) {
				break;
			}
			const int half = lod_step / 2;
			for (int32_t dx = -half; dx < half; ++dx) {
				for (int32_t dz = -half; dz < half; ++dz) {
					real_t h = get_modified_height(p_vgrid + Vector2i(dx, dz));
					if (std::isnan(h)) {
						height = NAN;
						return height;
					}
					if (h < height) {
						height = h;
					}
				}
			}
		} break;
	}
	return height;
}

void Terrain3DData::add_edited_area(const AABB &p_area) {
	if (_terrain && (_terrain->is_surface_vt_enabled() || _terrain->is_surface_svt_enabled())) {
		float world = _region_size * _vertex_spacing;
		Vector3 end = p_area.position + p_area.size;
		for (int z = int(Math::floor((p_area.position.z - _vertex_spacing) / world)); z <= int(Math::floor((end.z + _vertex_spacing) / world)); z++) {
			for (int x = int(Math::floor((p_area.position.x - _vertex_spacing) / world)); x <= int(Math::floor((end.x + _vertex_spacing) / world)); x++) {
				_terrain->invalidate_surface_pages(Vector2i(x, z));
			}
		}
	}
	if (_edited_area.has_surface()) {
		_edited_area = _edited_area.merge(p_area);
	} else {
		_edited_area = p_area;
	}
	LOG(DEBUG, "Emitting maps_edited");
	emit_signal("maps_edited", p_area);
}

// Recalculates master height range from all active regions current height ranges
// Recursive mode has all regions to recalculate from each heightmap pixel
void Terrain3DData::calc_height_range(const bool p_recursive) {
	_master_height_range = V2_ZERO;
	for (const Vector2i &region_loc : _region_locations) {
		Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		if (p_recursive) {
			region->calc_height_range();
		}
		update_master_heights(region->get_height_range());
	}
	LOG(EXTREME, "Accumulated height range for all regions: ", _master_height_range);
}

void Terrain3DData::dump(const bool verbose) const {
	LOG(MESG, "_region_locations (", _region_locations.size(), "): ", _region_locations);
	LOG(MESG, "Map slots: ", _slot_capacity, " capacity, ", _region_slots.size(), " used, ", _free_slots.size(), " free");
	Array keys = _regions.keys();
	LOG(MESG, "_regions (", keys.size(), "):");
	for (const Vector2i &region_loc : keys) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "No region found at: ", region_loc);
			continue;
		}
		region->dump(verbose);
	}
	if (verbose) {
		for (int slot = 0; slot < _slot_capacity; slot++) {
			if (_slot_locations[slot] != V2I_MAX) {
				LOG(MESG, "Slot ", slot, " / ", _slot_capacity - 1, " -> region ", _slot_locations[slot]);
			}
		}
		for (int i = 0; i < _region_map.size(); i++) {
			if (_region_map[i]) {
				LOG(MESG, "Region map array index: ", i, " / ", _region_map.size() - 1, ", Slot: ", _region_map[i] - 1);
			}
		}
		Util::dump_maps(_height_maps, "Height maps");
		Util::dump_gentex(_generated_height_maps, "height");
		Util::dump_maps(_control_maps, "Control maps");
		Util::dump_gentex(_generated_control_maps, "control");
		Util::dump_maps(_color_maps, "Color maps");
		Util::dump_gentex(_generated_color_maps, "color");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DData::_bind_methods() {
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_NEAREST);
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_MINIMUM);

	BIND_ENUM_CONSTANT(EXPORT_SLICES);
	BIND_ENUM_CONSTANT(EXPORT_REGIONS);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DData::get_region_count);
	ClassDB::bind_method(D_METHOD("set_region_locations", "region_locations"), &Terrain3DData::set_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Terrain3DData::get_region_locations);
	ClassDB::bind_method(D_METHOD("get_regions_active", "copy", "deep"), &Terrain3DData::get_regions_active, DEFVAL(false), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_regions_all"), &Terrain3DData::get_regions_all);
	ClassDB::bind_method(D_METHOD("get_region_map"), &Terrain3DData::get_region_map);
	ClassDB::bind_method(D_METHOD("get_region_directory_rid"), &Terrain3DData::get_region_directory_rid);
	ClassDB::bind_method(D_METHOD("is_region_directory_valid"), &Terrain3DData::is_region_directory_valid);
	ClassDB::bind_method(D_METHOD("region_map_to_image", "region_map"), &Terrain3DData::region_map_to_image);
	ClassDB::bind_method(D_METHOD("get_map_capacity"), &Terrain3DData::get_map_capacity);
	ClassDB::bind_method(D_METHOD("get_slot_locations"), &Terrain3DData::get_slot_locations);
	ClassDB::bind_method(D_METHOD("get_map_stats"), &Terrain3DData::get_map_stats);
	ClassDB::bind_method(D_METHOD("reset_map_stats"), &Terrain3DData::reset_map_stats);
	ClassDB::bind_static_method("Terrain3DData", D_METHOD("get_region_map_index", "region_location"), &Terrain3DData::get_region_map_index);

	ClassDB::bind_method(D_METHOD("do_for_regions", "area", "callback"), &Terrain3DData::do_for_regions);
	ClassDB::bind_method(D_METHOD("change_region_size", "region_size"), &Terrain3DData::change_region_size);
	ClassDB::bind_method(D_METHOD("change_surface_density", "density"), &Terrain3DData::change_surface_density);
	ClassDB::bind_method(D_METHOD("make_sparse_surface_page", "page_x", "page_y", "local_mip",
								 "page_world_size", "page_size", "border"),
			&Terrain3DData::make_sparse_surface_page);

	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Terrain3DData::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_id", "region_location"), &Terrain3DData::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_idp", "global_position"), &Terrain3DData::get_region_idp);

	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Terrain3DData::has_region);
	ClassDB::bind_method(D_METHOD("has_regionp", "global_position"), &Terrain3DData::has_regionp);
	ClassDB::bind_method(D_METHOD("get_region", "region_location"), &Terrain3DData::get_region);
	ClassDB::bind_method(D_METHOD("get_regionp", "global_position"), &Terrain3DData::get_regionp);

	ClassDB::bind_method(D_METHOD("set_region_modified", "region_location", "modified"), &Terrain3DData::set_region_modified);
	ClassDB::bind_method(D_METHOD("is_region_modified", "region_location"), &Terrain3DData::is_region_modified);
	ClassDB::bind_method(D_METHOD("set_region_deleted", "region_location", "deleted"), &Terrain3DData::set_region_deleted);
	ClassDB::bind_method(D_METHOD("is_region_deleted", "region_location"), &Terrain3DData::is_region_deleted);

	ClassDB::bind_method(D_METHOD("add_region_blankp", "global_position", "update"), &Terrain3DData::add_region_blankp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blank", "region_location", "update"), &Terrain3DData::add_region_blank, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region", "region", "update"), &Terrain3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionp", "global_position", "update"), &Terrain3DData::remove_regionp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionl", "region_location", "update"), &Terrain3DData::remove_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "region", "update"), &Terrain3DData::remove_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("unload_region", "region_location", "update"), &Terrain3DData::unload_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Terrain3DData::save_directory);
	ClassDB::bind_method(D_METHOD("save_region", "region_location", "directory", "save_16_bit"), &Terrain3DData::save_region, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Terrain3DData::load_directory);
	ClassDB::bind_method(D_METHOD("load_region", "region_location", "directory", "update"), &Terrain3DData::load_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DData::get_height_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DData::get_control_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DData::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_surface_maps"), &Terrain3DData::get_surface_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DData::get_maps);
	ClassDB::bind_method(D_METHOD("update_maps", "map_type", "all_regions", "generate_mipmaps"), &Terrain3DData::update_maps, DEFVAL(TYPE_MAX), DEFVAL(true), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Terrain3DData::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Terrain3DData::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Terrain3DData::get_color_maps_rid);
	ClassDB::bind_method(D_METHOD("get_surface_maps_rid"), &Terrain3DData::get_surface_maps_rid);

	ClassDB::bind_method(D_METHOD("set_pixel", "map_type", "global_position", "pixel"), &Terrain3DData::set_pixel);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DData::get_pixel);

	// Height Map
	ClassDB::bind_method(D_METHOD("set_height", "global_position", "height"), &Terrain3DData::set_height);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DData::get_height);
	ClassDB::bind_method(D_METHOD("get_surface_height", "global_position"), &Terrain3DData::get_surface_height);
	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DData::get_normal);
	ClassDB::bind_method(D_METHOD("is_in_slope", "global_position", "slope_range", "normal"), &Terrain3DData::is_in_slope, DEFVAL(V3_ZERO));

	// Control Map
	ClassDB::bind_method(D_METHOD("set_control", "global_position", "control"), &Terrain3DData::set_control);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DData::get_control);
	ClassDB::bind_method(D_METHOD("set_control_base_id", "global_position", "texture_id"), &Terrain3DData::set_control_base_id);
	ClassDB::bind_method(D_METHOD("get_control_base_id", "global_position"), &Terrain3DData::get_control_base_id);
	ClassDB::bind_method(D_METHOD("set_control_overlay_id", "global_position", "texture_id"), &Terrain3DData::set_control_overlay_id);
	ClassDB::bind_method(D_METHOD("get_control_overlay_id", "global_position"), &Terrain3DData::get_control_overlay_id);
	ClassDB::bind_method(D_METHOD("set_control_blend", "global_position", "blend_value"), &Terrain3DData::set_control_blend);
	ClassDB::bind_method(D_METHOD("get_control_blend", "global_position"), &Terrain3DData::get_control_blend);
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DData::get_texture_id);
	ClassDB::bind_method(D_METHOD("set_control_angle", "global_position", "degrees"), &Terrain3DData::set_control_angle);
	ClassDB::bind_method(D_METHOD("get_control_angle", "global_position"), &Terrain3DData::get_control_angle);
	ClassDB::bind_method(D_METHOD("set_control_scale", "global_position", "percentage_modifier"), &Terrain3DData::set_control_scale);
	ClassDB::bind_method(D_METHOD("get_control_scale", "global_position"), &Terrain3DData::get_control_scale);
	ClassDB::bind_method(D_METHOD("set_control_hole", "global_position", "enable"), &Terrain3DData::set_control_hole);
	ClassDB::bind_method(D_METHOD("get_control_hole", "global_position"), &Terrain3DData::get_control_hole);
	ClassDB::bind_method(D_METHOD("set_control_navigation", "global_position", "enable"), &Terrain3DData::set_control_navigation);
	ClassDB::bind_method(D_METHOD("get_control_navigation", "global_position"), &Terrain3DData::get_control_navigation);
	ClassDB::bind_method(D_METHOD("set_control_auto", "global_position", "enable"), &Terrain3DData::set_control_auto);
	ClassDB::bind_method(D_METHOD("get_control_auto", "global_position"), &Terrain3DData::get_control_auto);

	// Color Map
	ClassDB::bind_method(D_METHOD("set_color", "global_position", "color"), &Terrain3DData::set_color);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DData::get_color);
	ClassDB::bind_method(D_METHOD("set_roughness", "global_position", "roughness"), &Terrain3DData::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DData::get_roughness);

	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DData::get_mesh_vertex);

	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DData::get_height_range);
	ClassDB::bind_method(D_METHOD("calc_height_range", "recursive"), &Terrain3DData::calc_height_range, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DData::import_images, DEFVAL(V3_ZERO), DEFVAL(0.f), DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type", "mode"), &Terrain3DData::export_image, DEFVAL(TYPE_HEIGHT), DEFVAL(EXPORT_SLICES));
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type", "bounds"), &Terrain3DData::layered_to_image, DEFVAL(Rect2i()));
	ClassDB::bind_method(D_METHOD("dump", "verbose"), &Terrain3DData::dump, DEFVAL(false));

	int ro_flags = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_locations", PROPERTY_HINT_ARRAY_TYPE, "Vector2i", ro_flags), "set_region_locations", "get_region_locations");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_color_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "surface_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_surface_maps");

	ADD_SIGNAL(MethodInfo("maps_changed"));
	ADD_SIGNAL(MethodInfo("region_map_changed"));
	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("control_maps_changed"));
	ADD_SIGNAL(MethodInfo("color_maps_changed"));
	ADD_SIGNAL(MethodInfo("surface_maps_changed"));
	ADD_SIGNAL(MethodInfo("maps_edited", PropertyInfo(Variant::AABB, "edited_area")));
}
