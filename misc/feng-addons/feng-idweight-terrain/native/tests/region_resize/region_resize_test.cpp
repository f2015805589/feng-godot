#include "../../src/terrain_region_resize.h"
#include <cassert>
#include <iostream>
#include <map>

int main() {
	using namespace TerrainRegionResize;
	assert(plan({{63, 0}}, 128, 64, 128, 1024).error == Error::OUT_OF_BOUNDS);
	assert(plan({{-64, 0}}, 128, 64, 128, 1024).error == Error::OUT_OF_BOUNDS);
	assert(plan({{-32, 0}, {31, 0}}, 128, 64, 128, 1024).locations.size() == 8);
	auto split = plan({{0, 0}}, 128, 64, 128, 1024);
	assert(split.error == Error::NONE && split.locations.size() == 4);
	auto merged = plan(split.locations, 64, 128, 128, 1024);
	assert(merged.error == Error::NONE && merged.locations == std::vector<Location>({{0, 0}}));
	assert(plan(split.locations, 64, 128, 128, 0).error == Error::CAPACITY);
	assert(plan({{0, 0}}, 128, 64, 128, 3).error == Error::CAPACITY);
	assert(plan({{0, 0}}, 0, 64, 128, 1024).error == Error::INVALID_SIZE);
	assert(plan({}, 128, 64, 128, 1024).locations.empty());

	struct Region { bool deleted; int payload; };
	// Execute the production commit boundary with failure at every insertion.
	for (int fail = 0; fail <= 4; ++fail) {
		std::map<int, Region> live = {{42, {false, 123456}}, {99, {true, 987654}}};
		const auto original = live;
		int size = 128;
		bool restored = false;
		const bool ok = commit(4, [&] { live[42].deleted = true; size = 64; },
				[&](std::size_t i) {
					live[int(i)] = {false, int(i) + 100};
					return int(i) != fail;
				}, [&] { live = original; size = 128; restored = true; });
		assert(ok == (fail == 4));
		if (!ok) {
			assert(restored && size == 128 && live.size() == 2);
			assert(!live[42].deleted && live[42].payload == 123456);
			assert(live[99].deleted && live[99].payload == 987654);
		} else {
			assert(!restored && size == 64 && live[42].deleted);
			assert(live[0].payload == 100 && live[3].payload == 103);
		}
	}
	std::cout << "PASS region resize preflight and transactional rollback\n";
}
