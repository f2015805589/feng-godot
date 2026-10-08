// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Read one nearest height-map sample per logical texel.

#include "terrain_3d_clipmap_source_height.h"

#include "terrain_3d_data.h"

void Terrain3DClipmapSourceHeight::fill_row(const Row &p_row, float *r_values) {
	if (_snapshot != nullptr) {
		for (int x = p_row.x0; x < p_row.x1; x++) {
			r_values[x] = _snapshot->clipmap_height_texel(p_row.world_of(x));
		}
		return;
	}
	if (_data == nullptr) {
		return;
	}
	for (int x = p_row.x0; x < p_row.x1; x++) {
		r_values[x] = float(_data->get_height_texel_nearest(p_row.world_of(x)));
	}
}
