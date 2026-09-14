// Contract test for the terrain virtual texture addressing core in
// src/terrain_vt.h: the indirection mip-chain walk and the POT quadtree
// allocator. Standalone: no Godot, no GPU.
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

static void test_virtual_image_atlas() {
	// The atlas the runtime builds by default: 1024x1024 pages, 4x4 minimal block.
	VirtualImageAtlas atlas(1024, 4);
	CHECK(atlas.is_valid_image_size(1024));
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
	CHECK(atlas.try_get_avt_image_info(0, 0, info));

	// The next 256 block must not overlap the first.
	VirtualImageOwner avt_b;
	ImageInfo info_b;
	CHECK(atlas.try_insert_avt_image(1, 0, 256, avt_b, info_b));
	CHECK_EQ(info_b.origin_x, 256);
	CHECK_EQ(info_b.origin_y, 0);
	CHECK_EQ(info_b.size, 256);
	CHECK(!(info_b == info));
	CHECK(avt_a.generation != avt_b.generation);

	// Sector lookup finds the AVT image without a linear scan.
	ImageInfo found;
	CHECK(atlas.try_get_avt_image_info(1, 0, found));
	CHECK(found == info_b);
	CHECK(!atlas.try_get_avt_image_info(9, 9, found));

	// Removing frees the block so the next allocation reuses it.
	CHECK(atlas.remove_image(avt_b));
	CHECK_EQ(atlas.allocated_node_count(), 1);
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
	CHECK(small.is_valid_image_size(64));
	CHECK(!small.is_valid_image_size(128));
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
	CHECK(!quad.try_get_avt_image_info(9, 9, info));
}

static void test_atlas_full_leaf_capacity() {
	// The atlas the runtime builds by default: 1024x1024 pages, 4x4 minimal block.
	VirtualImageAtlas atlas(1024, 4);
	constexpr int EDGE = 256;
	std::vector<VirtualImageOwner> owners(EDGE * EDGE);
	std::vector<bool> occupied(EDGE * EDGE, false);
	ImageInfo info;
	for (int i = 0; i < EDGE * EDGE; ++i) {
		CHECK(atlas.try_insert_avt_image(i, 0, 4, owners[i], info));
		const int cell = (info.origin_y / 4) * EDGE + info.origin_x / 4;
		CHECK(!occupied[cell]);
		occupied[cell] = true;
	}
	CHECK_EQ(atlas.allocated_node_count(), EDGE * EDGE);
	VirtualImageOwner owner;
	// A wrapped descendant count used to make the full root look empty.
	CHECK(!atlas.try_insert_avt_image(-1, 0, 1024, owner, info));
	CHECK(!atlas.try_insert_avt_image(-1, -1, 4, owner, info));
	ImageInfo before, after;
	CHECK(!atlas.try_resize_avt_image(0, 0, 8, owner, before, after));
	CHECK(before == after);
	CHECK(atlas.try_get_avt_image_info(0, 0, info));
	CHECK_EQ(atlas.allocated_node_count(), EDGE * EDGE);
	// Releasing and refilling a leaf must propagate occupancy through every parent.
	CHECK(atlas.remove_image(owners[12345]));
	CHECK(atlas.try_insert_avt_image(-1, -1, 4, owner, info));
	CHECK_EQ(atlas.allocated_node_count(), EDGE * EDGE);
	CHECK(!atlas.try_insert_avt_image(-2, 0, 4, owner, info));
	std::cout << "PASS: full 65,536-leaf atlas, non-overlap, resize rollback and refill\n";
}

int main() {
	test_indirection_lookup();
	test_virtual_image_atlas();
	test_atlas_full_leaf_capacity();
	std::cout << "PASS: indirection mip chain walk, POT VirtualImageAtlas allocation and "
				 "full leaf capacity\n";
	return 0;
}
