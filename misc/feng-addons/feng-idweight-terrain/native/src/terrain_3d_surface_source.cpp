// Copyright © 2026 Terrain3D contributors.

#include "terrain_3d_data.h"

#include <cmath>
#include <cstring>
#include <unordered_map>

Ref<Image> Terrain3DData::make_vt_height_page(const Rect2 &p_world_rect, int p_page_size, int p_border) const {
	if (p_page_size <= 0 || p_border < 0 || _region_size <= 0) {
		return Ref<Image>();
	}
	struct Source {
		PackedByteArray bytes;
		const uint8_t *ptr = nullptr;
		int size = 0;
	};
	auto key = [](int x, int y) { return (uint64_t(uint32_t(x)) << 32) | uint32_t(y); };
	std::unordered_map<uint64_t, Source> sources;
	const float spacing = MAX(0.0001f, _vertex_spacing);
	const float region_world = _region_size * spacing;
	const Vector2 texel = p_world_rect.size / float(p_page_size);
	const Vector2 margin = texel * float(p_border + 1) + Vector2(spacing, spacing);
	const Rect2 footprint(p_world_rect.position - margin, p_world_rect.size + margin * 2.f);
	for (const Vector2i &location : _region_locations) {
		if (!footprint.intersects(Rect2(Vector2(location) * region_world, Vector2(region_world, region_world)))) {
			continue;
		}
		Ref<Terrain3DRegion> region = get_region(location);
		if (region.is_null() || region->is_deleted()) {
			continue;
		}
		Ref<Image> heights = region->get_height_map();
		if (heights.is_null() || heights->get_format() != Image::FORMAT_RF) {
			continue;
		}
		Source &source = sources[key(location.x, location.y)];
		source.bytes = heights->get_data();
		source.ptr = source.bytes.ptr();
		source.size = heights->get_width();
	}
	auto height_at = [&](int x, int y) -> float {
		const int rx = int(std::floor(double(x) / _region_size));
		const int ry = int(std::floor(double(y) / _region_size));
		auto found = sources.find(key(rx, ry));
		if (found == sources.end()) {
			return 0.f;
		}
		const Source &source = found->second;
		const int sx = CLAMP(x - rx * _region_size, 0, source.size - 1);
		const int sy = CLAMP(y - ry * _region_size, 0, source.size - 1);
		float height;
		std::memcpy(&height, source.ptr + (int64_t(sy) * source.size + sx) * sizeof(float), sizeof(float));
		return std::isfinite(height) ? height : 0.f;
	};
	const int stored = p_page_size + p_border * 2;
	PackedByteArray bytes;
	bytes.resize(int64_t(stored) * stored * sizeof(float));
	uint8_t *output = bytes.ptrw();
	// Sub-metre AVT pages often sample one or two terrain cells hundreds of
	// times. Resolve the integer column once, and the four source heights once
	// per cell/row rather than doing four hash lookups per output texel.
	std::vector<int> columns(stored);
	std::vector<float> weights(stored);
	for (int x = 0; x < stored; ++x) {
		const float px = (p_world_rect.position.x + (float(x - p_border) + 0.5f) * texel.x) / spacing;
		columns[x] = int(std::floor(px));
		weights[x] = px - columns[x];
	}
	for (int y = 0; y < stored; y++) {
		const float z = (p_world_rect.position.y + (float(y - p_border) + 0.5f) * texel.y) / spacing;
		const int iz = int(std::floor(z));
		const float fz = z - iz;
		int previous_column = 0;
		float h00 = 0.f, h10 = 0.f, h01 = 0.f, h11 = 0.f;
		for (int x = 0; x < stored; x++) {
			const int ix = columns[x];
			const float fx = weights[x];
			if (x == 0 || ix != previous_column) {
				h00 = height_at(ix, iz); h10 = height_at(ix + 1, iz);
				h01 = height_at(ix, iz + 1); h11 = height_at(ix + 1, iz + 1);
				previous_column = ix;
			}
			// Same BL-TR diagonal as terrain geometry and the ID/weight evaluator.
			const float height = fx > fz ? h00 * (1.f - fx) + h10 * (fx - fz) + h11 * fz :
					h00 * (1.f - fz) + h01 * (fz - fx) + h11 * fx;
			std::memcpy(output + (int64_t(y) * stored + x) * sizeof(float), &height, sizeof(float));
		}
	}
	return Image::create_from_data(stored, stored, false, Image::FORMAT_RF, bytes);
}
