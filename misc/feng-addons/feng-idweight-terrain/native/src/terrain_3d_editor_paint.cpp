// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DEditor, part 2 of 4: the map brush loop.

// One of four files that define the editor. `_operate_map()` reads the brush dictionary into one
// `MapBrushOp`, then walks the brush square one vertex spacing at a time, resolves the region and
// the map each step lands in, evaluates the brush mask at the vertex being written and hands the
// texel to the handler for the map being painted. `_finish_map_operation()` is everything after
// the loop: flush the cached surface bytes, re-upload the maps (partially, or rebuilt when the
// brush added or removed a region), invalidate the pages that carry the edited payload, and
// update collision, the instancer and the snap.
//
// `_sample_brush_mask()` is the bilinear sample of the mask `set_brush_data()` cached; this loop
// is its only caller, so it is a file-scope static rather than a member.
//
// The others: terrain_3d_editor.cpp (the object and its public API),
// terrain_3d_editor_texel.cpp (one brush texel) and
// terrain_3d_editor_undo.cpp (the undo and redo snapshots).

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/time.hpp>

// Bilinear brush mask sample. The mask is the brush image's R channel, cached in
// _brush_data["brush_mask"] by set_brush_data(). UVs outside [0, 1] read as
// zero.
static real_t _sample_brush_mask(const PackedFloat32Array &p_mask, const Vector2i &p_size, const Vector2 &p_uv) {
	if (p_mask.is_empty() || p_size.x < 1 || p_size.y < 1) {
		return 0.f;
	}
	if (p_uv.x < 0.f || p_uv.x > 1.f || p_uv.y < 0.f || p_uv.y > 1.f) {
		return 0.f;
	}
	const real_t x = p_uv.x * real_t(p_size.x - 1);
	const real_t y = p_uv.y * real_t(p_size.y - 1);
	const int x0 = int(Math::floor(x));
	const int y0 = int(Math::floor(y));
	const int x1 = Math::min(x0 + 1, p_size.x - 1);
	const int y1 = Math::min(y0 + 1, p_size.y - 1);
	const real_t tx = x - real_t(x0);
	const real_t ty = y - real_t(y0);
	const real_t bottom = Math::lerp(p_mask[y0 * p_size.x + x0], p_mask[y0 * p_size.x + x1], tx);
	const real_t top = Math::lerp(p_mask[y1 * p_size.x + x0], p_mask[y1 * p_size.x + x1], tx);
	return Math::lerp(bottom, top, ty);
}

void Terrain3DEditor::_operate_map(const Vector3 &p_global_position, const real_t p_camera_direction) {
	LOG(EXTREME, "Operating at ", p_global_position, " tool type ", _tool, " op ", _operation);

	MapBrushOp op;
	op.map_type = _get_map_type();
	if (op.map_type == TYPE_MAX) {
		LOG(ERROR, "Invalid tool selected");
		return;
	}

	op.region_size = _terrain->get_region_size();
	op.region_size_v = V2I(op.region_size);

	// If no region and can't add one, skip whole function. Checked again later
	Terrain3DData *data = _terrain->get_data();
	if (!data->has_regionp(p_global_position) && (!_brush_data["auto_regions"] || (_tool != SCULPT && _tool != HEIGHT))) {
		return;
	}

	bool modifier_alt = _brush_data["modifier_alt"];
	bool modifier_ctrl = _brush_data["modifier_ctrl"];

	Image *brush_image = cast_to<Image>(_brush_data["brush_image"]);
	if (!brush_image) {
		LOG(ERROR, "Invalid brush image. Returning");
		return;
	}
	// Brush mask cached as floats by set_brush_data(), sampled bilinearly below.
	op.brush_mask = _brush_data.get("brush_mask", PackedFloat32Array());
	op.brush_mask_size = _brush_data.get("brush_image_size", Vector2i());
	op.brush_size = CLAMP(real_t(_brush_data.get("size", 10.f)), 2.f, 4096.f); // Meters
	op.vertex_spacing = _terrain->get_vertex_spacing();

	// Typicall we multiply mouse pressure & strength setting, but
	// * Mouse movement w/ button down has a pressure of 1
	// * Mouse clicks always have a pressure of 0
	// * Pen movement pressure varies, sometimes lifting or clicking has a pressure of 0
	// If we're operating with a pressure of 0.001-.999 it's a pen
	// So if there's a 0 pressure operation >100ms after a pen operation, we assume it's
	// a mouse click. This occasionally catches a pen click, but avoids most pen lifts.
	real_t mouse_pressure = CLAMP(real_t(_brush_data.get("mouse_pressure", 0.f)), 0.f, 1.f);
	if (mouse_pressure > CMP_EPSILON && mouse_pressure < 1.f) {
		_last_pen_tick = Time::get_singleton()->get_ticks_msec();
	}
	uint64_t ticks = Time::get_singleton()->get_ticks_msec();
	if (mouse_pressure < CMP_EPSILON && ticks - _last_pen_tick >= 100) {
		mouse_pressure = 1.f;
	}
	op.strength = mouse_pressure * (real_t)_brush_data["strength"];

	op.height = _brush_data["height"];
	op.color = _brush_data["color"];
	op.roughness = _brush_data["roughness"];

	op.texture_filter = _brush_data["texture_filter"];
	op.margin = _brush_data["margin"];
	op.asset_id = _brush_data["asset_id"];
	// IdWeight pair painting parameters (defaults keep legacy behavior)
	op.pair_overlay_id = int(_brush_data.get("pair_overlay_id", op.asset_id));
	op.pair_background_id = int(_brush_data.get("pair_background_id", op.asset_id));
	op.pair_mode = int(_brush_data.get("pair_mode", 0)); // 0=Set, 1=Add, 2=Sub, 3=Mix
	op.pair_weight_level = int(_brush_data.get("pair_weight_level", 8)); // 1..8

	op.slope_range = _brush_data["slope"];
	// enable_angle / dynamic_angle / angle / enable_scale / scale are still
	// sanitized by set_brush_data() for the decal and the pickers, but nothing in
	// this function consumes them any more: the IdWeight R16 contract has
	// no per-texel UV rotation or scale field (see _paint_surface_pair).

	op.gamma = _brush_data["gamma"];
	op.gradient_points = _brush_data["gradient_points"];
	op.modifier_alt = modifier_alt;

	real_t randf = UtilityFunctions::randf();
	op.rotation = randf * Math_PI * real_t(_brush_data["brush_spin_speed"]);
	if (_brush_data["align_to_view"]) {
		op.rotation += p_camera_direction;
	}
	// Rotate the decal to align with the brush
	if (_terrain->get_plugin()) {
		Node *node = cast_to<Node>(_terrain->get_plugin()->get("ui"));
		if (node && node->has_method("set_decal_rotation")) {
			node->call("set_decal_rotation", op.rotation);
		}
	}
	AABB edited_area;
	edited_area.position = p_global_position - Vector3(op.brush_size, 0.f, op.brush_size) * .5f;
	edited_area.size = Vector3(op.brush_size, 0.f, op.brush_size);

	if (_tool == INSTANCER) {
		if (modifier_ctrl) {
			_terrain->get_instancer()->remove_instances(p_global_position, _brush_data);
		} else {
			_terrain->get_instancer()->add_instances(p_global_position, _brush_data);
		}
		return;
	}

	// MAP Operations
	// save region count before brush pixel loop. Any regions added will have caused an Array
	// rebuild at the end of the last _operate_map() call, but until painting is finished we only
	// need to track if _added_removed_locations has changed between now and the end of the loop
	int regions_added_removed = _added_removed_locations.size();

	// The R16 surface payload is cached per region while the brush stays inside it and
	// written back before the maps are uploaded. See SurfaceByteCache.
	SurfaceByteCache surface;

	for (real_t x = 0.f; x < op.brush_size; x += op.vertex_spacing) {
		for (real_t y = 0.f; y < op.brush_size; y += op.vertex_spacing) {
			Vector2 brush_offset = Vector2(x, y) - (V2(op.brush_size) * .5f);
			Vector3 brush_global_position =
					Vector3(p_global_position.x + brush_offset.x + .5f, p_global_position.y,
							p_global_position.z + brush_offset.y + .5f);

			// Get region for current brush pixel global position
			Vector2i region_loc = data->get_region_location(brush_global_position);
			Ref<Terrain3DRegion> region = _operate_region(region_loc);
			// If no region and can't make one, skip
			if (region.is_null()) {
				continue;
			}

			// Get map for this region and tool. The TEXTURE tool paints the
			// R16 IdWeight surface map; other tools use legacy maps.
			Image *map = nullptr;
			if (_tool == TEXTURE) {
				if (!region->ensure_surface_map()) {
					continue;
				}
				map = region->get_surface_map_ptr();
			} else {
				map = region->get_map_ptr(op.map_type);
			}
			if (!map) {
				continue;
			}

			// Identify position on map image
			Vector2 uv_position = _get_uv_position(brush_global_position, op.region_size, op.vertex_spacing);
			Vector2i map_pixel_position = Vector2i(uv_position * op.region_size);
			if (!_is_in_bounds(map_pixel_position, op.region_size_v)) {
				continue;
			}

			// The brush mask is evaluated at the world position of the vertex
			// being written, never at the loop's sample coordinate. The loop
			// samples are offset from the texel lattice by up to one vertex
			// spacing, so using (x, y) / brush_size here would leave the mask up
			// to a texel away from its target and slide the whole stamp with the
			// cursor.
			Vector2 lattice_position = Vector2(
					Math::floor(brush_global_position.x / op.vertex_spacing),
					Math::floor(brush_global_position.z / op.vertex_spacing)) *
					op.vertex_spacing;
			Vector2 brush_uv = (lattice_position - Vector2(p_global_position.x, p_global_position.z)) / op.brush_size + V2(0.5f);

			Vector3 edited_position = brush_global_position;
			edited_position.y = data->get_height(edited_position);
			edited_area = edited_area.expand(edited_position);

			// Start brushing on the map
			real_t brush_alpha = _sample_brush_mask(op.brush_mask, op.brush_mask_size, _get_rotated_uv(brush_uv, op.rotation));
			brush_alpha = real_t(Math::pow(double(brush_alpha), double(op.gamma)));
			brush_alpha = std::isnan(brush_alpha) ? 0.f : brush_alpha;
			Color src = map->get_pixelv(map_pixel_position);
			Color dest = src;
			TexelResult result;
			if (op.map_type == TYPE_HEIGHT) {
				result = _paint_height_texel(op, p_global_position, brush_global_position, brush_offset,
						brush_alpha, src.r, region.ptr(), data, edited_position, dest);
				if (result == TEXEL_WRITE) {
					// The height map decides the Y the edited area has to cover.
					edited_area = edited_area.expand(edited_position);
				}
			} else if (op.map_type == TYPE_CONTROL) {
				result = _paint_control_texel(op, data, brush_global_position, brush_alpha, region, map,
						map_pixel_position, src, surface, dest);
			} else {
				result = _paint_color_texel(op, data, brush_global_position, brush_alpha, region,
						map_pixel_position, src, dest);
			}
			if (result == TEXEL_ABORT) {
				// Two gradient points closer than 0.1 m cancel the whole operation.
				// The surface cache is only ever populated for the TEXTURE tool, so
				// this flush is a no-op here; it keeps the cache self-consistent.
				surface.flush();
				return;
			}
			if (result == TEXEL_SKIP) {
				continue;
			}
			backup_region(region);
			map->set_pixelv(map_pixel_position, dest);
		}
	}
	_finish_map_operation(op, data, regions_added_removed, edited_area, surface);
}

void Terrain3DEditor::_finish_map_operation(const MapBrushOp &p_op, Terrain3DData *p_data,
		const int p_regions_added_removed, const AABB &p_edited_area, SurfaceByteCache &r_surface) {
	// Write the cached R16 surface bytes back before the maps are uploaded.
	r_surface.flush();
	// Regenerate color mipmaps for edited regions
	if (p_op.map_type == TYPE_COLOR) {
		for (Ref<Terrain3DRegion> region : _edited_regions) {
			if (region.is_valid()) {
				region->get_map(p_op.map_type)->generate_mipmaps();
			}
		}
	}
	// If no added or removed regions, update only changed texture array layers from the edited regions in the rendering server
	if (_added_removed_locations.size() == p_regions_added_removed) {
		p_data->update_maps(p_op.map_type, false, false);
	} else {
		// If region qty was changed, must fully rebuild the maps
		p_data->update_maps(p_op.map_type, true, p_op.map_type == TYPE_COLOR);
	}
	// Surface map edits need their own array refresh (both paths rebuild when
	// regions were added, so only the partial-update path needs the call).
	if (_tool == TEXTURE && _added_removed_locations.size() == p_regions_added_removed) {
		for (const Vector2i &region_loc : p_data->get_region_locations()) {
			Terrain3DRegion *edited = p_data->get_region_ptr(region_loc);
			if (edited && edited->is_edited()) {
				int region_id = p_data->get_region_id(region_loc);
				// The array layer is the region_size reduction, not the dense payload:
				// the array is the fallback and must not grow with the density.
				Ref<Image> surface = edited->get_surface_map_array_image();
				if (surface.is_valid()) {
					p_data->update_surface_region(surface.ptr(), region_id);
				}
			}
		}
	}
	// Both virtual textures cache the same payload, so an edit has to drop the pages that
	// carry it. Without this an array-free configuration keeps rendering the material the
	// page was produced with until the LRU happens to evict it.
	if (_tool == TEXTURE) {
		for (const Vector2i &region_loc : p_data->get_region_locations()) {
			Terrain3DRegion *edited = p_data->get_region_ptr(region_loc);
			if (edited && edited->is_edited()) {
				_terrain->invalidate_surface_pages(region_loc);
			}
		}
	}
	p_data->add_edited_area(p_edited_area);

	if (_tool == HOLES || _tool == HEIGHT || _tool == SCULPT) {
		_terrain->get_instancer()->update_transforms(p_edited_area);
	}
	// Update Dynamic / Editor collision
	if (_terrain->get_collision_mode() == Terrain3DCollision::DYNAMIC_EDITOR) {
		_terrain->get_collision()->update(V2I_MAX, true);
	}
	if (_tool == HEIGHT || _tool == SCULPT || _tool == TEXTURE || _tool == AUTOSHADER) {
		_terrain->snap();
	}
}
