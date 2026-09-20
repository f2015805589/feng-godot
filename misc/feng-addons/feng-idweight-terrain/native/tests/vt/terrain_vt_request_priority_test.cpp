// Standalone contract test for the AVT request order. No Godot or GPU is needed.
#include "../../src/terrain_vt_request_priority.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

using TerrainVT::PageRequestKind;
using TerrainVT::PageRequestPriority;

#define CHECK(condition)                                                                  \
	do {                                                                                     \
		if (!(condition)) {                                                                    \
			std::cerr << "FAIL line " << __LINE__ << ": " #condition << '\n';                  \
			std::exit(1);                                                                        \
		}                                                                                      \
	} while (false)

static void sort_priorities(std::vector<PageRequestPriority> &r_priorities) {
	std::stable_sort(r_priorities.begin(), r_priorities.end(), TerrainVT::page_request_priority_before);
}

static void test_root_and_current_tiers() {
	std::vector<PageRequestPriority> priorities = {
		TerrainVT::make_page_request_priority(PageRequestKind::OPTIONAL, 1.f, 16.f),
		TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 2.f, 32.f),
		TerrainVT::make_page_request_priority(PageRequestKind::ROOT, 1000.f, 1024.f),
	};
	sort_priorities(priorities);
	CHECK(priorities[0].kind == PageRequestKind::ROOT);
	CHECK(priorities[1].kind == PageRequestKind::CURRENT);
	CHECK(priorities[2].kind == PageRequestKind::OPTIONAL);
}

static void test_distance_band_beats_span() {
	// A nearby fine page must be submitted before a distant coarse page. The
	// span tie-break is intentionally after the visibility distance band.
	const PageRequestPriority near_fine =
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 4.f, 64.f);
	const PageRequestPriority far_coarse =
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 64.f, 256.f);
	CHECK(TerrainVT::page_request_priority_before(near_fine, far_coarse));
	CHECK(!TerrainVT::page_request_priority_before(far_coarse, near_fine));
}

static void test_same_band_parent_before_child() {
	const PageRequestPriority parent =
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 8.f, 128.f);
	const PageRequestPriority child =
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 8.f, 64.f);
	std::vector<PageRequestPriority> priorities = { child, parent };
	sort_priorities(priorities);
	CHECK(priorities[0].span == 128.f);
	CHECK(priorities[1].span == 64.f);
}

static void test_current_beats_optional() {
	// Prefetch/apron work cannot move ahead of a current page even when its
	// geometric footprint is nearer or larger.
	const PageRequestPriority current =
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 128.f, 32.f);
	const PageRequestPriority optional =
			TerrainVT::make_page_request_priority(PageRequestKind::OPTIONAL, 1.f, 1024.f);
	CHECK(TerrainVT::page_request_priority_before(current, optional));
}

static void test_invalid_distance_is_finite() {
	for (const float distance : { std::numeric_limits<float>::quiet_NaN(),
				std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity(), -1.f }) {
		const PageRequestPriority priority = TerrainVT::make_page_request_priority(
				PageRequestKind::CURRENT, distance, std::numeric_limits<float>::quiet_NaN());
		CHECK(std::isfinite(priority.distance));
		CHECK(priority.distance_band >= 0);
		CHECK(!TerrainVT::page_request_priority_before(priority, priority));
	}
}

static void test_stable_equal_ties() {
	std::vector<int> order = { 0, 1, 2 };
	std::vector<PageRequestPriority> priorities(3,
			TerrainVT::make_page_request_priority(PageRequestKind::CURRENT, 8.f, 64.f));
	std::stable_sort(order.begin(), order.end(), [&](const int p_left, const int p_right) {
		return TerrainVT::page_request_priority_before(priorities[p_left], priorities[p_right]);
	});
	CHECK(order == std::vector<int>({ 0, 1, 2 }));
}

int main() {
	test_root_and_current_tiers();
	test_distance_band_beats_span();
	test_same_band_parent_before_child();
	test_current_beats_optional();
	test_invalid_distance_is_finite();
	test_stable_equal_ties();
	std::cout << "PASS: AVT root/current/optional request priority order\n";
	return 0;
}
