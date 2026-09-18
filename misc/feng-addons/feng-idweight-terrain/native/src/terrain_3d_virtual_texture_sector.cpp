// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DVirtualTexture, part 2 of 3: the sector blocks of the near field's indirection grid.

// One of three files that define a view. A sector is a block of the indirection grid allocated
// by `VirtualImageAtlas`; this file is the view's side of that contract - register, resize and
// unregister a sector, answer where its block starts and how big it is, and translate a
// sector-local page coordinate into a virtual texel (`_virtual_to_physical()`, which the lookup
// half calls as well).
//
// Its two maintenance passes each carry an invariant. `_release_sector_pages()` walks the
// resident owners rather than the potentially millions of virtual addresses a block can span.
// `_remap_sector_pages()` keeps a page's *world footprint* across a resize: a doubling of the
// block moves the same payload from mip L to L+1, because keeping L would reinterpret its
// contents over a quarter of the area.
//
// The other two: `terrain_3d_virtual_texture.cpp` (the view object and its indirection table)
// and `terrain_3d_virtual_texture_lookup.cpp` (addressing and the request entry points).

#include "terrain_3d_virtual_texture.h"

#include "logger.h"

#include <algorithm>

using namespace TerrainVT;

///////////////////////////
// Private Functions
///////////////////////////

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
