// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_virtual_texture.h"

#include "logger.h"

#include <algorithm>

#include <godot_cpp/classes/rendering_server.hpp>

using namespace TerrainVT;

// FORMAT_R16 (39) is not named in this godot-cpp binding, the same numeric form the
// surface map already uses.
static constexpr Image::Format FORMAT_R16_UNORM = Image::Format(39);

///////////////////////////
// Private Functions
///////////////////////////

// Bytes per texel for the formats this runtime is allowed to carry. Godot's
// Image::get_format_pixel_size() is not exposed to extensions, and guessing here
// would silently mis-size the indirection chain.
static int _format_pixel_size(const Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return 1;
		case FORMAT_R16_UNORM:
		case Image::FORMAT_RH:
			return 2;
		case Image::FORMAT_RF:
		case Image::FORMAT_RGBA8:
			return 4;
		default:
			return 0;
	}
}

int Terrain3DVirtualTexture::get_level_size(const int p_mip) const {
	if (p_mip < 0 || p_mip >= _level_count) {
		return 0;
	}
	return _level_sizes[p_mip];
}

uint32_t Terrain3DVirtualTexture::_read_level(const int p_x, const int p_y, const int p_mip) const {
	if (p_mip < 0 || p_mip >= _level_count) {
		return INVALID_SLOT;
	}
	const int size = _level_sizes[p_mip];
	if (p_x < 0 || p_y < 0 || p_x >= size || p_y >= size) {
		return INVALID_SLOT;
	}
	const int64_t offset = int64_t(_level_offsets[p_mip]) + (int64_t(p_y) * size + p_x) * 4;
	return uint32_t(_bytes.decode_float(offset));
}

void Terrain3DVirtualTexture::_write_level(const int p_x, const int p_y, const int p_mip, const uint32_t p_slot) {
	if (p_mip < 0 || p_mip >= _level_count) {
		return;
	}
	const int size = _level_sizes[p_mip];
	if (p_x < 0 || p_y < 0 || p_x >= size || p_y >= size) {
		return;
	}
	const int64_t offset = int64_t(_level_offsets[p_mip]) + (int64_t(p_y) * size + p_x) * 4;
	_bytes.encode_float(offset, real_t(p_slot));
	_indirection_dirty = true;
}

// Most-recently-used first, so the back of the list is the eviction candidate.
void Terrain3DVirtualTexture::_touch_slot(const uint32_t p_slot) {
	for (size_t i = 0; i < _lru.size(); i++) {
		if (_lru[i] == p_slot) {
			_lru.erase(_lru.begin() + i);
			break;
		}
	}
	_lru.insert(_lru.begin(), p_slot);
}

// Drops every indirection entry that still publishes this slot. Hydra only
// invalidates when the published slot matches, which is what keeps a stale reverse
// index from clobbering an entry that a later allocation already republished.
void Terrain3DVirtualTexture::_evict_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(_page_count)) {
		return;
	}
	for (const uint32_t packed : _slot_owners[p_slot]) {
		const int mip = int(packed >> 24) & 0xFF;
		const int x = int(packed >> 12) & 0xFFF;
		const int y = int(packed) & 0xFFF;
		if (_read_level(x, y, mip) == p_slot) {
			_write_level(x, y, mip, INVALID_SLOT);
		}
	}
	_slot_owners[p_slot].clear();
	_slot_used[p_slot] = 0;
	_evict_count++;
}

int Terrain3DVirtualTexture::_acquire_slot() {
	if (!_free_slots.empty()) {
		const uint32_t slot = _free_slots.back();
		_free_slots.pop_back();
		_slot_used[slot] = 1;
		_touch_slot(slot);
		_alloc_count++;
		return int(slot);
	}
	// Nothing free: evict the least recently used unprotected page.
	for (int i = int(_lru.size()) - 1; i >= 0; i--) {
		const uint32_t slot = _lru[i];
		if (_slot_protected[slot]) {
			continue;
		}
		_evict_slot(slot);
		_slot_used[slot] = 1;
		_touch_slot(slot);
		_alloc_count++;
		return int(slot);
	}
	_protected_block_count++;
	LOG(DEBUG, "Virtual texture: every page is protected, cannot allocate");
	return -1;
}

bool Terrain3DVirtualTexture::_virtual_to_physical(const int p_sector_x, const int p_sector_y,
		const int p_local_mip, const int p_page_x, const int p_page_y,
		int &r_virtual_x, int &r_virtual_y) const {
	r_virtual_x = 0;
	r_virtual_y = 0;
	if (!_virtual_atlas) {
		return false;
	}
	ImageInfo info;
	if (!_virtual_atlas->try_get_avt_image_info(p_sector_x, p_sector_y, info)) {
		return false;
	}
	const int max_local_mip = log2_power_of_two(info.size);
	if (p_local_mip < 0 || p_local_mip > max_local_mip) {
		return false;
	}
	const int pages = std::max(1, info.size >> p_local_mip);
	if (p_page_x < 0 || p_page_y < 0 || p_page_x >= pages || p_page_y >= pages) {
		return false;
	}
	// A block origin is a multiple of the block size, so shifting stays aligned.
	r_virtual_x = (info.origin_x >> p_local_mip) + p_page_x;
	r_virtual_y = (info.origin_y >> p_local_mip) + p_page_y;
	return true;
}

int Terrain3DVirtualTexture::_sector_max_local_mip(const int p_sector_x, const int p_sector_y) const {
	if (!_virtual_atlas) {
		return 0;
	}
	ImageInfo info;
	if (!_virtual_atlas->try_get_avt_image_info(p_sector_x, p_sector_y, info)) {
		return 0;
	}
	return log2_power_of_two(info.size);
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DVirtualTexture::set_page_size(const int p_size) {
	_page_size = CLAMP(p_size, 1, 4096);
}

void Terrain3DVirtualTexture::set_page_border(const int p_border) {
	_page_border = CLAMP(p_border, 0, 64);
}

void Terrain3DVirtualTexture::set_page_count(const int p_count) {
	_page_count = CLAMP(p_count, 1, int(SLOT_MASK));
}

void Terrain3DVirtualTexture::set_indirection_size(const int p_size) {
	_indirection_size = CLAMP(p_size, 2, 4096);
}

void Terrain3DVirtualTexture::set_minimal_block(const int p_size) {
	_minimal_block = CLAMP(p_size, 1, 4096);
}

void Terrain3DVirtualTexture::set_format(const Image::Format p_format) {
	_format = p_format;
}

Error Terrain3DVirtualTexture::initialize() {
	clear();

	const int pixel_size = _format_pixel_size(_format);
	if (pixel_size == 0) {
		LOG(ERROR, "Virtual texture format ", int(_format), " is not supported");
		return ERR_INVALID_PARAMETER;
	}
	if (!AddressProfile::is_power_of_two(_indirection_size)) {
		LOG(ERROR, "Indirection size ", _indirection_size, " must be a power of two");
		return ERR_INVALID_PARAMETER;
	}
	if (!AddressProfile::is_power_of_two(_minimal_block) || _minimal_block > _indirection_size) {
		LOG(ERROR, "Minimal block ", _minimal_block, " must be a power of two within ", _indirection_size);
		return ERR_INVALID_PARAMETER;
	}
	_stored_page_size = _page_size + 2 * _page_border;

	// Physical page atlas: one blank layer per page, replaced by write_page().
	{
		PackedByteArray zeros;
		zeros.resize(int64_t(_stored_page_size) * _stored_page_size * pixel_size);
		_atlas_template = Image::create_from_data(_stored_page_size, _stored_page_size, false, _format, zeros);
		if (_atlas_template.is_null()) {
			LOG(ERROR, "Could not build the page template");
			return ERR_CANT_CREATE;
		}
		if (!_atlas.ensure_layers(_atlas_template, _page_count)) {
			LOG(ERROR, "Could not create the physical page atlas");
			return ERR_CANT_CREATE;
		}
	}

	// Indirection mip chain, built by hand. Level m is indirection_size >> m.
	_level_offsets.clear();
	_level_sizes.clear();
	int64_t total_texels = 0;
	int size = _indirection_size;
	while (true) {
		_level_offsets.push_back(int(total_texels * 4));
		_level_sizes.push_back(size);
		total_texels += int64_t(size) * size;
		if (size == 1) {
			break;
		}
		size >>= 1;
	}
	_level_count = int(_level_sizes.size());
	_bytes.resize(total_texels * 4);
	for (int64_t i = 0; i < total_texels; i++) {
		_bytes.encode_float(i * 4, real_t(INVALID_SLOT));
	}
	_indirection_dirty = true;

	// Slot allocator state.
	_lru.clear();
	_slot_used.assign(_page_count, 0);
	_slot_protected.assign(_page_count, 0);
	_slot_owners.assign(_page_count, std::vector<uint32_t>());
	_free_slots.clear();
	for (int slot = _page_count - 1; slot >= 0; slot--) {
		_free_slots.push_back(uint32_t(slot));
	}

	_virtual_atlas = std::make_unique<VirtualImageAtlas>(_indirection_size, _minimal_block);

	commit();
	if (!is_initialized()) {
		LOG(ERROR, "Virtual texture failed to create its GPU resources");
		return ERR_CANT_CREATE;
	}
	LOG(INFO, "Virtual texture initialized: ", _page_count, " pages of ", _stored_page_size,
			" (", _page_size, " + 2x", _page_border, "), indirection ", _indirection_size,
			" with ", _level_count, " mips");
	return OK;
}

void Terrain3DVirtualTexture::clear() {
	_atlas.clear();
	_atlas_template.unref();
	_indirection.clear();
	_indirection_image.unref();
	_bytes.clear();
	_level_offsets.clear();
	_level_sizes.clear();
	_level_count = 0;
	_indirection_dirty = true;
	_virtual_atlas.reset();
	_sector_owners.clear();
	_lru.clear();
	_slot_used.clear();
	_slot_protected.clear();
	_slot_owners.clear();
	_free_slots.clear();
}

bool Terrain3DVirtualTexture::register_sector(const Vector2i &p_sector, const int p_virtual_image_size) {
	if (!_virtual_atlas) {
		LOG(ERROR, "register_sector before initialize()");
		return false;
	}
	if (!AddressProfile::is_power_of_two(p_virtual_image_size) || p_virtual_image_size < _minimal_block ||
			p_virtual_image_size > _indirection_size) {
		LOG(WARN, "Sector block size ", p_virtual_image_size, " must be a power of two within [",
				_minimal_block, ", ", _indirection_size, "]");
		return false;
	}
	if (has_sector(p_sector)) {
		// Idempotent for the same block size; a different size would need the old
		// block freed and a new one allocated, which the caller has to ask for
		// explicitly with unregister_sector() first.
		if (get_sector_block_size(p_sector) == p_virtual_image_size) {
			return true;
		}
		LOG(WARN, "Sector ", p_sector, " is already registered with block size ",
				get_sector_block_size(p_sector), ", not ", p_virtual_image_size,
				". Unregister it first to change the size.");
		return false;
	}
	VirtualImageOwner owner;
	ImageInfo info;
	if (!_virtual_atlas->try_insert_avt_image(p_sector.x, p_sector.y, p_virtual_image_size, owner, info)) {
		LOG(DEBUG, "Virtual image atlas is full, cannot register sector ", p_sector);
		return false;
	}
	_sector_owners[_sector_key(p_sector)] = owner;
	return true;
}

bool Terrain3DVirtualTexture::unregister_sector(const Vector2i &p_sector) {
	if (!_virtual_atlas) {
		return false;
	}
	const auto found = _sector_owners.find(_sector_key(p_sector));
	if (found == _sector_owners.end()) {
		return false;
	}
	// Present the owner the atlas actually created; a reconstructed one has the wrong
	// generation and would never match.
	const bool removed = _virtual_atlas->remove_image(found->second);
	if (removed) {
		_sector_owners.erase(found);
	}
	return removed;
}

bool Terrain3DVirtualTexture::has_sector(const Vector2i &p_sector) const {
	if (!_virtual_atlas) {
		return false;
	}
	ImageInfo info;
	return _virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, info);
}

int Terrain3DVirtualTexture::get_sector_block_size(const Vector2i &p_sector) const {
	if (!_virtual_atlas) {
		return 0;
	}
	ImageInfo info;
	return _virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, info) ? info.size : 0;
}

int Terrain3DVirtualTexture::get_sector_block_origin_x(const Vector2i &p_sector) const {
	if (!_virtual_atlas) {
		return -1;
	}
	ImageInfo info;
	return _virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, info) ? info.origin_x : -1;
}

int Terrain3DVirtualTexture::get_sector_block_origin_y(const Vector2i &p_sector) const {
	if (!_virtual_atlas) {
		return -1;
	}
	ImageInfo info;
	return _virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, info) ? info.origin_y : -1;
}

int Terrain3DVirtualTexture::lookup_virtual(const int p_virtual_x, const int p_virtual_y,
		const int p_mip, const int p_max_mip) const {
	if (p_virtual_x < 0 || p_virtual_y < 0 || p_mip < 0 || p_mip > p_max_mip) {
		return -1;
	}
	PageId page_id;
	page_id.x = uint32_t(p_virtual_x);
	page_id.y = uint32_t(p_virtual_y);
	page_id.z = uint32_t(p_mip);
	// Any non-zero descriptor index: this runtime carries a single density, so the
	// descriptor only has to be valid for the walk to run.
	page_id.w = 1u;

	uint32_t slot = 0;
	uint32_t matched_x = 0;
	uint32_t matched_y = 0;
	uint32_t matched_mip = 0;
	const bool found = try_match_indirection_slot(page_id, uint32_t(p_max_mip),
			[this](uint32_t p_x, uint32_t p_y, uint32_t p_level) {
				return _read_level(int(p_x), int(p_y), int(p_level));
			},
			slot, matched_x, matched_y, matched_mip);
	return found ? int(slot) : -1;
}

int Terrain3DVirtualTexture::lookup_page(const Vector2i &p_sector, const int p_local_mip,
		const int p_page_x, const int p_page_y) const {
	int virtual_x = 0;
	int virtual_y = 0;
	if (!_virtual_to_physical(p_sector.x, p_sector.y, p_local_mip, p_page_x, p_page_y, virtual_x, virtual_y)) {
		return -1;
	}
	return lookup_virtual(virtual_x, virtual_y, p_local_mip, _sector_max_local_mip(p_sector.x, p_sector.y));
}

int Terrain3DVirtualTexture::request_page(const Vector2i &p_sector, const int p_local_mip,
		const int p_page_x, const int p_page_y) {
	return request_page_internal(p_sector, p_local_mip, p_page_x, p_page_y, nullptr);
}

int Terrain3DVirtualTexture::request_page_internal(const Vector2i &p_sector, const int p_local_mip,
		const int p_page_x, const int p_page_y, bool *r_miss) {
	if (r_miss) {
		*r_miss = false;
	}
	int virtual_x = 0;
	int virtual_y = 0;
	if (!_virtual_to_physical(p_sector.x, p_sector.y, p_local_mip, p_page_x, p_page_y, virtual_x, virtual_y)) {
		return -1;
	}
	const int max_local_mip = _sector_max_local_mip(p_sector.x, p_sector.y);
	const int existing = lookup_virtual(virtual_x, virtual_y, p_local_mip, max_local_mip);
	if (existing >= 0) {
		_hit_count++;
		_touch_slot(uint32_t(existing));
		return existing;
	}
	_miss_count++;
	if (r_miss) {
		*r_miss = true;
	}
	const int slot = _acquire_slot();
	if (slot < 0) {
		return -1;
	}
	_write_level(virtual_x, virtual_y, p_local_mip, uint32_t(slot));
	// Record the reverse mapping so eviction can invalidate exactly this entry.
	_slot_owners[slot].push_back((uint32_t(p_local_mip) << 24) |
			(uint32_t(virtual_x) & 0xFFFu) << 12 | (uint32_t(virtual_y) & 0xFFFu));
	return slot;
}

int Terrain3DVirtualTexture::get_indirection_slot(const int p_virtual_x, const int p_virtual_y,
		const int p_mip) const {
	return int(_read_level(p_virtual_x, p_virtual_y, p_mip));
}

bool Terrain3DVirtualTexture::write_page(const int p_slot, const Ref<Image> &p_page) {
	if (p_slot < 0 || p_slot >= _page_count || p_page.is_null()) {
		return false;
	}
	if (p_page->get_width() != _stored_page_size || p_page->get_height() != _stored_page_size) {
		// A caller mistake, not an engine fault: the false return is the contract, and
		// ERROR would fail a test run that is deliberately checking the rejection.
		LOG(WARN, "Page must be ", _stored_page_size, " squared, got ", p_page->get_size());
		return false;
	}
	if (p_page->get_format() != _format) {
		LOG(WARN, "Page format ", int(p_page->get_format()), " does not match the atlas ", int(_format));
		return false;
	}
	if (!_atlas.get_rid().is_valid()) {
		return false;
	}
	_atlas.update(p_page, p_slot);
	_page_write_count++;
	return true;
}

Ref<Image> Terrain3DVirtualTexture::read_page(const int p_slot) const {
	if (p_slot < 0 || p_slot >= _page_count || !_atlas.get_rid().is_valid()) {
		return Ref<Image>();
	}
	return RS->texture_2d_layer_get(_atlas.get_rid(), p_slot);
}

Ref<Image> Terrain3DVirtualTexture::get_atlas_image() const {
	if (!_atlas.get_rid().is_valid()) {
		return Ref<Image>();
	}
	return RS->texture_2d_layer_get(_atlas.get_rid(), 0);
}

void Terrain3DVirtualTexture::protect_page(const int p_slot, const bool p_protected) {
	if (p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	_slot_protected[p_slot] = p_protected ? 1 : 0;
}

bool Terrain3DVirtualTexture::is_page_protected(const int p_slot) const {
	if (p_slot < 0 || p_slot >= _page_count) {
		return false;
	}
	return _slot_protected[p_slot] != 0;
}

bool Terrain3DVirtualTexture::is_page_used(const int p_slot) const {
	if (p_slot < 0 || p_slot >= _page_count) {
		return false;
	}
	return _slot_used[p_slot] != 0;
}

int Terrain3DVirtualTexture::get_slot_owner_count(const int p_slot) const {
	if (p_slot < 0 || p_slot >= _page_count) {
		return 0;
	}
	return int(_slot_owners[p_slot].size());
}

void Terrain3DVirtualTexture::commit() {
	if (!_indirection_dirty) {
		return;
	}
	// The whole chain is re-created from `_bytes` and uploaded. A per-texel partial
	// update would be the next optimisation; Hydra's budget is 64 indirection writes
	// per frame, which is small enough that this is not the bottleneck yet.
	_indirection_image = Image::create_from_data(_indirection_size, _indirection_size, true,
			Image::FORMAT_RF, _bytes);
	if (_indirection_image.is_null()) {
		LOG(ERROR, "Could not build the indirection image");
		return;
	}
	if (_indirection.get_rid().is_valid() &&
			_indirection.get_layer_size() == Vector2i(_indirection_size, _indirection_size)) {
		_indirection.update(_indirection_image, 0);
	} else {
		_indirection.create(_indirection_image);
	}
	_indirection_dirty = false;
	_commit_count++;
}

Dictionary Terrain3DVirtualTexture::get_stats() const {
	Dictionary stats;
	stats["page_size"] = _page_size;
	stats["page_border"] = _page_border;
	stats["stored_page_size"] = _stored_page_size;
	stats["page_count"] = _page_count;
	stats["indirection_size"] = _indirection_size;
	stats["indirection_mips"] = _level_count;
	stats["atlas_valid"] = _atlas.get_rid().is_valid();
	stats["indirection_valid"] = _indirection.get_rid().is_valid();
	stats["alloc_count"] = _alloc_count;
	stats["evict_count"] = _evict_count;
	stats["hit_count"] = _hit_count;
	stats["miss_count"] = _miss_count;
	stats["protected_block_count"] = _protected_block_count;
	stats["commit_count"] = _commit_count;
	stats["page_write_count"] = _page_write_count;
	stats["free_count"] = int(_free_slots.size());
	stats["protected_count"] = int(std::count(_slot_protected.begin(), _slot_protected.end(), uint8_t(1)));
	stats["virtual_atlas_nodes"] = _virtual_atlas ? _virtual_atlas->allocated_node_count() : 0;
	return stats;
}

void Terrain3DVirtualTexture::reset_stats() {
	_alloc_count = 0;
	_evict_count = 0;
	_hit_count = 0;
	_miss_count = 0;
	_protected_block_count = 0;
	_commit_count = 0;
	_page_write_count = 0;
}

///////////////////////////
// Bindings
///////////////////////////

void Terrain3DVirtualTexture::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_page_size", "size"), &Terrain3DVirtualTexture::set_page_size);
	ClassDB::bind_method(D_METHOD("get_page_size"), &Terrain3DVirtualTexture::get_page_size);
	ClassDB::bind_method(D_METHOD("set_page_border", "border"), &Terrain3DVirtualTexture::set_page_border);
	ClassDB::bind_method(D_METHOD("get_page_border"), &Terrain3DVirtualTexture::get_page_border);
	ClassDB::bind_method(D_METHOD("set_page_count", "count"), &Terrain3DVirtualTexture::set_page_count);
	ClassDB::bind_method(D_METHOD("get_page_count"), &Terrain3DVirtualTexture::get_page_count);
	ClassDB::bind_method(D_METHOD("set_indirection_size", "size"), &Terrain3DVirtualTexture::set_indirection_size);
	ClassDB::bind_method(D_METHOD("get_indirection_size"), &Terrain3DVirtualTexture::get_indirection_size);
	ClassDB::bind_method(D_METHOD("set_minimal_block", "size"), &Terrain3DVirtualTexture::set_minimal_block);
	ClassDB::bind_method(D_METHOD("get_minimal_block"), &Terrain3DVirtualTexture::get_minimal_block);
	ClassDB::bind_method(D_METHOD("set_format", "format"), &Terrain3DVirtualTexture::set_format);
	ClassDB::bind_method(D_METHOD("get_format"), &Terrain3DVirtualTexture::get_format);

	ClassDB::bind_method(D_METHOD("initialize"), &Terrain3DVirtualTexture::initialize);
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DVirtualTexture::clear);
	ClassDB::bind_method(D_METHOD("is_initialized"), &Terrain3DVirtualTexture::is_initialized);

	ClassDB::bind_method(D_METHOD("register_sector", "sector", "virtual_image_size"), &Terrain3DVirtualTexture::register_sector);
	ClassDB::bind_method(D_METHOD("unregister_sector", "sector"), &Terrain3DVirtualTexture::unregister_sector);
	ClassDB::bind_method(D_METHOD("has_sector", "sector"), &Terrain3DVirtualTexture::has_sector);
	ClassDB::bind_method(D_METHOD("get_sector_block_size", "sector"), &Terrain3DVirtualTexture::get_sector_block_size);
	ClassDB::bind_method(D_METHOD("get_sector_block_origin_x", "sector"), &Terrain3DVirtualTexture::get_sector_block_origin_x);
	ClassDB::bind_method(D_METHOD("get_sector_block_origin_y", "sector"), &Terrain3DVirtualTexture::get_sector_block_origin_y);

	ClassDB::bind_method(D_METHOD("request_page", "sector", "local_mip", "page_x", "page_y"), &Terrain3DVirtualTexture::request_page);
	ClassDB::bind_method(D_METHOD("lookup_page", "sector", "local_mip", "page_x", "page_y"), &Terrain3DVirtualTexture::lookup_page);
	ClassDB::bind_method(D_METHOD("lookup_virtual", "virtual_x", "virtual_y", "mip", "max_mip"), &Terrain3DVirtualTexture::lookup_virtual);
	ClassDB::bind_method(D_METHOD("get_indirection_slot", "virtual_x", "virtual_y", "mip"), &Terrain3DVirtualTexture::get_indirection_slot);

	ClassDB::bind_method(D_METHOD("write_page", "slot", "page"), &Terrain3DVirtualTexture::write_page);
	ClassDB::bind_method(D_METHOD("read_page", "slot"), &Terrain3DVirtualTexture::read_page);
	ClassDB::bind_method(D_METHOD("get_atlas_image"), &Terrain3DVirtualTexture::get_atlas_image);

	ClassDB::bind_method(D_METHOD("protect_page", "slot", "protected"), &Terrain3DVirtualTexture::protect_page);
	ClassDB::bind_method(D_METHOD("is_page_protected", "slot"), &Terrain3DVirtualTexture::is_page_protected);
	ClassDB::bind_method(D_METHOD("is_page_used", "slot"), &Terrain3DVirtualTexture::is_page_used);
	ClassDB::bind_method(D_METHOD("get_slot_owner_count", "slot"), &Terrain3DVirtualTexture::get_slot_owner_count);

	ClassDB::bind_method(D_METHOD("commit"), &Terrain3DVirtualTexture::commit);
	ClassDB::bind_method(D_METHOD("get_atlas_rid"), &Terrain3DVirtualTexture::get_atlas_rid);
	ClassDB::bind_method(D_METHOD("get_indirection_rid"), &Terrain3DVirtualTexture::get_indirection_rid);
	ClassDB::bind_method(D_METHOD("get_indirection_image"), &Terrain3DVirtualTexture::get_indirection_image);
	ClassDB::bind_method(D_METHOD("get_level_count"), &Terrain3DVirtualTexture::get_level_count);
	ClassDB::bind_method(D_METHOD("get_level_size", "mip"), &Terrain3DVirtualTexture::get_level_size);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DVirtualTexture::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &Terrain3DVirtualTexture::reset_stats);
}
