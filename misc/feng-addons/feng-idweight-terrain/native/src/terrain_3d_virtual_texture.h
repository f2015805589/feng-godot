// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H
#define TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_vt_indirection.h"
#include <set>
#include "terrain_vt.h"

class Terrain3DVirtualTexture;

// A page can be published by either the near-field AVT indirection or the
// world-space SVT indirection. The physical slot is global, while each owner
// retains enough addressing information for eviction and editor inspection.
struct Terrain3DVTPageOwner {
	Terrain3DVirtualTexture *texture = nullptr;
	TerrainVT::VirtualImageKind kind = TerrainVT::VirtualImageKind::AVT;
	int sector_x = 0;
	int sector_y = 0;
	int virtual_x = 0;
	int virtual_y = 0;
	int mip = 0;
	bool world_space = false;
};

// Shared physical residency state for the near and far virtual texture views.
// Addressing remains per Terrain3DVirtualTexture; this object only owns the
// Texture2DArray, global slot IDs, LRU/protection state, budget, and reverse
// owner index used to invalidate the correct indirection on eviction.
struct Terrain3DVTPagePool {
	~Terrain3DVTPagePool() { clear(); }

	GeneratedTexture atlas;
	Ref<Image> atlas_template;
	int page_size = 0;
	int page_border = 0;
	int stored_page_size = 0;
	int page_count = 0;
	Image::Format format = Image::FORMAT_MAX;

	std::vector<uint32_t> lru;
	std::vector<uint8_t> slot_used;
	std::vector<Ref<Image>> authored_pages;
	std::vector<uint8_t> slot_protected;
	std::vector<uint64_t> slot_demand_epoch;
	uint64_t demand_epoch = 0;
	uint64_t residency_revision = 1;
	bool demand_active = false;
	std::vector<std::vector<Terrain3DVTPageOwner>> slot_owners;
	std::vector<uint32_t> free_slots;
	int allocation_budget = -1;
	int alloc_count = 0;
	int evict_count = 0;
	int protected_block_count = 0;
	bool initialized = false;

	bool grow(int p_page_count);
	bool initialize(int p_page_size, int p_page_border, int p_page_count,
			Image::Format p_format);
	void clear();
	bool is_initialized() const { return initialized && atlas.get_rid().is_valid(); }

	int acquire_slot(Terrain3DVirtualTexture *p_requester);
	void touch_slot(uint32_t p_slot);
	void mark_demanded(uint32_t p_slot) { if (demand_active && p_slot < slot_demand_epoch.size()) { slot_demand_epoch[p_slot] = demand_epoch; } }
	void evict_slot(uint32_t p_slot);
	void publish_owner(uint32_t p_slot, const Terrain3DVTPageOwner &p_owner);
	bool remove_owner(uint32_t p_slot, Terrain3DVirtualTexture *p_texture,
			int p_virtual_x, int p_virtual_y, int p_mip);
	bool move_owner(uint32_t p_slot, Terrain3DVirtualTexture *p_texture,
			int p_old_virtual_x, int p_old_virtual_y, int p_old_mip,
			int p_new_virtual_x, int p_new_virtual_y, int p_new_mip);
	void detach_texture(Terrain3DVirtualTexture *p_texture);

	bool write_page(int p_slot, const Ref<Image> &p_page);
	Ref<Image> read_page(int p_slot) const;
	Ref<Image> get_atlas_image() const;
	void set_allocation_budget(int p_pages) { allocation_budget = p_pages; }
	void begin_demand() { ++demand_epoch; demand_active = true; }
	void end_demand() { demand_active = false; }
	Array get_slot_owner_metadata(int p_slot) const;
};

/**
 * Virtual texture runtime: the physical page atlas, the indirection texture and the
 * page slot allocator, built on the Hydra-derived addressing core in `terrain_vt.h`.
 *
 * Layout, following Hydra's AVT:
 *   - A sector (one terrain region) owns a power-of-two block of *virtual* pages,
 *     handed out by `TerrainVT::VirtualImageAtlas` so blocks never overlap.
 *   - A virtual page is 2^mip pages wide at local mip `mip`, so the mip chain halves
 *     the page coordinate each level and a lookup walks up until it finds a resident
 *     slot. That walk is `TerrainVT::try_match_indirection_slot`.
 *   - The indirection texture holds one slot per virtual page per mip. Its mip chain
 *     is built by hand: averaging slot indices with generate_mipmaps() is meaningless,
 *     a coarser texel has to hold a real slot or the invalid marker.
 *   - The physical atlas is a Texture2DArray of `page_count` pages, each
 *     `page_size + 2 * page_border` texels square, allocated LRU with a protected set.
 *
 * This class owns no terrain data. Step 3 (page production) fills pages from the
 * region surface maps and the shader samples through the indirection.
 */
class Terrain3DVirtualTexture : public Object {
	GDCLASS(Terrain3DVirtualTexture, Object);
	CLASS_NAME();

public:
	// Hydra AVT defaults. Every one of these can be changed before initialize(), which
	// is what the GPU readback test does to keep the atlas small.
	static inline const int DEFAULT_PAGE_SIZE = 256;
	static inline const int DEFAULT_PAGE_BORDER = 4;
	static inline const int DEFAULT_PAGE_COUNT = 64;
	static inline const int DEFAULT_INDIRECTION_SIZE = 512;
	static inline const int DEFAULT_MINIMAL_BLOCK = 4;
	static inline const uint32_t INVALID_SLOT = TerrainVT::INVALID_PHYSICAL_PAGE_SLOT;

private:
	// Configuration
	int _page_size = DEFAULT_PAGE_SIZE;
	int _page_border = DEFAULT_PAGE_BORDER;
	int _page_count = DEFAULT_PAGE_COUNT;
	// Also the virtual image atlas size: sectors are allocated blocks of the mip 0
	// page space the indirection covers, so the two are the same grid.
	int _indirection_size = DEFAULT_INDIRECTION_SIZE;
	int _minimal_block = DEFAULT_MINIMAL_BLOCK;
	// R16 by default: this carries the packed id/weight surface map.
	Image::Format _format = Image::Format(39);
	// World-space mode. The page grid is a regular world grid centred on the origin
	// instead of one allocated block per sector, which is what the far field (SVT)
	// needs: a page's block origin is a pure function of its coordinate, so there is
	// nothing to allocate, pack or register. VirtualImageAtlas is skipped entirely.
	bool _world_space = false;
	// Coarsest level the world grid may publish. The chain is capped one level below
	// the root because the root texel would straddle the grid's centre offset. -1
	// means "auto": resolved to the cap on initialize().
	int _world_max_local_mip = -1;

	// The physical atlas and allocator are shared by the near/far views. This
	// object retains only the derived size for page validation.
	std::shared_ptr<Terrain3DVTPagePool> _page_pool;
	int _stored_page_size = 0;

	// Indirection. `_bytes` is the single source of truth for the whole mip chain,
	// laid out exactly as Image::create_from_data expects it; `_levels[m]` starts at
	// the mip's byte offset and holds `_level_sizes[m]` texels.
	GeneratedTexture _indirection; // Compatibility renderer fallback.
	Ref<Terrain3DVTIndirection> _indirection_gpu;
	std::set<uint64_t> _dirty_tiles;
	uint64_t _indirection_uploaded_bytes = 0;
	Ref<Image> _indirection_image;
	PackedByteArray _bytes;
	std::vector<int> _level_offsets;
	std::vector<int> _level_sizes;
	int _level_count = 0;
	bool _indirection_dirty = true;

	// Sector -> virtual block allocation.
	std::unique_ptr<TerrainVT::VirtualImageAtlas> _virtual_atlas;
	// The exact owner the atlas handed out per sector. VirtualImageOwner carries a
	// generation counter, so removal has to present the original owner, not a
	// reconstructed one.
	std::map<uint64_t, TerrainVT::VirtualImageOwner> _sector_owners;
	static uint64_t _sector_key(const Vector2i &p_sector) {
		return (uint64_t(uint32_t(p_sector.x)) << 32) | uint64_t(uint32_t(p_sector.y));
	}

	// Diagnostics
	int _hit_count = 0;
	int _miss_count = 0;
	int _commit_count = 0;
	int _page_write_count = 0;
	bool _material_cache_mode = false;

	uint32_t _read_level(int p_x, int p_y, int p_mip) const;
	void _write_level(int p_x, int p_y, int p_mip, uint32_t p_slot);
	void _touch_slot(uint32_t p_slot);
	int _acquire_slot();
	void _invalidate_pool_owner(uint32_t p_slot, const Terrain3DVTPageOwner &p_owner);
	void _release_sector_pages(const Vector2i &p_sector, const TerrainVT::ImageInfo &p_info);
	bool _remap_sector_pages(const Vector2i &p_sector, const TerrainVT::ImageInfo &p_old_info,
			const TerrainVT::ImageInfo &p_new_info);
	// Shared by the sector and world-space paths: allocate on a miss, publish the
	// entry and report whether the page had to be produced.
	int _request_virtual(int p_virtual_x, int p_virtual_y, int p_local_mip, int p_max_local_mip,
			const Terrain3DVTPageOwner &p_owner, bool *r_miss);
	bool _virtual_to_physical(int p_sector_x, int p_sector_y, int p_local_mip,
			int p_page_x, int p_page_y, int &r_virtual_x, int &r_virtual_y) const;
	int _sector_max_local_mip(int p_sector_x, int p_sector_y) const;

public:
	Terrain3DVirtualTexture() : _page_pool(std::make_shared<Terrain3DVTPagePool>()) {}
	~Terrain3DVirtualTexture() { clear(); }

	// Configuration, valid before initialize().
	void set_page_size(const int p_size);
	int get_page_size() const { return _page_size; }
	void set_page_border(const int p_border);
	int get_page_border() const { return _page_border; }
	void set_page_count(const int p_count);
	bool grow_capacity(int p_count);
	int get_page_count() const { return _page_count; }
	void set_indirection_size(const int p_size);
	int get_indirection_size() const { return _indirection_size; }
	void set_minimal_block(const int p_size);
	int get_minimal_block() const { return _minimal_block; }
	void set_format(const Image::Format p_format);
	Image::Format get_format() const { return _format; }

	// Builds the atlas and the indirection. Safe to call again after a settings change.
	Error initialize();
	void clear();
	bool is_initialized() const {
		return _page_pool && _page_pool->is_initialized() && (_indirection_gpu.is_valid() || _indirection.get_rid().is_valid());
	}

	// Native-only sharing hook used by Terrain3D to give both compatibility views
	// one physical page pool. The indirection texture remains owned by this object.
	static std::shared_ptr<Terrain3DVTPagePool> create_page_pool() {
		return std::make_shared<Terrain3DVTPagePool>();
	}
	void set_page_pool(const std::shared_ptr<Terrain3DVTPagePool> &p_pool);
	void share_physical_pool(Terrain3DVirtualTexture *p_source);
	std::shared_ptr<Terrain3DVTPagePool> get_page_pool() const { return _page_pool; }

	// Sectors
	bool register_sector(const Vector2i &p_sector, const int p_virtual_image_size);
	// Reallocates a registered POT block and remaps its cached exact pages. A
	// failed allocation leaves the original block and page mappings untouched.
	bool resize_sector(const Vector2i &p_sector, const int p_virtual_image_size);
	bool unregister_sector(const Vector2i &p_sector);
	bool has_sector(const Vector2i &p_sector) const;
	int get_sector_block_size(const Vector2i &p_sector) const;
	int get_sector_block_origin_x(const Vector2i &p_sector) const;
	int get_sector_block_origin_y(const Vector2i &p_sector) const;

	// World-space mode. Page coordinates are mip 0 pages of a world grid centred on
	// the origin, so world page (0,0) starts at world (0,0) and negative coordinates
	// are valid. `world_page_to_virtual` is the one formula the shader also uses.
	void set_world_space(const bool p_enabled) { _world_space = p_enabled; }
	bool is_world_space() const { return _world_space; }
	void set_world_max_mip(const int p_mip);
	int get_world_max_mip() const { return _world_max_local_mip; }
	// Pages of the grid on each side of the origin, i.e. the indirection's half size.
	int get_world_grid_half() const { return _indirection_size >> 1; }
	void world_page_to_virtual(int p_page_x, int p_page_y, int p_local_mip, int &r_virtual_x,
			int &r_virtual_y) const;
	// Binding-friendly form: godot-cpp cannot marshal reference out-parameters.
	Vector2i get_world_page_virtual(int p_page_x, int p_page_y, int p_local_mip) const;
	int request_world_page(int p_page_x, int p_page_y, int p_local_mip);
	// Same, but reports whether the page had to be allocated, so a producer only
	// fills the pages that are actually new.
	int request_world_page_internal(int p_page_x, int p_page_y, int p_local_mip, bool *r_miss);
	int lookup_world_page(int p_page_x, int p_page_y, int p_local_mip) const;

	// Pages. `request_page` allocates and publishes a slot on a miss; `lookup_page`
	// only walks the mip chain. Both return -1 when there is nothing to serve.
	int request_page(const Vector2i &p_sector, const int p_local_mip, const int p_page_x, const int p_page_y);
	// Same, but reports whether the page had to be allocated, so a producer only
	// fills the pages that are actually new.
	int request_page_internal(const Vector2i &p_sector, const int p_local_mip,
			const int p_page_x, const int p_page_y, bool *r_miss);
	int lookup_page(const Vector2i &p_sector, const int p_local_mip, const int p_page_x, const int p_page_y) const;
	int lookup_page_exact(const Vector2i &p_sector, int p_mip, int p_x, int p_y) const;
	int lookup_virtual(const int p_virtual_x, const int p_virtual_y, const int p_mip, const int p_max_mip) const;
	// Request by indirection coordinate, for a caller that already knows it (the root
	// pyramid walks whole levels). Only valid in world-space mode.
	int request_virtual_page(const int p_virtual_x, const int p_virtual_y, const int p_local_mip);
	int request_virtual_page_internal(const int p_virtual_x, const int p_virtual_y,
			const int p_local_mip, bool *r_miss);
	// Release: invalidates exactly the entries that publish the page and returns its
	// slot to the free list, so an edited region's pages are re-produced by the next
	// demand pass instead of serving stale material.
	bool release_page(const Vector2i &p_sector, const int p_local_mip, const int p_page_x,
			const int p_page_y);
	bool release_world_page(const int p_page_x, const int p_page_y, const int p_local_mip);

	// Page content
	void set_material_cache_mode(bool p_enabled) { _material_cache_mode = p_enabled; }
	bool write_page(const int p_slot, const Ref<Image> &p_page);
	Ref<Image> read_page(const int p_slot) const;
	Ref<Image> get_atlas_image() const;

	// Slot allocator
	void protect_page(const int p_slot, const bool p_protected);
	bool is_page_protected(const int p_slot) const;
	bool is_page_used(const int p_slot) const;
	int get_slot_owner_count(const int p_slot) const;
	// CPU metadata for the shared physical slot, including owner field, sector,
	// virtual coordinate and mip. The array is empty for an invalid slot.
	Array get_slot_owner_metadata(const int p_slot) const;
	Array get_page_metadata(const int p_slot) const { return get_slot_owner_metadata(p_slot); }

	// Uploads the indirection if it changed.
	void commit();
	// True while a committed indirection change has not reached the render thread yet.
	bool has_pending_indirection() const { return _indirection_gpu.is_valid() && _indirection_gpu->has_pending_upload(); }

	RID get_atlas_rid() const { return _page_pool ? _page_pool->atlas.get_rid() : RID(); }
	RID get_indirection_rid() const { return _indirection_gpu.is_valid() ? _indirection_gpu->get_rid() : _indirection.get_rid(); }
	// CPU copy of the full mip chain, laid out as Image::create_from_data expects.
	Ref<Image> get_indirection_image() const { return Image::create_from_data(_indirection_size, _indirection_size, true, Image::FORMAT_RF, _bytes); }
	int get_level_count() const { return _level_count; }
	int get_level_size(const int p_mip) const;
	// Slot published at an exact mip, with no mip-chain walk. For tests and diagnostics.
	int get_indirection_slot(const int p_virtual_x, const int p_virtual_y, const int p_mip) const;

	Dictionary get_stats() const;
	void reset_stats();
	// Negative is unlimited. Hits still refresh the LRU when no allocations remain.
	void set_allocation_budget(int p_pages);

protected:
	static void _bind_methods();
	friend struct Terrain3DVTPagePool;
};

#endif // TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H
