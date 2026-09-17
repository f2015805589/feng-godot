// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The shared physical page pool: the page atlas, the global slot allocation and the reverse
// owner index that both virtual texture views publish into.
//
// One pool is shared by the near field (AVT) and the far field (SVT), so it belongs to neither
// view and is not a member of either: the per-view half stays in terrain_3d_virtual_texture.h
// (the indirection texture, its mip-chain walk and the sector block allocator), and the
// addressing core both halves use is terrain_vt.h. This header is the hand-off between them, so
// a reader of either side sees the other side's shape without having to read it.
//
// Three contracts a caller has to keep, and nothing here can enforce them:
//   - acquire_slot() only *reserves* a slot. A producer that fails before publishing calls
//     abort_slot(), and no resident page is destroyed for nothing: the LRU victim is only
//     *chosen* at acquire time and actually evicted by commit_slot().
//   - A slot's content changes only through this object, and an eviction that ends a page calls
//     back into the view that published it (Terrain3DVirtualTexture::_invalidate_pool_owner) so
//     the indirection entry naming the slot is cleared in the same step.
//   - slot_protect_refs[] is a pin *count*, not a flag: the AVT pass's transient pins and the far
//     field's long-lived root pins compose, so one caller's unprotect cannot release the other's.

#ifndef TERRAIN3D_VT_PAGE_POOL_H
#define TERRAIN3D_VT_PAGE_POOL_H

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "generated_texture.h"
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
	// Independent pins per slot. A slot is protected while this is non-zero, so the
	// AVT pass's transient pins and the far field's long-lived root pins compose
	// instead of one caller's unprotect clearing the other's.
	std::vector<uint8_t> slot_protect_refs;
	std::vector<uint64_t> slot_demand_epoch;
	uint64_t demand_epoch = 0;
	uint64_t residency_revision = 1;
	bool demand_active = false;
	std::vector<std::vector<Terrain3DVTPageOwner>> slot_owners;
	std::vector<uint32_t> free_slots;
	// Acquire transaction. acquire_slot() reserves a slot and remembers whether it took a
	// free one or merely *chose* an LRU victim; the victim keeps its content and its owners'
	// indirection entries until commit_slot() makes the eviction final. A caller that fails
	// between the two calls abort_slot()s and no resident page was destroyed for nothing.
	std::vector<uint8_t> slot_reserved;
	std::vector<uint8_t> slot_evict_on_commit;
	int allocation_budget = -1;
	int alloc_count = 0;
	int evict_count = 0;
	int protected_block_count = 0;
	int aborted_acquires = 0;
	bool initialized = false;

	bool grow(int p_page_count);
	bool initialize(int p_page_size, int p_page_border, int p_page_count,
			Image::Format p_format);
	void clear();
	bool is_initialized() const { return initialized && atlas.get_rid().is_valid(); }

	int acquire_slot(Terrain3DVirtualTexture *p_requester);
	// Finalizes a reservation: an LRU victim chosen by acquire_slot() is evicted now, once
	// the replacement page exists and its indirection entry has been published.
	void commit_slot(uint32_t p_slot);
	// Drops a reservation without producing anything. The victim (if any) is untouched, so
	// the page it still serves stays resident and its table entries stay valid.
	void abort_slot(uint32_t p_slot);
	bool is_slot_reserved(uint32_t p_slot) const {
		return p_slot < slot_reserved.size() && slot_reserved[p_slot] != 0;
	}
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
	void set_allocation_budget(int p_pages) { allocation_budget = p_pages; }
	void begin_demand() { ++demand_epoch; demand_active = true; }
	void end_demand() { demand_active = false; }
	Array get_slot_owner_metadata(int p_slot) const;
};

// Bytes per texel for the formats this runtime is allowed to carry - for the atlas layers and
// the indirection chain alike. Godot's Image::get_format_pixel_size() is not exposed to
// extensions, and guessing here would silently mis-size both. 0 means "not supported".
int vt_format_pixel_size(Image::Format p_format);

#endif // TERRAIN3D_VT_PAGE_POOL_H
