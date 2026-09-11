// Contract test for the Hydra-compatible terrain virtual texture addressing
// core in src/terrain_vt.h. Standalone: no Godot, no GPU.
#include "../../src/terrain_vt.h"

#include <cstdlib>
#include <iostream>
#include <vector>

using namespace TerrainVT;

#define CHECK(condition)                                                                  \
	do {                                                                                  \
		if (!(condition)) {                                                               \
			std::cerr << "FAIL line " << __LINE__ << ": " #condition << '\n';             \
			std::exit(1);                                                                 \
		}                                                                                 \
	} while (false)

#define CHECK_EQ(actual, expected)                                                        \
	do {                                                                                  \
		auto a_ = (actual);                                                               \
		auto e_ = (expected);                                                             \
		if (!(a_ == e_)) {                                                                \
			std::cerr << "FAIL line " << __LINE__ << ": " #actual " == " << a_            \
					  << " expected " << e_ << '\n';                                      \
			std::exit(1);                                                                 \
		}                                                                                 \
	} while (false)

static bool near(float a, float b, float epsilon = 1e-5f) {
	return std::fabs(a - b) <= epsilon;
}

// ── Constants parity with TerrainAVTConstants ───────────────────────────────
static void test_constants() {
	CHECK_EQ(SECTOR_SIZE, 64);
	CHECK_EQ(PAGE_SIZE_SHIFT, 8);
	CHECK_EQ(PAGE_SIZE, 256);
	CHECK_EQ(BORDER_SIZE, 4);
	CHECK_EQ(PAGE_SIZE_WITH_BORDER, 264);
	CHECK_EQ(MAX_VIRTUAL_PAGE_SIZE, 256);
	CHECK_EQ(PAGE_ID_TEXTURE_DOWNSCALE, 8);
	CHECK_EQ(INDIRECTION_TEXTURE_SIZE, 1024);
	CHECK_EQ(INDIRECTION_MIP_COUNT, 11);
	CHECK_EQ(MINIMAL_VIRTUAL_IMAGE_SIZE, 1024);
	CHECK_EQ(INVALID_PHYSICAL_PAGE_SLOT, 65535u);
	CHECK_EQ(AVT_MAX_GLOBAL_MIP, 8);
	CHECK_EQ(SVT_START_GLOBAL_MIP, 9);
	CHECK_EQ(MAX_ACTIVE_SECTOR_COUNT, 256);
	CHECK_EQ(UPDATE_INDIRECTION_TEXTURE_PER_FRAME, 64);
	CHECK_EQ(FALLBACK_PAGE_COUNT, 5);
	CHECK_EQ(SECTOR_PRELOAD_DISTANCE, 6);
	CHECK_EQ(SLOT_BIT_COUNT, 11);
	CHECK_EQ(SLOT_MASK, 2047u);
	// SwitchDistance = SectorSize * SectorSize * 1.5
	CHECK(near(SWITCH_DISTANCE, 6144.f));
}

// ── Descriptor tables parity with TerrainAVTAddressProfiles ─────────────────
static void test_profiles() {
	const AddressProfile &base800 = base_800();
	CHECK(base800.validate());
	CHECK_EQ(base800.base_texels_per_meter, 800);
	CHECK(base800.id == AddressProfileId::BASE_800);
	CHECK_EQ(int(base800.descriptors.size()), DESCRIPTOR_COUNT);

	// Index 0 must stay invalid; SVT slot 15 is reserved and uninitialized here.
	CHECK(!base800.descriptors[0].is_valid());
	VirtualImageDescriptor reserved;
	CHECK(!base800.try_get_descriptor(0, reserved));
	CHECK(!base800.try_get_descriptor(8, reserved));
	CHECK(!base800.try_get_descriptor(-1, reserved));

	// Base800: 64 m * 800 texels/m = 51200 texels at global mip 0.
	const int expected_resolution[7] = { 51200, 25600, 12800, 6400, 3200, 1600, 800 };
	const int expected_pages[7] = { 200, 100, 50, 25, 13, 7, 4 };
	const int expected_block[7] = { 256, 128, 64, 32, 16, 8, 4 };
	for (int index = 0; index < 7; index++) {
		const int size_index = FIRST_AVT_SIZE_INDEX + index;
		VirtualImageDescriptor descriptor;
		CHECK(base800.try_get_descriptor(size_index, descriptor));
		CHECK_EQ(descriptor.size_index, size_index);
		CHECK_EQ(descriptor.min_global_mip, index);
		CHECK_EQ(descriptor.max_local_mip, AVT_MAX_GLOBAL_MIP - index);
		CHECK_EQ(descriptor.resolution_texels, expected_resolution[index]);
		CHECK_EQ(descriptor.mip0_page_count, expected_pages[index]);
		CHECK_EQ(descriptor.allocation_block_size, expected_block[index]);
		CHECK(AddressProfile::is_power_of_two(descriptor.allocation_block_size));
		// A descriptor's own local mip 0 sits at global mip index, so its density
		// is the profile's base halved index times.
		CHECK_EQ(descriptor.resolution_texels / SECTOR_SIZE, 800 >> index);
	}

	const AddressProfile &base1024 = base_1024();
	CHECK(base1024.validate());
	CHECK_EQ(base1024.base_texels_per_meter, 1024);
	const int expected_1024_pages[7] = { 256, 128, 64, 32, 16, 8, 4 };
	for (int index = 0; index < 7; index++) {
		VirtualImageDescriptor descriptor;
		CHECK(base1024.try_get_descriptor(FIRST_AVT_SIZE_INDEX + index, descriptor));
		CHECK_EQ(descriptor.resolution_texels, 65536 >> index);
		CHECK_EQ(descriptor.mip0_page_count, expected_1024_pages[index]);
		CHECK_EQ(descriptor.allocation_block_size, expected_1024_pages[index]);
		CHECK_EQ(descriptor.resolution_texels / SECTOR_SIZE, 1024 >> index);
	}

	// Allocation block sizes are unique per profile, so the reverse lookup is total.
	for (int size_index = FIRST_AVT_SIZE_INDEX; size_index <= LAST_AVT_SIZE_INDEX; size_index++) {
		VirtualImageDescriptor forward;
		CHECK(base800.try_get_descriptor(size_index, forward));
		VirtualImageDescriptor reverse;
		CHECK(base800.try_get_avt_descriptor_by_allocation_block_size(
				forward.allocation_block_size, reverse));
		CHECK_EQ(reverse.size_index, size_index);
	}
	VirtualImageDescriptor missing;
	CHECK(!base800.try_get_avt_descriptor_by_allocation_block_size(1024, missing));
	CHECK(!base800.try_get_avt_descriptor_by_allocation_block_size(0, missing));

	// Density presets resolve to the matching profile and finest descriptor.
	AddressSelection selection;
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_8, selection));
	CHECK(selection.profile == &base800);
	CHECK_EQ(selection.finest_size_index, 1);
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_4, selection));
	CHECK(selection.profile == &base800);
	CHECK_EQ(selection.finest_size_index, 2);
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_2, selection));
	CHECK(selection.profile == &base800);
	CHECK_EQ(selection.finest_size_index, 3);
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_10_24, selection));
	CHECK(selection.profile == &base1024);
	CHECK_EQ(selection.finest_size_index, 1);
	CHECK(!try_resolve(TexelDensityPreset(9), selection));
	CHECK(get_profile(AddressProfileId::BASE_800) == &base800);
	CHECK(get_profile(AddressProfileId::INVALID) == nullptr);

	// Valid texels shrink on the NPOT tail page and vanish past the last page.
	VirtualImageDescriptor coarse;
	CHECK(base800.try_get_descriptor(7, coarse)); // 800 texels, 4 pages
	CHECK_EQ(coarse.calculate_mip_resolution(0), 800);
	CHECK_EQ(coarse.calculate_page_count(0), 4);
	CHECK_EQ(coarse.calculate_valid_texels(3, 0), 800 - (3 * PAGE_SIZE));
	CHECK_EQ(coarse.calculate_valid_texels(4, 0), 0);
	CHECK_EQ(coarse.calculate_valid_texels(-1, 0), 0);
	CHECK_EQ(coarse.calculate_allocation_block_size(0), 4);
	CHECK_EQ(coarse.calculate_allocation_block_size(1), 2);
	CHECK_EQ(coarse.calculate_allocation_block_size(2), 1);
	CHECK_EQ(coarse.calculate_allocation_block_size(3), 0); // past max_local_mip
	CHECK_EQ(coarse.calculate_mip_resolution(3), 0);
}

// ── PageID bit layout parity with TerrainAVTUtility ────────────────────────
static void test_page_id() {
	CHECK_EQ(pack_page_id({ 0xFFF, 0xFFF, 0xF, 0xF }), 0xFFFFFFFFu);
	CHECK_EQ(pack_page_id({ 0, 0, 0, 0 }), 0u);
	CHECK_EQ(pack_page_id({ 0xABC, 0x123, 5, 3 }), (0xABCu << 20) | (0x123u << 8) | (5u << 4) | 3u);

	// Round trip across the whole encodable range of each field.
	for (uint32_t x = 0; x <= PAGE_COORDINATE_MASK; x += 37) {
		for (uint32_t y = 0; y <= PAGE_COORDINATE_MASK; y += 53) {
			for (uint32_t z = 0; z <= PAGE_NIBBLE_MASK; z++) {
				for (uint32_t w = 0; w <= PAGE_NIBBLE_MASK; w += 3) {
					const PageId page_id{ x, y, z, w };
					const PageId decoded = unpack_page_id(pack_page_id(page_id));
					CHECK(decoded == page_id);
				}
			}
		}
	}
	// Field overflow is masked, never carried into the neighbour field.
	const PageId clamped = unpack_page_id(pack_page_id({ 0x1234, 0x2345, 0x1F, 0x2A }));
	CHECK_EQ(clamped.x, 0x234u);
	CHECK_EQ(clamped.y, 0x345u);
	CHECK_EQ(clamped.z, 0xFu);
	CHECK_EQ(clamped.w, 0xAu);

	// Indirection payload keeps 11 bits.
	CHECK_EQ(pack_indirection_entry(0u), 0u);
	CHECK_EQ(pack_indirection_entry(2047u), 2047u);
	CHECK_EQ(pack_indirection_entry(2048u), 0u);
	CHECK_EQ(pack_indirection_entry(INVALID_PHYSICAL_PAGE_SLOT), INVALID_PHYSICAL_PAGE_SLOT & SLOT_MASK);

	// SectorImageInfo: block origin in page space plus the descriptor slot byte.
	const AddressProfile &base800 = base_800();
	const uint32_t info = pack_sector_image_info_for_shader(16, 32, 16, base800);
	CHECK_EQ(info, (16u << 20) | (32u << 8) | 5u);
	// No AVT descriptor owns block size 1024 in Base800.
	CHECK_EQ(pack_sector_image_info_for_shader(16, 32, 1024, base800), 0u);
}

static void test_page_address() {
	const AddressProfile &base800 = base_800();
	VirtualImageDescriptor descriptor;
	int origin_x = 0;
	int origin_y = 0;
	int local_x = 0;
	int local_y = 0;

	// Descriptor 1: block 256, 200 valid mip0 pages.
	CHECK(try_resolve_avt_page_address({ 10, 20, 0, 1 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	CHECK_EQ(descriptor.size_index, 1);
	CHECK_EQ(origin_x, 0);
	CHECK_EQ(origin_y, 0);
	CHECK_EQ(local_x, 10);
	CHECK_EQ(local_y, 20);

	// Page 200 is outside the 200 page mip0 extent.
	CHECK(!try_resolve_avt_page_address({ 200, 0, 0, 1 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	// Mip coordinates are local to their own mip, then scaled back to mip0.
	CHECK(!try_resolve_avt_page_address({ 100, 0, 1, 1 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));

	// Descriptor 5: block 16, 13 valid mip0 pages, so a page at 20 lives in the
	// block starting at page 16 and resolves to local page 4.
	CHECK(try_resolve_avt_page_address({ 20, 0, 0, 5 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	CHECK_EQ(origin_x, 16);
	CHECK_EQ(origin_y, 0);
	CHECK_EQ(local_x, 4);
	CHECK_EQ(local_y, 0);
	CHECK(try_resolve_avt_page_address({ 16, 0, 0, 5 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	CHECK_EQ(origin_x, 16);
	CHECK_EQ(local_x, 0);
	// Page 15 belongs to the previous block, which has no valid page 15.
	CHECK(!try_resolve_avt_page_address({ 15, 0, 0, 5 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));

	// Invalid size index and out of range mip are rejected.
	CHECK(!try_resolve_avt_page_address({ 0, 0, 0, 0 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	CHECK(!try_resolve_avt_page_address({ 0, 0, 9, 1 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
	CHECK(!try_resolve_avt_page_address({ 0, 0, 0, 8 }, base800, descriptor, origin_x, origin_y,
			local_x, local_y));
}

static void test_indirection_lookup() {
	// A slot only exists at local mip 2, so a request for mip 0 must walk up.
	auto lookup = [](uint32_t x, uint32_t y, uint32_t mip) -> uint32_t {
		if (mip == 2 && x == 5 && y == 7) {
			return 123u;
		}
		return INVALID_PHYSICAL_PAGE_SLOT;
	};
	uint32_t slot = 0;
	uint32_t matched_x = 0;
	uint32_t matched_y = 0;
	uint32_t matched_mip = 0;
	CHECK(try_match_indirection_slot({ 20, 28, 0, 1 }, 8, lookup, slot, matched_x, matched_y,
			matched_mip));
	CHECK_EQ(slot, 123u);
	CHECK_EQ(matched_x, 5u);
	CHECK_EQ(matched_y, 7u);
	CHECK_EQ(matched_mip, 2u);

	// Slot values are masked to 11 bits. 0xFFFE is not the invalid sentinel, so
	// the lookup still hits and the stored slot keeps only 0x7FE.
	auto wide = [](uint32_t, uint32_t, uint32_t) -> uint32_t { return 0xFFFEu; };
	CHECK(try_match_indirection_slot({ 1, 1, 0, 1 }, 8, wide, slot, matched_x, matched_y,
			matched_mip));
	CHECK_EQ(slot, 0x7FEu);

	// Nothing resident anywhere in the chain.
	auto empty = [](uint32_t, uint32_t, uint32_t) -> uint32_t { return INVALID_PHYSICAL_PAGE_SLOT; };
	CHECK(!try_match_indirection_slot({ 1, 1, 0, 1 }, 8, empty, slot, matched_x, matched_y,
			matched_mip));
	CHECK_EQ(slot, INVALID_PHYSICAL_PAGE_SLOT);
	// Invalid size index short circuits.
	CHECK(!try_match_indirection_slot({ 1, 1, 0, 0 }, 8, empty, slot, matched_x, matched_y,
			matched_mip));
	// Requested mip beyond the descriptor's max local mip short circuits.
	CHECK(!try_match_indirection_slot({ 1, 1, 9, 1 }, 8, empty, slot, matched_x, matched_y,
			matched_mip));
}

static void test_lru_key() {
	const AddressProfile &base800 = base_800();
	VirtualImageDescriptor fine;
	CHECK(base800.try_get_descriptor(1, fine)); // block 256, min global mip 0
	int x = 0;
	int y = 0;
	int mip = 0;
	CHECK_EQ(encode_lru_key(1, 2, 0, 0, 0, fine), (uint64_t(256) << 32) + (uint64_t(512) << 8));
	decode_lru_key(encode_lru_key(1, 2, 0, 0, 0, fine), x, y, mip);
	CHECK_EQ(x, 256);
	CHECK_EQ(y, 512);
	CHECK_EQ(mip, 0);

	// A coarser descriptor shifts the same world page onto a shared global mip.
	// Local page coordinates are normalized to the 256 page per sector space, so
	// descriptor 3 (block 64) scales its local page 8 up by 256/64 = 4.
	VirtualImageDescriptor coarse;
	CHECK(base800.try_get_descriptor(3, coarse)); // block 64, min global mip 2
	const uint64_t fine_key = encode_lru_key(1, 0, 8, 0, 0, fine);
	const uint64_t coarse_key = encode_lru_key(1, 0, 8, 0, 0, coarse);
	CHECK(fine_key != coarse_key);
	decode_lru_key(fine_key, x, y, mip);
	CHECK_EQ(mip, 0);
	CHECK_EQ(x, 256 + 8);
	CHECK_EQ(y, 0);
	decode_lru_key(coarse_key, x, y, mip);
	CHECK_EQ(mip, 2);
	CHECK_EQ(x, (256 + (8 << 2)) >> 2);
	CHECK_EQ(y, 0);

	// Round trip over a sector neighbourhood and every local mip. Sector
	// coordinates are terrain local and therefore non-negative: the key packs
	// 24 bits per axis, so negative sectors are outside the contract.
	for (int sx = 0; sx <= 4; sx++) {
		for (int sy = 0; sy <= 4; sy++) {
			for (int local_mip = 0; local_mip <= fine.max_local_mip; local_mip++) {
				const uint64_t key = encode_lru_key(sx, sy, 3, 5, local_mip, fine);
				decode_lru_key(key, x, y, mip);
				CHECK_EQ(mip, local_mip);
				CHECK_EQ(x, (256 * sx + 3) >> local_mip);
				CHECK_EQ(y, (256 * sy + 5) >> local_mip);
			}
		}
	}
	// At a fixed mip the key is injective over the valid local page range.
	{
		std::vector<uint64_t> keys;
		for (int sx = 0; sx < 3; sx++) {
			for (int sy = 0; sy < 3; sy++) {
				for (int lx = 0; lx < fine.mip0_page_count; lx += 7) {
					for (int ly = 0; ly < fine.mip0_page_count; ly += 11) {
						keys.push_back(encode_lru_key(sx, sy, lx, ly, 0, fine));
					}
				}
			}
		}
		std::sort(keys.begin(), keys.end());
		CHECK(std::adjacent_find(keys.begin(), keys.end()) == keys.end());
	}
	CHECK_EQ(log2_power_of_two(1), 0);
	CHECK_EQ(log2_power_of_two(256), 8);
	CHECK_EQ(log2_power_of_two(0), 0);
}

static void test_target_size_index() {
	AddressSelection selection;
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_8, selection));
	// Sector (0,0) spans 0..64 m, so its center is (32, 32).
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, 32.f, 32.f, selection), 1);
	// SwitchDistance = 1.5 sector areas = 6144 m^2, so t = 1 at 78.38 m and the
	// size index steps one coarser. t quadruples per doubling of distance, and
	// lodImage = floor(log2(t)) + 1, so the index steps every sqrt(2) distance.
	const float base_x = 32.f;
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, base_x + std::sqrt(6144.f), 32.f, selection), 2);
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, base_x + std::sqrt(24576.f), 32.f, selection), 4);
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, base_x + std::sqrt(98304.f), 32.f, selection), 6);
	// Clamped to the last AVT descriptor.
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, base_x + 100000.f, 32.f, selection),
			LAST_AVT_SIZE_INDEX);
	// Monotone non-decreasing as the sector recedes.
	int previous = 0;
	for (float distance = 0.f; distance < 4000.f; distance += 7.f) {
		const int size_index = calculate_target_size_index(0, 0, 0.f, 0.f, base_x + distance, 32.f,
				selection);
		CHECK(size_index >= previous);
		CHECK(size_index >= selection.finest_size_index);
		CHECK(size_index <= LAST_AVT_SIZE_INDEX);
		previous = size_index;
	}
	// Terrain origin offsets the sector grid.
	CHECK_EQ(calculate_target_size_index(1, 0, -64.f, 0.f, 32.f, 32.f, selection), 1);
	// A 4 texel/cm preset starts two descriptors coarser.
	AddressSelection coarse_selection;
	CHECK(try_resolve(TexelDensityPreset::TEXELS_PER_CENTIMETER_4, coarse_selection));
	CHECK_EQ(calculate_target_size_index(0, 0, 0.f, 0.f, 32.f, 32.f, coarse_selection), 2);
}

static void test_physical_page_math() {
	const AddressProfile &base800 = base_800();
	VirtualImageDescriptor fine;
	CHECK(base800.try_get_descriptor(1, fine));

	// Descriptor 1: 51200 texels over 64 m, so one 256 texel page is 0.32 m.
	const WorldRect rect = calculate_physical_page_world_rect(0, 0, 0.f, 0.f, 1, 0, 0, fine, false);
	CHECK(near(rect.x, 0.32f));
	CHECK(near(rect.z, 0.f));
	CHECK(near(rect.size_x, 0.32f));
	CHECK(near(rect.size_z, 0.32f));
	const WorldRect bordered = calculate_physical_page_world_rect(0, 0, 0.f, 0.f, 1, 0, 0, fine, true);
	CHECK(near(bordered.x, 0.32f - 0.005f));
	CHECK(near(bordered.size_x, 0.33f));

	// Sector offsets move the rect by whole sectors.
	const WorldRect shifted = calculate_physical_page_world_rect(1, 2, 0.f, 0.f, 0, 0, 0, fine, false);
	CHECK(near(shifted.x, 64.f));
	CHECK(near(shifted.z, 128.f));

	// UV: the page center of page 100 sits at texel 128, plus the 4 texel border.
	float u = 0.f;
	float v = 0.f;
	calculate_physical_page_uv(0.16f, 0.f, 0.f, 0.f, 0, fine, u, v);
	CHECK(near(u, 132.f / 264.f));
	CHECK(near(v, 4.f / 264.f));
	// The border texel itself maps to the first content texel.
	calculate_physical_page_uv(0.f, 0.f, 0.f, 0.f, 0, fine, u, v);
	CHECK(near(u, 4.f / 264.f));
	// A position in the next sector wraps to the same in-page UV.
	calculate_physical_page_uv(64.f, 64.f, 0.f, 0.f, 0, fine, u, v);
	CHECK(near(u, 4.f / 264.f));
	CHECK(near(v, 4.f / 264.f));
}

// ── VirtualImageAtlas parity with TerrainVirtualImageAtlas ─────────────────
static void test_virtual_image_atlas() {
	VirtualImageAtlas atlas = VirtualImageAtlas::create_default();
	CHECK_EQ(atlas.atlas_size(), 1024);
	// MinimalVirtualImageSize >> PageSizeShift == 4 pages.
	CHECK_EQ(atlas.minimal_virtual_image_size(), 4);
	CHECK_EQ(atlas.internal_node_count(), 21845);
	CHECK_EQ(atlas.node_capacity(), 87381);
	CHECK_EQ(atlas.allocated_node_count(), 0);

	// Sizes must be POT, at least the minimal image, at most the atlas.
	VirtualImageOwner owner;
	ImageInfo info;
	CHECK(!atlas.try_insert_avt_image(0, 0, 3, owner, info));
	CHECK(!atlas.try_insert_avt_image(0, 0, 2048, owner, info));
	CHECK(!atlas.try_insert_avt_image(0, 0, 300, owner, info));
	CHECK(atlas.try_insert_avt_image(0, 0, 4, owner, info));
	CHECK(atlas.remove_image(owner));

	// AVT fills low coordinates first: the first 256 block lands at (0,0).
	VirtualImageOwner avt_a;
	CHECK(atlas.try_insert_avt_image(0, 0, 256, avt_a, info));
	CHECK_EQ(info.origin_x, 0);
	CHECK_EQ(info.origin_y, 0);
	CHECK_EQ(info.size, 256);
	CHECK_EQ(atlas.allocated_node_count(), 1);
	CHECK(avt_a.kind == VirtualImageKind::AVT);
	CHECK(atlas.has_owner(avt_a));

	// The next 256 block must not overlap the first.
	VirtualImageOwner avt_b;
	ImageInfo info_b;
	CHECK(atlas.try_insert_avt_image(1, 0, 256, avt_b, info_b));
	CHECK_EQ(info_b.origin_x, 256);
	CHECK_EQ(info_b.origin_y, 0);
	CHECK_EQ(info_b.size, 256);
	CHECK(!(info_b == info));
	CHECK(avt_a.generation != avt_b.generation);

	// SVT fills high coordinates first, away from the AVT cluster.
	VirtualImageOwner svt;
	ImageInfo svt_info;
	CHECK(atlas.try_insert_svt_image(256, svt, svt_info));
	CHECK_EQ(svt_info.origin_x, 768);
	CHECK_EQ(svt_info.origin_y, 768);
	CHECK(svt.kind == VirtualImageKind::SVT);
	CHECK_EQ(atlas.allocated_node_count(), 3);

	// Sector lookup finds the AVT image without a linear scan.
	ImageInfo found;
	CHECK(atlas.try_get_avt_image_info(1, 0, found));
	CHECK(found == info_b);
	CHECK(!atlas.try_get_avt_image_info(9, 9, found));

	// Removing frees the block so the next allocation reuses it.
	CHECK(atlas.remove_image(avt_b));
	CHECK_EQ(atlas.allocated_node_count(), 2);
	CHECK(!atlas.has_owner(avt_b));
	CHECK(!atlas.try_get_avt_image_info(1, 0, found));
	VirtualImageOwner reuse;
	ImageInfo reuse_info;
	CHECK(atlas.try_insert_avt_image(1, 0, 256, reuse, reuse_info));
	CHECK(reuse_info == info_b);
	// Removing an unknown owner is a no-op, and a stale owner cannot free a
	// block that now belongs to a newer generation.
	CHECK(!atlas.remove_image(avt_b));
	CHECK(!atlas.remove_image(VirtualImageOwner{}));
	CHECK(atlas.remove_image(reuse));
	CHECK(atlas.remove_image(avt_a));
	CHECK(atlas.remove_image(svt));
	CHECK_EQ(atlas.allocated_node_count(), 0);

	// The minimal image is always allocatable at the deepest level.
	VirtualImageOwner tiny;
	ImageInfo tiny_info;
	CHECK(atlas.try_insert_avt_image(3, 4, 4, tiny, tiny_info));
	CHECK_EQ(tiny_info.size, 4);
	CHECK_EQ(tiny_info.origin_x, 0);
	CHECK_EQ(tiny_info.origin_y, 0);
	CHECK(atlas.remove_image(tiny));

	// A block larger than the atlas is rejected.
	VirtualImageAtlas small(64, 4);
	CHECK_EQ(small.atlas_size(), 64);
	CHECK(!small.try_insert_avt_image(0, 0, 128, owner, info));
	CHECK(small.try_insert_avt_image(0, 0, 64, owner, info));
	CHECK_EQ(info.size, 64);
	CHECK_EQ(info.origin_x, 0);
	CHECK(small.remove_image(owner));
	CHECK(!small.remove_image(owner));

	// Exhaustion: a 64 page atlas holds exactly four 32x32 blocks.
	VirtualImageAtlas quad(64, 4);
	VirtualImageOwner owners[5];
	ImageInfo infos[5];
	int allocated = 0;
	for (int index = 0; index < 5; index++) {
		if (quad.try_insert_avt_image(index, 0, 32, owners[index], infos[index])) {
			allocated++;
		}
	}
	CHECK_EQ(allocated, 4);
	CHECK_EQ(quad.allocated_node_count(), 4);
	// No two allocated blocks may share a page.
	for (int a = 0; a < 4; a++) {
		for (int b = a + 1; b < 4; b++) {
			const bool disjoint = infos[a].origin_x + infos[a].size <= infos[b].origin_x ||
					infos[b].origin_x + infos[b].size <= infos[a].origin_x ||
					infos[a].origin_y + infos[a].size <= infos[b].origin_y ||
					infos[b].origin_y + infos[b].size <= infos[a].origin_y;
			CHECK(disjoint);
		}
	}
	// Freeing one block makes room again.
	CHECK(quad.remove_image(owners[2]));
	CHECK(quad.try_insert_avt_image(9, 9, 32, owner, info));
	CHECK_EQ(quad.allocated_node_count(), 4);

	// Clear resets the allocator and the generation counter.
	quad.clear();
	CHECK_EQ(quad.allocated_node_count(), 0);
	CHECK(!quad.has_owner(owner));
}

static void test_feedback_math() {
	int width = 0;
	int height = 0;
	calculate_feedback_size(1920, 1080, width, height);
	CHECK_EQ(width, 241);
	CHECK_EQ(height, 136);
	calculate_feedback_size(0, 0, width, height);
	CHECK_EQ(width, 1);
	CHECK_EQ(height, 1);
	calculate_feedback_size(3840, 2160, width, height);
	CHECK_EQ(width, 481);
	CHECK_EQ(height, 271);

	// The 8x8 Bayer matrix is a permutation of 0..63.
	bool seen[64] = { false };
	for (int row = 0; row < 8; row++) {
		for (int column = 0; column < 8; column++) {
			const int value = bayer_dither_8x8(row, column);
			CHECK(value >= 0 && value < 64);
			CHECK(!seen[value]);
			seen[value] = true;
		}
	}
	CHECK_EQ(bayer_dither_8x8(0, 0), 0);
	CHECK_EQ(bayer_dither_8x8(1, 0), 48);

	// Dither indices wrap into 0..63 and always yield an in-block offset.
	for (int index = -70; index < 200; index++) {
		const int normalized = normalize_dither_index(index);
		CHECK(normalized >= 0 && normalized < 64);
		int offset_x = 0;
		int offset_y = 0;
		get_dither_for_index(index, offset_x, offset_y);
		CHECK(offset_x >= 0 && offset_x < 8);
		CHECK(offset_y >= 0 && offset_y < 8);
	}
	CHECK_EQ(normalize_dither_index(64), 0);
	CHECK_EQ(normalize_dither_index(-1), 63);
	// The 64 dither indices cover all 64 sub-pixel offsets exactly once.
	bool offsets[8][8] = { { false } };
	for (int index = 0; index < 64; index++) {
		int offset_x = 0;
		int offset_y = 0;
		get_dither_for_index(index, offset_x, offset_y);
		CHECK(!offsets[offset_y][offset_x]);
		offsets[offset_y][offset_x] = true;
	}
}

int main() {
	test_constants();
	test_profiles();
	test_page_id();
	test_page_address();
	test_indirection_lookup();
	test_lru_key();
	test_target_size_index();
	test_physical_page_math();
	test_virtual_image_atlas();
	test_feedback_math();
	std::cout << "PASS: 2 address profiles x 7 AVT descriptors, PageID 12/12/4/4 bit layout, "
				 "AVT page resolution, indirection mip chain, LRU keys, sector LOD selection, "
				 "physical page UV/world rect, POT VirtualImageAtlas allocation and 8x8 feedback "
				 "dither\n";
	return 0;
}
