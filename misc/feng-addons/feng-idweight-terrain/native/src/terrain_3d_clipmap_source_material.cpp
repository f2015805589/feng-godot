// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The material channel's production: one packed surface-payload texel and one height texel per clipmap
// texel. The per-texel cost is the lookup (`Terrain3DData::get_surface_texel_nearest()` /
// `get_height_texel_nearest()`: region resolution and a texel read), which is what the row granularity
// of `Terrain3DClipmapSource` exists to amortise.

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
	// Channel 0 is the payload the material is evaluated from, channel 1 the height the bake needs to
	// normalise it. Both are rows of the same level over the same world positions, so the row is
	// walked once and only the lookup differs.
	for (int x = p_row.x0; x < p_row.x1; x++) {
		const Vector2 world = p_row.world_of(x);
		r_values[x] = p_row.channel == 0 ? float(_data->get_surface_texel_nearest(world))
										: float(_data->get_height_texel_nearest(world));
	}
}
