// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Sample packed material payload and height on the same logical grid.

#include "terrain_3d_clipmap_source_material.h"

#include "terrain_3d_data.h"

void Terrain3DClipmapSourceMaterial::fill_row(const Row &p_row, float *r_values) {
	if (_snapshot != nullptr) {
		for (int x = p_row.x0; x < p_row.x1; x++) {
			const Vector2 world = p_row.world_of(x);
			r_values[x] = p_row.channel == 0 ? float(_snapshot->clipmap_surface_texel(world))
										: _snapshot->clipmap_height_texel(world);
		}
		return;
	}
	if (_data == nullptr) {
		return;
	}
	// Channel 0 is raw id/weight; channel 1 is bake height.
	for (int x = p_row.x0; x < p_row.x1; x++) {
		const Vector2 world = p_row.world_of(x);
		r_values[x] = p_row.channel == 0 ? float(_data->get_surface_texel_nearest(world))
										: float(_data->get_height_texel_nearest(world));
	}
}
