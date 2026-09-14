// Virtual texture addressing contract: the page-id payload, the indirection mip
// walk and the POT quadtree allocator over the virtual page space. Port of ZRP
// TerrainVirtualImageAtlas. No Godot or Unity dependencies, no runtime state.
#ifndef TERRAIN_VT_H
#define TERRAIN_VT_H

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
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

// ─────────────────────────────────────────────────────────────────────────────
// Address profile
// ─────────────────────────────────────────────────────────────────────────────

// Hydra sizes a sector's virtual image from a descriptor table (resolution,
// global mip range and allocatable block per size index). This port sizes them
// from the live settings instead, so only the power-of-two rule it validates
// against is kept.
struct AddressProfile {
	static bool is_power_of_two(int value) {
		return value > 0 && (value & (value - 1)) == 0;
	}
};

// ─────────────────────────────────────────────────────────────────────────────
// Page addressing
// ─────────────────────────────────────────────────────────────────────────────

// Local page coordinate inside one sector's VirtualImage, plus local mip and
// descriptor slot. Matches Hydra's uint4 pageId.
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
		if (candidate != INVALID_PHYSICAL_PAGE_SLOT) {
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

} // namespace TerrainVT

#endif // TERRAIN_VT_H
