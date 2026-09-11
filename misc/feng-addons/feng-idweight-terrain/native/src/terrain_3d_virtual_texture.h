// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H
#define TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H

#include <map>
#include <memory>
#include <vector>

#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_vt.h"

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

	// Physical page atlas, page_count layers of stored_page_size squared.
	GeneratedTexture _atlas;
	Ref<Image> _atlas_template;
	int _stored_page_size = 0;

	// Indirection. `_bytes` is the single source of truth for the whole mip chain,
	// laid out exactly as Image::create_from_data expects it; `_levels[m]` starts at
	// the mip's byte offset and holds `_level_sizes[m]` texels.
	GeneratedTexture _indirection;
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

	// Physical slot allocator. `_lru` is most-recently-used first.
	std::vector<uint32_t> _lru;
	std::vector<uint8_t> _slot_used;
	std::vector<uint8_t> _slot_protected;
	// slot -> packed (mip << 24 | y << 12 | x) indirection texels that publish it, so
	// eviction can invalidate exactly the entries that still point at the slot.
	std::vector<std::vector<uint32_t>> _slot_owners;
	std::vector<uint32_t> _free_slots;

	// Diagnostics
	int _alloc_count = 0;
	int _evict_count = 0;
	int _hit_count = 0;
	int _miss_count = 0;
	int _protected_block_count = 0;
	int _commit_count = 0;
	int _page_write_count = 0;

	uint32_t _read_level(int p_x, int p_y, int p_mip) const;
	void _write_level(int p_x, int p_y, int p_mip, uint32_t p_slot);
	void _touch_slot(uint32_t p_slot);
	int _acquire_slot();
	void _evict_slot(uint32_t p_slot);
	bool _virtual_to_physical(int p_sector_x, int p_sector_y, int p_local_mip,
			int p_page_x, int p_page_y, int &r_virtual_x, int &r_virtual_y) const;
	int _sector_max_local_mip(int p_sector_x, int p_sector_y) const;

public:
	Terrain3DVirtualTexture() {}
	~Terrain3DVirtualTexture() { clear(); }

	// Configuration, valid before initialize().
	void set_page_size(const int p_size);
	int get_page_size() const { return _page_size; }
	void set_page_border(const int p_border);
	int get_page_border() const { return _page_border; }
	void set_page_count(const int p_count);
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
	bool is_initialized() const { return _atlas.get_rid().is_valid() && _indirection.get_rid().is_valid(); }

	// Sectors
	bool register_sector(const Vector2i &p_sector, const int p_virtual_image_size);
	bool unregister_sector(const Vector2i &p_sector);
	bool has_sector(const Vector2i &p_sector) const;
	int get_sector_block_size(const Vector2i &p_sector) const;
	int get_sector_block_origin_x(const Vector2i &p_sector) const;
	int get_sector_block_origin_y(const Vector2i &p_sector) const;

	// Pages. `request_page` allocates and publishes a slot on a miss; `lookup_page`
	// only walks the mip chain. Both return -1 when there is nothing to serve.
	int request_page(const Vector2i &p_sector, const int p_local_mip, const int p_page_x, const int p_page_y);
	// Same, but reports whether the page had to be allocated, so a producer only
	// fills the pages that are actually new.
	int request_page_internal(const Vector2i &p_sector, const int p_local_mip,
			const int p_page_x, const int p_page_y, bool *r_miss);
	int lookup_page(const Vector2i &p_sector, const int p_local_mip, const int p_page_x, const int p_page_y) const;
	int lookup_virtual(const int p_virtual_x, const int p_virtual_y, const int p_mip, const int p_max_mip) const;

	// Page content
	bool write_page(const int p_slot, const Ref<Image> &p_page);
	Ref<Image> read_page(const int p_slot) const;
	Ref<Image> get_atlas_image() const;

	// Slot allocator
	void protect_page(const int p_slot, const bool p_protected);
	bool is_page_protected(const int p_slot) const;
	bool is_page_used(const int p_slot) const;
	int get_slot_owner_count(const int p_slot) const;

	// Uploads the indirection if it changed.
	void commit();

	RID get_atlas_rid() const { return _atlas.get_rid(); }
	RID get_indirection_rid() const { return _indirection.get_rid(); }
	// CPU copy of the full mip chain, laid out as Image::create_from_data expects.
	Ref<Image> get_indirection_image() const { return _indirection_image; }
	int get_level_count() const { return _level_count; }
	int get_level_size(const int p_mip) const;
	// Slot published at an exact mip, with no mip-chain walk. For tests and diagnostics.
	int get_indirection_slot(const int p_virtual_x, const int p_virtual_y, const int p_mip) const;

	Dictionary get_stats() const;
	void reset_stats();

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_VIRTUAL_TEXTURE_CLASS_H
