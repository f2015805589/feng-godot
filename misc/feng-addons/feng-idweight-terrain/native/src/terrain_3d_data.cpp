// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's slots, the chunk directory and the slot maps.

// One of five files that define Terrain3DData. This one owns the layer table the shader reads:
// the stable slot allocator (`_grow_slot_capacity()`, `_acquire_slot()`, `_release_slot()`), the
// chunk -> layer directory texture, the per-map-type blank layers and the slot-map upload that
// `_sync_slot_map()` performs. The region files are `terrain_3d_data_regions.cpp`, the map arrays
// and queries `terrain_3d_data_maps.cpp`, the edit bookkeeping `terrain_3d_data_edit.cpp`,
// `.vtcell`-free region I/O `terrain_3d_data_io.cpp` and page production
// `terrain_3d_data_surface.cpp`.
//
// This file includes what it uses rather than the family's old shared block: the block carried
// DirAccess, EditorFileSystem, EditorInterface, FileAccess, ResourceSaver, Engine and
// <unordered_map>, none of which appears in it.

#include "terrain_3d_data.h"
#include "terrain_3d.h"

#include "logger.h"

#include <algorithm>

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
	// Bounded by MAX_MAP_SLOTS, the CPU ceiling that matches the material's largest
	// selectable `max_regions` - not by the world grid. The shader drops any layer
	// index at or above the MAX_REGIONS it was compiled with, so a table that grew
	// past the ceiling could never render that layer.
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
	_mark_slot_dirty(slot, SLOT_MAP_ALL);
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
			PackedByteArray zeros;
			zeros.resize(int64_t(_region_size) * _region_size * 2);
			blank = Image::create_from_data(_region_size, _region_size, false, IDWEIGHT_IMAGE_FORMAT, zeros);
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
	return load_u16_le(texel);
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
			return SLOT_MAP_ALL;
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
