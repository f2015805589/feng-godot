// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's map arrays: what they hold, how they reach the GPU, and how they are sampled.

// One of five files that define Terrain3DData. The four `_*_maps` arrays and their blank layers,
// `update_maps()` (the upload path and its mipmap pass), `update_surface_region()`, and the read
// side every consumer uses: `set_pixel()`, `get_pixel_descaled()`, the height, normal, blend,
// slope and texture-id queries and the mesh-vertex decimation they feed.

#include "terrain_3d.h"
#include "terrain_3d_data.h"

#include "logger.h"
#include "terrain_surface_idweight.h"

#include <cmath>

// The layer -> region location table the shader reads as `_region_locations`.
// Free slots are V2I_MAX; the region map never points at them, so the shader never
// indexes one. Padded to the material's max_regions by Terrain3DMaterial.
PackedVector2Array Terrain3DData::get_slot_locations() const {
	PackedVector2Array locations;
	locations.resize(_slot_capacity);
	for (int slot = 0; slot < _slot_capacity; slot++) {
		locations[slot] = (_slot_locations[slot] == V2I_MAX) ? Vector2() : Vector2(_slot_locations[slot]);
	}
	return locations;
}

// Diagnostics for the slot table and the texture arrays. `map_create_count` counts
// GPU array allocations, `map_update_count` counts single layer uploads: steady
// streaming should grow the second and leave the first alone.
Dictionary Terrain3DData::get_map_stats() const {
	Dictionary stats;
	stats["slot_capacity"] = _slot_capacity;
	stats["slot_count"] = int(_region_slots.size());
	stats["free_slots"] = int(_free_slots.size());
	stats["region_count"] = _region_locations.size();
	stats["map_create_count"] = _generated_height_maps.get_create_count() +
			_generated_control_maps.get_create_count() +
			_generated_color_maps.get_create_count() +
			_generated_surface_maps.get_create_count();
	stats["map_update_count"] = _generated_height_maps.get_update_count() +
			_generated_control_maps.get_update_count() +
			_generated_color_maps.get_update_count() +
			_generated_surface_maps.get_update_count();
	stats["height_layers"] = _generated_height_maps.get_layer_count();
	stats["control_layers"] = _generated_control_maps.get_layer_count();
	stats["color_layers"] = _generated_color_maps.get_layer_count();
	stats["surface_layers"] = _generated_surface_maps.get_layer_count();
	stats["slot_grow_count"] = _slot_grow_count;
	stats["region_map_rebuild_count"] = _region_map_rebuild_count;
	stats["slot_full_sync_count"] = _slot_full_sync_count;
	stats["region_map_size"] = REGION_MAP_SIZE;
	stats["directory_valid"] = _region_directory.get_rid().is_valid();
	return stats;
}

void Terrain3DData::reset_map_stats() {
	_generated_height_maps.reset_counters();
	_generated_control_maps.reset_counters();
	_generated_color_maps.reset_counters();
	_generated_surface_maps.reset_counters();
	_slot_grow_count = 0;
	_region_map_rebuild_count = 0;
	_slot_full_sync_count = 0;
}

TypedArray<Image> Terrain3DData::get_maps(const MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return get_height_maps();
			break;
		case TYPE_CONTROL:
			return get_control_maps();
			break;
		case TYPE_COLOR:
			return get_color_maps();
			break;
		default:
			break;
	}
	return TypedArray<Image>();
}

void Terrain3DData::update_maps(const MapType p_map_type, const bool p_all_regions, const bool p_generate_mipmaps) {
	// Generate region color mipmaps
	if (p_generate_mipmaps && (p_map_type == TYPE_COLOR || p_map_type == TYPE_MAX)) {
		LOG(EXTREME, "Regenerating color mipmaps");
		for (const Vector2i &region_loc : _regions.keys()) {
			Terrain3DRegion *region = get_region_ptr(region_loc);
			// Generate all or only those marked edited
			if (region && !region->is_deleted() && (p_all_regions || region->is_edited())) {
				region->get_color_map()->generate_mipmaps();
			}
		}
	}

	// p_all_regions means "assume every region changed". It no longer throws the GPU
	// arrays away: the layer layout belongs to the slot table, so the arrays are only
	// recreated when the slot capacity changes.
	if (p_all_regions) {
		LOG(EXTREME, "Marking dirty maps of type: ", p_map_type);
		switch (p_map_type) {
			case TYPE_HEIGHT:
				_slot_map_full[SLOT_MAP_HEIGHT] = true;
				break;
			case TYPE_CONTROL:
				_slot_map_full[SLOT_MAP_CONTROL] = true;
				break;
			case TYPE_COLOR:
				_slot_map_full[SLOT_MAP_COLOR] = true;
				break;
			default:
				for (int i = 0; i < SLOT_MAP_MAX; i++) {
					_slot_map_full[i] = true;
				}
				_region_map_dirty = true;
				break;
		}
	}

	// A structural change (a region entering or leaving memory, a bulk rebuild, or a
	// capacity change) has to reach the material, because the array RIDs and the
	// region/layer mapping it holds may have moved. Content edits do not, and the old
	// code relied on a full rebuild to tell the two apart.
	bool structural = _region_map_dirty || _region_map_signal_dirty;
	for (int i = 0; i < SLOT_MAP_MAX && !structural; i++) {
		structural = _slot_map_full[i];
	}
	for (int slot = 0; slot < (int)_slot_dirty.size() && !structural; slot++) {
		structural = _slot_dirty[slot] != 0;
	}

	if (_region_map_dirty) {
		_rebuild_region_map();
	}

	// Fold content edits into the slot dirtiness so one upload pass covers both
	// structural and edited changes: a region can be edited in the same call that
	// adds or unloads another one.
	const int edit_mask = _slot_map_mask(p_map_type);
	for (const Vector2i &region_loc : _region_locations) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (region && region->is_edited()) {
			_mark_slot_dirty(get_region_id(region_loc), edit_mask);
		}
	}

	bool any_changed = false;
	for (int slot_map = 0; slot_map < SLOT_MAP_MAX; slot_map++) {
		if (!_slot_map_requested(p_map_type, slot_map)) {
			continue;
		}
		const bool changed = _sync_slot_map(slot_map);
		any_changed = any_changed || changed;
		if (changed && slot_map == SLOT_MAP_HEIGHT) {
			calc_height_range();
		}
	}

	// The directory has to reach the shader whenever it changed, not only when the
	// region map signal fires: adding a region patches one texel without touching
	// `_region_map_signal_dirty`.
	const bool directory_changed = _region_directory_dirty;
	if (directory_changed) {
		_update_region_directory();
	}

	if (_region_map_signal_dirty) {
		_region_map_signal_dirty = false;
		LOG(DEBUG, "Emitting region_map_changed");
		emit_signal("region_map_changed");
	}

	if (any_changed || structural || directory_changed) {
		LOG(DEBUG, "Emitting maps_changed");
		emit_signal("maps_changed");
		_terrain->snap();
	}
}

void Terrain3DData::update_surface_region(Image *p_surface_map, const int p_region_id) {
	if (_terrain && !_terrain->is_surface_array_upload_needed()) {
		// The array does not carry the surface channel in this configuration; the
		// virtual textures are refreshed through invalidate_surface_pages() instead.
		return;
	}
	if (p_surface_map && p_region_id >= 0 && p_region_id < _surface_maps.size()) {
		// A first paint can replace the blank placeholder with a newly created
		// region surface map. Keep CPU queries aligned with the uploaded layer.
		_surface_maps[p_region_id] = Ref<Image>(p_surface_map);
		_generated_surface_maps.update(Ref<Image>(p_surface_map), p_region_id);
		LOG(DEBUG, "Emitting surface_maps_changed");
		emit_signal("surface_maps_changed");
	}
}

void Terrain3DData::set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return;
	}
	Vector2i vgrid = world_to_vgrid(p_global_position);
	Vector2i region_loc = V2I_DIVIDE_FLOOR(vgrid, _region_size);
	Terrain3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		LOG(ERROR, "No active region found at: ", p_global_position);
		return;
	}
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		// Local pixel in the region is always [0, region_size)
		Vector2i img_pos(Math::posmod(vgrid.x, _region_size), Math::posmod(vgrid.y, _region_size));
		map->set_pixelv(img_pos, p_pixel);
		region->set_modified(true);
	}
}

// Expects descaled, snapped/floored, global position - vertex grid
Color Terrain3DData::get_pixel_descaled(const MapType p_map_type, const Vector2i &p_vgrid) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_NAN;
	}
	Vector2i region_loc = V2I_DIVIDE_FLOOR(p_vgrid, _region_size);
	const Terrain3DRegion *region = get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		return COLOR_NAN;
	}
	Image *map = region->get_map_ptr(p_map_type);
	if (map) {
		// Local pixel in the region is always [0, region_size)
		Vector2i img_pos(Math::posmod(p_vgrid.x, _region_size), Math::posmod(p_vgrid.y, _region_size));
		return map->get_pixelv(img_pos);
	} else {
		return COLOR_NAN;
	}
}

real_t Terrain3DData::get_height_texel_nearest(const Vector2 &p_world_xz) const {
	const Vector2i vgrid = world_to_vgrid_xz(p_world_xz.x, p_world_xz.y, _vertex_spacing);
	const Terrain3DRegion *region = get_region_ptr(V2I_DIVIDE_FLOOR(vgrid, _region_size));
	if (!region || region->is_deleted()) {
		return 0.f;
	}
	Image *map = region->get_map_ptr(TYPE_HEIGHT);
	if (map == nullptr) {
		return 0.f;
	}
	return map->get_pixelv(Vector2i(Math::posmod(vgrid.x, _region_size), Math::posmod(vgrid.y, _region_size))).r;
}

real_t Terrain3DData::get_surface_height(const Vector3 &p_global_position) const {
	Vector3 pos = p_global_position;
	const real_t &step = _vertex_spacing;
	pos.y = 0.f;
	// Compare position to nearest vertex, and if close don't interpolate
	Vector3 pos_round = pos.snapped(Vector3(step, 0.f, step));
	if ((pos - pos_round).length_squared() < 0.0001f) {
		return get_modified_height(world_to_vgrid(pos_round));
	} else {
		// Otherwise, bilinearly interpolate 4 surrounding vertices
		Vector2i v00 = world_to_vgrid(pos);
		real_t ht00 = get_modified_height(v00);
		Vector2i v01 = v00 + Vector2i(0, 1);
		real_t ht01 = get_modified_height(v01);
		Vector2i v10 = v00 + Vector2i(1, 0);
		real_t ht10 = get_modified_height(v10);
		Vector2i v11 = v00 + Vector2i(1, 1);
		real_t ht11 = get_modified_height(v11);
		return bilerp(ht00, ht01, ht10, ht11, Vector2(v00), Vector2(v11), v3v2(pos / step));
	}
}

// Expects descaled, snapped/floored global position - vertex grid
// Returns height modified by world background region blend, ground level
real_t Terrain3DData::get_modified_height(const Vector2i &p_vgrid) const {
	// Control map is always packed as a float32 Color component, regardless
	// of engine precision, so this must stay float, not real_t.
	float control = get_pixel_descaled(TYPE_CONTROL, p_vgrid).r;
	if (is_hole(control)) {
		return NAN;
	}
	real_t height = get_pixel_descaled(TYPE_HEIGHT, p_vgrid).r;
	const Ref<Terrain3DMaterial> material = _terrain->get_material();
	if (material.is_valid()) {
		const Terrain3DMaterial::WorldBackground bg_mode = material->get_world_background();
		if (bg_mode == Terrain3DMaterial::WorldBackground::FLAT || bg_mode == Terrain3DMaterial::WorldBackground::NOISE) {
			Variant var_gl = material->get("ground_level");
			Variant var_rb = material->get("region_blend");
			if (var_gl.get_type() == Variant::NIL || var_rb.get_type() == Variant::NIL) {
				return height;
			}
			const real_t ground_level = var_gl;
			const real_t region_texel_size = 1.f / real_t(_region_size);
			Vector2 uv2 = Vector2(p_vgrid) * region_texel_size;
			height = Math::lerp(height, ground_level, smoothstep(0.f, 1.f, get_region_blend(uv2)));
		}
	}
	return height;
}

real_t Terrain3DData::get_region_blend(const Vector2 &p_uv2) const {
	const Ref<Terrain3DMaterial> material = _terrain->get_material();
	if (!material.is_valid()) {
		return 0.f;
	}
	Variant var_rb = material->get("region_blend");
	if (var_rb.get_type() == Variant::NIL) {
		return 0.f;
	}
	const real_t region_blend = var_rb;

	auto check_region = [&](const Vector2 &uv2) -> real_t {
		int idx = get_region_map_index(Vector2i(Math::floor(uv2.x), Math::floor(uv2.y)));
		return (idx >= 0 && _region_map[idx] > 0) ? 1.f : 0.f;
	};

	// Floating point bias (must match shader)
	Vector2 uv2 = p_uv2 - Vector2(0.5011f, 0.5011f);

	real_t a = check_region(uv2 + Vector2(0.0f, 1.0f));
	real_t b = check_region(uv2 + Vector2(1.0f, 1.0f));
	real_t c = check_region(uv2 + Vector2(1.0f, 0.0f));
	real_t d = check_region(uv2 + Vector2(0.0f, 0.0f));

	real_t blend_factor = 2.0f + 126.0f * (1.0f - region_blend);
	Vector2 f = Vector2(uv2.x - Math::floor(uv2.x), uv2.y - Math::floor(uv2.y));
	f.x = Math::clamp(f.x, real_t(1e-8f), real_t(1.0f - 1e-8f));
	f.y = Math::clamp(f.y, real_t(1e-8f), real_t(1.0f - 1e-8f));
	Vector2 w = Vector2(1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.x) / f.x))),
			1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.y) / f.y))));
	real_t blend = Math::lerp(Math::lerp(d, c, w.x), Math::lerp(a, b, w.x), w.y);

	return (1.f - blend) * 2.f;
}

Vector3 Terrain3DData::get_normal(const Vector3 &p_global_position) const {
	if (get_region_idp(p_global_position) < 0 || is_hole(get_control(p_global_position))) {
		return V3_NAN;
	}
	const real_t step = _vertex_spacing;
	real_t h = get_surface_height(p_global_position);
	if (!std::isfinite(h)) {
		return V3_NAN;
	}
	real_t hx = get_surface_height(p_global_position + Vector3(step, 0.f, 0.f));
	if (!std::isfinite(hx)) {
		return V3_NAN;
	}
	real_t hz = get_surface_height(p_global_position + Vector3(0.f, 0.f, step));
	if (!std::isfinite(hx)) {
		return V3_NAN;
	}
	Vector3 normal(h - hx, step, h - hz);
	normal.normalize();
	return normal;
}

bool Terrain3DData::is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal) const {
	// If slope is full range, nothing to do here
	const Vector2 slope_range = CLAMP(p_slope_range, V2_ZERO, V2(90.f));
	if (slope_range.y - slope_range.x > 89.99f) {
		return true;
	}

	// Use custom normal if provided
	Vector3 slope_normal = p_normal;
	if (!slope_normal.is_zero_approx()) {
		slope_normal.normalize();
	} else {
		// Else, compute terrain normal
		slope_normal = get_normal(p_global_position);
		if (!slope_normal.is_finite()) {
			return false;
		}
	}

	const real_t slope_angle = slope_normal.angle_to(V3_UP);
	const real_t slope_angle_degrees = Math::rad_to_deg(slope_angle);
	return (slope_range.x <= slope_angle_degrees) && (slope_angle_degrees <= slope_range.y);
}

/**
 * Returns:
 * X = base index
 * Y = overlay index
 * Z = percentage blend between X and Y. Limited to the fixed values in RANGE.
 * Interpretation of this data is up to the gamedev. Unfortunately due to blending, this isn't
 * pixel perfect. I would have your player print this location as you walk around to see how the
 * blending values look, then consider that the overlay texture is visible starting at a blend
 * value of .3-.5, otherwise it's the base texture.
 **/
Vector3 Terrain3DData::get_texture_id(const Vector3 &p_global_position) const {
	Vector2i vgrid = world_to_vgrid(p_global_position);

	// Region + hole check. See get_modified_height() above for why this is float, not real_t.
	float control = get_pixel_descaled(TYPE_CONTROL, vgrid).r;
	if (std::isnan(control) || is_hole(control)) {
		return V3_NAN;
	}

	// Material painting writes the R16 ID/weight map, not the legacy control
	// map. Picking and live info must read the same data as the shader.
	Ref<Terrain3DRegion> region = get_regionp(p_global_position);
	if (region.is_valid() && region->get_surface_map().is_valid()) {
		// The stored payload is region_size * surface_density squared, while vgrid
		// is in region texels.
		const int density = MAX(1, region->get_surface_density());
		Vector2i pixel = (vgrid - region->get_location() * region->get_region_size()) * density;
		const int surface_size = region->get_surface_map()->get_width();
		pixel.x = CLAMP(pixel.x, 0, surface_size - 1);
		pixel.y = CLAMP(pixel.y, 0, surface_size - 1);
		float value = region->get_surface_map()->get_pixelv(pixel).r;
		uint16_t packed = uint16_t(CLAMP(Math::round(value * 65535.0f), 0.0f, 65535.0f));
		TerrainSurfaceIdWeight::Pair pair = TerrainSurfaceIdWeight::decode(packed);
		return Vector3(pair.background, pair.overlay, TerrainSurfaceIdWeight::contribution(packed));
	}

	// If material available, autoshader enabled, and pixel set to auto
	if (_terrain) {
		Ref<Terrain3DMaterial> mat = _terrain->get_material();
		if (mat.is_valid() && mat->get_auto_shader_enabled() && is_auto(control)) {
			real_t auto_slope = real_t(mat->get_shader_param("auto_slope"));
			real_t auto_height_reduction = real_t(mat->get_shader_param("auto_height_reduction"));
			real_t height = get_modified_height(vgrid);
			Vector3 normal = get_normal(p_global_position);
			uint32_t base_id = mat->get_shader_param("auto_base_texture");
			uint32_t overlay_id = mat->get_shader_param("auto_overlay_texture");
			real_t blend = CLAMP((auto_slope * 2.f * (normal.y - 1.f) + 1.f) - auto_height_reduction * .01f * height, 0.f, 1.f);
			return Vector3(real_t(base_id), real_t(overlay_id), blend);
		}
	}

	// Else, just get textures from control map
	uint32_t base_id = get_base(control);
	uint32_t overlay_id = get_overlay(control);
	real_t blend = real_t(get_blend(control)) / 255.f;
	return Vector3(real_t(base_id), real_t(overlay_id), blend);
}

/**
 * Returns the location of a terrain vertex at a certain LOD. If there is a hole at the position, it returns
 * NAN in the vector's Y coordinate.
 * p_lod (0-8): Determines how many heights around the given global position will be sampled.
 * p_filter:
 *  HEIGHT_FILTER_NEAREST: Samples the height map at the exact coordinates given.
 *  HEIGHT_FILTER_MINIMUM: Samples (1 << p_lod) ** 2 heights around the given coordinates and returns the lowest.
 * p_global_position: X and Z coordinates of the vertex. Heights will be sampled around these coordinates.
 */
Vector3 Terrain3DData::get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const {
	LOG(INFO, "Calculating vertex location");
	Vector2i vgrid = world_to_vgrid(p_global_position);
	real_t height = get_mesh_vertex_height(p_lod, p_filter, vgrid);
	return Vector3(p_global_position.x, height, p_global_position.z);
}

real_t Terrain3DData::get_mesh_vertex_height(const int32_t p_lod, const HeightFilter p_filter, const Vector2i &p_vgrid) const {
	const int32_t lod_step = 1 << CLAMP(p_lod, 0, 8);
	real_t height = 0.f;
	switch (p_filter) {
		case HEIGHT_FILTER_NEAREST: {
			height = get_modified_height(p_vgrid);
		} break;

		case HEIGHT_FILTER_MINIMUM: {
			height = get_modified_height(p_vgrid);
			if (std::isnan(height)) {
				break;
			}
			const int half = lod_step / 2;
			for (int32_t dx = -half; dx < half; ++dx) {
				for (int32_t dz = -half; dz < half; ++dz) {
					real_t h = get_modified_height(p_vgrid + Vector2i(dx, dz));
					if (std::isnan(h)) {
						height = NAN;
						return height;
					}
					if (h < height) {
						height = h;
					}
				}
			}
		} break;
	}
	return height;
}
