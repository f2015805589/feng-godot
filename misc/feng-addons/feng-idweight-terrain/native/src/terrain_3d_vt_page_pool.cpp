// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The shared page pool's translation unit: format support, lifecycle, the slot allocator
// (reserve / commit / abort), the reverse owner index, and page content access.
//
// Read terrain_3d_vt_page_pool.h first: it states the three contracts these functions rely on.
// What is here is only the mechanics of them - the free list and slot recency, the per-slot arrays
// that all have the pool's page count, and the counters the diagnostics report. The per-view
// half is terrain_3d_virtual_texture.cpp, and this file calls into it in exactly one place: an
// eviction invalidates the indirection entry that published the page, through
// Terrain3DVirtualTexture::_invalidate_pool_owner() and the friendship declared on that class.

#include "terrain_3d_vt_page_pool.h"

#include "constants.h"
#include "terrain_3d_virtual_texture.h"

#include <algorithm>

#include <godot_cpp/classes/rendering_server.hpp>

using namespace TerrainVT;

int vt_format_pixel_size(Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return 1;
		case IDWEIGHT_IMAGE_FORMAT:
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
// Lifecycle
///////////////////////////

bool Terrain3DVTPagePool::initialize(const int p_page_size, const int p_page_border,
		const int p_page_count, const Image::Format p_format) {
	if (is_initialized()) {
		return page_size == p_page_size && page_border == p_page_border &&
				page_count == p_page_count && format == p_format;
	}
	const int pixel_size = vt_format_pixel_size(p_format);
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

	slot_recency.assign(page_count, 0);
	recency_counter = 0;
	slot_used.assign(page_count, 0);
	authored_pages.resize(page_count);
	slot_protected.assign(page_count, 0);
	slot_reserved.assign(page_count, 0);
	slot_evict_on_commit.assign(page_count, 0);
	slot_protect_refs.assign(page_count, 0);
	slot_demand_epoch.assign(page_count, 0);
	slot_owners.assign(page_count, std::vector<Terrain3DVTPageOwner>());
	free_slots.clear();
	for (int slot = page_count - 1; slot >= 0; slot--) {
		free_slots.push_back(uint32_t(slot));
	}
	alloc_count = 0;
	evict_count = 0;
	protected_block_count = 0;
	reserved_block_count = 0;
	initialized = true;
	return true;
}

bool Terrain3DVTPagePool::grow(int p_count) {
	if (!is_initialized() || p_count <= page_count) { return p_count == page_count; }
	// The atlas is rebuilt from blank layers on the next write (`ensure_layers()`
	// frees the RID and recreates every layer), so no resident page survives a
	// resize. Drop residency explicitly: evict_slot() walks the reverse owner index
	// and clears each published indirection entry, which is what makes the demand
	// passes re-produce these pages instead of sampling zeroed layers forever.
	int released = 0;
	for (uint32_t slot = 0; slot < uint32_t(page_count); ++slot) {
		if (slot_used[slot]) { evict_slot(slot); ++released; }
	}
	slot_recency.assign(p_count, 0);
	slot_used.resize(p_count, 0);
	authored_pages.resize(p_count);
	slot_protected.assign(p_count, 0);
	slot_reserved.assign(p_count, 0);
	slot_evict_on_commit.assign(p_count, 0);
	slot_protect_refs.assign(p_count, 0);
	slot_demand_epoch.assign(p_count, 0);
	slot_owners.assign(p_count, std::vector<Terrain3DVTPageOwner>());
	// Nothing is resident, so every slot - old and new - is free again.
	free_slots.clear();
	for (int slot = p_count - 1; slot >= 0; --slot) { free_slots.push_back(uint32_t(slot)); }
	page_count = p_count;
	++residency_revision;
	// A grown pool has no reserved page either: every slot above was just released.
	reserved_block_count = 0;
	// Terrain3DVTPagePool is a plain struct, so it has no GDCLASS __class__ for LOG;
	// warn through the engine macro instead. Only a growth that actually released pages is
	// worth reporting: an empty pool grows into a blank atlas without losing anything, and
	// reporting that would blame the caller for work it does not have to redo.
	if (released > 0) {
		WARN_PRINT("Virtual texture pool grew to " + String::num_int64(p_count) + " pages; " +
				String::num_int64(released) + " resident pages were released while the atlas is rebuilt");
	}
	return true;
}

void Terrain3DVTPagePool::clear() {
	++residency_revision;
	// Texture owners detach before the final shared_ptr release. Clearing the
	// reverse index here still makes the destructor safe if a caller explicitly
	// tears down a pool after all views have already gone away.
	atlas.clear();
	atlas_template.unref();
	slot_recency.clear();
	slot_used.clear();
	authored_pages.clear();
	slot_protected.clear();
	slot_reserved.clear();
	slot_evict_on_commit.clear();
	slot_protect_refs.clear();
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

///////////////////////////
// Slot reservation
///////////////////////////

void Terrain3DVTPagePool::touch_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count)) {
		return;
	}
	if (demand_active) { slot_demand_epoch[p_slot] = demand_epoch; }
	// One stamp per touch instead of a move-to-front list: the demand passes hit a
	// resident page once per slot per tick, so the list's linear find plus two
	// memmoves of the whole pool was the per-tick cost this is sized to remove.
	slot_recency[p_slot] = ++recency_counter;
}

int Terrain3DVTPagePool::acquire_slot(Terrain3DVirtualTexture *p_requester) {
	(void)p_requester;
	if (!is_initialized() || allocation_budget == 0) {
		return -1;
	}
	uint32_t slot = INVALID_PHYSICAL_PAGE_SLOT;
	bool evict_on_commit = false;
	bool saw_reserved_victim = false;
	if (!free_slots.empty()) {
		slot = free_slots.back();
		free_slots.pop_back();
	} else {
		// Nothing free: choose the least recently used unprotected page. With a
		// stamp per slot the victim is the eligible slot with the smallest stamp -
		// the same choice the back-to-front LRU list scan made - and freed slots
		// are skipped on `slot_used` the same way stale list entries were.
		uint64_t oldest_stamp = UINT64_MAX;
		for (uint32_t candidate = 0; candidate < uint32_t(page_count); ++candidate) {
			if (!slot_used[candidate] || slot_protected[candidate] || slot_reserved[candidate]) {
				continue;
			}
			// A page the addressing reserved is not a victim at any pressure. The fallback tier's
			// residency is a guarantee rather than demand (docs/avt_addressing_redesign.md rules R2
			// and R3), so the search skips it exactly as it skips a protected page - and counts it
			// separately, so a view whose upgrade set is competing for reserved slots reports that
			// instead of looking like a view that is simply full.
			if (has_reserved_owner(candidate)) {
				saw_reserved_victim = true;
				continue;
			}
			// An oversubscribed working set must not evict its own still-needed
			// pages every tick. Allow one complete demand pass before considering
			// a resident unused, independent of request order across AVT and SVT.
			// Missing selected pages retain diagnostics until capacity is available. Explicit
			// offline baking and standalone cache APIs retain ordinary LRU behavior.
			if (demand_active && slot_demand_epoch[candidate] != 0 &&
					demand_epoch - slot_demand_epoch[candidate] <= 1) {
				continue;
			}
			// The victim is only *chosen* here. Evicting it now would destroy a
			// resident page even when the caller fails before publishing the
			// replacement; commit_slot() makes it final.
			if (slot_recency[candidate] < oldest_stamp) {
				oldest_stamp = slot_recency[candidate];
				slot = candidate;
			}
		}
		if (slot != INVALID_PHYSICAL_PAGE_SLOT) {
			evict_on_commit = true;
		}
		if (slot == INVALID_PHYSICAL_PAGE_SLOT) {
			protected_block_count++;
			if (saw_reserved_victim) { reserved_block_count++; }
			return -1;
		}
	}
	slot_reserved[slot] = 1;
	slot_evict_on_commit[slot] = evict_on_commit ? 1 : 0;
	if (!evict_on_commit) {
		slot_used[slot] = 1;
		touch_slot(slot);
	}
	alloc_count++;
	if (allocation_budget > 0) {
		allocation_budget--;
	}
	return int(slot);
}

void Terrain3DVTPagePool::commit_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count) || !slot_reserved[p_slot]) {
		return;
	}
	const bool evict_victim = slot_evict_on_commit[p_slot] != 0;
	slot_reserved[p_slot] = 0;
	slot_evict_on_commit[p_slot] = 0;
	if (!evict_victim) {
		return;
	}
	// The replacement is published (or about to be), so the page this slot used to serve
	// can go. evict_slot() invalidates exactly the owners that still name this slot and
	// leaves it free; take it for the new page in the same step.
	evict_slot(p_slot);
	slot_used[p_slot] = 1;
	touch_slot(p_slot);
}

void Terrain3DVTPagePool::abort_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count) || !slot_reserved[p_slot]) {
		return;
	}
	const bool evict_victim = slot_evict_on_commit[p_slot] != 0;
	slot_reserved[p_slot] = 0;
	slot_evict_on_commit[p_slot] = 0;
	if (!evict_victim) {
		// A slot taken from the free list simply goes back to it.
		authored_pages[p_slot].unref();
		slot_used[p_slot] = 0;
		slot_protected[p_slot] = 0;
		slot_protect_refs[p_slot] = 0;
		slot_demand_epoch[p_slot] = 0;
		free_slots.push_back(p_slot);
	}
	// Nothing was produced by this acquisition, so the counters go back too. The victim's
	// content, owners and indirection entries were never touched.
	alloc_count = MAX(0, alloc_count - 1);
	if (allocation_budget > 0) {
		allocation_budget++;
	}
}

void Terrain3DVTPagePool::evict_slot(const uint32_t p_slot) {
	if (p_slot >= uint32_t(page_count) || !slot_used[p_slot]) {
		return;
	}
	// Only a slot that actually held a page changes residency. Bumping the revision
	// for a no-op eviction would invalidate the callers' "nothing changed since this
	// revision" fast paths for nothing.
	++residency_revision;
	const std::vector<Terrain3DVTPageOwner> owners = slot_owners[p_slot];
	for (const Terrain3DVTPageOwner &owner : owners) {
		if (owner.texture) {
			owner.texture->_invalidate_pool_owner(p_slot, owner);
		}
	}
	slot_owners[p_slot].clear();
	authored_pages[p_slot].unref();
	slot_used[p_slot] = 0;
	evict_count++;
}

///////////////////////////
// Reverse owner index
///////////////////////////

void Terrain3DVTPagePool::publish_owner(const uint32_t p_slot,
		const Terrain3DVTPageOwner &p_owner) {
	++residency_revision;
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
	++residency_revision;
	if (p_slot >= uint32_t(page_count) || !p_texture) {
		return false;
	}
	std::vector<Terrain3DVTPageOwner> &owners = slot_owners[p_slot];
	for (auto it = owners.begin(); it != owners.end(); ++it) {
		if (it->texture == p_texture && it->virtual_x == p_virtual_x &&
				it->virtual_y == p_virtual_y && it->mip == p_mip) {
			owners.erase(it);
			if (owners.empty() && slot_used[p_slot]) {
				authored_pages[p_slot].unref();
				slot_used[p_slot] = 0;
				slot_protected[p_slot] = 0;
				slot_protect_refs[p_slot] = 0;
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
	++residency_revision;
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
	++residency_revision;
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
			// Unref the authored page with the slot. Leaving it behind would let a
			// later read upload the previous owner's raw IDs into whichever page
			// takes this slot next.
			authored_pages[slot].unref();
			slot_used[slot] = 0;
			slot_protected[slot] = 0;
			slot_protect_refs[slot] = 0;
			slot_demand_epoch[slot] = 0;
			free_slots.push_back(slot);
		}
	}
}

///////////////////////////
// Page content
///////////////////////////

bool Terrain3DVTPagePool::write_page(const int p_slot, const Ref<Image> &p_page) {
	if (!is_initialized() || p_slot < 0 || p_slot >= page_count || p_page.is_null() ||
			p_page->get_width() != stored_page_size || p_page->get_height() != stored_page_size ||
			p_page->get_format() != format) {
		return false;
	}
	if (!slot_used[p_slot]) {
		// No indirection entry can reach an unowned slot, and the next allocation of
		// this slot would serve these bytes as if they were its own page.
		WARN_PRINT("Refusing to write a page into unallocated slot " + String::num_int64(p_slot));
		return false;
	}
	if (atlas.get_layer_count() < page_count && !atlas.ensure_layers(atlas_template, page_count)) { return false; }
	atlas.update(p_page, p_slot);
	return true;
}

Ref<Image> Terrain3DVTPagePool::read_page(const int p_slot) const {
	if (!is_initialized() || p_slot < 0 || p_slot >= page_count) {
		return Ref<Image>();
	}
	return RS->texture_2d_layer_get(atlas.get_rid(), p_slot);
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
