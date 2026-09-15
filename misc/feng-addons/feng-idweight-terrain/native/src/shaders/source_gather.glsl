R"(
// Device-side far-field page source. A page whose source is not already resident as a
// baked cell is normally cropped out of the region payloads on the CPU, one page image at
// a time. These two evaluations are that crop, evaluated per texel on the device instead:
// the packed id/weight nearest on the payload grid, and the height bilinearly on the
// terrain cell grid with the same bottom-left/top-right diagonal the geometry uses. The
// bake below then reads them exactly like an uploaded source page, so a page is produced
// without a CPU crop and without waiting for one.
//
// `bake_push.region` carries what the evaluation needs: the region size in texels, the
// region size in metres, the payload texel step in metres and the region map's size. The
// terrain cell step is region_world / region_size.

int surface_gather_region_layer(ivec2 p_chunk) {
	const int map_size = int(bake_push.region.w + 0.5);
	ivec2 position = p_chunk + ivec2(map_size / 2);
	if (any(lessThan(position, ivec2(0))) || any(greaterThanEqual(position, ivec2(map_size)))) {
		return -1;
	}
	// The directory stores slot + 1, so 0 is either outside the world grid or an empty
	// chunk, and an editor dummy is negative. Neither has a payload to crop.
	const int layer = int(texelFetch(bake_region_map, position, 0).r + 0.5) - 1;
	return layer >= 0 ? layer : -1;
}

// The region payload is a density grid, so a texel of it is `source_step` metres wide.
// A position outside every resident region contributes nothing, exactly like the CPU
// crop leaving those texels at zero.
uint surface_gather_id(vec2 p_world) {
	const float region_world = bake_push.region.y;
	const ivec2 chunk = ivec2(floor(p_world / region_world));
	const int layer = surface_gather_region_layer(chunk);
	if (layer < 0) {
		return 0u;
	}
	const float source_step = bake_push.region.z;
	// The payload grid is the terrain density grid, which is the grid the material shader
	// reads the same arrays on.
	const float vertex_spacing = region_world / bake_push.region.x;
	const ivec2 map_texels = ivec2(int(bake_push.region.x + 0.5) * int(max(1.0, round(vertex_spacing / source_step))));
	const ivec2 texel = clamp(ivec2(floor((p_world - vec2(chunk) * region_world) / source_step)),
			ivec2(0), max(map_texels - ivec2(1), ivec2(0)));
	return uint(texelFetch(bake_surface_maps, ivec3(texel, layer), 0).r * 65535.0 + 0.5);
}

float surface_gather_height_at(ivec2 p_cell) {
	const int region_size = int(bake_push.region.x + 0.5);
	const ivec2 chunk = ivec2(floor(vec2(p_cell) / float(region_size)));
	const int layer = surface_gather_region_layer(chunk);
	if (layer < 0) {
		return 0.0;
	}
	// A corner beyond a region's own grid belongs to the neighbouring region; a corner
	// past the world edge repeats the region's last texel, as the CPU lookup does.
	const ivec2 texel = clamp(p_cell - chunk * region_size, ivec2(0), ivec2(region_size - 1));
	const float height = texelFetch(bake_height_maps, ivec3(texel, layer), 0).r;
	return (isinf(height) || isnan(height)) ? 0.0 : height;
}

float surface_gather_height(vec2 p_world) {
	const float region_size = bake_push.region.x;
	const float vertex_spacing = bake_push.region.y / region_size;
	vec2 cell_position = p_world / vertex_spacing;
	const ivec2 cell = ivec2(floor(cell_position));
	const vec2 fraction = cell_position - vec2(cell);
	const float h00 = surface_gather_height_at(cell);
	const float h10 = surface_gather_height_at(cell + ivec2(1, 0));
	const float h01 = surface_gather_height_at(cell + ivec2(0, 1));
	const float h11 = surface_gather_height_at(cell + ivec2(1, 1));
	// The diagonal split of the rendered geometry: the lower-left triangle blends h00,
	// h10 and h11, the upper-right one blends h00, h01 and h11.
	return fraction.x > fraction.y
			? h00 * (1.0 - fraction.x) + h10 * (fraction.x - fraction.y) + h11 * fraction.y
			: h00 * (1.0 - fraction.y) + h01 * (fraction.y - fraction.x) + h11 * fraction.x;
}
)"
