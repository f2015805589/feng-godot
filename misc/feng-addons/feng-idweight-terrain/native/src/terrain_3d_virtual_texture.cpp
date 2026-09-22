// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DVirtualTexture, part 1 of 3: the view object, its indirection table and its settings.

// One of three files that define a view. This one owns the view's own state and the table every
// lookup reads: the hand-built indirection mip chain (`_read_level()` / `_write_level()` and the
// dirty-tile set they feed), the page-slot reservation the pool hands out (`_acquire_slot()` and
// the reverse-owner invalidation the pool calls back into), the settings with `initialize()` /
// `clear()` and the shared-pool binding, the upload `commit()` performs, the page I/O and slot
// queries the demand passes and the tests call, the counters `get_stats()` reports, and the
// ClassDB bindings.
//
// The other two: `terrain_3d_virtual_texture_sector.cpp` (the near field's sector blocks) and
// `terrain_3d_virtual_texture_lookup.cpp` (addressing and the request entry points).

#include "terrain_3d_virtual_texture.h"

#include "logger.h"

#include <algorithm>
#include <cstring>

#include <godot_cpp/classes/rendering_server.hpp>

using namespace TerrainVT;

///////////////////////////
// Private Functions
///////////////////////////

uint32_t Terrain3DVirtualTexture::_read_level(const int p_x, const int p_y, const int p_mip) const {
	if (p_mip < 0 || p_mip >= _level_count) {
		return INVALID_SLOT;
	}
	const int size = _level_sizes[p_mip];
	if (p_x < 0 || p_y < 0 || p_x >= size || p_y >= size) {
		return INVALID_SLOT;
	}
	const int64_t offset = int64_t(_level_offsets[p_mip]) + (int64_t(p_y) * size + p_x) * 4;
	float value;
	std::memcpy(&value, _bytes.ptr() + offset, sizeof(value));
	return uint32_t(value);
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
	float old_value;
	std::memcpy(&old_value, _bytes.ptr() + offset, sizeof(old_value));
	if (uint32_t(old_value) == p_slot) { return; }
	const float value = float(p_slot);
	std::memcpy(_bytes.ptrw() + offset, &value, sizeof(value));
	_dirty_tiles.insert((uint64_t(p_mip) << 32) | (uint64_t(p_y >> 4) << 16) | uint64_t(p_x >> 4));
	_indirection_dirty = true;
}

void Terrain3DVirtualTexture::_touch_slot(const uint32_t p_slot) {
	if (_page_pool) {
		_page_pool->touch_slot(p_slot);
	}
}

int Terrain3DVirtualTexture::_acquire_slot() {
	if (!_page_pool) {
		return -1;
	}
	return _page_pool->acquire_slot(this);
}

void Terrain3DVirtualTexture::_invalidate_pool_owner(const uint32_t p_slot,
		const Terrain3DVTPageOwner &p_owner) {
	if (p_owner.texture != this) {
		return;
	}
	// The pool has already selected this owner as the eviction target. Check the
	// slot before clearing so a stale reverse record cannot clobber a republish.
	if (_read_level(p_owner.virtual_x, p_owner.virtual_y, p_owner.mip) == p_slot) {
		_write_level(p_owner.virtual_x, p_owner.virtual_y, p_owner.mip, INVALID_SLOT);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

bool Terrain3DVirtualTexture::grow_capacity(int p_count) {
	if (!_material_cache_mode || !_page_pool || p_count < _page_count) { return false; }
	if (_page_pool->page_count < p_count && !_page_pool->grow(p_count)) { return false; }
	_page_count = p_count;
	return true;
}

int Terrain3DVirtualTexture::get_level_size(const int p_mip) const {
	if (p_mip < 0 || p_mip >= _level_count) {
		return 0;
	}
	return _level_sizes[p_mip];
}

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

void Terrain3DVirtualTexture::set_allocation_budget(const int p_pages) {
	if (_page_pool) {
		_page_pool->set_allocation_budget(p_pages);
	}
}

void Terrain3DVirtualTexture::set_page_pool(
		const std::shared_ptr<Terrain3DVTPagePool> &p_pool) {
	if (_page_pool == p_pool) {
		return;
	}
	clear();
	_page_pool = p_pool ? p_pool : std::make_shared<Terrain3DVTPagePool>();
	if (_page_pool->is_initialized()) {
		_page_size = _page_pool->page_size;
		_page_border = _page_pool->page_border;
		_page_count = _page_pool->page_count;
		_format = _page_pool->format;
		_stored_page_size = _page_pool->stored_page_size;
	}
}

void Terrain3DVirtualTexture::share_physical_pool(Terrain3DVirtualTexture *p_source) {
	if (p_source == this) {
		return;
	}
	set_page_pool(p_source ? p_source->_page_pool : nullptr);
}

Error Terrain3DVirtualTexture::initialize() {
	clear();

	const int pixel_size = vt_format_pixel_size(_format);
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
	// The first view configures the shared physical atlas. A second view adopts
	// the already configured physical settings, so reinitializing it cannot tear
	// down or resize an atlas still used by its sibling. A standalone view owns
	// its pool exclusively (use_count()==1), however, and is allowed to rebuild
	// that pool after a page setting change. Without this branch a standalone
	// `set_page_size`/`set_page_count` followed by `initialize()` silently
	// reverted to the old atlas configuration.
	if (!_page_pool) {
		_page_pool = std::make_shared<Terrain3DVTPagePool>();
	}
	if (_page_pool->is_initialized()) {
		const bool config_changed = _page_pool->page_size != _page_size ||
				_page_pool->page_border != _page_border ||
				_page_pool->page_count != _page_count || _page_pool->format != _format;
		if (config_changed && _page_pool.use_count() == 1) {
			// No sibling can be sampling this pool. Release it only after clear()
			// has detached this view's reverse-owner entries.
			_page_pool = std::make_shared<Terrain3DVTPagePool>();
		} else {
			_page_size = _page_pool->page_size;
			_page_border = _page_pool->page_border;
			_page_count = _page_pool->page_count;
			_format = _page_pool->format;
		}
	} else if (!_page_pool->initialize(_page_size, _page_border, _page_count, _format)) {
		LOG(ERROR, "Could not create the shared physical page atlas");
		return ERR_CANT_CREATE;
	}
	if (!_page_pool->is_initialized() &&
			!_page_pool->initialize(_page_size, _page_border, _page_count, _format)) {
		LOG(ERROR, "Could not rebuild the physical page atlas");
		return ERR_CANT_CREATE;
	}
	_stored_page_size = _page_pool->stored_page_size;

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
	_bytes.encode_float(0, real_t(INVALID_SLOT));
	uint8_t *indirection_bytes = _bytes.ptrw();
	for (int64_t i = 1; i < total_texels; i++) {
		std::memcpy(indirection_bytes + i * 4, indirection_bytes, 4);
	}
	_indirection_dirty = true;

	if (_world_space) {
		// A regular world grid needs no allocator: a page's block origin is a pure
		// function of its coordinate, so nothing has to be packed or registered.
		_virtual_atlas.reset();
		const int cap = MAX(0, _level_count - 2);
		_world_max_local_mip = (_world_max_local_mip < 0) ? cap : MIN(_world_max_local_mip, cap);
	} else {
		_virtual_atlas = std::make_unique<VirtualImageAtlas>(_indirection_size, _minimal_block);
	}

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
	if (_page_pool) {
		_page_pool->detach_texture(this);
	}
	_indirection.clear();
	_indirection_gpu.unref();
	_dirty_tiles.clear();
	_indirection_uploaded_bytes = 0;
	_indirection_image.unref();
	_bytes.clear();
	_level_offsets.clear();
	_level_sizes.clear();
	_level_count = 0;
	_indirection_dirty = true;
	_virtual_atlas.reset();
	_sector_owners.clear();
}

int Terrain3DVirtualTexture::get_indirection_slot(const int p_virtual_x, const int p_virtual_y,
		const int p_mip) const {
	return int(_read_level(p_virtual_x, p_virtual_y, p_mip));
}

bool Terrain3DVirtualTexture::write_page(const int p_slot, const Ref<Image> &p_page) {
	if (!_page_pool || p_page.is_null()) {
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
	if (p_slot < 0 || p_slot >= _page_count) { return false; }
	if (_material_cache_mode) {
		// Material-cache rendering reads the baked channels, not this raw-ID atlas.
		// Retain authored IDs for explicit diagnostics without uploading them twice,
		// but only while the pool still owns the slot: an authored page kept on a
		// free slot is re-uploaded into whatever page takes the slot next.
		if (!_page_pool->slot_used[p_slot]) {
			return false;
		}
		_page_pool->authored_pages[p_slot] = p_page;
	} else if (_indirection_gpu.is_valid()) {
		_indirection_gpu->queue_layer(_page_pool->atlas.get_rid(), p_slot, p_page);
	} else if (!_page_pool->write_page(p_slot, p_page)) { return false; }
	_page_write_count++;
	return true;
}

Ref<Image> Terrain3DVirtualTexture::read_page(const int p_slot) const {
	if (_material_cache_mode && _page_pool && p_slot >= 0 && p_slot < int(_page_pool->authored_pages.size()) && _page_pool->authored_pages[p_slot].is_valid()) {
		// Explicit GPU inspection still uploads and reads the real raw-ID layer.
		_page_pool->write_page(p_slot, _page_pool->authored_pages[p_slot]);
	}
	if (_indirection_gpu.is_valid() && _indirection_gpu->has_pending_layers()) { const_cast<Terrain3DVirtualTexture *>(this)->commit(); }
	return _page_pool ? _page_pool->read_page(p_slot) : Ref<Image>();
}

Ref<Image> Terrain3DVirtualTexture::get_atlas_image() const {
	if (_material_cache_mode) { return read_page(0); }
	if (_indirection_gpu.is_valid() && _indirection_gpu->has_pending_layers()) { const_cast<Terrain3DVirtualTexture *>(this)->commit(); }
	return _page_pool ? _page_pool->read_page(0) : Ref<Image>();
}

void Terrain3DVirtualTexture::protect_page(const int p_slot, const bool p_protected) {
	if (!_page_pool || p_slot < 0 || p_slot >= _page_pool->page_count) {
		return;
	}
	// Reference counted: several owners can pin the same slot (the AVT pass pins its
	// visible plan, the far field pins its root pyramid), and one owner's release must
	// not clear a pin another owner still holds.
	uint8_t &refs = _page_pool->slot_protect_refs[p_slot];
	if (p_protected) {
		if (refs < 255) { ++refs; }
	} else if (refs > 0) {
		--refs;
	}
	_page_pool->slot_protected[p_slot] = refs > 0 ? 1 : 0;
}

bool Terrain3DVirtualTexture::is_page_protected(const int p_slot) const {
	if (!_page_pool || p_slot < 0 || p_slot >= _page_pool->page_count) {
		return false;
	}
	return _page_pool->slot_protected[p_slot] != 0;
}

bool Terrain3DVirtualTexture::is_page_used(const int p_slot) const {
	if (!_page_pool || p_slot < 0 || p_slot >= _page_pool->page_count) {
		return false;
	}
	return _page_pool->slot_used[p_slot] != 0;
}

int Terrain3DVirtualTexture::get_slot_owner_count(const int p_slot) const {
	if (!_page_pool || p_slot < 0 || p_slot >= _page_pool->page_count) {
		return 0;
	}
	return int(_page_pool->slot_owners[p_slot].size());
}

Array Terrain3DVirtualTexture::get_slot_owner_metadata(const int p_slot) const {
	return _page_pool ? _page_pool->get_slot_owner_metadata(p_slot) : Array();
}

void Terrain3DVirtualTexture::commit() {
	if (!_indirection_dirty) {
		if (_indirection_gpu.is_valid() && (_indirection_gpu->needs_retry() || _indirection_gpu->has_pending_layers())) {
			_indirection_gpu->submit({});
		}
		return;
	}
	// A cleared view has no page table and no levels. Publishing it would build a GPU
	// table for zero levels, which the device rejects, and the failed table would then be
	// mistaken for an initialized one for the rest of the session.
	if (_bytes.is_empty() || _level_count <= 0) {
		return;
	}
	if (_indirection_gpu.is_valid() || RS->get_rendering_device()) {
		if (_indirection_gpu.is_null()) {
			_indirection_gpu.instantiate();
			_indirection_gpu->initialize(_indirection_size, _level_count, _bytes);
			_indirection_uploaded_bytes += _bytes.size();
		} else {
			std::vector<Terrain3DVTIndirection::Patch> patches;
			for (uint64_t tile : _dirty_tiles) {
				const int mip = int(tile >> 32), x = int(tile & 0xffff) * 16, y = int((tile >> 16) & 0xffff) * 16;
				const int width = std::min(16, _level_sizes[mip] - x), height = std::min(16, _level_sizes[mip] - y);
				Terrain3DVTIndirection::Patch patch = {mip, x, y, width, height};
				patch.bytes.resize(width * height * 4);
				uint8_t *output = patch.bytes.ptrw();
				const uint8_t *source = _bytes.ptr() + _level_offsets[mip] + (int64_t(y) * _level_sizes[mip] + x) * 4;
				for (int row = 0; row < height; ++row) { std::memcpy(output + row * width * 4, source + int64_t(row) * _level_sizes[mip] * 4, width * 4); }
				_indirection_uploaded_bytes += patch.bytes.size();
				patches.push_back(std::move(patch));
			}
			_indirection_gpu->submit(std::move(patches));
		}
		_dirty_tiles.clear();
		_indirection_dirty = false;
		_commit_count++;
		return;
	}
	// Compatibility renderers without RenderingDevice use the full image path.
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
	stats["indirection_uploaded_bytes"] = int64_t(_indirection_uploaded_bytes);
	stats["page_size"] = _page_size;
	stats["page_border"] = _page_border;
	stats["stored_page_size"] = _stored_page_size;
	stats["page_count"] = _page_pool ? _page_pool->page_count : _page_count;
	stats["indirection_size"] = _indirection_size;
	stats["indirection_mips"] = _level_count;
	stats["atlas_valid"] = _page_pool && _page_pool->atlas.get_rid().is_valid();
	stats["indirection_valid"] = get_indirection_rid().is_valid();
	stats["alloc_count"] = _page_pool ? _page_pool->alloc_count : 0;
	stats["evict_count"] = _page_pool ? _page_pool->evict_count : 0;
	stats["hit_count"] = _hit_count;
	stats["miss_count"] = _miss_count;
	stats["protected_block_count"] = _page_pool ? _page_pool->protected_block_count : 0;
	// Reserved residency and the pressure it caused: how many slots the addressing is holding for a
	// page it treats as a guarantee, and how often a request found only reserved candidates left.
	stats["reserved_count"] = _page_pool ? _page_pool->count_reserved_slots() : 0;
	stats["reserved_block_count"] = _page_pool ? _page_pool->reserved_block_count : 0;
	stats["commit_count"] = _commit_count;
	stats["page_write_count"] = _page_write_count;
	stats["free_count"] = _page_pool ? int(_page_pool->free_slots.size()) : 0;
	stats["protected_count"] = _page_pool ? int(std::count(_page_pool->slot_protected.begin(),
			_page_pool->slot_protected.end(), uint8_t(1))) : 0;
	stats["allocation_budget"] = _page_pool ? _page_pool->allocation_budget : -1;
	stats["shared_pool"] = _page_pool != nullptr;
	stats["virtual_atlas_nodes"] = _virtual_atlas ? _virtual_atlas->allocated_node_count() : 0;
	return stats;
}

void Terrain3DVirtualTexture::reset_stats() {
	_hit_count = 0;
	_miss_count = 0;
	_commit_count = 0;
	_page_write_count = 0;
	if (_page_pool) {
		_page_pool->alloc_count = 0;
		_page_pool->evict_count = 0;
		_page_pool->protected_block_count = 0;
	}
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
	ClassDB::bind_method(D_METHOD("set_world_space", "enabled"), &Terrain3DVirtualTexture::set_world_space);
	ClassDB::bind_method(D_METHOD("is_world_space"), &Terrain3DVirtualTexture::is_world_space);
	ClassDB::bind_method(D_METHOD("set_world_max_mip", "mip"), &Terrain3DVirtualTexture::set_world_max_mip);
	ClassDB::bind_method(D_METHOD("get_world_max_mip"), &Terrain3DVirtualTexture::get_world_max_mip);
	ClassDB::bind_method(D_METHOD("get_world_grid_half"), &Terrain3DVirtualTexture::get_world_grid_half);
	ClassDB::bind_method(D_METHOD("get_world_page_virtual", "page_x", "page_y", "local_mip"),
			&Terrain3DVirtualTexture::get_world_page_virtual);
	ClassDB::bind_method(D_METHOD("share_physical_pool", "source"),
			&Terrain3DVirtualTexture::share_physical_pool);

	ClassDB::bind_method(D_METHOD("initialize"), &Terrain3DVirtualTexture::initialize);
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DVirtualTexture::clear);
	ClassDB::bind_method(D_METHOD("is_initialized"), &Terrain3DVirtualTexture::is_initialized);

	ClassDB::bind_method(D_METHOD("register_sector", "sector", "virtual_image_size"), &Terrain3DVirtualTexture::register_sector);
	ClassDB::bind_method(D_METHOD("resize_sector", "sector", "virtual_image_size"), &Terrain3DVirtualTexture::resize_sector);
	ClassDB::bind_method(D_METHOD("unregister_sector", "sector"), &Terrain3DVirtualTexture::unregister_sector);
	ClassDB::bind_method(D_METHOD("has_sector", "sector"), &Terrain3DVirtualTexture::has_sector);
	ClassDB::bind_method(D_METHOD("get_sector_block_size", "sector"), &Terrain3DVirtualTexture::get_sector_block_size);
	ClassDB::bind_method(D_METHOD("get_sector_block_origin_x", "sector"), &Terrain3DVirtualTexture::get_sector_block_origin_x);
	ClassDB::bind_method(D_METHOD("get_sector_block_origin_y", "sector"), &Terrain3DVirtualTexture::get_sector_block_origin_y);

	ClassDB::bind_method(D_METHOD("request_page", "sector", "local_mip", "page_x", "page_y"), &Terrain3DVirtualTexture::request_page);
	ClassDB::bind_method(D_METHOD("lookup_page", "sector", "local_mip", "page_x", "page_y"), &Terrain3DVirtualTexture::lookup_page);
	ClassDB::bind_method(D_METHOD("request_world_page", "page_x", "page_y", "local_mip"),
			&Terrain3DVirtualTexture::request_world_page);
	ClassDB::bind_method(D_METHOD("lookup_world_page", "page_x", "page_y", "local_mip"), &Terrain3DVirtualTexture::lookup_world_page);
	ClassDB::bind_method(D_METHOD("request_virtual_page", "virtual_x", "virtual_y", "local_mip"),
			&Terrain3DVirtualTexture::request_virtual_page);
	ClassDB::bind_method(D_METHOD("release_page", "sector", "local_mip", "page_x", "page_y"),
			&Terrain3DVirtualTexture::release_page);
	ClassDB::bind_method(D_METHOD("release_world_page", "page_x", "page_y", "local_mip"),
			&Terrain3DVirtualTexture::release_world_page);
	ClassDB::bind_method(D_METHOD("lookup_virtual", "virtual_x", "virtual_y", "mip", "max_mip"), &Terrain3DVirtualTexture::lookup_virtual);
	ClassDB::bind_method(D_METHOD("get_indirection_slot", "virtual_x", "virtual_y", "mip"), &Terrain3DVirtualTexture::get_indirection_slot);

	ClassDB::bind_method(D_METHOD("write_page", "slot", "page"), &Terrain3DVirtualTexture::write_page);
	ClassDB::bind_method(D_METHOD("read_page", "slot"), &Terrain3DVirtualTexture::read_page);
	ClassDB::bind_method(D_METHOD("get_atlas_image"), &Terrain3DVirtualTexture::get_atlas_image);

	ClassDB::bind_method(D_METHOD("protect_page", "slot", "protected"), &Terrain3DVirtualTexture::protect_page);
	ClassDB::bind_method(D_METHOD("is_page_protected", "slot"), &Terrain3DVirtualTexture::is_page_protected);
	ClassDB::bind_method(D_METHOD("is_page_used", "slot"), &Terrain3DVirtualTexture::is_page_used);
	ClassDB::bind_method(D_METHOD("get_slot_owner_count", "slot"), &Terrain3DVirtualTexture::get_slot_owner_count);
	ClassDB::bind_method(D_METHOD("get_slot_owner_metadata", "slot"), &Terrain3DVirtualTexture::get_slot_owner_metadata);
	ClassDB::bind_method(D_METHOD("get_page_metadata", "slot"), &Terrain3DVirtualTexture::get_page_metadata);

	ClassDB::bind_method(D_METHOD("commit"), &Terrain3DVirtualTexture::commit);
	ClassDB::bind_method(D_METHOD("get_atlas_rid"), &Terrain3DVirtualTexture::get_atlas_rid);
	ClassDB::bind_method(D_METHOD("get_indirection_rid"), &Terrain3DVirtualTexture::get_indirection_rid);
	ClassDB::bind_method(D_METHOD("get_indirection_image"), &Terrain3DVirtualTexture::get_indirection_image);
	ClassDB::bind_method(D_METHOD("get_level_count"), &Terrain3DVirtualTexture::get_level_count);
	ClassDB::bind_method(D_METHOD("get_level_size", "mip"), &Terrain3DVirtualTexture::get_level_size);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DVirtualTexture::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &Terrain3DVirtualTexture::reset_stats);
	ClassDB::bind_method(D_METHOD("set_allocation_budget", "pages"), &Terrain3DVirtualTexture::set_allocation_budget);
}
