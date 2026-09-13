// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_virtual_texture.h"

#include "logger.h"

#include <algorithm>
#include <cstring>

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

///////////////////////////
// Shared page pool
///////////////////////////

bool Terrain3DVTPagePool::initialize(const int p_page_size, const int p_page_border,
		const int p_page_count, const Image::Format p_format) {
	if (is_initialized()) {
		return page_size == p_page_size && page_border == p_page_border &&
				page_count == p_page_count && format == p_format;
	}
	const int pixel_size = _format_pixel_size(p_format);
	if (pixel_size == 0 || p_page_size <= 0 || p_page_border < 0 || p_page_count <= 0 ||
			p_page_count > int(SLOT_MASK)) {
		return false;
	}
	page_size = p_page_size;
	page_border = p_page_border;
	stored_page_size = page_size + 2 * page_border;
	page_count = p_page_count;
	format = p_format;

	PackedByteArray zeros;
	zeros.resize(int64_t(stored_page_size) * stored_page_size * pixel_size);
	atlas_template = Image::create_from_data(stored_page_size, stored_page_size, false, format, zeros);
	if (atlas_template.is_null() || !atlas.ensure_layers(atlas_template, page_count)) {
		atlas.clear();
		atlas_template.unref();
		page_size = 0;
		page_border = 0;
		stored_page_size = 0;
		page_count = 0;
		format = Image::FORMAT_MAX;
		return false;
	}

	lru.clear();
	slot_used.assign(page_count, 0);
	slot_protected.assign(page_count, 0);
	slot_demand_epoch.assign(page_count, 0);
	slot_owners.assign(page_count, std::vector<Terrain3DVTPageOwner>());
	free_slots.clear();
	for (int slot = page_count - 1; slot >= 0; slot--) {
		free_slots.push_back(uint32_t(slot));
	}
	alloc_count = 0;
	evict_count = 0;
	protected_block_count = 0;
	initialized = true;
	return true;
}

void Terrain3DVTPagePool::clear() {
	// Texture owners detach before the final shared_ptr release. Clearing the
	// reverse index here still makes the destructor safe if a caller explicitly
	// tears down a pool after all views have already gone away.
	atlas.clear();
	atlas_template.unref();
	lru.clear();
	slot_used.clear();
	slot_protected.clear();
	slot_demand_epoch.clear();
	demand_epoch = 0;
	demand_active = false;
	slot_owners.clear();
	free_slots.clear();
	page_size = 0;
	page_border = 0;
	stored_page_size = 0;
	page_count = 0;
	format = Image::FORMAT_MAX;
	allocation_budget = -1;
	initialized = false;
}

void Terrain3DVTPagePool::touch_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count)) {
		return;
	}
	if (demand_active) { slot_demand_epoch[p_slot] = demand_epoch; }
	for (size_t i = 0; i < lru.size(); i++) {
		if (lru[i] == p_slot) {
			lru.erase(lru.begin() + i);
			break;
		}
	}
	lru.insert(lru.begin(), p_slot);
}

int Terrain3DVTPagePool::acquire_slot(Terrain3DVirtualTexture *p_requester) {
	(void)p_requester;
	if (!is_initialized() || allocation_budget == 0) {
		return -1;
	}
	uint32_t slot = INVALID_PHYSICAL_PAGE_SLOT;
	if (!free_slots.empty()) {
		slot = free_slots.back();
		free_slots.pop_back();
	} else {
		// Nothing free: evict the least recently used unprotected page. Entries
		// left in LRU by release/detach are skipped because they are already free.
		for (int i = int(lru.size()) - 1; i >= 0; i--) {
			const uint32_t candidate = lru[i];
			if (candidate >= uint32_t(page_count) || !slot_used[candidate] ||
					slot_protected[candidate]) {
				continue;
			}
			// An oversubscribed working set must not evict its own still-needed
			// pages every tick. Allow one complete demand pass before considering
			// a resident unused, independent of request order across AVT and SVT.
			// Misses use shader fallback until capacity becomes available. Explicit
			// offline baking and standalone cache APIs retain ordinary LRU behavior.
			if (demand_active && slot_demand_epoch[candidate] != 0 &&
					demand_epoch - slot_demand_epoch[candidate] <= 1) {
				continue;
			}
			slot = candidate;
			evict_slot(slot);
			break;
		}
		if (slot == INVALID_PHYSICAL_PAGE_SLOT) {
			protected_block_count++;
			return -1;
		}
	}
	slot_used[slot] = 1;
	touch_slot(slot);
	alloc_count++;
	if (allocation_budget > 0) {
		allocation_budget--;
	}
	return int(slot);
}

void Terrain3DVTPagePool::evict_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count) || !slot_used[p_slot]) {
		return;
	}
	const std::vector<Terrain3DVTPageOwner> owners = slot_owners[p_slot];
	for (const Terrain3DVTPageOwner &owner : owners) {
		if (owner.texture) {
			owner.texture->_invalidate_pool_owner(p_slot, owner);
		}
	}
	slot_owners[p_slot].clear();
	slot_used[p_slot] = 0;
	evict_count++;
}

void Terrain3DVTPagePool::publish_owner(const uint32_t p_slot,
		const Terrain3DVTPageOwner &p_owner) {
	if (p_slot >= uint32_t(page_count) || !slot_used[p_slot] || !p_owner.texture) {
		return;
	}
	// A caller can republish after a remap. Avoid duplicate reverse entries while
	// retaining the exact owner metadata for cross-view eviction.
	for (const Terrain3DVTPageOwner &owner : slot_owners[p_slot]) {
		if (owner.texture == p_owner.texture && owner.virtual_x == p_owner.virtual_x &&
				owner.virtual_y == p_owner.virtual_y && owner.mip == p_owner.mip) {
			return;
		}
	}
	slot_owners[p_slot].push_back(p_owner);
}

bool Terrain3DVTPagePool::remove_owner(const uint32_t p_slot,
		Terrain3DVirtualTexture *p_texture, const int p_virtual_x, const int p_virtual_y,
		const int p_mip) {
	if (p_slot >= uint32_t(page_count) || !p_texture) {
		return false;
	}
	std::vector<Terrain3DVTPageOwner> &owners = slot_owners[p_slot];
	for (auto it = owners.begin(); it != owners.end(); ++it) {
		if (it->texture == p_texture && it->virtual_x == p_virtual_x &&
				it->virtual_y == p_virtual_y && it->mip == p_mip) {
			owners.erase(it);
			if (owners.empty() && slot_used[p_slot]) {
				slot_used[p_slot] = 0;
				slot_protected[p_slot] = 0;
				slot_demand_epoch[p_slot] = 0;
				free_slots.push_back(p_slot);
			}
			return true;
		}
	}
	return false;
}

bool Terrain3DVTPagePool::move_owner(const uint32_t p_slot,
		Terrain3DVirtualTexture *p_texture, const int p_old_virtual_x,
		const int p_old_virtual_y, const int p_old_mip, const int p_new_virtual_x,
		const int p_new_virtual_y, const int p_new_mip) {
	if (p_slot >= uint32_t(page_count) || !p_texture) {
		return false;
	}
	for (Terrain3DVTPageOwner &owner : slot_owners[p_slot]) {
		if (owner.texture == p_texture && owner.virtual_x == p_old_virtual_x &&
				owner.virtual_y == p_old_virtual_y && owner.mip == p_old_mip) {
			owner.virtual_x = p_new_virtual_x;
			owner.virtual_y = p_new_virtual_y;
			owner.mip = p_new_mip;
			return true;
		}
	}
	return false;
}

void Terrain3DVTPagePool::detach_texture(Terrain3DVirtualTexture *p_texture) {
	if (!p_texture) {
		return;
	}
	for (uint32_t slot = 0; slot < uint32_t(page_count); slot++) {
		std::vector<Terrain3DVTPageOwner> &owners = slot_owners[slot];
		owners.erase(std::remove_if(owners.begin(), owners.end(),
				[p_texture](const Terrain3DVTPageOwner &owner) {
					return owner.texture == p_texture;
				}), owners.end());
		if (owners.empty() && slot_used[slot]) {
			slot_used[slot] = 0;
			slot_protected[slot] = 0;
			slot_demand_epoch[slot] = 0;
			free_slots.push_back(slot);
		}
	}
}

bool Terrain3DVTPagePool::write_page(const int p_slot, const Ref<Image> &p_page) {
	if (!is_initialized() || p_slot < 0 || p_slot >= page_count || p_page.is_null() ||
			p_page->get_width() != stored_page_size || p_page->get_height() != stored_page_size ||
			p_page->get_format() != format) {
		return false;
	}
	atlas.update(p_page, p_slot);
	return true;
}

Ref<Image> Terrain3DVTPagePool::read_page(const int p_slot) const {
	if (!is_initialized() || p_slot < 0 || p_slot >= page_count) {
		return Ref<Image>();
	}
	return RS->texture_2d_layer_get(atlas.get_rid(), p_slot);
}

Ref<Image> Terrain3DVTPagePool::get_atlas_image() const {
	if (!is_initialized()) {
		return Ref<Image>();
	}
	return RS->texture_2d_layer_get(atlas.get_rid(), 0);
}

Array Terrain3DVTPagePool::get_slot_owner_metadata(const int p_slot) const {
	Array result;
	if (!is_initialized() || p_slot < 0 || p_slot >= page_count) {
		return result;
	}
	for (const Terrain3DVTPageOwner &owner : slot_owners[p_slot]) {
		Dictionary item;
		item["kind"] = int(owner.kind);
		item["owner_type"] = owner.kind == VirtualImageKind::SVT ? String("svt") : String("avt");
		item["world_space"] = owner.world_space;
		item["sector"] = Vector2i(owner.sector_x, owner.sector_y);
		item["sector_x"] = owner.sector_x;
		item["sector_y"] = owner.sector_y;
		item["virtual"] = Vector2i(owner.virtual_x, owner.virtual_y);
		item["virtual_x"] = owner.virtual_x;
		item["virtual_y"] = owner.virtual_y;
		item["mip"] = owner.mip;
		result.push_back(item);
	}
	return result;
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

void Terrain3DVirtualTexture::_release_sector_pages(const Vector2i &p_sector,
		const ImageInfo &p_info) {
	if (!_page_pool) {
		return;
	}
	// Traverse resident owners, not the potentially millions of virtual addresses.
	for (uint32_t slot = 0; slot < _page_pool->slot_owners.size(); ++slot) {
		const auto owners = _page_pool->slot_owners[slot];
		for (const Terrain3DVTPageOwner &owner : owners) {
			if (owner.texture != this || owner.sector_x != p_sector.x || owner.sector_y != p_sector.y) { continue; }
			_write_level(owner.virtual_x, owner.virtual_y, owner.mip, INVALID_SLOT);
			_page_pool->remove_owner(slot, this, owner.virtual_x, owner.virtual_y, owner.mip);
		}
	}
}

bool Terrain3DVirtualTexture::_remap_sector_pages(const Vector2i &p_sector,
		const ImageInfo &p_old_info, const ImageInfo &p_new_info) {
	if (!_page_pool) {
		return false;
	}
	struct CachedPage {
		uint32_t slot = INVALID_SLOT;
		int virtual_x = 0;
		int virtual_y = 0;
		int mip = 0;
		int local_x = 0;
		int local_y = 0;
	};
	std::vector<CachedPage> cached;
	const int old_max_mip = log2_power_of_two(p_old_info.size);
	for (uint32_t slot = 0; slot < _page_pool->slot_owners.size(); ++slot) {
		for (const Terrain3DVTPageOwner &owner : _page_pool->slot_owners[slot]) {
			if (owner.texture != this || owner.sector_x != p_sector.x || owner.sector_y != p_sector.y) { continue; }
			cached.push_back({slot, owner.virtual_x, owner.virtual_y, owner.mip,
					owner.virtual_x - (p_old_info.origin_x >> owner.mip), owner.virtual_y - (p_old_info.origin_y >> owner.mip)});
		}
	}

	// Remove every old exact entry first. This also handles an allocator that
	// happens to return the same virtual block for the resized image.
	for (const CachedPage &page : cached) {
		_write_level(page.virtual_x, page.virtual_y, page.mip, INVALID_SLOT);
	}

	const int new_max_mip = log2_power_of_two(p_new_info.size);
	const TerrainVT::VirtualImageKind kind = _world_space ? VirtualImageKind::SVT : VirtualImageKind::AVT;
	for (const CachedPage &page : cached) {
		// A page represents a fixed world footprint, not a fixed mip number.
		// Doubling the virtual image moves the same payload from mip L to L+1.
		// Keeping L would reinterpret its contents over a quarter of the area.
		const int new_mip = page.mip + new_max_mip - old_max_mip;
		const bool overlaps = new_mip >= 0 && new_mip <= new_max_mip;
		if (!overlaps) {
			_page_pool->remove_owner(page.slot, this, page.virtual_x, page.virtual_y, page.mip);
			continue;
		}
		const int new_virtual_x = (p_new_info.origin_x >> new_mip) + page.local_x;
		const int new_virtual_y = (p_new_info.origin_y >> new_mip) + page.local_y;
		_write_level(new_virtual_x, new_virtual_y, new_mip, page.slot);
		if (!_page_pool->move_owner(page.slot, this, page.virtual_x, page.virtual_y,
				page.mip, new_virtual_x, new_virtual_y, new_mip)) {
			Terrain3DVTPageOwner owner;
			owner.texture = this;
			owner.kind = kind;
			owner.sector_x = p_sector.x;
			owner.sector_y = p_sector.y;
			owner.virtual_x = new_virtual_x;
			owner.virtual_y = new_virtual_y;
			owner.mip = new_mip;
			owner.world_space = _world_space;
			_page_pool->publish_owner(page.slot, owner);
		}
	}
	return true;
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
		// Idempotent for the same block size. Keep the historical refusal for a
		// changed size; callers that intentionally adapt a region use resize_sector,
		// which preserves cached pages while moving the virtual block.
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

bool Terrain3DVirtualTexture::resize_sector(const Vector2i &p_sector,
		const int p_virtual_image_size) {
	if (!_virtual_atlas) {
		LOG(ERROR, "resize_sector before initialize()");
		return false;
	}
	const auto found = _sector_owners.find(_sector_key(p_sector));
	if (found == _sector_owners.end()) {
		return false;
	}
	if (!_virtual_atlas->is_valid_image_size(p_virtual_image_size)) {
		LOG(WARN, "Sector resize block size ", p_virtual_image_size,
				" must be a power of two within [", _minimal_block, ", ", _indirection_size, "]");
		return false;
	}
	ImageInfo old_info;
	if (!_virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, old_info)) {
		return false;
	}
	if (old_info.size == p_virtual_image_size) {
		return true;
	}
	VirtualImageOwner owner;
	ImageInfo allocator_old_info;
	ImageInfo new_info;
	if (!_virtual_atlas->try_resize_avt_image(p_sector.x, p_sector.y, p_virtual_image_size,
				owner, allocator_old_info, new_info)) {
		LOG(DEBUG, "Virtual image atlas could not resize sector ", p_sector);
		return false;
	}
	_sector_owners[_sector_key(p_sector)] = owner;
	return _remap_sector_pages(p_sector, old_info, new_info);
}

bool Terrain3DVirtualTexture::unregister_sector(const Vector2i &p_sector) {
	if (!_virtual_atlas) {
		return false;
	}
	const auto found = _sector_owners.find(_sector_key(p_sector));
	if (found == _sector_owners.end()) {
		return false;
	}
	ImageInfo info;
	if (_virtual_atlas->try_get_avt_image_info(p_sector.x, p_sector.y, info)) {
		_release_sector_pages(p_sector, info);
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

// Shared core of both addressing modes: a hit only touches the LRU, a miss allocates a
// slot, publishes it at this exact level and records the reverse mapping so eviction can
// invalidate precisely the entries that still point at it.
int Terrain3DVirtualTexture::_request_virtual(const int p_virtual_x, const int p_virtual_y,
		const int p_local_mip, const int p_max_local_mip, const Terrain3DVTPageOwner &p_owner,
		bool *r_miss) {
	if (r_miss) {
		*r_miss = false;
	}
	if (p_local_mip < 0 || p_local_mip > p_max_local_mip || p_virtual_x < 0 || p_virtual_y < 0 ||
			p_virtual_x >= get_level_size(p_local_mip) || p_virtual_y >= get_level_size(p_local_mip)) {
		return -1;
	}
	// A coarse fallback is usable for sampling, but is not a hit for production:
	// otherwise a previously cached root prevents finer pages from ever arriving.
	const uint32_t existing = _read_level(p_virtual_x, p_virtual_y, p_local_mip);
	if (existing != INVALID_SLOT) {
		_hit_count++;
		_touch_slot(uint32_t(existing));
		return existing;
	}
	_miss_count++;
	const int slot = _acquire_slot();
	if (slot < 0) {
		return -1;
	}
	_write_level(p_virtual_x, p_virtual_y, p_local_mip, uint32_t(slot));
	Terrain3DVTPageOwner owner = p_owner;
	owner.texture = this;
	owner.virtual_x = p_virtual_x;
	owner.virtual_y = p_virtual_y;
	owner.mip = p_local_mip;
	if (_page_pool) {
		_page_pool->publish_owner(uint32_t(slot), owner);
	}
	if (r_miss) {
		*r_miss = true;
	}
	return slot;
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
	Terrain3DVTPageOwner owner;
	owner.kind = VirtualImageKind::AVT;
	owner.sector_x = p_sector.x;
	owner.sector_y = p_sector.y;
	owner.world_space = false;
	return _request_virtual(virtual_x, virtual_y, p_local_mip,
			_sector_max_local_mip(p_sector.x, p_sector.y), owner, r_miss);
}

void Terrain3DVirtualTexture::set_world_max_mip(const int p_mip) {
	_world_max_local_mip = MAX(-1, p_mip);
}

// World page -> indirection texel. The grid is centred on the origin, so the centre
// offset is added before the mip shift; the offset is a multiple of every level's
// scale up to the cap, which is what makes "publish at mip m" land on the texel that
// covers the page. The shader uses this exact formula.
void Terrain3DVirtualTexture::world_page_to_virtual(int p_page_x, int p_page_y, int p_local_mip,
		int &r_virtual_x, int &r_virtual_y) const {
	const int half = _indirection_size >> 1;
	r_virtual_x = (p_page_x + half) >> p_local_mip;
	r_virtual_y = (p_page_y + half) >> p_local_mip;
}

Vector2i Terrain3DVirtualTexture::get_world_page_virtual(int p_page_x, int p_page_y,
		int p_local_mip) const {
	int virtual_x = 0;
	int virtual_y = 0;
	world_page_to_virtual(p_page_x, p_page_y, p_local_mip, virtual_x, virtual_y);
	return Vector2i(virtual_x, virtual_y);
}

int Terrain3DVirtualTexture::request_world_page(const int p_page_x, const int p_page_y,
		const int p_local_mip) {
	return request_world_page_internal(p_page_x, p_page_y, p_local_mip, nullptr);
}

int Terrain3DVirtualTexture::request_world_page_internal(int p_page_x, int p_page_y, int p_local_mip,
		bool *r_miss) {
	if (!_world_space || p_local_mip < 0 || p_local_mip > _world_max_local_mip) {
		if (r_miss) {
			*r_miss = false;
		}
		return -1;
	}
	int virtual_x = 0;
	int virtual_y = 0;
	world_page_to_virtual(p_page_x, p_page_y, p_local_mip, virtual_x, virtual_y);
	Terrain3DVTPageOwner owner;
	owner.kind = VirtualImageKind::SVT;
	owner.sector_x = p_page_x;
	owner.sector_y = p_page_y;
	owner.world_space = true;
	return _request_virtual(virtual_x, virtual_y, p_local_mip, _world_max_local_mip, owner, r_miss);
}

int Terrain3DVirtualTexture::lookup_world_page(int p_page_x, int p_page_y, int p_local_mip) const {
	if (!_world_space || p_local_mip < 0 || p_local_mip > _world_max_local_mip) {
		return -1;
	}
	int virtual_x = 0;
	int virtual_y = 0;
	world_page_to_virtual(p_page_x, p_page_y, p_local_mip, virtual_x, virtual_y);
	return lookup_virtual(virtual_x, virtual_y, p_local_mip, _world_max_local_mip);
}

int Terrain3DVirtualTexture::request_virtual_page(const int p_virtual_x, const int p_virtual_y,
		const int p_local_mip) {
	return request_virtual_page_internal(p_virtual_x, p_virtual_y, p_local_mip, nullptr);
}

int Terrain3DVirtualTexture::request_virtual_page_internal(const int p_virtual_x,
		const int p_virtual_y, const int p_local_mip, bool *r_miss) {
	if (!_world_space || p_local_mip < 0 || p_local_mip > _world_max_local_mip) {
		if (r_miss) {
			*r_miss = false;
		}
		return -1;
	}
	Terrain3DVTPageOwner owner;
	owner.kind = VirtualImageKind::SVT;
	owner.world_space = true;
	return _request_virtual(p_virtual_x, p_virtual_y, p_local_mip, _world_max_local_mip, owner, r_miss);
}

bool Terrain3DVirtualTexture::release_page(const Vector2i &p_sector, const int p_local_mip,
		const int p_page_x, const int p_page_y) {
	int virtual_x = 0;
	int virtual_y = 0;
	if (!_virtual_to_physical(p_sector.x, p_sector.y, p_local_mip, p_page_x, p_page_y, virtual_x,
				virtual_y)) {
		return false;
	}
	const uint32_t slot = _read_level(virtual_x, virtual_y, p_local_mip);
	if (slot == INVALID_SLOT) {
		return false;
	}
	_write_level(virtual_x, virtual_y, p_local_mip, INVALID_SLOT);
	return _page_pool && _page_pool->remove_owner(slot, this, virtual_x, virtual_y, p_local_mip);
}

bool Terrain3DVirtualTexture::release_world_page(const int p_page_x, const int p_page_y,
		const int p_local_mip) {
	if (!_world_space || p_local_mip < 0 || p_local_mip > _world_max_local_mip) {
		return false;
	}
	int virtual_x = 0;
	int virtual_y = 0;
	world_page_to_virtual(p_page_x, p_page_y, p_local_mip, virtual_x, virtual_y);
	const uint32_t slot = _read_level(virtual_x, virtual_y, p_local_mip);
	if (slot == INVALID_SLOT) {
		return false;
	}
	_write_level(virtual_x, virtual_y, p_local_mip, INVALID_SLOT);
	return _page_pool && _page_pool->remove_owner(slot, this, virtual_x, virtual_y, p_local_mip);
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
	if (!_page_pool->write_page(p_slot, p_page)) {
		return false;
	}
	_page_write_count++;
	return true;
}

Ref<Image> Terrain3DVirtualTexture::read_page(const int p_slot) const {
	return _page_pool ? _page_pool->read_page(p_slot) : Ref<Image>();
}

Ref<Image> Terrain3DVirtualTexture::get_atlas_image() const {
	return _page_pool ? _page_pool->get_atlas_image() : Ref<Image>();
}

void Terrain3DVirtualTexture::protect_page(const int p_slot, const bool p_protected) {
	if (!_page_pool || p_slot < 0 || p_slot >= _page_pool->page_count) {
		return;
	}
	_page_pool->slot_protected[p_slot] = p_protected ? 1 : 0;
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
		if (_indirection_gpu.is_valid() && _indirection_gpu->needs_retry()) {
			_indirection_gpu->submit({});
		}
		return;
	}
	if (RS->get_rendering_device()) {
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
