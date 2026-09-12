// Hydra-compatible terrain virtual texture addressing contract.
// Port of ZRP TerrainAVTConstants / TerrainAVTAddressProfile / TerrainAVTUtility
// / TerrainVirtualImageAtlas. No Godot or Unity dependencies.
#ifndef TERRAIN_VT_H
#define TERRAIN_VT_H

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace TerrainVT {
constexpr int FORMAT_VERSION = 1;

// ─────────────────────────────────────────────────────────────────────────────
// TerrainAVTConstants parity
// ─────────────────────────────────────────────────────────────────────────────

// World is carved into 64 m sectors. One sector owns one VirtualImage.
constexpr int SECTOR_SIZE = 64;
// A physical page holds 256x256 texels plus a 4 texel border on every side.
constexpr int PAGE_SIZE_SHIFT = 8;
constexpr int PAGE_SIZE = 1 << PAGE_SIZE_SHIFT;
constexpr int BORDER_SIZE = 4;
constexpr int PAGE_SIZE_WITH_BORDER = PAGE_SIZE + (BORDER_SIZE * 2);
// Sector page space stride: a sector's VirtualImage never exceeds 256x256 pages.
constexpr int MAX_VIRTUAL_PAGE_SIZE_SHIFT = 8;
constexpr int MAX_VIRTUAL_PAGE_SIZE = 1 << MAX_VIRTUAL_PAGE_SIZE_SHIFT;
// Feedback is downscaled 8x per axis from the camera resolution.
constexpr int PAGE_ID_TEXTURE_DOWNSCALE = 8;
// Indirection texture: one texel per virtual page, 1024x1024 pages, 11 mips.
constexpr int INDIRECTION_TEXTURE_SIZE = 1024;
constexpr int INDIRECTION_MIP_COUNT = 11;
// Smallest allocatable VirtualImage block, in pages.
constexpr int MINIMAL_VIRTUAL_IMAGE_SIZE = 1024;
constexpr uint32_t INVALID_PHYSICAL_PAGE_SLOT = 65535u;
// AVT owns global mip 0..8 (runtime generated). SVT starts at global mip 9.
constexpr int AVT_MAX_GLOBAL_MIP = 8;
constexpr int SVT_START_GLOBAL_MIP = AVT_MAX_GLOBAL_MIP + 1;
constexpr int DEFAULT_SVT_BAKE_MIP_BIAS = 0;
// Sector residency limits and per frame budgets.
constexpr int MAX_ACTIVE_SECTOR_COUNT = 256;
constexpr int UPDATE_INDIRECTION_TEXTURE_PER_FRAME = 64;
constexpr int MAX_INDIRECTION_UPDATES_PER_PAGE_WORK = 4;
// SVT keeps a fixed 4+1 fallback page set resident.
constexpr int FALLBACK_PAGE_COUNT = 5;
constexpr int MAX_DEDUPLICATED_PAGE_COUNT = 256;
constexpr int MAX_PRELOAD_SECTOR = 256;
constexpr int SECTOR_PRELOAD_DISTANCE = 6;
constexpr float CAMERA_POSITION_SQR_DELTA_THRESHOLD = 4.f;
// Sector LOD switch: squared distance where the size index steps coarser.
constexpr float SWITCH_DISTANCE = float(SECTOR_SIZE * SECTOR_SIZE) * 1.5f;

// Indirection texel payload: 11 bit physical page slot index.
constexpr int SLOT_BIT_COUNT = 11;
constexpr uint32_t SLOT_MASK = (1u << SLOT_BIT_COUNT) - 1u;
// Feedback texel payload: x:12 | y:12 | localMip:4 | sizeIndex:4.
constexpr uint32_t PAGE_COORDINATE_MASK = 0xFFFu;
constexpr uint32_t PAGE_NIBBLE_MASK = 0xFu;

// Descriptor table shape.
constexpr int DESCRIPTOR_COUNT = 16;
constexpr int FIRST_AVT_SIZE_INDEX = 1;
constexpr int LAST_AVT_SIZE_INDEX = 7;
constexpr int SVT_SIZE_INDEX = 15;
constexpr int CURRENT_TABLE_VERSION = 1;

// ─────────────────────────────────────────────────────────────────────────────
// Address profiles
// ─────────────────────────────────────────────────────────────────────────────

enum class AddressProfileId : int {
	INVALID = 0,
	BASE_800 = 1,
	BASE_1024 = 2,
};

enum class TexelDensityPreset : int {
	TEXELS_PER_CENTIMETER_10_24 = 0,
	TEXELS_PER_CENTIMETER_8 = 1,
	TEXELS_PER_CENTIMETER_4 = 2,
	TEXELS_PER_CENTIMETER_2 = 3,
};

struct VirtualImageDescriptor {
	int size_index = 0;
	int resolution_texels = 0;
	int mip0_page_count = 0;
	int allocation_block_size = 0;
	int min_global_mip = 0;
	int max_local_mip = 0;

	bool is_valid() const {
		return size_index > 0 && resolution_texels > 0 && mip0_page_count > 0 &&
				allocation_block_size > 0;
	}

	int calculate_mip_resolution(int local_mip) const {
		if (!is_valid() || local_mip < 0 || local_mip > max_local_mip) {
			return 0;
		}
		return std::max(1, resolution_texels >> local_mip);
	}

	int calculate_page_count(int local_mip) const {
		int resolution = calculate_mip_resolution(local_mip);
		return resolution <= 0 ? 0 : divide_round_up(resolution, PAGE_SIZE);
	}

	int calculate_allocation_block_size(int local_mip) const {
		if (!is_valid() || local_mip < 0 || local_mip > max_local_mip) {
			return 0;
		}
		return std::max(1, allocation_block_size >> local_mip);
	}

	// Padding pages of an NPOT tail return 0 valid texels.
	int calculate_valid_texels(int page_coordinate, int local_mip) const {
		int resolution = calculate_mip_resolution(local_mip);
		int page_count = calculate_page_count(local_mip);
		if (page_coordinate < 0 || page_coordinate >= page_count) {
			return 0;
		}
		return std::min(PAGE_SIZE, resolution - (page_coordinate * PAGE_SIZE));
	}

	static int divide_round_up(int value, int divisor) {
		return (value + divisor - 1) / divisor;
	}
};

struct AddressProfile {
	AddressProfileId id = AddressProfileId::INVALID;
	int base_texels_per_meter = 0;
	std::array<VirtualImageDescriptor, DESCRIPTOR_COUNT> descriptors{};

	bool is_valid() const { return id != AddressProfileId::INVALID && base_texels_per_meter > 0; }

	// Index 0 and uninitialized reserved slots return false.
	bool try_get_descriptor(int size_index, VirtualImageDescriptor &out) const {
		if (size_index < 0 || size_index >= DESCRIPTOR_COUNT) {
			out = VirtualImageDescriptor();
			return false;
		}
		const VirtualImageDescriptor &candidate = descriptors[size_index];
		out = candidate;
		return candidate.is_valid() && candidate.size_index == size_index;
	}

	bool try_get_avt_descriptor_by_allocation_block_size(int allocation_block_size,
			VirtualImageDescriptor &out) const {
		for (int size_index = FIRST_AVT_SIZE_INDEX; size_index <= LAST_AVT_SIZE_INDEX; size_index++) {
			const VirtualImageDescriptor &candidate = descriptors[size_index];
			if (candidate.allocation_block_size == allocation_block_size) {
				out = candidate;
				return true;
			}
		}
		out = VirtualImageDescriptor();
		return false;
	}

	// Mirrors TerrainAVTAddressProfile.ValidateAvtDescriptors.
	bool validate() const {
		if (!is_valid()) {
			return false;
		}
		if (descriptors[0].is_valid()) {
			return false;
		}
		for (int size_index = FIRST_AVT_SIZE_INDEX; size_index <= LAST_AVT_SIZE_INDEX; size_index++) {
			const VirtualImageDescriptor &descriptor = descriptors[size_index];
			if (!descriptor.is_valid() || descriptor.size_index != size_index ||
					descriptor.min_global_mip != size_index - FIRST_AVT_SIZE_INDEX ||
					descriptor.max_local_mip != AVT_MAX_GLOBAL_MIP - descriptor.min_global_mip ||
					descriptor.mip0_page_count > descriptor.allocation_block_size ||
					!is_power_of_two(descriptor.allocation_block_size)) {
				return false;
			}
			for (int local_mip = 0; local_mip <= descriptor.max_local_mip; local_mip++) {
				if (descriptor.calculate_page_count(local_mip) >
						descriptor.calculate_allocation_block_size(local_mip)) {
					return false;
				}
			}
		}
		return true;
	}

	static bool is_power_of_two(int value) {
		return value > 0 && (value & (value - 1)) == 0;
	}

	static int next_power_of_two(int value) {
		int result = 1;
		while (result < value) {
			result <<= 1;
		}
		return result;
	}
};

inline const AddressProfile &create_profile(AddressProfileId id, int base_texels_per_meter) {
	static std::array<AddressProfile, 3> cache{};
	static std::array<bool, 3> built{ { false, false, false } };
	const int slot = static_cast<int>(id);
	if (!built[slot]) {
		AddressProfile profile;
		profile.id = id;
		profile.base_texels_per_meter = base_texels_per_meter;
		for (int size_index = FIRST_AVT_SIZE_INDEX; size_index <= LAST_AVT_SIZE_INDEX; size_index++) {
			const int min_global_mip = size_index - FIRST_AVT_SIZE_INDEX;
			const int resolution_texels = (SECTOR_SIZE * base_texels_per_meter) >> min_global_mip;
			const int mip0_page_count = VirtualImageDescriptor::divide_round_up(resolution_texels, PAGE_SIZE);
			VirtualImageDescriptor descriptor;
			descriptor.size_index = size_index;
			descriptor.resolution_texels = resolution_texels;
			descriptor.mip0_page_count = mip0_page_count;
			descriptor.allocation_block_size = AddressProfile::next_power_of_two(mip0_page_count);
			descriptor.min_global_mip = min_global_mip;
			descriptor.max_local_mip = AVT_MAX_GLOBAL_MIP - min_global_mip;
			profile.descriptors[size_index] = descriptor;
		}
		cache[slot] = profile;
		built[slot] = true;
	}
	return cache[slot];
}

// Shared by 8, 4 and 2 texel/cm presets.
inline const AddressProfile &base_800() {
	return create_profile(AddressProfileId::BASE_800, 800);
}

// Used by the 10.24 texel/cm preset.
inline const AddressProfile &base_1024() {
	return create_profile(AddressProfileId::BASE_1024, 1024);
}

inline const AddressProfile *get_profile(AddressProfileId profile_id) {
	switch (profile_id) {
		case AddressProfileId::BASE_800:
			return &base_800();
		case AddressProfileId::BASE_1024:
			return &base_1024();
		default:
			return nullptr;
	}
}

struct AddressSelection {
	const AddressProfile *profile = nullptr;
	int finest_size_index = 0;
};

inline bool try_resolve(TexelDensityPreset preset, AddressSelection &out) {
	switch (preset) {
		case TexelDensityPreset::TEXELS_PER_CENTIMETER_2:
			out = { &base_800(), 3 };
			return true;
		case TexelDensityPreset::TEXELS_PER_CENTIMETER_4:
			out = { &base_800(), 2 };
			return true;
		case TexelDensityPreset::TEXELS_PER_CENTIMETER_8:
			out = { &base_800(), 1 };
			return true;
		case TexelDensityPreset::TEXELS_PER_CENTIMETER_10_24:
			out = { &base_1024(), 1 };
			return true;
		default:
			out = AddressSelection();
			return false;
	}
}

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

// Feedback texel payload written by the terrain fragment shader.
inline uint32_t pack_page_id(const PageId &page_id) {
	return ((page_id.x & PAGE_COORDINATE_MASK) << 20) |
			((page_id.y & PAGE_COORDINATE_MASK) << 8) |
			((page_id.z & PAGE_NIBBLE_MASK) << 4) |
			(page_id.w & PAGE_NIBBLE_MASK);
}

inline PageId unpack_page_id(uint32_t packed) {
	PageId page_id;
	page_id.x = (packed >> 20) & PAGE_COORDINATE_MASK;
	page_id.y = (packed >> 8) & PAGE_COORDINATE_MASK;
	page_id.z = (packed >> 4) & PAGE_NIBBLE_MASK;
	page_id.w = packed & PAGE_NIBBLE_MASK;
	return page_id;
}

// Indirection texel payload: the physical page slot.
inline uint32_t pack_indirection_entry(uint32_t slot) {
	return slot & SLOT_MASK;
}

// SectorImageInfo texture payload: block origin in page space + descriptor slot.
// allocation_block_size is the atlas block size stored in ImageInfo.size.
// Returns the canonical invalid value 0 when no AVT descriptor matches.
inline uint32_t pack_sector_image_info_for_shader(int block_origin_x, int block_origin_y,
		int allocation_block_size, const AddressProfile &profile) {
	const uint32_t offset_x = uint32_t(std::max(0, block_origin_x));
	const uint32_t offset_y = uint32_t(std::max(0, block_origin_y));
	VirtualImageDescriptor descriptor;
	if (!profile.try_get_avt_descriptor_by_allocation_block_size(allocation_block_size,
				descriptor)) {
		return 0u;
	}
	return ((offset_x & PAGE_COORDINATE_MASK) << 20) |
			((offset_y & PAGE_COORDINATE_MASK) << 8) |
			(uint32_t(descriptor.size_index) & 0xFFu);
}

// Resolves the descriptor, POT block origin and mip0 local page coordinate.
inline bool try_resolve_avt_page_address(const PageId &page_id, const AddressProfile &profile,
		VirtualImageDescriptor &descriptor, int &block_origin_x, int &block_origin_y,
		int &local_page_x, int &local_page_y) {
	descriptor = VirtualImageDescriptor();
	block_origin_x = 0;
	block_origin_y = 0;
	local_page_x = 0;
	local_page_y = 0;
	if (page_id.w == 0u || !profile.try_get_descriptor(int(page_id.w), descriptor) ||
			page_id.z > uint32_t(descriptor.max_local_mip)) {
		return false;
	}
	const int page_at_mip0_x = int(page_id.x) << page_id.z;
	const int page_at_mip0_y = int(page_id.y) << page_id.z;
	block_origin_x = (page_at_mip0_x / descriptor.allocation_block_size) *
			descriptor.allocation_block_size;
	block_origin_y = (page_at_mip0_y / descriptor.allocation_block_size) *
			descriptor.allocation_block_size;
	local_page_x = page_at_mip0_x - block_origin_x;
	local_page_y = page_at_mip0_y - block_origin_y;
	return local_page_x >= 0 && local_page_y >= 0 &&
			local_page_x < descriptor.mip0_page_count &&
			local_page_y < descriptor.mip0_page_count;
}

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

// Global LRU key shared across VirtualImage LOD levels.
inline uint64_t encode_lru_key(int sector_x, int sector_y, int local_page_x, int local_page_y,
		int mip, const VirtualImageDescriptor &descriptor) {
	const int allocation_block_size_log = log2_power_of_two(descriptor.allocation_block_size);
	const int virtual_page_x = MAX_VIRTUAL_PAGE_SIZE * sector_x +
			(local_page_x << (MAX_VIRTUAL_PAGE_SIZE_SHIFT - allocation_block_size_log));
	const int virtual_page_y = MAX_VIRTUAL_PAGE_SIZE * sector_y +
			(local_page_y << (MAX_VIRTUAL_PAGE_SIZE_SHIFT - allocation_block_size_log));
	const int physical_mip = descriptor.min_global_mip + mip;
	return (uint64_t(uint32_t(virtual_page_x >> physical_mip)) << 32) +
			(uint64_t(uint32_t(virtual_page_y >> physical_mip)) << 8) +
			uint64_t(uint32_t(physical_mip));
}

inline void decode_lru_key(uint64_t lru_key, int &virtual_page_x, int &virtual_page_y, int &mip) {
	virtual_page_x = int((lru_key >> 32) & 0xFFFFFFu);
	virtual_page_y = int((lru_key >> 8) & 0xFFFFFFu);
	mip = int(lru_key & 0xFFu);
}

// Sector LOD selection: 1.5 sector areas of squared distance per size index step.
inline int calculate_target_size_index(int sector_x, int sector_y, float terrain_origin_x,
		float terrain_origin_z, float camera_x, float camera_z, const AddressSelection &selection) {
	const float center_x = terrain_origin_x + (float(sector_x) * SECTOR_SIZE) + (SECTOR_SIZE * 0.5f);
	const float center_z = terrain_origin_z + (float(sector_y) * SECTOR_SIZE) + (SECTOR_SIZE * 0.5f);
	const float delta_x = center_x - camera_x;
	const float delta_z = center_z - camera_z;
	const float distance_sq = (delta_x * delta_x) + (delta_z * delta_z);
	const float t = distance_sq / SWITCH_DISTANCE;
	const int lod_image = t >= 1.f ? (int(std::floor(std::log2(t))) + 1) : 0;
	return std::clamp(selection.finest_size_index + std::max(0, lod_image),
			selection.finest_size_index, LAST_AVT_SIZE_INDEX);
}

// Physical page content UV: the fixed 4 texel border offset is preserved.
inline void calculate_physical_page_uv(float position_x, float position_z, float terrain_origin_x,
		float terrain_origin_z, int matched_mip, const VirtualImageDescriptor &descriptor,
		float &out_u, float &out_v) {
	const int safe_mip = std::clamp(matched_mip, 0, descriptor.max_local_mip);
	const int mip_resolution = descriptor.calculate_mip_resolution(safe_mip);
	const float sector_u = (position_x - terrain_origin_x) / float(SECTOR_SIZE);
	const float sector_v = (position_z - terrain_origin_z) / float(SECTOR_SIZE);
	const float frac_u = sector_u - std::floor(sector_u);
	const float frac_v = sector_v - std::floor(sector_v);
	const float page_u = (frac_u * mip_resolution / float(PAGE_SIZE)) * PAGE_SIZE;
	const float page_v = (frac_v * mip_resolution / float(PAGE_SIZE)) * PAGE_SIZE;
	const float in_page_u = page_u - std::floor(page_u / PAGE_SIZE) * PAGE_SIZE;
	const float in_page_v = page_v - std::floor(page_v / PAGE_SIZE) * PAGE_SIZE;
	out_u = (in_page_u + BORDER_SIZE) / float(PAGE_SIZE_WITH_BORDER);
	out_v = (in_page_v + BORDER_SIZE) / float(PAGE_SIZE_WITH_BORDER);
}

struct WorldRect {
	float x = 0.f;
	float z = 0.f;
	float size_x = 0.f;
	float size_z = 0.f;
};

// Full content slot world rect; the optional border never clips an NPOT tail.
inline WorldRect calculate_physical_page_world_rect(int sector_x, int sector_y,
		float terrain_origin_x, float terrain_origin_z, int local_page_x, int local_page_y, int mip,
		const VirtualImageDescriptor &descriptor, bool include_border) {
	const int safe_mip = std::clamp(mip, 0, descriptor.max_local_mip);
	const int mip_resolution = descriptor.calculate_mip_resolution(safe_mip);
	const float mip0_texel_world_size = float(SECTOR_SIZE) / float(descriptor.resolution_texels);
	const float page_world_size = PAGE_SIZE * float(SECTOR_SIZE) / float(mip_resolution);
	const float min_x = terrain_origin_x + (float(sector_x) * SECTOR_SIZE) +
			(float(local_page_x) * PAGE_SIZE * mip0_texel_world_size);
	const float min_z = terrain_origin_z + (float(sector_y) * SECTOR_SIZE) +
			(float(local_page_y) * PAGE_SIZE * mip0_texel_world_size);
	if (!include_border) {
		return { min_x, min_z, page_world_size, page_world_size };
	}
	const float border_world_size = page_world_size * BORDER_SIZE / float(PAGE_SIZE);
	const float size_with_border = page_world_size + (border_world_size * 2.f);
	return { min_x - border_world_size, min_z - border_world_size, size_with_border, size_with_border };
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

// Allocation order decides which quadrant is searched first, so AVT clusters in
// low coordinates and SVT lands in high coordinates of the same page space.
enum class AllocationOrder : uint8_t {
	LOW_COORDINATES_FIRST = 0,
	HIGH_COORDINATES_FIRST = 1,
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
		mark_child_as_used_.assign(node_count, 0);
		mark_as_used_.assign(node_count + current_size_node_count, false);
		node_owners_.assign(mark_as_used_.size(), VirtualImageOwner());
	}

	// Hydra default: 1024x1024 page space, minimum block 4x4 pages.
	static VirtualImageAtlas create_default() {
		return VirtualImageAtlas(INDIRECTION_TEXTURE_SIZE, MINIMAL_VIRTUAL_IMAGE_SIZE >> PAGE_SIZE_SHIFT);
	}

	int atlas_size() const { return atlas_size_; }
	int minimal_virtual_image_size() const { return minimal_virtual_image_size_; }
	// Hydra markAsUsed_.Length: internal nodes plus the leaf ring.
	int node_capacity() const { return int(mark_as_used_.size()); }
	// Hydra markChildAsUsed_.Length: nodes that can own children.
	int internal_node_count() const { return int(mark_child_as_used_.size()); }
	int allocated_node_count() const {
		int count = 0;
		for (bool used : mark_as_used_) {
			if (used) {
				count++;
			}
		}
		return count;
	}

	void clear() {
		std::fill(mark_as_used_.begin(), mark_as_used_.end(), false);
		std::fill(mark_child_as_used_.begin(), mark_child_as_used_.end(), int16_t(0));
		std::fill(node_owners_.begin(), node_owners_.end(), VirtualImageOwner());
		sector_to_image_.clear();
		owner_to_image_.clear();
		next_generation_ = 1;
	}

	// SVT uses the high coordinate half so AVT keeps the low coordinates.
	bool try_insert_svt_image(int virtual_image_size, VirtualImageOwner &owner, ImageInfo &image_info) {
		owner = create_owner(0, 0, VirtualImageKind::SVT);
		return try_allocate_free(owner, virtual_image_size, AllocationOrder::HIGH_COORDINATES_FIRST,
				image_info);
	}

	bool try_insert_avt_image(int sector_x, int sector_y, int virtual_image_size,
			VirtualImageOwner &owner, ImageInfo &image_info) {
		owner = create_owner(sector_x, sector_y, VirtualImageKind::AVT);
		if (!try_allocate_free(owner, virtual_image_size, AllocationOrder::LOW_COORDINATES_FIRST,
					image_info)) {
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

	bool has_owner(const VirtualImageOwner &owner) const {
		return owner_to_image_.find(owner) != owner_to_image_.end();
	}

	bool try_get_image_info(const VirtualImageOwner &owner, ImageInfo &image_info) const {
		auto found = owner_to_image_.find(owner);
		if (found == owner_to_image_.end()) {
			image_info = ImageInfo();
			return false;
		}
		image_info = found->second;
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
		if (try_allocate_free(resized_owner, virtual_image_size,
				AllocationOrder::LOW_COORDINATES_FIRST, new_info)) {
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
			AllocationOrder allocation_order, ImageInfo &image_info) {
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
				push_children(travel_stack, current, allocation_order);
				continue;
			}
			if (current.size == virtual_image_size &&
					(virtual_image_size == minimal_virtual_image_size_ ||
							mark_child_as_used_[current.node_index] == 0)) {
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
			mark_child_as_used_[parent]++;
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
			mark_child_as_used_[parent]--;
			if (parent == 0) {
				break;
			}
			parent = parent_of(parent);
		}
	}

	static void push_children(std::vector<ImageInfo> &stack, const ImageInfo &node,
			AllocationOrder allocation_order) {
		const int half_size = node.size >> 1;
		const int child_node_index = node.node_index << 2;
		const ImageInfo low_low{ child_node_index + 1, node.origin_x, node.origin_y, half_size };
		const ImageInfo high_low{ child_node_index + 2, node.origin_x + half_size, node.origin_y,
			half_size };
		const ImageInfo low_high{ child_node_index + 3, node.origin_x, node.origin_y + half_size,
			half_size };
		const ImageInfo high_high{ child_node_index + 4, node.origin_x + half_size,
			node.origin_y + half_size, half_size };
		if (allocation_order == AllocationOrder::HIGH_COORDINATES_FIRST) {
			stack.push_back(low_low);
			stack.push_back(high_low);
			stack.push_back(low_high);
			stack.push_back(high_high);
			return;
		}
		stack.push_back(high_high);
		stack.push_back(low_high);
		stack.push_back(high_low);
		stack.push_back(low_low);
	}

	int atlas_size_ = 0;
	int minimal_virtual_image_size_ = 0;
	std::vector<bool> mark_as_used_;
	std::vector<int16_t> mark_child_as_used_;
	std::vector<VirtualImageOwner> node_owners_;
	std::unordered_map<std::pair<int, int>, ImageInfo, SectorHash> sector_to_image_;
	std::unordered_map<VirtualImageOwner, ImageInfo, VirtualImageOwnerHash> owner_to_image_;
	uint32_t next_generation_ = 1;
};

// ─────────────────────────────────────────────────────────────────────────────
// Feedback sizing
// ─────────────────────────────────────────────────────────────────────────────

// Feedback is reference_size / 8 + 1 texels per axis.
inline void calculate_feedback_size(int reference_width, int reference_height, int &out_width,
		int &out_height) {
	out_width = std::max(1, reference_width / PAGE_ID_TEXTURE_DOWNSCALE + 1);
	out_height = std::max(1, reference_height / PAGE_ID_TEXTURE_DOWNSCALE + 1);
}

// 8x8 Bayer matrix index used to pick the sub-pixel that writes feedback.
inline int bayer_dither_8x8(int row, int column) {
	static const int matrix[8][8] = {
		{ 0, 32, 8, 40, 2, 34, 10, 42 },
		{ 48, 16, 56, 24, 50, 18, 58, 26 },
		{ 12, 44, 4, 36, 14, 46, 6, 38 },
		{ 60, 28, 52, 20, 62, 30, 54, 22 },
		{ 3, 35, 11, 43, 1, 33, 9, 41 },
		{ 51, 19, 59, 27, 49, 17, 57, 25 },
		{ 15, 47, 7, 39, 13, 45, 5, 37 },
		{ 63, 31, 55, 23, 61, 29, 53, 21 },
	};
	return matrix[row & 7][column & 7];
}

inline int normalize_dither_index(int dither_index) {
	constexpr int BAYER_SAMPLE_COUNT = 64;
	const int normalized = dither_index % BAYER_SAMPLE_COUNT;
	return normalized < 0 ? normalized + BAYER_SAMPLE_COUNT : normalized;
}

// Returns the sub-pixel offset inside one 8x8 screen block.
inline void get_dither_for_index(int dither_index, int &out_x, int &out_y) {
	const int normalized = normalize_dither_index(dither_index);
	const int value = bayer_dither_8x8(normalized / PAGE_ID_TEXTURE_DOWNSCALE,
			normalized % PAGE_ID_TEXTURE_DOWNSCALE);
	out_x = value / PAGE_ID_TEXTURE_DOWNSCALE;
	out_y = value % PAGE_ID_TEXTURE_DOWNSCALE;
}
} // namespace TerrainVT

#endif // TERRAIN_VT_H
