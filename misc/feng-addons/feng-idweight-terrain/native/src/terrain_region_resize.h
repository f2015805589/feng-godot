// Pure planning and commit boundary for region-size changes. No live data is
// touched until every destination is representable and fits resident capacity.
#ifndef TERRAIN_REGION_RESIZE_H
#define TERRAIN_REGION_RESIZE_H

#include <cstddef>
#include <cstdint>
#include <set>
#include <utility>
#include <vector>

namespace TerrainRegionResize {
using Location = std::pair<int, int>;
enum class Error { NONE, INVALID_SIZE, OUT_OF_BOUNDS, CAPACITY };
struct Plan {
	Error error = Error::NONE;
	std::vector<Location> locations;
};

inline Plan plan(const std::vector<Location> &p_sources, int p_old_size, int p_new_size,
		int p_map_size, std::size_t p_capacity) {
	Plan result;
	if (p_old_size <= 0 || p_new_size <= 0 || p_map_size <= 0) {
		result.error = Error::INVALID_SIZE;
		return result;
	}
	auto floor_div = [](int64_t n, int64_t d) { return n / d - (n % d < 0 ? 1 : 0); };
	std::set<Location> unique;
	for (const Location &source : p_sources) {
		const int64_t x0 = int64_t(source.first) * p_old_size;
		const int64_t y0 = int64_t(source.second) * p_old_size;
		for (int64_t y = floor_div(y0, p_new_size); y <= floor_div(y0 + p_old_size - 1, p_new_size); ++y) {
			for (int64_t x = floor_div(x0, p_new_size); x <= floor_div(x0 + p_old_size - 1, p_new_size); ++x) {
				if (x < -p_map_size / 2 || y < -p_map_size / 2 || x >= p_map_size / 2 || y >= p_map_size / 2) {
					result.error = Error::OUT_OF_BOUNDS;
					return result;
				}
				unique.emplace(int(x), int(y));
				if (unique.size() > p_capacity) {
					result.error = Error::CAPACITY;
					return result;
				}
			}
		}
	}
	result.locations.assign(unique.begin(), unique.end());
	return result;
}

// The caller holds the original table and flags until every insertion succeeds.
template <typename Begin, typename Insert, typename Restore>
bool commit(std::size_t p_count, Begin p_begin, Insert p_insert, Restore p_restore) {
	p_begin();
	for (std::size_t i = 0; i < p_count; ++i) {
		if (!p_insert(i)) {
			p_restore();
			return false;
		}
	}
	return true;
}
} // namespace TerrainRegionResize
#endif
