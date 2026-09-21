// Contract test for the terrain virtual texture addressing, arrival-queue and
// screen-footprint helpers. Standalone: no Godot, no GPU.
#include "../../src/terrain_vt.h"
#include "../../src/terrain_vt_arrival_queue.h"
#include "../../src/terrain_vt_request_priority.h"
#include "../../src/terrain_vt_sampling.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
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

#define CHECK_NEAR(actual, expected, tolerance)                                           \
	do {                                                                                   \
		const float a_ = float(actual);                                                      \
		const float e_ = float(expected);                                                    \
		if (std::fabs(a_ - e_) > float(tolerance)) {                                        \
			std::cerr << "FAIL line " << __LINE__ << ": " #actual " ~= " << e_              \
					  << " actual " << a_ << " tolerance " << tolerance << '\n';                  \
			std::exit(1);                                                                      \
		}                                                                                    \
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

static void test_page_arrival_queue() {
	PageArrivalQueue queue(8);
	CHECK_EQ(queue.capacity(), size_t(8));
	CHECK(queue.empty());
	CHECK(!queue.enqueue(-1));
	CHECK(!queue.enqueue(8));

	// Re-enqueueing moves the one live node for a slot to the tail instead of
	// leaving an old record that could release a later reuse of that slot.
	CHECK(queue.enqueue(0));
	CHECK(queue.enqueue(1));
	CHECK(queue.enqueue(2));
	CHECK(queue.enqueue(3));
	CHECK(queue.enqueue(1));
	CHECK_EQ(queue.size(), size_t(4));
	CHECK(queue.contains(1));
	CHECK(queue.remove(2));
	CHECK(!queue.contains(2));
	CHECK_EQ(queue.size(), size_t(3));
	int slot = -1;
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 0);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 3);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 1);
	CHECK(!queue.pop(slot));

	// Pool growth preserves FIFO order. Shrinking drops only slots outside the
	// new pool and keeps all retained slots in their old order.
	queue.reset(8);
	CHECK(queue.enqueue(1));
	CHECK(queue.enqueue(7));
	CHECK(queue.enqueue(3));
	CHECK(queue.enqueue(2));
	queue.resize(16);
	CHECK_EQ(queue.capacity(), size_t(16));
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 1);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 7);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 3);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 2);
	CHECK(queue.empty());
	CHECK(queue.enqueue(1));
	CHECK(queue.enqueue(7));
	CHECK(queue.enqueue(3));
	CHECK(queue.enqueue(2));
	queue.resize(4);
	CHECK_EQ(queue.capacity(), size_t(4));
	CHECK_EQ(queue.size(), size_t(3));
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 1);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 3);
	CHECK(queue.pop(slot));
	CHECK_EQ(slot, 2);
	CHECK(!queue.contains(7));

	// Sustained churn never grows beyond physical slot capacity. This is the
	// regression that catches a vector-plus-cursor consumed-prefix leak.
	queue.reset(8);
	for (int iteration = 0; iteration < 100000; ++iteration) {
		CHECK(queue.enqueue(iteration % 8));
		if ((iteration % 3) == 0) {
			CHECK(queue.pop(slot));
		}
		CHECK(queue.size() <= queue.capacity());
	}
	CHECK(queue.size() <= size_t(8));
	queue.clear();
	CHECK(queue.empty());
	CHECK_EQ(queue.capacity(), size_t(8));
	std::cout << "PASS: bounded page-arrival FIFO duplicate-slot, resize and 100k churn\n";
}

static void test_sampling_footprint() {
	using TerrainVT::Sampling::Footprint;
	constexpr float ANISOTROPY = 4.f;
	const float diagonal = std::sqrt(0.5f);

	// A front-facing unit footprint remains one texel in both directions.
	Footprint front = TerrainVT::Sampling::singular_footprint({ { 1.f, 0.f }, { 0.f, 1.f } }, ANISOTROPY);
	CHECK_NEAR(front.major, 1.f, 1e-6f);
	CHECK_NEAR(front.minor, 1.f, 1e-6f);
	CHECK_NEAR(front.effective, 1.f, 1e-6f);

	// A grazing footprint keeps short-axis detail up to the effective cap.
	Footprint grazing = TerrainVT::Sampling::singular_footprint({ { 8.f, 0.f }, { 0.f, 0.25f } }, ANISOTROPY);
	CHECK_NEAR(grazing.major, 8.f, 1e-5f);
	CHECK_NEAR(grazing.minor, 0.25f, 1e-5f);
	CHECK_NEAR(grazing.effective, 2.f, 1e-5f);

	// Singular values are invariant under a 45 degree roll of the screen axes.
	Footprint rolled = TerrainVT::Sampling::singular_footprint(
			{ { 6.f * diagonal, 2.f * diagonal }, { -6.f * diagonal, 2.f * diagonal } }, ANISOTROPY);
	CHECK_NEAR(rolled.major, 6.f, 1e-5f);
	CHECK_NEAR(rolled.minor, 2.f, 1e-5f);
	CHECK_NEAR(rolled.effective, 2.f, 1e-5f);
	CHECK_NEAR(TerrainVT::Sampling::singular_footprint({ { 8.f, 0.f }, { 0.f, 0.25f } }, 0.f).effective,
			8.f, 1e-5f);
	std::cout << "PASS: front, grazing and 45-degree rolled Jacobian footprints\n";
}

static void test_sampling_bounds() {
	using TerrainVT::Sampling::Footprint;
	using TerrainVT::Sampling::FootprintBounds;
	using TerrainVT::Sampling::Vec2;
	constexpr float ANISOTROPY = 3.5f;
	std::mt19937 random(0x5EEDu);
	std::uniform_real_distribution<float> unit(0.f, 1.f);
	for (int sample = 0; sample < 20000; ++sample) {
		// Vary the interval too. A single wide interval crossing zero only tests
		// a trivial zero lower bound, missing regressions in narrow sloped patches.
		auto interval = [&]() {
			const float center = unit(random) * 20.f - 10.f;
			const float radius = unit(random) * 2.f;
			return Vec2{ center - radius, center + radius };
		};
		const Vec2 xx = interval(), xz = interval(), yx = interval(), yz = interval();
		const Vec2 dx_min{ xx.x, xz.x }, dx_max{ xx.y, xz.y };
		const Vec2 dy_min{ yx.x, yz.x }, dy_max{ yx.y, yz.y };
		const Vec2 near_dx{ std::clamp(0.f, xx.x, xx.y), std::clamp(0.f, xz.x, xz.y) };
		const Vec2 near_dy{ std::clamp(0.f, yx.x, yx.y), std::clamp(0.f, yz.x, yz.y) };
		const float lower_hint = std::max(TerrainVT::Sampling::length(near_dx), TerrainVT::Sampling::length(near_dy));
		const FootprintBounds bounds = TerrainVT::Sampling::singular_footprint_bounds(
				dx_min, dx_max, dy_min, dy_max, ANISOTROPY, lower_hint);
		CHECK(bounds.major_min <= bounds.major_max);
		CHECK(bounds.minor_min <= bounds.minor_max);
		CHECK(bounds.effective_min <= bounds.effective_max);
		const Vec2 dx = { dx_min.x + (dx_max.x - dx_min.x) * unit(random),
				dx_min.y + (dx_max.y - dx_min.y) * unit(random) };
		const Vec2 dy = { dy_min.x + (dy_max.x - dy_min.x) * unit(random),
				dy_min.y + (dy_max.y - dy_min.y) * unit(random) };
		const Footprint actual = TerrainVT::Sampling::singular_footprint({ dx, dy }, ANISOTROPY);
		CHECK(actual.major + 2e-5f >= bounds.major_min);
		CHECK(actual.major <= bounds.major_max + 2e-5f);
		CHECK(actual.minor + 2e-5f >= bounds.minor_min);
		CHECK(actual.minor <= bounds.minor_max + 2e-5f);
		CHECK(actual.effective + 2e-5f >= bounds.effective_min);
		CHECK(actual.effective <= bounds.effective_max + 2e-5f);
	}
	std::cout << "PASS: Weyl/Frobenius Jacobian bounds over 20,000 random matrices\n";
}

static void test_request_priority() {
	// Roots establish coverage before any current detail, regardless of their
	// larger distance or span.
	std::vector<PageRequestPriority> priorities = {
		make_page_request_priority(PageRequestKind::OPTIONAL, 1.f, 16.f),
		make_page_request_priority(PageRequestKind::CURRENT, 2.f, 32.f),
		make_page_request_priority(PageRequestKind::ROOT, 1000.f, 1024.f),
	};
	std::stable_sort(priorities.begin(), priorities.end(), page_request_priority_before);
	CHECK(priorities[0].kind == PageRequestKind::ROOT);
	CHECK(priorities[1].kind == PageRequestKind::CURRENT);
	CHECK(priorities[2].kind == PageRequestKind::OPTIONAL);

	// A near fine page beats a far coarse page because distance bands precede
	// the span tie-break.
	const PageRequestPriority near_fine = make_page_request_priority(PageRequestKind::CURRENT, 4.f, 64.f);
	const PageRequestPriority far_coarse = make_page_request_priority(PageRequestKind::CURRENT, 64.f, 256.f);
	CHECK(page_request_priority_before(near_fine, far_coarse));
	CHECK(!page_request_priority_before(far_coarse, near_fine));

	// Within one visibility band the covering parent precedes its child.
	const PageRequestPriority parent = make_page_request_priority(PageRequestKind::CURRENT, 8.f, 128.f);
	const PageRequestPriority child = make_page_request_priority(PageRequestKind::CURRENT, 8.f, 64.f);
	priorities = { child, parent };
	std::stable_sort(priorities.begin(), priorities.end(), page_request_priority_before);
	CHECK(priorities[0].span == 128.f);
	CHECK(priorities[1].span == 64.f);

	// Optional apron/prefetch work never outranks a current page, even when its
	// own geometric footprint is closer and larger.
	const PageRequestPriority current = make_page_request_priority(PageRequestKind::CURRENT, 128.f, 32.f);
	const PageRequestPriority optional = make_page_request_priority(PageRequestKind::OPTIONAL, 1.f, 1024.f);
	CHECK(page_request_priority_before(current, optional));

	for (const float distance : { std::numeric_limits<float>::quiet_NaN(),
				std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity(), -1.f }) {
		const PageRequestPriority invalid = make_page_request_priority(
				PageRequestKind::CURRENT, distance, std::numeric_limits<float>::quiet_NaN());
		CHECK(std::isfinite(invalid.distance));
		CHECK(invalid.distance_band >= 0);
		CHECK(!page_request_priority_before(invalid, invalid));
	}
	std::cout << "PASS: AVT request priority root/current/optional, distance bands and invalid input\n";
}

// The far field's level rule, both implementations and the selector that chooses between them. This
// is the side that has to agree with the GLSL mirror `surface_svt_mip_for_distance()` in
// `src/shaders/main.glsl`: a level the demand pass produces and the level the shader samples are the
// same level or the far field renders the diagnostic, so the arithmetic is pinned here rather than
// left to the two call sites that used to spell it.
static void test_mip_rule() {
	// The automatic rule follows the page size: a level m page covers `page_world * 2^m` metres, so
	// level m is right out to twice that and the bands double.
	const MipRule automatic = select_mip_rule(64.f, nullptr, 0);
	CHECK(automatic.kind == MipRuleKind::AutomaticBands);
	CHECK_NEAR(automatic.mip_for_distance(0.f, 16), 0.f, 0.f);
	CHECK_NEAR(automatic.mip_for_distance(128.f, 16), 0.f, 0.f); // the threshold itself is still level 0
	CHECK_NEAR(automatic.mip_for_distance(128.001f, 16), 1.f, 0.f);
	CHECK_NEAR(automatic.mip_for_distance(256.f, 16), 1.f, 0.f);
	CHECK_NEAR(automatic.mip_for_distance(256.001f, 16), 2.f, 0.f);
	CHECK_NEAR(automatic.mip_for_distance(1024.f, 16), 3.f, 0.f);
	// It coarsens without a limit of its own, so the cap is what stops it, and a cap of 0 is level 0.
	CHECK_NEAR(automatic.mip_for_distance(1e9f, 5), 5.f, 0.f);
	CHECK_NEAR(automatic.mip_for_distance(1e9f, 0), 0.f, 0.f);
	// The floor the old inline `MAX(1.f, page_world * 2.f)` carried: a page is never smaller than a
	// metre, so a sub-metre page size does not make the bands sub-metre too.
	const MipRule tiny = select_mip_rule(0.25f, nullptr, 0);
	CHECK_NEAR(tiny.mip_for_distance(1.f, 16), 0.f, 0.f);
	CHECK_NEAR(tiny.mip_for_distance(1.001f, 16), 1.f, 0.f);
	CHECK_NEAR(tiny.reach(16), 0.f, 0.f);

	// The explicit table states the distances directly, one entry per level, and the last entry is
	// where it stops coarsening whatever the cap says.
	const float bands[4] = { 100.f, 500.f, 2000.f, 8000.f };
	const MipRule table = select_mip_rule(64.f, bands, 4);
	CHECK(table.kind == MipRuleKind::ExplicitTable);
	CHECK_NEAR(table.mip_for_distance(0.f, 16), 0.f, 0.f);
	CHECK_NEAR(table.mip_for_distance(100.f, 16), 0.f, 0.f); // the band itself is still its own level
	CHECK_NEAR(table.mip_for_distance(100.001f, 16), 1.f, 0.f);
	CHECK_NEAR(table.mip_for_distance(500.f, 16), 1.f, 0.f);
	CHECK_NEAR(table.mip_for_distance(5000.f, 16), 3.f, 0.f);
	CHECK_NEAR(table.mip_for_distance(1e9f, 16), 3.f, 0.f); // the last band, then no further
	CHECK_NEAR(table.mip_for_distance(1e9f, 2), 2.f, 0.f); // the cap wins over the table
	// The reach is the band at the published cap, not always the last entry: a table longer than the
	// level the far field publishes is only served up to what it publishes.
	CHECK_NEAR(table.reach(16), 8000.f, 0.f);
	CHECK_NEAR(table.reach(1), 500.f, 0.f);
	CHECK_NEAR(table.reach(0), 100.f, 0.f);

	// The selector is the one place the mode is decided, and an empty table *is* the automatic rule.
	CHECK(select_mip_rule(64.f, bands, 0).kind == MipRuleKind::AutomaticBands);
	CHECK(select_mip_rule(64.f, nullptr, 4).kind == MipRuleKind::AutomaticBands);
	// Both rules agree with the automatic one at the level the page size implies, which is what makes
	// the table a statement of the same thing rather than a second rule.
	CHECK_NEAR(automatic.mip_for_distance(1024.f, 16), 3.f, 0.f);
	CHECK_NEAR(select_mip_rule(64.f, bands, 4).mip_for_distance(1024.001f, 16), 2.f, 0.f);

	std::cout << "PASS: far-field level rule, automatic bands and explicit table\n";
}

int main() {
	test_indirection_lookup();
	test_virtual_image_atlas();
	test_atlas_full_leaf_capacity();
	test_page_arrival_queue();
	test_sampling_footprint();
	test_sampling_bounds();
	test_request_priority();
	test_mip_rule();
	std::cout << "PASS: indirection mip chain walk, POT VirtualImageAtlas allocation and "
				 "full leaf capacity\n";
	return 0;
}
