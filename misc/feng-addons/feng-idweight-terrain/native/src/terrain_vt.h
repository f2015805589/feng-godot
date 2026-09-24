// Virtual texture addressing contract: the page-id payload, the indirection mip
// walk and the POT quadtree allocator over the virtual page space. No engine
// dependencies, no runtime state.
#ifndef TERRAIN_VT_H
#define TERRAIN_VT_H

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace TerrainVT {
// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

// Indirection texel payload: 11 bit physical page slot index.
constexpr int SLOT_BIT_COUNT = 11;
constexpr uint32_t SLOT_MASK = (1u << SLOT_BIT_COUNT) - 1u;
// An indirection texel that names no page.
constexpr uint32_t INVALID_PHYSICAL_PAGE_SLOT = 65535u;
// An indirection texel whose page the standing demand plan names but which has no physical
// content yet. It is not a slot: no allocator can hand out 65534 (the pool is capped at
// `SLOT_MASK` = 2047), so the value is free to mean "planned, still in production".
//
// It exists so the shader's strict resolve (feedback off) can tell the two reasons a level has
// no content apart. `INVALID` means the plan does not name that page at all, so the ground is
// asking for a level it will never hold and the walk must continue to the level the plan does
// hold. `PLANNED` means the plan names it and it is simply late, which strict mode must render
// as the missing-page diagnostic rather than resolving through a coarser ancestor. A plan that
// names a page is the *only* thing that can turn a level into `PLANNED`, which is what makes
// the demand plan the strict path's LOD contract instead of an invisible budget cut.
constexpr uint32_t PLANNED_PHYSICAL_PAGE_SLOT = 65534u;

// ─────────────────────────────────────────────────────────────────────────────
// Address profile
// ─────────────────────────────────────────────────────────────────────────────

// A sector's virtual image could be sized from a descriptor table (resolution,
// global mip range and allocatable block per size index). This implementation
// sizes them from the live settings instead, so only the power-of-two rule is
// kept.
struct AddressProfile {
	static bool is_power_of_two(int value) {
		return value > 0 && (value & (value - 1)) == 0;
	}
};

// ─────────────────────────────────────────────────────────────────────────────
// Page addressing
// ─────────────────────────────────────────────────────────────────────────────

// Local page coordinate inside one sector's VirtualImage, plus local mip and
// descriptor slot.
struct PageId {
	uint32_t x = 0;
	uint32_t y = 0;
	uint32_t z = 0; // local mip
	uint32_t w = 0; // size index / descriptor slot

	bool operator==(const PageId &other) const {
		return x == other.x && y == other.y && z == other.z && w == other.w;
	}
};

// Walks the indirection mip chain from the requested mip to max_local_mip and
// returns the first resident slot. Lookup must be callable as
// uint32_t(uint32_t virtual_page_x, uint32_t virtual_page_y, uint32_t mip).
template <typename Lookup>
bool try_match_indirection_slot(const PageId &page_id, uint32_t max_local_mip, Lookup lookup,
		uint32_t &slot, uint32_t &matched_page_x, uint32_t &matched_page_y,
		uint32_t &matched_mip) {
	if (page_id.w == 0u || page_id.z > max_local_mip) {
		slot = INVALID_PHYSICAL_PAGE_SLOT;
		matched_page_x = 0;
		matched_page_y = 0;
		matched_mip = max_local_mip;
		return false;
	}
	uint32_t virtual_page_x = page_id.x;
	uint32_t virtual_page_y = page_id.y;
	for (uint32_t mip = page_id.z; mip <= max_local_mip; mip++) {
		const uint32_t candidate = lookup(virtual_page_x, virtual_page_y, mip);
		if (candidate != INVALID_PHYSICAL_PAGE_SLOT && candidate != PLANNED_PHYSICAL_PAGE_SLOT) {
			slot = candidate & SLOT_MASK;
			matched_page_x = virtual_page_x;
			matched_page_y = virtual_page_y;
			matched_mip = mip;
			return true;
		}
		virtual_page_x >>= 1;
		virtual_page_y >>= 1;
	}
	slot = INVALID_PHYSICAL_PAGE_SLOT;
	matched_page_x = 0;
	matched_page_y = 0;
	matched_mip = max_local_mip;
	return false;
}

inline int log2_power_of_two(int value) {
	int safe = std::max(1, value);
	int result = 0;
	while (safe > 1) {
		safe >>= 1;
		result++;
	}
	return result;
}

// The indirection mip chain's shape. Level m is `p_size >> m` texels per axis, never below one, and
// the chain's levels are addressed one after another in a table whose texels are four bytes wide.
// It is one definition because three places build or read the same table - the CPU page table, the
// cleared table the device is handed before the first commit, and the level-size accessor - and a
// reader that disagreed with the builder would address the wrong level.
inline int indirection_level_size(const int p_size, const int p_mip) {
	const int size = p_mip <= 0 ? p_size : p_size >> p_mip;
	return std::max(1, size);
}

// The texel count of a chain of `p_levels` levels, which is the size of the table.
inline int64_t indirection_total_texels(const int p_size, const int p_levels) {
	int64_t texels = 0;
	for (int mip = 0; mip < p_levels; ++mip) {
		const int64_t level = indirection_level_size(p_size, mip);
		texels += level * level;
	}
	return texels;
}

// The table a page table starts as: every texel names no page. The invalid value is a slot index
// written as a float bit pattern - the sampler reads the table as floats - so it is broadcast
// word by word rather than produced by arithmetic.
inline void fill_indirection_cleared(uint8_t *p_bytes, const int64_t p_texels) {
	const float word = float(INVALID_PHYSICAL_PAGE_SLOT);
	for (int64_t i = 0; i < p_texels; ++i) {
		std::memcpy(p_bytes + i * 4, &word, 4);
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// VirtualImageAtlas: POT quadtree allocator over the indirection page space
// ─────────────────────────────────────────────────────────────────────────────

enum class VirtualImageKind : uint8_t {
	AVT = 0,
	SVT = 1,
};

struct VirtualImageOwner {
	int sector_x = 0;
	int sector_y = 0;
	VirtualImageKind kind = VirtualImageKind::AVT;
	uint32_t generation = 0;

	bool operator==(const VirtualImageOwner &other) const {
		return sector_x == other.sector_x && sector_y == other.sector_y && kind == other.kind &&
				generation == other.generation;
	}
};

// Block origin (x, y) and POT block size (w), in pages. Node index in x of the
// internal quadtree is not exposed.
struct ImageInfo {
	int node_index = 0;
	int origin_x = 0;
	int origin_y = 0;
	int size = 0;

	bool operator==(const ImageInfo &other) const {
		return node_index == other.node_index && origin_x == other.origin_x &&
				origin_y == other.origin_y && size == other.size;
	}
};

struct VirtualImageOwnerHash {
	std::size_t operator()(const VirtualImageOwner &owner) const {
		std::size_t hash = std::hash<int>()(owner.sector_x);
		hash = (hash * 397) ^ std::hash<int>()(owner.sector_y);
		hash = (hash * 397) ^ std::size_t(owner.kind);
		return (hash * 397) ^ std::hash<uint32_t>()(owner.generation);
	}
};

struct SectorHash {
	std::size_t operator()(const std::pair<int, int> &sector) const {
		std::size_t hash = std::hash<int>()(sector.first);
		return (hash * 397) ^ std::hash<int>()(sector.second);
	}
};

class VirtualImageAtlas {
public:
	explicit VirtualImageAtlas(int atlas_size, int minimal_virtual_image_size) :
			atlas_size_(atlas_size), minimal_virtual_image_size_(minimal_virtual_image_size) {
		int node_count = 0;
		int current_size_node_count = 1;
		int current_node_size = atlas_size;
		while (current_node_size > minimal_virtual_image_size) {
			node_count += current_size_node_count;
			current_node_size >>= 1;
			current_size_node_count <<= 2;
		}
		occupied_area_.assign(node_count, 0);
		mark_as_used_.assign(node_count + current_size_node_count, false);
		node_owners_.assign(mark_as_used_.size(), VirtualImageOwner());
	}

	int allocated_node_count() const {
		return int(owner_to_image_.size());
	}

	void clear() {
		std::fill(mark_as_used_.begin(), mark_as_used_.end(), false);
		std::fill(occupied_area_.begin(), occupied_area_.end(), uint64_t(0));
		std::fill(node_owners_.begin(), node_owners_.end(), VirtualImageOwner());
		sector_to_image_.clear();
		owner_to_image_.clear();
		next_generation_ = 1;
	}

	bool try_insert_avt_image(int sector_x, int sector_y, int virtual_image_size,
			VirtualImageOwner &owner, ImageInfo &image_info) {
		owner = create_owner(sector_x, sector_y, VirtualImageKind::AVT);
		if (!try_allocate_free(owner, virtual_image_size, image_info)) {
			owner = VirtualImageOwner();
			return false;
		}
		sector_to_image_[{ sector_x, sector_y }] = image_info;
		return true;
	}

	bool remove_image(const VirtualImageOwner &owner) {
		auto found = owner_to_image_.find(owner);
		if (found == owner_to_image_.end()) {
			return false;
		}
		const ImageInfo image_info = found->second;
		const int node_index = image_info.node_index;
		if (node_index < 0 || node_index >= int(mark_as_used_.size()) ||
				!mark_as_used_[node_index] || !(node_owners_[node_index] == owner)) {
			return false;
		}
		mark_free(image_info);
		owner_to_image_.erase(found);
		if (owner.kind == VirtualImageKind::AVT) {
			auto sector_found = sector_to_image_.find({ owner.sector_x, owner.sector_y });
			if (sector_found != sector_to_image_.end() && sector_found->second == image_info) {
				sector_to_image_.erase(sector_found);
			}
		}
		return true;
	}

	bool try_get_avt_image_info(int sector_x, int sector_y, ImageInfo &image_info) const {
		auto found = sector_to_image_.find({ sector_x, sector_y });
		if (found == sector_to_image_.end()) {
			image_info = ImageInfo();
			return false;
		}
		image_info = found->second;
		return true;
	}

	// Reallocate one sector's POT virtual image while retaining the old owner
	// information when allocation cannot satisfy the new size. The caller can
	// remap cached indirection entries from old_info to new_info after this returns.
	// Keeping this transaction in the address allocator avoids exposing its quadtree
	// bookkeeping to the runtime page pool.
	bool try_resize_avt_image(int sector_x, int sector_y, int virtual_image_size,
			VirtualImageOwner &owner, ImageInfo &old_info, ImageInfo &new_info) {
		auto sector_found = sector_to_image_.find({ sector_x, sector_y });
		if (sector_found == sector_to_image_.end()) {
			owner = VirtualImageOwner();
			old_info = ImageInfo();
			new_info = ImageInfo();
			return false;
		}
		old_info = sector_found->second;
		if (!is_valid_image_size(virtual_image_size)) {
			owner = node_owners_[old_info.node_index];
			new_info = old_info;
			return false;
		}
		const VirtualImageOwner old_owner = node_owners_[old_info.node_index];
		owner = old_owner;
		if (old_info.size == virtual_image_size) {
			new_info = old_info;
			return true;
		}
		if (!remove_image(old_owner)) {
			new_info = ImageInfo();
			return false;
		}

		VirtualImageOwner resized_owner = create_owner(sector_x, sector_y, VirtualImageKind::AVT);
		if (try_allocate_free(resized_owner, virtual_image_size, new_info)) {
			sector_to_image_[{ sector_x, sector_y }] = new_info;
			owner = resized_owner;
			return true;
		}

		// Roll back the exact old node and owner. No other allocation occurs while
		// this method runs, so the node is still free and can be restored verbatim.
		mark_allocated(old_info, old_owner);
		sector_to_image_[{ sector_x, sector_y }] = old_info;
		owner = old_owner;
		new_info = old_info;
		return false;
	}

	// Node index 0 is the root and has no parent; parent chain stops at root.
	static int parent_of(int node_index) {
		return (node_index - 1) >> 2;
	}

	bool is_valid_image_size(int virtual_image_size) const {
		return virtual_image_size >= minimal_virtual_image_size_ &&
				virtual_image_size <= atlas_size_ &&
				(virtual_image_size & (virtual_image_size - 1)) == 0;
	}

private:
	VirtualImageOwner create_owner(int sector_x, int sector_y, VirtualImageKind kind) {
		const uint32_t generation = next_generation_++;
		if (next_generation_ == 0) {
			next_generation_ = 1;
		}
		return { sector_x, sector_y, kind, generation };
	}

	bool try_allocate_free(const VirtualImageOwner &owner, int virtual_image_size,
			ImageInfo &image_info) {
		image_info = ImageInfo();
		if (!is_valid_image_size(virtual_image_size)) {
			return false;
		}
		std::vector<ImageInfo> travel_stack;
		travel_stack.push_back({ 0, 0, 0, atlas_size_ });
		while (!travel_stack.empty()) {
			const ImageInfo current = travel_stack.back();
			travel_stack.pop_back();
			if (mark_as_used_[current.node_index]) {
				continue;
			}
			if (current.size > virtual_image_size) {
				// A fully occupied subtree cannot satisfy any allocation. Skipping it
				// preserves traversal order among all nodes that can still succeed.
				if (occupied_area_[current.node_index] == uint64_t(current.size) * current.size) {
					continue;
				}
				push_children(travel_stack, current);
				continue;
			}
			if (current.size == virtual_image_size &&
					(virtual_image_size == minimal_virtual_image_size_ ||
							occupied_area_[current.node_index] == 0)) {
				mark_allocated(current, owner);
				image_info = current;
				return true;
			}
		}
		return false;
	}

	void mark_allocated(const ImageInfo &node, const VirtualImageOwner &owner) {
		mark_as_used_[node.node_index] = true;
		node_owners_[node.node_index] = owner;
		owner_to_image_[owner] = node;
		int parent = parent_of(node.node_index);
		while (parent >= 0) {
			occupied_area_[parent] += uint64_t(node.size) * node.size;
			if (parent == 0) {
				break;
			}
			parent = parent_of(parent);
		}
	}

	void mark_free(const ImageInfo &node) {
		mark_as_used_[node.node_index] = false;
		node_owners_[node.node_index] = VirtualImageOwner();
		int parent = parent_of(node.node_index);
		while (parent >= 0) {
			occupied_area_[parent] -= uint64_t(node.size) * node.size;
			if (parent == 0) {
				break;
			}
			parent = parent_of(parent);
		}
	}

	// Low coordinates first, so AVT blocks cluster in the low page space.
	static void push_children(std::vector<ImageInfo> &stack, const ImageInfo &node) {
		const int half_size = node.size >> 1;
		const int child_node_index = node.node_index << 2;
		const ImageInfo low_low{ child_node_index + 1, node.origin_x, node.origin_y, half_size };
		const ImageInfo high_low{ child_node_index + 2, node.origin_x + half_size, node.origin_y,
			half_size };
		const ImageInfo low_high{ child_node_index + 3, node.origin_x, node.origin_y + half_size,
			half_size };
		const ImageInfo high_high{ child_node_index + 4, node.origin_x + half_size,
			node.origin_y + half_size, half_size };
		stack.push_back(high_high);
		stack.push_back(low_high);
		stack.push_back(high_low);
		stack.push_back(low_low);
	}

	int atlas_size_ = 0;
	int minimal_virtual_image_size_ = 0;
	std::vector<bool> mark_as_used_;
	// Occupied descendant area, in page-table texels. Unlike a 16-bit node
	// count, this remains valid when all 65,536 default leaf blocks are allocated.
	std::vector<uint64_t> occupied_area_;
	std::vector<VirtualImageOwner> node_owners_;
	std::unordered_map<std::pair<int, int>, ImageInfo, SectorHash> sector_to_image_;
	std::unordered_map<VirtualImageOwner, ImageInfo, VirtualImageOwnerHash> owner_to_image_;
	uint32_t next_generation_ = 1;
};

// ─────────────────────────────────────────────────────────────────────────────
// Level rule
// ─────────────────────────────────────────────────────────────────────────────

// Which level a far-field page is *requested* at. Two implementations today and a third planned
// (H1's pixel footprint, `docs/vt_reference_avt_alignment.md`), which is why the decision is a value the
// callers hold rather than a branch each of them re-tests against the live settings: the demand pass
// that resolves a page's level and the shader that samples it have to agree, and a third kind must
// not mean a third copy of the arithmetic.
//
// It lives here, beside the addressing contract, because it is arithmetic both sides evaluate: the
// GLSL mirror is `surface_svt_mip_for_distance()` in `shaders/main.glsl`, and this side is pinned by
// `native/tests/vt/terrain_vt_contract_test.cpp`. No engine dependency, no runtime state.
enum class MipRuleKind : int {
	// A level m page covers `page_world * 2^m` metres, so level m is the right choice out to twice
	// that distance and the bands follow the page size with nothing to keep in step.
	AutomaticBands = 0,
	// The distances are stated directly, one entry per level, in metres.
	ExplicitTable = 1,
};

struct MipRule {
	MipRuleKind kind = MipRuleKind::AutomaticBands;
	float page_world = 1.f;
	// The explicit table, one entry per level, in metres. Borrowed, not owned: a caller builds a rule
	// from the live settings at the top of a pass and uses it within that pass.
	const float *bands = nullptr;
	int band_count = 0;

	// The level a point `p_distance` metres away is requested at, never finer than `p_max_mip`.
	int mip_for_distance(float p_distance, int p_max_mip) const {
		const int max_mip = p_max_mip > 0 ? p_max_mip : 0;
		if (kind == MipRuleKind::ExplicitTable && bands != nullptr && band_count > 0) {
			const int last = band_count - 1;
			int mip = 0;
			while (mip < last && p_distance > bands[mip]) {
				mip++;
			}
			return mip < max_mip ? mip : max_mip;
		}
		int mip = 0;
		// A page is never smaller than a metre, which is what the old inline `MAX(1.f, ...)` said.
		float threshold = page_world * 2.f;
		if (threshold < 1.f) {
			threshold = 1.f;
		}
		while (mip < max_mip && p_distance > threshold) {
			threshold *= 2.f;
			mip++;
		}
		return mip;
	}

	// Furthest distance the rule still serves with a produced page: the band at the published cap, or
	// 0 for the automatic rule, which coarsens without a limit of its own.
	float reach(int p_max_mip) const {
		if (kind != MipRuleKind::ExplicitTable || bands == nullptr || band_count <= 0) {
			return 0.f;
		}
		const int index = band_count - 1 < p_max_mip ? band_count - 1 : p_max_mip;
		return bands[index > 0 ? index : 0];
	}
};

// The one place the mode is decided from the live settings. A rule with no bands *is* the automatic
// rule, so the emptiness test that used to sit at each call site sits here. The shader has the mirror
// of this decision and it is the shader's own: `_surface_svt_mip_distance_count` is what its side
// tests, and `terrain_3d_material.cpp` uploads the count and the table without deciding anything.
inline MipRule select_mip_rule(const float p_page_world, const float *p_bands, const int p_band_count) {
	MipRule rule;
	rule.page_world = p_page_world;
	if (p_bands != nullptr && p_band_count > 0) {
		rule.kind = MipRuleKind::ExplicitTable;
		rule.bands = p_bands;
		rule.band_count = p_band_count;
	}
	return rule;
}

} // namespace TerrainVT

#endif // TERRAIN_VT_H
