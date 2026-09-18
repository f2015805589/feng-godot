// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DVirtualTexture, part 3 of 3: addressing - the mip-chain walk and the request entry points.

// One of three files that define a view. `_request_virtual()` is the shared core of both
// addressing modes: a hit only touches the LRU, a miss reserves a slot, publishes it at that
// exact level and records the reverse mapping, so eviction can invalidate precisely the entries
// that still point at it. Around it are the two coordinate systems - the near field's sector-local
// pages, whose block origin lives in the sector half, and the far field's world grid, which needs
// no allocator because a page's block origin is a pure function of its coordinate.
//
// `lookup_virtual()` is the walk itself: it hands `terrain_vt.h`'s `try_match_indirection_slot()`
// a reader for one level and lets it find the nearest level that holds a slot, which is how a
// coarse parent answers for a missing child. `set_world_max_mip()` and `world_page_to_virtual()`
// are here rather than with the settings because the shader uses that exact formula: the grid is
// centred on the origin, and the centre offset is a multiple of every level's scale up to the cap.
//
// The other two: `terrain_3d_virtual_texture.cpp` (the view object and its indirection table)
// and `terrain_3d_virtual_texture_sector.cpp` (the sector blocks).

#include "terrain_3d_virtual_texture.h"

using namespace TerrainVT;

///////////////////////////
// Private Functions
///////////////////////////

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
	// The entry that names this slot now exists, so the reservation becomes final: only here
	// is a chosen LRU victim evicted. A failure before this point leaves it resident.
	if (_page_pool) {
		_page_pool->commit_slot(uint32_t(slot));
	}
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

///////////////////////////
// Public Functions
///////////////////////////

int Terrain3DVirtualTexture::lookup_page_exact(const Vector2i &p_sector, int p_mip, int p_x, int p_y) const {
	int x, y;
	if (!_virtual_to_physical(p_sector.x, p_sector.y, p_mip, p_x, p_y, x, y)) { return -1; }
	return lookup_virtual(x, y, p_mip, p_mip);
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
