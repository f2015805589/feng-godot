// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DMaterialClipmapDetail: the sparse, demand-resident fine material layer.
//
// The header states the design. This file is the mechanism: the integer addressing, the slot table
// and its eviction, the screen-footprint level rule, the source pipeline's submit/poll, the
// generation check that gates publication, and the two GPU halves (the source arrays a result is
// uploaded into, and the baked arrays a producer writes). It contains no bake and no shading: the
// producer is offered `BakeOffer`s and reports them back, and the shader reads the directory this
// file publishes.

#include "terrain_3d_material_clipmap_detail.h"

#include "logger.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>
#include <cmath>

// `tile_key()` packs a signed tile coordinate into 27 bits an axis and the level above them, so the
// key is one integer: a world 2^26 tiles out - about 16 000 km at level 0's quarter-metre tile -
// addresses exactly, which is what "no floating point in the addressing" buys.
static constexpr int DETAIL_TILE_BITS = 27;
static constexpr int64_t DETAIL_TILE_MASK = (int64_t(1) << DETAIL_TILE_BITS) - 1;
static constexpr int64_t DETAIL_TILE_SIGN = int64_t(1) << (DETAIL_TILE_BITS - 1);
static constexpr int DETAIL_LEVEL_SHIFT = DETAIL_TILE_BITS * 2;

// How many ticks an offer may stay unacknowledged before the tile is offered again. A producer that
// exists but cannot dispatch (no material list yet, no device) leaves its offers queued rather than
// acking them, and without this the tile would wait forever for a bake that was already dropped.
static constexpr uint64_t DETAIL_OFFER_TIMEOUT_TICKS = 240;

// How long a wanted tile may stay unreadable before its slot is eligible for eviction. It is four
// times the offer timeout, so a tile that was merely slow to bake is never taken: only a source or a
// bake that has genuinely stopped reporting is, and the tile that replaces it is one the walk wants.
static constexpr uint64_t DETAIL_PENDING_EVICT_TICKS = 960;

// The bytes one stored texel of one value costs, and one baked texel: the two source arrays are a
// 16-bit payload and a 32-bit height, the three baked arrays are RGBA16F. The budget is charged in
// these bytes, so "the layer costs what the setting says" is a multiplication rather than a claim.
static constexpr int64_t DETAIL_PAYLOAD_BYTES_PER_TEXEL = 2;
static constexpr int64_t DETAIL_HEIGHT_BYTES_PER_TEXEL = 4;
static constexpr int64_t DETAIL_BAKED_BYTES_PER_TEXEL = 8;
static constexpr int DETAIL_BAKED_CHANNELS = 3;

int64_t Terrain3DMaterialClipmapDetail::tile_key(const int p_level, const int p_x, const int p_y) {
	return (int64_t(p_level) << DETAIL_LEVEL_SHIFT) | ((int64_t(p_x) & DETAIL_TILE_MASK) << DETAIL_TILE_BITS) |
			(int64_t(p_y) & DETAIL_TILE_MASK);
}

int Terrain3DMaterialClipmapDetail::key_level(const int64_t p_key) {
	return int(uint64_t(p_key) >> DETAIL_LEVEL_SHIFT);
}

int Terrain3DMaterialClipmapDetail::key_x(const int64_t p_key) {
	const int64_t raw = (p_key >> DETAIL_TILE_BITS) & DETAIL_TILE_MASK;
	return int(raw >= DETAIL_TILE_SIGN ? raw - (DETAIL_TILE_MASK + 1) : raw);
}

int Terrain3DMaterialClipmapDetail::key_y(const int64_t p_key) {
	const int64_t raw = p_key & DETAIL_TILE_MASK;
	return int(raw >= DETAIL_TILE_SIGN ? raw - (DETAIL_TILE_MASK + 1) : raw);
}

Terrain3DMaterialClipmapDetail::~Terrain3DMaterialClipmapDetail() {
	clear();
}

///////////////////////////
// Shape
///////////////////////////

void Terrain3DMaterialClipmapDetail::configure(const Config &p_config) {
	Config config = p_config;
	config.tile_size = CLAMP(config.tile_size, 32, 1024);
	// The gutter is a *bound*, the same one the ring and the pages carry: a filtering footprint
	// cannot reach past the border texels a tile owns. Four admits 7x anisotropy, eight 15x, and the
	// near field requests 8 by default - so four is the floor that does not silently reduce it.
	config.border = CLAMP(config.border, 2, 16);
	config.density = MAX(real_t(1), config.density);
	config.levels = CLAMP(config.levels, 1, MAX_LEVELS);
	config.directory_size = CLAMP(config.directory_size, 16, 512);
	config.budget_bytes = MAX(MIN_BUDGET_BYTES, config.budget_bytes);
	config.max_slots = CLAMP(config.max_slots, MIN_SLOTS, MAX_SLOTS);
	config.demand_radius = MAX(real_t(0.25), config.demand_radius);
	config.forward_half_angle = CLAMP(config.forward_half_angle, real_t(0.1), real_t(3.14159));
	config.texels_per_pixel = MAX(real_t(0.25), config.texels_per_pixel);
	const int stored_size = config.tile_size + config.border * 2;
	const bool same = _enabled == true && config.tile_size == _config.tile_size &&
			config.border == _config.border && config.levels == _config.levels &&
			Math::is_equal_approx(config.density, _config.density) &&
			config.directory_size == _config.directory_size;
	if (same && stored_size == _stored_size && config.max_slots == _config.max_slots &&
			config.budget_bytes == _config.budget_bytes) {
		// Only the policy numbers moved: they are read per tick and change nothing resident.
		_config = config;
		return;
	}
	_config = config;
	_stored_size = stored_size;
	// A different shape is a different addressing, so every resident tile and every offer goes. The
	// arrays are rebuilt below; the counters are the session's and survive, because a reconfigure is
	// not a different layer.
	clear();
	_config = config;
	_stored_size = stored_size;
	const int64_t per_slot = bytes_per_slot();
	if (per_slot <= 0) {
		LOG(ERROR, "Detail layer has no bytes per slot; it stays off.");
		return;
	}
	const int64_t affordable = config.budget_bytes / per_slot;
	_slot_count = int(CLAMP(affordable, int64_t(0), int64_t(config.max_slots)));
	if (_slot_count < MIN_SLOTS) {
		// Explicit, not silent: the caller keeps the coarse ring and the report says why. The plan
		// requires this to be a reading, because "the detail layer is on" must never be inferred from
		// a setting while the budget cannot hold one ring of tiles.
		LOG(WARN, "Detail material layer budget ", config.budget_bytes, " B affords ", affordable,
				" slots of ", per_slot, " B at ", _stored_size, "^2, below the ", MIN_SLOTS,
				" a cache needs; the coarse ring serves.");
		_enabled = false;
		_slot_count = 0;
		return;
	}
	_slots.assign(size_t(_slot_count), Tile());
	_free_slots.clear();
	_free_slots.reserve(size_t(_slot_count));
	for (int slot = _slot_count - 1; slot >= 0; slot--) {
		_slots[size_t(slot)].slot = -1;
		_free_slots.push_back(slot);
	}
	_enabled = true;
	LOG(INFO, "Configuring detail material layer: ", _slot_count, " slots of ", _stored_size, "^2 texels, ",
			"levels ", config.levels, " at ", config.density, " texels/m, budget ", config.budget_bytes,
			" B (", get_used_bytes(), " B allocated)");
}

void Terrain3DMaterialClipmapDetail::clear() {
	// A reconfigure tears the pipeline down with the arrays: a queued source result for a shape that
	// no longer exists would be uploaded into a layer count that no longer matches.
	if (_pipeline) {
		_pipeline->reset();
		_pipeline.reset();
	}
	_offers.clear();
	_resident.clear();
	_free_slots.clear();
	_slots.clear();
	_wanted.clear();
	_payload.clear();
	_height.clear();
	for (int level = 0; level < MAX_LEVELS; level++) {
		_directory[level].clear();
		_directory_dirty[level] = true;
		_window_origin[level] = Vector2();
	}
	_free_baked();
	// A reconfigure is what retries an allocation the device refused once: the shape may be smaller,
	// or the failure may have been transient.
	_baked_unavailable = false;
	_slot_count = 0;
	_stored_size = 0;
	_enabled = false;
	_starved = 0;
	_generation_serial++;
	_state_stamp++;
}

int64_t Terrain3DMaterialClipmapDetail::bytes_per_slot() const {
	if (_stored_size <= 0) {
		return 0;
	}
	const int64_t texels = int64_t(_stored_size) * int64_t(_stored_size);
	return texels * (DETAIL_BAKED_CHANNELS * DETAIL_BAKED_BYTES_PER_TEXEL + DETAIL_PAYLOAD_BYTES_PER_TEXEL +
							DETAIL_HEIGHT_BYTES_PER_TEXEL);
}

int Terrain3DMaterialClipmapDetail::slot_capacity_for(const Config &p_config) const {
	const int stored = p_config.tile_size + p_config.border * 2;
	const int64_t per_slot = int64_t(stored) * int64_t(stored) *
			(DETAIL_BAKED_CHANNELS * DETAIL_BAKED_BYTES_PER_TEXEL + DETAIL_PAYLOAD_BYTES_PER_TEXEL +
					DETAIL_HEIGHT_BYTES_PER_TEXEL);
	if (per_slot <= 0) {
		return 0;
	}
	return int(CLAMP(int64_t(p_config.budget_bytes) / per_slot, int64_t(0), int64_t(p_config.max_slots)));
}

int64_t Terrain3DMaterialClipmapDetail::get_used_bytes() const {
	return int64_t(_slot_count) * bytes_per_slot() + get_directory_bytes();
}

int64_t Terrain3DMaterialClipmapDetail::get_directory_bytes() const {
	// One R32F texel a tile per level, per level. The directory is the only CPU-side image the layer
	// keeps, and it is charged here so the budget figure is the whole layer rather than the arrays.
	return int64_t(_config.levels) * int64_t(_config.directory_size) * int64_t(_config.directory_size) * 4;
}

///////////////////////////
// Addressing
///////////////////////////

real_t Terrain3DMaterialClipmapDetail::get_level_texels_per_meter(const int p_level) const {
	const int level = CLAMP(p_level, 0, MAX_LEVELS - 1);
	return _config.density / real_t(int64_t(1) << level);
}

real_t Terrain3DMaterialClipmapDetail::get_level_tile_world(const int p_level) const {
	const real_t ppm = get_level_texels_per_meter(p_level);
	return real_t(_config.tile_size) / ppm;
}

Vector2 Terrain3DMaterialClipmapDetail::get_window_origin(const int p_level) const {
	return _window_origin[CLAMP(p_level, 0, MAX_LEVELS - 1)];
}

Vector2i Terrain3DMaterialClipmapDetail::_tile_of_world(const int p_level, const Vector2 &p_world) const {
	const real_t tile_world = get_level_tile_world(p_level);
	return Vector2i(int(Math::floor(p_world.x / tile_world)), int(Math::floor(p_world.y / tile_world)));
}

Rect2 Terrain3DMaterialClipmapDetail::_tile_world_rect(const int p_level, const int p_x, const int p_y) const {
	const real_t tile_world = get_level_tile_world(p_level);
	const real_t texel_world = 1.f / get_level_texels_per_meter(p_level);
	return Rect2(Vector2(real_t(p_x) * tile_world, real_t(p_y) * tile_world),
			Vector2(real_t(_config.tile_size) * texel_world, real_t(_config.tile_size) * texel_world));
}

// The directory window follows the camera by whole tiles, so a stationary camera publishes nothing
// and a moving one moves the window one tile at a time. The origin is an exact multiple of the
// level's tile span, which is what keeps the shader's `floor((world - origin) / tile_world)` and the
// CPU's integer tile index the same index.
Vector2 Terrain3DMaterialClipmapDetail::_snap_window(const int p_level, const Vector2 &p_focus) const {
	const real_t tile_world = get_level_tile_world(p_level);
	const Vector2i center(int(Math::floor(p_focus.x / tile_world)), int(Math::floor(p_focus.y / tile_world)));
	const Vector2i base = center - Vector2i(_config.directory_size / 2, _config.directory_size / 2);
	return Vector2(real_t(base.x) * tile_world, real_t(base.y) * tile_world);
}

real_t Terrain3DMaterialClipmapDetail::required_texels_per_meter(const DemandView &p_view,
		const real_t p_distance) const {
	const real_t tpp = p_view.texels_per_pixel > 0.f ? p_view.texels_per_pixel : _config.texels_per_pixel;
	// The ground footprint of one screen pixel at `p_distance`, from the vertical field of view and
	// the viewport's pixel height: `2 * d * tan(fov/2) / height` metres a pixel, so the density that
	// puts `tpp` texels on it is the reciprocal. The camera's height and pitch are deliberately not
	// in this: the rule is a screen-footprint rule, and the caller measures the distance it asks
	// about on the ground plane.
	const real_t pixel_world = MAX(real_t(1e-4),
			2.f * p_distance * Math::tan(p_view.fov_y * 0.5f) / real_t(MAX(1, p_view.viewport_height)));
	return tpp / pixel_world;
}

int Terrain3DMaterialClipmapDetail::level_for_distance(const DemandView &p_view, const real_t p_distance) const {
	const real_t required = required_texels_per_meter(p_view, p_distance);
	int chosen = _config.levels - 1;
	for (int level = 0; level < _config.levels; level++) {
		if (get_level_texels_per_meter(level) >= required) {
			chosen = level;
			break;
		}
	}
	return chosen;
}

///////////////////////////
// Residency
///////////////////////////

void Terrain3DMaterialClipmapDetail::_ensure_storage() {
	Ref<Image> payload_blank = Image::create(_stored_size, _stored_size, false, IDWEIGHT_IMAGE_FORMAT);
	Ref<Image> height_blank = Image::create(_stored_size, _stored_size, false, Image::FORMAT_RF);
	_payload.ensure_layers(payload_blank, _slot_count);
	_height.ensure_layers(height_blank, _slot_count);
	_ensure_baked();
	if (_pipeline == nullptr) {
		_pipeline = std::make_unique<Terrain3DPagePipeline>(_config.source_workers);
	}
}

void Terrain3DMaterialClipmapDetail::_ensure_baked() {
	if (_stored_size <= 0 || _slot_count <= 0 || _baked_unavailable) {
		return;
	}
	if (!_baked_rd.empty() && _baked_rd[0].is_valid() && int(_baked_rd.size()) == DETAIL_BAKED_CHANNELS) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		// No device yet - a headless run, or a configure before the first frame. This is called
		// again on the next tick, which is the first moment a device is certain.
		return;
	}
	_free_baked();
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	// The bake shader writes `rgba16f` storage images, so a baked tile is half float: the same format
	// the ring's baked channels carry, which is what lets one shader serve both producers.
	format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
	format->set_width(uint32_t(_stored_size));
	format->set_height(uint32_t(_stored_size));
	format->set_depth(1);
	// At least two layers whatever the slot count: the renderer refuses to wrap a one-layer array as
	// a layered texture, and the arm samples these as an array.
	format->set_array_layers(uint32_t(MAX(_slot_count, 2)));
	format->set_mipmaps(1);
	// Storage, so a producer writes a tile; sampling, so the arm reads it; update, because the
	// producer's pass is issued against the same texture the material binds.
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	// Created uninitialised: every texel belongs to a producer, and a tile is only ever read while
	// its directory entry says a bake landed.
	TypedArray<PackedByteArray> initial;
	for (int channel = 0; channel < DETAIL_BAKED_CHANNELS; channel++) {
		RID device = rd->texture_create(format, view, initial);
		RID shader = device.is_valid()
				? server->texture_rd_create(device, RenderingServer::TEXTURE_LAYERED_2D_ARRAY)
				: RID();
		if (!shader.is_valid()) {
			if (device.is_valid()) {
				rd->free_rid(device);
			}
			LOG(ERROR, "Could not allocate detail material baked channel ", channel, " at ", _stored_size,
					"^2 x ", _slot_count, " layers; the detail layer stays unreadable and the coarse ring serves.");
			_baked_unavailable = true;
			_free_baked();
			return;
		}
		rd->set_resource_name(device, "Terrain3D Detail Baked " + String::num_int64(channel));
		_baked_rd.push_back(device);
		_baked_rs.push_back(shader);
	}
}

void Terrain3DMaterialClipmapDetail::_free_baked() {
	if (_baked_rd.empty() && _baked_rs.empty()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	// The wrapper first and the device texture second: the wrapper is what a material holds, and it
	// is the device texture's lifetime that has to outlast every reader of it.
	for (const RID &rid : _baked_rs) {
		if (rid.is_valid() && server != nullptr) {
			server->free_rid(rid);
		}
	}
	for (const RID &rid : _baked_rd) {
		if (rid.is_valid() && rd != nullptr) {
			rd->free_rid(rid);
		}
	}
	_baked_rd.clear();
	_baked_rs.clear();
}

RID Terrain3DMaterialClipmapDetail::get_baked_texture_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rs.size())) {
		return RID();
	}
	return _baked_rs[size_t(p_channel)];
}

RID Terrain3DMaterialClipmapDetail::get_baked_device_rid(const int p_channel) const {
	if (p_channel < 0 || p_channel >= int(_baked_rd.size())) {
		return RID();
	}
	return _baked_rd[size_t(p_channel)];
}

RID Terrain3DMaterialClipmapDetail::get_directory_rid(const int p_level) const {
	if (p_level < 0 || p_level >= MAX_LEVELS || p_level >= _config.levels) {
		return RID();
	}
	return _directory[p_level].get_rid();
}

bool Terrain3DMaterialClipmapDetail::take_pending_bake(const int p_slot, const uint64_t p_generation) {
	for (size_t index = 0; index < _offers.size(); index++) {
		if (_offers[index].slot != p_slot || _offers[index].generation != p_generation) {
			continue;
		}
		_offers.erase(_offers.begin() + int64_t(index));
		return true;
	}
	return false;
}

void Terrain3DMaterialClipmapDetail::_release_slot(const int p_slot) {
	if (p_slot < 0 || p_slot >= _slot_count) {
		return;
	}
	Tile &tile = _slots[size_t(p_slot)];
	if (tile.slot < 0) {
		return;
	}
	// The slot's content is about to describe a different tile, so the generation moves and the
	// directory entry goes with it: a bake still in flight for the old tile lands with a generation
	// that no longer matches and is dropped rather than published. The offers and the pipeline entry
	// for the old tile go too, because a dispatch recorded against a slot that now holds another
	// tile's source would write that tile's world position into the wrong directory entry.
	if (_pipeline) {
		_pipeline->discard({ tile.level, tile.x, tile.y, 0, 0 });
	}
	for (size_t index = 0; index < _offers.size();) {
		if (_offers[index].slot == p_slot) {
			_offers.erase(_offers.begin() + int64_t(index));
			continue;
		}
		index++;
	}
	tile.generation = ++_generation_serial;
	tile.slot = -1;
	tile.level = -1;
	tile.x = 0;
	tile.y = 0;
	tile.key = 0;
	tile.valid = false;
	tile.pending = false;
	tile.source_ready = false;
	tile.bake_in_flight = false;
	tile.offer_tick = 0;
	tile.source_grid = Vector3();
	_free_slots.push_back(p_slot);
}

int Terrain3DMaterialClipmapDetail::_eviction_candidate(const Vector2 &p_focus) const {
	int best = -1;
	int best_rank = INT32_MAX;
	uint64_t best_used = UINT64_MAX;
	real_t best_dist = 0.f;
	for (int slot = 0; slot < _slot_count; slot++) {
		const Tile &tile = _slots[size_t(slot)];
		if (tile.slot < 0) {
			continue;
		}
		// Rank 0 is a resident tile this frame's walk does not want at all - the LRU's own case.
		// Rank 1 is a wanted tile whose production has been stuck past the timeout, which is the one
		// way a wanted slot is reclaimed. Rank 2 is a wanted tile that is readable or still inside
		// its production window, and it is deliberately *never* evicted: evicting a wanted readable
		// tile under over-subscription makes every frame trade one nearer tile for one further one,
		// which is a thrash rather than a cache. The walk's tail starves instead, and the reading
		// reports how much.
		const bool wanted = _wanted.find(tile.key) != _wanted.end();
		int rank = 0;
		if (wanted) {
			rank = (!tile.valid && _tick - tile.pending_tick > DETAIL_PENDING_EVICT_TICKS) ? 1 : 2;
		}
		if (rank == 2) {
			continue;
		}
		const real_t scale = MAX(get_level_tile_world(tile.level), real_t(1e-4));
		const real_t dist = Vector2(real_t(tile.x), real_t(tile.y)).distance_to(p_focus / scale);
		if (rank < best_rank || (rank == best_rank && tile.last_used < best_used) ||
				(rank == best_rank && tile.last_used == best_used && dist > best_dist)) {
			best = slot;
			best_rank = rank;
			best_used = tile.last_used;
			best_dist = dist;
		}
	}
	return best;
}

int Terrain3DMaterialClipmapDetail::_acquire_slot(const int64_t p_key, const Vector2 &p_focus) {
	int slot = -1;
	if (!_free_slots.empty()) {
		slot = _free_slots.back();
		_free_slots.pop_back();
	} else {
		slot = _eviction_candidate(p_focus);
		if (slot < 0) {
			return -1;
		}
		// The victim leaves the resident map and the directory before its slot is reused, so the
		// directory never names a slot twice.
		_resident.erase(_slots[size_t(slot)].key);
		_release_slot(slot);
		// `_release_slot()` puts the slot back on the free list, and this allocation is taking it
		// straight out again. Leaving it there handed the *same* slot to the next key that needed one
		// - the resident map then held two keys per slot, `used_slots` grew past the slot table, and
		// the directory published a slot under a key whose content was another tile's, so a fragment
		// at the focus found no readable tile and the coarse ring served instead. Measured before the
		// fix: `used_slots` reached 252 of 126 slots with `dup_slots=126`.
		if (!_free_slots.empty() && _free_slots.back() == slot) {
			_free_slots.pop_back();
		} else {
			_free_slots.erase(std::remove(_free_slots.begin(), _free_slots.end(), slot), _free_slots.end());
		}
		_evictions++;
	}
	Tile &tile = _slots[size_t(slot)];
	tile.key = p_key;
	tile.level = key_level(p_key);
	tile.x = key_x(p_key);
	tile.y = key_y(p_key);
	tile.slot = slot;
	tile.generation = ++_generation_serial;
	tile.last_used = _tick;
	tile.valid = false;
	tile.pending = true;
	tile.source_ready = false;
	tile.bake_in_flight = false;
	tile.offer_tick = 0;
	tile.pending_tick = _tick;
	_resident[p_key] = slot;
	return slot;
}

bool Terrain3DMaterialClipmapDetail::acknowledge_bake(const int p_slot, const uint64_t p_generation) {
	if (p_slot < 0 || p_slot >= _slot_count) {
		_bake_rejects++;
		return false;
	}
	Tile &tile = _slots[size_t(p_slot)];
	// The generation is the whole check. A slot that has been handed to another tile, or whose
	// content was invalidated while the dispatch was in flight, carries a different one - and a
	// fragment must never be mapped to texels a producer wrote for another world position.
	if (tile.slot < 0 || tile.generation != p_generation || !tile.pending) {
		_bake_rejects++;
		return false;
	}
	tile.pending = false;
	tile.bake_in_flight = false;
	tile.valid = true;
	tile.last_used = _tick;
	_bake_acks++;
	_directory_dirty[tile.level] = true;
	_state_stamp++;
	return true;
}

int Terrain3DMaterialClipmapDetail::invalidate_rect(const Rect2 &p_world) {
	if (!is_enabled()) {
		return 0;
	}
	_invalidation_calls++;
	int touched = 0;
	bool dirty[MAX_LEVELS] = { false, false, false, false };
	for (auto &entry : _resident) {
		Tile &tile = _slots[size_t(entry.second)];
		if (tile.slot < 0) {
			continue;
		}
		// The tile's own rect *grown by its border*: the gutter reads the neighbouring ground, so an
		// edit just outside a tile changes the texels the bake would produce for it.
		const Rect2 rect = _tile_world_rect(tile.level, tile.x, tile.y)
								   .grow(real_t(_config.border) / get_level_texels_per_meter(tile.level));
		if (!rect.intersects(p_world)) {
			continue;
		}
		touched++;
		// The content is gone from the moment the source moves, so the readable bit goes with it and
		// the pipeline's stale result is dropped. The next demand walk re-requests and re-bakes.
		tile.generation = ++_generation_serial;
		tile.valid = false;
		tile.source_ready = false;
		tile.bake_in_flight = false;
		tile.pending = true;
		if (_pipeline) {
			_pipeline->discard({ tile.level, tile.x, tile.y, 0, 0 });
		}
		dirty[tile.level] = true;
	}
	_invalidated_tiles += uint64_t(touched);
	for (int level = 0; level < MAX_LEVELS; level++) {
		if (dirty[level]) {
			_directory_dirty[level] = true;
		}
	}
	if (touched > 0) {
		_state_stamp++;
	}
	return touched;
}

///////////////////////////
// One demand tick
///////////////////////////

int Terrain3DMaterialClipmapDetail::update(const DemandView &p_view,
		const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot, const int p_source_budget) {
	if (!is_enabled()) {
		return 0;
	}
	_ensure_storage();
	_tick++;
	_starved = 0;
	_wanted.clear();
	_last_focus = p_view.focus;

	// 1. The windows. A level whose window moved has to re-publish its directory, because the
	//    directory's index is relative to the window the shader is told about.
	for (int level = 0; level < _config.levels; level++) {
		const Vector2 origin = _snap_window(level, p_view.focus);
		if (!origin.is_equal_approx(_window_origin[level])) {
			_window_origin[level] = origin;
			_directory_dirty[level] = true;
			_state_stamp++;
		}
	}

	// 2. The demand walk. Each level owns a *band* of distances: the range over which its density is
	//    the one the screen footprint asks for. That is what makes the demand follow the camera: the
	//    finest tiles are requested under and just in front of it, the coarser levels take the
	//    fringe, and nothing outside `demand_radius` is requested at all.
	struct Demand {
		int level;
		int x;
		int y;
		int64_t key;
		real_t distance;
	};
	std::vector<Demand> demand;
	demand.reserve(256);
	const Vector2 forward = p_view.forward.length_squared() > 1e-8f ? p_view.forward.normalized()
																	: Vector2(0.f, -1.f);
	const real_t cos_limit = Math::cos(_config.forward_half_angle);
	// The ground footprint of one screen pixel at distance d is `pixel_unit * d` metres, where
	// `pixel_unit` is the viewport's angular pixel size. `required_texels_per_meter(d)` is
	// `tpp / (pixel_unit * d)`, so the *requested* band of a level - the distances over which its
	// density is the one a pixel wants - runs from where the next finer level's density stops being
	// enough to where its own does, and the coarsest runs to the demand radius.
	//
	// That rule is a request, and at the shipped shape it asks for far more 2 MiB tiles than the slot
	// table holds: the finest band alone needs hundreds. The walk below spends the table nearest
	// first, so a table that cannot hold the whole request used to leave everything past the nearest
	// tiles to the 1 texel/m ring while the tile under the focus - the one every density reading is
	// taken at - answered 1024. That is the "numbers pass, picture is mush" state this fit exists to
	// remove. The bands are therefore fitted to the table first: one factor `scale <= 1` shrinks every
	// boundary except the coarsest (which always reaches `demand_radius`), chosen as the largest that
	// keeps the demanded tile count inside the table. The near field is then covered *contiguously* -
	// the finest level over its share, each coarser level over the next - so the whole `demand_radius`
	// is detail, at the finest density the table can afford, instead of a fine patch under the camera.
	const real_t pixel_unit = 2.f * Math::tan(p_view.fov_y * 0.5f) / real_t(MAX(1, p_view.viewport_height));
	const real_t tpp = p_view.texels_per_pixel > 0.f ? p_view.texels_per_pixel : _config.texels_per_pixel;
	real_t desired[MAX_LEVELS];
	for (int level = 0; level < _config.levels; level++) {
		desired[level] = _config.demand_radius;
		if (level < _config.levels - 1) {
			desired[level] = MIN(desired[level],
					tpp / MAX(real_t(1e-4), pixel_unit * get_level_texels_per_meter(level)));
		}
	}
	// The tiles a fitted band set demands, over the disc the forward cone keeps. The walk below keeps
	// a tile whose *square* meets its band (one half diagonal of reach), so the estimate measures each
	// band grown by that reach and targets 90% of the table: the ~10% left over keeps the walk from
	// starving its own tail, and whatever survives the discrete grid is still reported through
	// `_starved`.
	const real_t cone_fraction = _config.forward_half_angle / real_t(Math_PI);
	real_t band_outer[MAX_LEVELS];
	const double table_target = double(_slot_count) * 0.9;
	auto fit_bands = [&](const real_t p_scale) {
		for (int level = 0; level < _config.levels; level++) {
			band_outer[level] = level == _config.levels - 1
					? _config.demand_radius
					: MIN(_config.demand_radius, p_scale * desired[level]);
		}
		// The scale preserves the order, but a tiny `demand_radius` can make the coarsest boundary
		// smaller than a scaled one; keep the boundaries monotone either way.
		for (int level = 1; level < _config.levels; level++) {
			band_outer[level] = MAX(band_outer[level], band_outer[level - 1]);
		}
	};
	auto estimate_tiles = [&]() {
		double total = 0.0;
		for (int level = 0; level < _config.levels; level++) {
			const real_t tile_world = get_level_tile_world(level);
			// The walk below keeps a tile whose *square* meets its band, not only whose centre does -
			// that is what closes the seams between two bands, whose boundary is one radius but whose
			// tiles are two sizes. The estimate therefore measures the bands grown by a tile's half
			// diagonal, which is the set the walk actually keeps.
			const real_t reach = tile_world * 0.70710678f;
			const real_t inner = MAX(real_t(0), (level > 0 ? band_outer[level - 1] : 0.f) - reach);
			const real_t outer = band_outer[level] + reach;
			if (outer > inner) {
				total += double(cone_fraction) * double(Math_PI) *
						double(outer * outer - inner * inner) / double(tile_world * tile_world);
			}
		}
		return total;
	};
	fit_bands(1.f);
	if (estimate_tiles() > table_target) {
		real_t low = 0.f;
		real_t high = 1.f;
		for (int step = 0; step < 32; step++) {
			const real_t mid = (low + high) * 0.5f;
			fit_bands(mid);
			if (estimate_tiles() <= table_target) {
				low = mid;
			} else {
				high = mid;
			}
		}
		fit_bands(low);
	}
	for (int level = 0; level < _config.levels; level++) {
		const real_t tile_world = get_level_tile_world(level);
		const real_t outer = band_outer[level];
		const real_t inner = level > 0 ? band_outer[level - 1] : 0.f;
		if (inner >= outer) {
			continue;
		}
		// A tile joins its band when its *square* meets the annulus, not when its centre does: two
		// adjacent bands meet at one radius but hold tiles of two sizes, so a centre test leaves a
		// tile-wide seam between them where neither level's tile is kept and the fragment falls to the
		// ring. Growing each band by a half diagonal makes the two overlap instead.
		const real_t reach = tile_world * 0.70710678f;
		const int radius = int(Math::ceil((outer + reach) / tile_world)) + 1;
		const Vector2i center = _tile_of_world(level, p_view.focus);
		for (int dy = -radius; dy <= radius; dy++) {
			for (int dx = -radius; dx <= radius; dx++) {
				const int x = center.x + dx;
				const int y = center.y + dy;
				const Vector2 tile_center((real_t(x) + 0.5f) * tile_world, (real_t(y) + 0.5f) * tile_world);
				const Vector2 offset = tile_center - p_view.focus;
				const real_t distance = offset.length();
				if (distance - reach >= outer || distance + reach < inner) {
					continue;
				}
				// The forward cone. A tile behind the camera is not drawn, and a slot spent on it is
				// a slot the visible near field cannot use. The camera's own tile is always kept.
				if (distance > MAX(real_t(0.5), tile_world) && offset.normalized().dot(forward) < cos_limit) {
					continue;
				}
				demand.push_back({ level, x, y, tile_key(level, x, y), distance });
			}
		}
	}
	// Nearest first: the fitted walk fits the table, but eviction and the one-tile-a-tick bake offer
	// both read this order, so the tile a fragment is waiting for is still the first one served.
	std::sort(demand.begin(), demand.end(), [](const Demand &a, const Demand &b) {
		if (a.distance != b.distance) {
			return a.distance < b.distance;
		}
		return a.level < b.level;
	});

	// 3. The wanted set, before any slot is handed out, so eviction can tell this frame's demand
	//    from what the last frame left behind. The value is the tile's rank in the walk (1 is the
	//    nearest), which is what the offer queue below orders by.
	for (size_t rank = 0; rank < demand.size(); rank++) {
		_wanted[demand[rank].key] = uint32_t(rank) + 1;
	}

	// 4. Residency: keep what is wanted, allocate what is missing.
	int requested = 0;
	for (const Demand &entry : demand) {
		auto found = _resident.find(entry.key);
		if (found != _resident.end()) {
			Tile &tile = _slots[size_t(found->second)];
			tile.last_used = _tick;
			if (tile.valid) {
				_hits++;
			} else {
				_misses++;
			}
			continue;
		}
		const int slot = _acquire_slot(entry.key, p_view.focus);
		if (slot < 0) {
			_starved++;
			_misses++;
			continue;
		}
		_misses++;
		requested++;
	}

	// 5. Drop what no level's window can address any more. A tile outside its level's directory is
	//    unreachable however valid it is, so holding it only keeps a slot the near field needs.
	int released = 0;
	for (auto it = _resident.begin(); it != _resident.end();) {
		const Tile &tile = _slots[size_t(it->second)];
		const int level = tile.level;
		if (level < 0 || level >= _config.levels) {
			_release_slot(it->second);
			it = _resident.erase(it);
			released++;
			continue;
		}
		const real_t tile_world = get_level_tile_world(level);
		const Vector2i base(int(Math::floor(_window_origin[level].x / tile_world)),
				int(Math::floor(_window_origin[level].y / tile_world)));
		const int local_x = tile.x - base.x;
		const int local_y = tile.y - base.y;
		if (local_x < 0 || local_y < 0 || local_x >= _config.directory_size ||
				local_y >= _config.directory_size) {
			_release_slot(it->second);
			it = _resident.erase(it);
			released++;
			continue;
		}
		++it;
	}
	(void)released;

	// 6. Source: submit what the walk newly asked for, then collect what the workers finished. The
	//    pipeline is only touched when there is something to do, so a settled view costs a scan of
	//    the resident set rather than a queue lock.
	if (_pipeline && p_snapshot) {
		std::vector<Terrain3DPagePipeline::Request> requests;
		const int budget = CLAMP(p_source_budget, 1, 32);
		requests.reserve(size_t(budget));
		for (const Demand &entry : demand) {
			if (int(requests.size()) >= budget) {
				break;
			}
			auto found = _resident.find(entry.key);
			if (found == _resident.end()) {
				continue;
			}
			Tile &tile = _slots[size_t(found->second)];
			if (!tile.pending || tile.source_ready) {
				continue;
			}
			requests.push_back({ { tile.level, tile.x, tile.y, 0, 0 },
					_tile_world_rect(tile.level, tile.x, tile.y), _config.tile_size, _config.border,
					false, String(), 0u, get_level_texels_per_meter(tile.level) });
		}
		if (!requests.empty()) {
			_pipeline->prime(requests, p_snapshot);
		}
		// Poll every tile that is still waiting for its source, in demand order. A result that is
		// not ready is left for the tick that follows; a result that is ready is uploaded now, and
		// its bake is offered to the producer below.
		for (const Demand &entry : demand) {
			auto found = _resident.find(entry.key);
			if (found == _resident.end()) {
				continue;
			}
			Tile &tile = _slots[size_t(found->second)];
			if (!tile.pending || tile.source_ready) {
				continue;
			}
			Terrain3DPagePipeline::Request request{ { tile.level, tile.x, tile.y, 0, 0 },
				_tile_world_rect(tile.level, tile.x, tile.y), _config.tile_size, _config.border, false,
				String(), 0u, get_level_texels_per_meter(tile.level) };
			Terrain3DPagePipeline::Result prepared;
			if (!_pipeline->poll(request, p_snapshot, prepared)) {
				continue;
			}
			if (prepared.ids.is_null() || prepared.height.is_null()) {
				continue;
			}
			// The two source arrays are RenderingServer-owned, so the upload is a queued command
			// and the bake that reads it is dispatched a call later - the ring's own one-tick
			// separation, for the same reason.
			_payload.update(prepared.ids, tile.slot);
			_height.update(prepared.height, tile.slot);
			// The pipeline answers with the *source* corner grid when the output texel is finer than
			// the source step, which is the case this layer exists for. A zero grid means it produced
			// the output-resolution payload instead (the output texel is coarser than the source, so
			// there is nothing to filter from); the bake job then carries `policy.w == 0`, which is
			// the page path's own "read the stored texel at the output resolution" rule.
			tile.source_grid = prepared.grid;
			tile.source_ready = true;
			tile.bake_in_flight = false;
			tile.offer_tick = 0;
			_source_uploads++;
		}
	}

	// 7. Offers. A tile whose source landed and whose bake no producer has taken is offered here;
	//    an offer that has gone unacknowledged for too long is offered again, because a producer
	//    that could not dispatch (no material list, no device) leaves its queue holding work it
	//    will not report back.
	//
	//    The walk's own order, nearest first: the producer bakes one tile a tick at the default
	//    budget, so the order decides *which* tile a fragment waits for. Iterating the slot table
	//    instead offered whatever slot happened to be free first, which put the tile under the
	//    crosshair last behind a hundred tiles the view does not need yet - measured, the probe point
	//    1.6 m ahead stayed unreadable for the whole acceptance window while ten tiles a mile away
	//    were valid. Only a tile this walk wants is offered: a resident tile the view has left is
	//    about to be evicted, and spending a dispatch on it is the same defect from the other side.
	for (const Demand &entry : demand) {
		auto found = _resident.find(entry.key);
		if (found == _resident.end()) {
			continue;
		}
		Tile &tile = _slots[size_t(found->second)];
		if (tile.slot < 0 || tile.valid || !tile.source_ready) {
			continue;
		}
		if (tile.bake_in_flight && _tick - tile.offer_tick < DETAIL_OFFER_TIMEOUT_TICKS) {
			continue;
		}
		// One offer a slot: a retry after a timeout must not leave the earlier one behind, or a
		// producer that arrives late would dispatch the same tile twice.
		bool already_offered = false;
		for (const BakeOffer &offer : _offers) {
			already_offered = already_offered || (offer.slot == tile.slot && offer.generation == tile.generation);
		}
		if (already_offered) {
			continue;
		}
		tile.bake_in_flight = true;
		tile.offer_tick = _tick;
		BakeOffer offer;
		offer.slot = tile.slot;
		offer.level = tile.level;
		offer.generation = tile.generation;
		offer.world_rect = _tile_world_rect(tile.level, tile.x, tile.y);
		offer.source_grid = tile.source_grid;
		offer.texel_world = 1.f / get_level_texels_per_meter(tile.level);
		offer.border = _config.border;
		offer.stored_size = _stored_size;
		_offers.push_back(offer);
		_bake_offers++;
	}
	// The queue is re-ordered by the walk's own rank, nearest first, because the producer takes one
	// tile a tick at the default budget while the source pipeline can deliver a dozen: without this
	// the bake order was the order the *workers* happened to finish in, and the tile under the
	// crosshair sat behind a hundred tiles further away - measured, the focus tile's offer was the
	// 112th of 238 and the probe point read the coarse ring for the whole acceptance window. An
	// offer whose tile the walk no longer wants sorts last; it is collected only if nothing nearer
	// is left, which is the same priority the slot table's eviction already uses.
	std::stable_sort(_offers.begin(), _offers.end(), [this](const BakeOffer &p_a, const BakeOffer &p_b) {
		auto rank_of = [this](const BakeOffer &p_offer) {
			const auto found = _wanted.find(_slots[size_t(p_offer.slot)].key);
			return found != _wanted.end() ? found->second : UINT32_MAX;
		};
		return rank_of(p_a) < rank_of(p_b);
	});

	// 8. Publish the directories that moved. Only `valid` tiles are written, so a resident but
	//    unbaked slot is invisible to a fragment rather than merely unadvertised.
	for (int level = 0; level < _config.levels; level++) {
		if (_directory_dirty[level]) {
			_publish_directory(level);
		}
	}
	if (_pipeline) {
		_pipeline->flush_wakes();
	}
	return requested;
}

void Terrain3DMaterialClipmapDetail::_publish_directory(const int p_level) {
	if (p_level < 0 || p_level >= _config.levels) {
		return;
	}
	const int size = _config.directory_size;
	const real_t tile_world = get_level_tile_world(p_level);
	const Vector2 origin = _window_origin[p_level];
	const Vector2i base(int(Math::floor(origin.x / tile_world)), int(Math::floor(origin.y / tile_world)));
	Ref<Image> image = Image::create(size, size, false, Image::FORMAT_RF);
	// A slot entry is `slot + 1`, zero is "nothing readable". The image is rebuilt from the resident
	// set on every publish rather than patched: the set is a few hundred entries, and a fresh image
	// is the only way to be sure a slot that left the set cannot linger in the directory.
	for (const auto &entry : _resident) {
		const Tile &tile = _slots[size_t(entry.second)];
		if (tile.slot < 0 || !tile.valid || tile.level != p_level) {
			continue;
		}
		const int local_x = tile.x - base.x;
		const int local_y = tile.y - base.y;
		if (local_x < 0 || local_y < 0 || local_x >= size || local_y >= size) {
			continue;
		}
		image->set_pixel(local_x, local_y, Color(real_t(tile.slot + 1), 0.f, 0.f, 1.f));
	}
	if (_directory[p_level].get_rid().is_valid()) {
		_directory[p_level].update(image, 0);
	} else {
		_directory[p_level].create(image);
	}
	_directory_dirty[p_level] = false;
	_directory_publishes++;
	_state_stamp++;
}

///////////////////////////
// The arm
///////////////////////////

Dictionary Terrain3DMaterialClipmapDetail::get_arm() const {
	Dictionary arm;
	arm["configured"] = is_configured();
	arm["enabled"] = is_enabled();
	arm["levels"] = _config.levels;
	arm["tile_size"] = _config.tile_size;
	arm["border"] = _config.border;
	arm["stored_size"] = _stored_size;
	arm["directory_size"] = _config.directory_size;
	arm["slots"] = _slot_count;
	arm["density"] = _config.density;
	arm["demand_radius"] = _config.demand_radius;
	arm["budget_bytes"] = get_budget_bytes();
	arm["used_bytes"] = get_used_bytes();
	arm["resident"] = get_used_slots();
	arm["valid"] = get_valid_count();
	arm["pending"] = get_pending_count();
	arm["starved"] = _starved;
	arm["state_stamp"] = get_state_stamp();
	arm["baked_albedo"] = get_baked_texture_rid(0);
	arm["baked_normal"] = get_baked_texture_rid(1);
	arm["baked_params"] = get_baked_texture_rid(2);
	PackedFloat32Array texels_per_meter;
	PackedFloat32Array tile_worlds;
	PackedFloat32Array texel_worlds;
	PackedVector2Array window_origins;
	Array directories;
	texels_per_meter.resize(MAX_LEVELS);
	tile_worlds.resize(MAX_LEVELS);
	texel_worlds.resize(MAX_LEVELS);
	window_origins.resize(MAX_LEVELS);
	for (int level = 0; level < MAX_LEVELS; level++) {
		// Padded to the shader's declared length: Godot's uniform arrays are read at their declared
		// size, so a shorter binding would leave the tail undefined. `levels` says how many entries
		// are meaningful.
		texels_per_meter[level] = get_level_texels_per_meter(level);
		tile_worlds[level] = get_level_tile_world(level);
		texel_worlds[level] = 1.f / get_level_texels_per_meter(level);
		window_origins[level] = level < _config.levels ? _window_origin[level] : Vector2();
		directories.push_back(level < _config.levels ? get_directory_rid(level) : RID());
	}
	arm["texels_per_meter"] = texels_per_meter;
	arm["tile_world"] = tile_worlds;
	arm["texel_world"] = texel_worlds;
	arm["window_origin"] = window_origins;
	arm["directory"] = directories;
	return arm;
}

///////////////////////////
// Readings
///////////////////////////

int Terrain3DMaterialClipmapDetail::get_valid_count() const {
	int valid = 0;
	for (int slot = 0; slot < _slot_count; slot++) {
		if (_slots[size_t(slot)].slot >= 0 && _slots[size_t(slot)].valid) {
			valid++;
		}
	}
	return valid;
}

int Terrain3DMaterialClipmapDetail::get_pending_count() const {
	int pending = 0;
	for (int slot = 0; slot < _slot_count; slot++) {
		const Tile &tile = _slots[size_t(slot)];
		if (tile.slot >= 0 && !tile.valid) {
			pending++;
		}
	}
	return pending;
}

int Terrain3DMaterialClipmapDetail::level_at(const Vector2 &p_world) const {
	if (!is_enabled()) {
		return -1;
	}
	for (int level = 0; level < _config.levels; level++) {
		// The same lookup the shader performs: the level's snapped window, the integer tile index in
		// it, and the resident map's slot. A tile that is resident but not valid is *not* readable, so
		// this is the directory bit rather than the slot's existence.
		const real_t tile_world = get_level_tile_world(level);
		const Vector2i base(int(Math::floor(_window_origin[level].x / tile_world)),
				int(Math::floor(_window_origin[level].y / tile_world)));
		const Vector2i tile = _tile_of_world(level, p_world);
		if (tile.x - base.x < 0 || tile.y - base.y < 0 || tile.x - base.x >= _config.directory_size ||
				tile.y - base.y >= _config.directory_size) {
			continue;
		}
		const auto found = _resident.find(tile_key(level, tile.x, tile.y));
		if (found == _resident.end()) {
			continue;
		}
		const Tile &entry = _slots[size_t(found->second)];
		if (entry.slot >= 0 && entry.valid) {
			return level;
		}
	}
	return -1;
}

real_t Terrain3DMaterialClipmapDetail::density_at(const Vector2 &p_world) const {
	const int level = level_at(p_world);
	return level >= 0 ? get_level_texels_per_meter(level) : 0.f;
}

String Terrain3DMaterialClipmapDetail::get_budget_report() const {
	return String("detail_material: ") + (is_enabled() ? "on" : "off") + ", budget " +
			String::num_int64(get_budget_bytes()) + " B, slots " + String::num_int64(_slot_count) +
			" of " + String::num_int64(_config.max_slots) + ", " + String::num_int64(get_used_bytes()) +
			" B allocated, resident " + String::num_int64(get_used_slots()) + ", valid " +
			String::num_int64(get_valid_count()) + ", starved " + String::num_int64(_starved) +
			", evictions " + String::num_int64(_evictions);
}
