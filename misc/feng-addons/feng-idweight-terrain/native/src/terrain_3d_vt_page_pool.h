// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Shared physical atlas, allocation budget, LRU/pin state and reverse owner index.
// Allocation and indirection publication are synchronous on the scene thread.
// Eviction clears every owner's mapping before a slot is reused; pin counts compose
// across near-field transient pins and far-field root pins.

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
	// A page the addressing treats as a guarantee rather than as demand: it is never chosen as an
	// eviction victim, so its owner's residency is a function of configuration instead of of what
	// the view asks for and of the production order. The near field's fallback tier is the owner
	// that sets this. See `docs/avt_addressing_redesign.md` rules R2 and R3.
	bool reserved = false;
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

	// Recency is a stamp, not a list: touch_slot() is hit once per demanded page per
	// tick by the demand passes, so a move-to-front vector turned every resident hit into
	// a linear scan plus two memmoves of the whole pool. A monotonically increasing stamp
	// per slot is the same total order; acquire_slot() finds the victim as the eligible
	// slot with the smallest stamp.
	std::vector<uint64_t> slot_recency;
	uint64_t recency_counter = 0;
	std::vector<uint8_t> slot_used;
	std::vector<Ref<Image>> authored_pages;
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
	int allocation_budget = -1;
	int alloc_count = 0;
	int evict_count = 0;
	int protected_block_count = 0;
	// Times a slot request found no victim because the only candidates left were reserved pages.
	// It is the reservation's own pressure reading: non-zero means the upgrade set is competing for
	// slots the fallback tier is holding, and zero means the reservation is not the binding term.
	int reserved_block_count = 0;
	bool initialized = false;

	// Whether any owner of this slot is a reserved page, which is what keeps the slot out of the
	// victim search. A slot can carry several owners - a page a sector grew into and the fallback
	// entry that named it - so the question is asked of the set, not of one entry.
	bool has_reserved_owner(const uint32_t p_slot) const {
		if (p_slot >= slot_owners.size()) {
			return false;
		}
		for (const Terrain3DVTPageOwner &owner : slot_owners[p_slot]) {
			if (owner.reserved) {
				return true;
			}
		}
		return false;
	}

	// How many slots currently hold a reserved page. The fallback tier's residency, as opposed to
	// how often a request was blocked by it.
	int count_reserved_slots() const {
		int count = 0;
		for (uint32_t slot = 0; slot < uint32_t(slot_owners.size()); ++slot) {
			if (has_reserved_owner(slot)) {
				++count;
			}
		}
		return count;
	}

	bool grow(int p_page_count);
	bool initialize(int p_page_size, int p_page_border, int p_page_count,
			Image::Format p_format);
	void clear();
	bool is_initialized() const { return initialized && atlas.get_rid().is_valid(); }

	// Allocates immediately; the caller has validated the address and publishes it
	// without another fallible operation. Production of page contents is separate.
	int acquire_slot();
	void touch_slot(uint32_t p_slot);
	void mark_demanded(uint32_t p_slot) { if (demand_active && p_slot < slot_demand_epoch.size()) { slot_demand_epoch[p_slot] = demand_epoch; } }
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

private:
	void _evict_slot(uint32_t p_slot);
	void _release_slot(uint32_t p_slot);
};

// Bytes per texel for the formats this runtime is allowed to carry - for the atlas layers and
// the indirection chain alike. Godot's Image::get_format_pixel_size() is not exposed to
// extensions, and guessing here would silently mis-size both. 0 means "not supported".
int vt_format_pixel_size(Image::Format p_format);

#endif // TERRAIN3D_VT_PAGE_POOL_H
