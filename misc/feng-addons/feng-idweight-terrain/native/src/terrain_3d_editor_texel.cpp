// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DEditor, part 3 of 4: what one brush texel does.

// One of four files that define the editor. One handler per map: `_paint_height_texel()` for the
// five operations on the height map, `_paint_control_texel()` for the bitfield tools and for the
// IdWeight surface map the Texture tool authors as raw bytes, `_paint_color_texel()` for color and
// roughness. Each returns what the loop should do with the texel - write `r_dest`, skip it, or
// abort the whole operation - and `_average_scalar()` / `_average()` are the neighbourhood
// samples the Average operation is built on.
//
// `SurfaceByteCache` and `_paint_surface_pair()` are the R16 path. The packed word is written
// bit-exactly into the region image's own bytes because `Image::set_pixelv()` would route it
// through a float and truncate it; `_paint_surface_pair()` documents the pair semantics the
// format defines and why the truncation used to leave a ring of garbage around a soft stroke.
//
// The others: terrain_3d_editor.cpp (the object and its public API),
// terrain_3d_editor_paint.cpp (the map brush loop) and
// terrain_3d_editor_undo.cpp (the undo and redo snapshots).

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_util.h"
#include "terrain_surface_idweight.h"

// IdWeight pair painting. Writes one R16 texel of the surface map with the
// ordered-pair semantics the packed format defines:
//   - same overlay/background id encodes a single background material
//   - same-pair strokes lerp the existing contribution toward the target level
//   - different-pair strokes start from target * influence
//   - a non-zero brush mask always authors the selected pair, keeping at least
//     the first discrete level instead of silently replacing with one material
//
// p_texel points at the texel's two little-endian bytes inside the region's
// surface map. The packed word is written bit-exactly: it must NOT go through
// Image::set_pixelv(), which routes the value through a float and truncates.
// That loses one LSB for 32895 of the 65536 possible words, and for the
// level-1 word (2048) the borrow reaches into the BackgroundId field, turning
// {overlay 1, level 1} into an invalid {overlay 0, background 31, mode 3,
// level 8} at full weight. That is what used to leave a ring of garbage around
// every soft brush stroke. Returns true when the texel changed.
bool Terrain3DEditor::_paint_surface_pair(uint8_t *p_texel, const real_t p_brush_alpha,
		const real_t p_strength, const int p_overlay_id, const int p_background_id,
		const int p_pair_mode, const int p_weight_level, const bool p_modifier_alt) {
	using namespace TerrainSurfaceIdWeight;
	if (!p_texel) {
		return false;
	}
	uint16_t current = read_le(p_texel);
	// Influence combines brush alpha and strength: the brush's own influence
	// curve multiplied by its strength.
	real_t influence = CLAMP(p_brush_alpha * p_strength, 0.f, 1.f);
	Pair target = { uint8_t(p_overlay_id), uint8_t(p_background_id), Mode(p_pair_mode), uint8_t(p_weight_level), 0 };
	uint16_t next = current;
	if (p_modifier_alt) {
		// Alt-click erases the overlay: encode the background as a single material.
		next = single(uint8_t(p_background_id));
	} else if (!paint(current, target, float(influence), next)) {
		LOG(ERROR, "Invalid surface paint parameters");
		return false;
	}
	if (next == current) {
		return false;
	}
	write_le(next, p_texel);
	return true;
}

Terrain3DEditor::TexelResult Terrain3DEditor::_paint_height_texel(const MapBrushOp &p_op,
		const Vector3 &p_cursor, const Vector3 &p_brush_position, const Vector2 &p_brush_offset,
		const real_t p_brush_alpha, const real_t p_src, Terrain3DRegion *p_region, Terrain3DData *p_data,
		Vector3 &r_edited_position, Color &r_dest) {
	real_t srcf = p_src;
	// In case data in existing map has nan or inf saved, check, and reset to real number if required.
	srcf = std::isnan(srcf) ? 0.f : srcf;
	real_t destf = srcf;

	switch (_operation) {
		case ADD: {
			if (_tool == HEIGHT) {
				// Height
				destf = Math::lerp(srcf, p_op.height, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
			} else if (p_op.modifier_alt && !std::isnan(p_cursor.y)) {
				// Lift troughs
				real_t brush_center_y = p_cursor.y + p_brush_alpha * p_op.strength;
				destf = Math::clamp(brush_center_y, srcf, srcf + p_brush_alpha * p_op.strength);
			} else {
				// Raise
				destf = srcf + (p_brush_alpha * p_op.strength);
			}
			break;
		}
		case SUBTRACT: {
			if (_tool == HEIGHT) {
				// Height, but GDScript has already picked height at cursor
				destf = Math::lerp(srcf, p_op.height, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
			} else if (p_op.modifier_alt && !std::isnan(p_cursor.y)) {
				// Flatten peaks
				real_t brush_center_y = p_cursor.y - p_brush_alpha * p_op.strength;
				destf = Math::clamp(brush_center_y, srcf - p_brush_alpha * p_op.strength, srcf);
			} else {
				// Lower
				destf = srcf - (p_brush_alpha * p_op.strength);
			}
			break;
		}
		case AVERAGE: {
			real_t avg_default = _terrain->get_material()->get_world_background() == 0u ? srcf : 0.f;
			real_t avg = _average_scalar(TYPE_HEIGHT, p_brush_position, srcf, avg_default);
			destf = Math::lerp(srcf, avg, CLAMP(p_brush_alpha * p_op.strength * 2.f, .02f, 1.f));
			break;
		}
		case GRADIENT: {
			if (p_op.gradient_points.size() == 2) {
				Vector3 point_1 = p_op.gradient_points[0];
				Vector3 point_2 = p_op.gradient_points[1];
				Vector2 point_1_xz = Vector2(point_1.x, point_1.z);
				Vector2 point_2_xz = Vector2(point_2.x, point_2.z);
				Vector2 dir = point_2_xz - point_1_xz;
				if (dir.length_squared() < 0.01f) {
					return TEXEL_ABORT;
				}
				Vector2 brush_xz = Vector2(p_brush_position.x, p_brush_position.z);

				if (_operation_movement.length_squared() > 0.f) {
					// Ramp up/down only in the direction of movement, to avoid giving winding
					// paths one edge higher than the other.
					Vector2 movement_xz = Vector2(_operation_movement.x, _operation_movement.z).normalized();
					Vector2 offset = movement_xz * Vector2(p_brush_offset).dot(movement_xz);
					brush_xz = Vector2(p_cursor.x + offset.x, p_cursor.z + offset.y);
				}

				real_t weight = dir.normalized().dot(brush_xz - point_1_xz) / dir.length();
				weight = Math::clamp(weight, (real_t)0.0f, (real_t)1.0f);
				real_t gradient_height = Math::lerp(point_1.y, point_2.y, weight);
				destf = Math::lerp(srcf, gradient_height, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
			}
			break;
		}
		default:
			break;
	}
	r_dest = Color(destf, 0.f, 0.f, 1.f);
	p_region->update_height(destf);
	p_data->update_master_height(destf);
	r_edited_position.y = destf;

	return TEXEL_WRITE;
}

Terrain3DEditor::TexelResult Terrain3DEditor::_paint_control_texel(const MapBrushOp &p_op,
		Terrain3DData *p_data, const Vector3 &p_brush_position, const real_t p_brush_alpha,
		const Ref<Terrain3DRegion> &p_region, Image *p_map, const Vector2i &p_map_pixel,
		const Color &p_src, SurfaceByteCache &r_surface, Color &r_dest) {
	if (_tool == TEXTURE) {
		// IdWeight material painting writes the region's R16 surface
		// map. The legacy RF control map is never authored by
		// this tool and must not be decoded here: `p_src` holds the
		// packed R16 word, not a control bitfield.
		if (!p_data->is_in_slope(p_brush_position, p_op.slope_range)) {
			return TEXEL_SKIP;
		}
		backup_region(p_region);
		if (!r_surface.adopt(p_region, p_map)) {
			LOG(ERROR, "Surface map must be R16 UNORM");
			return TEXEL_SKIP;
		}
		// The stored payload is surface_density squared texels per region
		// texel. The brush authors one region texel per step, so it writes
		// the whole block. The block is uniform by construction: every write
		// is a block write, and a density change replicates one source texel
		// over its block.
		const int density = MAX(1, p_region->get_surface_density());
		const int surface_width = p_map->get_width();
		uint8_t *surface_texel = r_surface.texel(surface_width, p_map_pixel, density);
		if (_paint_surface_pair(surface_texel, p_brush_alpha, p_op.strength,
					p_op.pair_overlay_id, p_op.pair_background_id, p_op.pair_mode, p_op.pair_weight_level,
					p_op.modifier_alt) &&
				density > 1) {
			const uint16_t painted = TerrainSurfaceIdWeight::read_le(surface_texel);
			for (int by = 0; by < density; by++) {
				for (int bx = 0; bx < density; bx++) {
					if (bx == 0 && by == 0) {
						// The base texel already holds the painted value.
						continue;
					}
					TerrainSurfaceIdWeight::write_le(painted,
							r_surface.texel(surface_width, p_map_pixel, density, Vector2i(bx, by)));
				}
			}
		}
		return TEXEL_SKIP;
	}
	// Get current bit field from pixel
	uint32_t base_id = get_base(p_src.r);
	uint32_t overlay_id = get_overlay(p_src.r);
	real_t blend = real_t(get_blend(p_src.r)) / 255.f;
	uint32_t uvrotation = get_uv_rotation(p_src.r);
	uint32_t uvscale = get_uv_scale(p_src.r);
	bool hole = is_hole(p_src.r);
	bool navigation = is_nav(p_src.r);
	bool autoshader = is_auto(p_src.r);

	switch (_tool) {
		case AUTOSHADER: {
			if (p_brush_alpha > 0.5f) {
				autoshader = (_operation == ADD);
				uvscale = 0.f;
				uvrotation = 0.f;
			}
			break;
		}
		case HOLES: {
			if (p_brush_alpha > 0.5f) {
				hole = (_operation == ADD);
			}
			break;
		}
		case NAVIGATION: {
			if (p_brush_alpha > 0.5f) {
				navigation = (_operation == ADD);
			}
			break;
		}
		default: {
			break;
		}
	}

	// Convert back to bitfield
	uint32_t blend_int = uint32_t(CLAMP(Math::round(blend * 255.f), 0.f, 255.f));
	uint32_t bits = enc_base(base_id) | enc_overlay(overlay_id) |
			enc_blend(blend_int) | enc_uv_rotation(uvrotation) |
			enc_uv_scale(uvscale) | enc_hole(hole) |
			enc_nav(navigation) | enc_auto(autoshader);

	// Write back to pixel in FORMAT_RF. Must be a 32-bit float
	r_dest = Color(as_float(bits), 0.f, 0.f, 1.f);
	return TEXEL_WRITE;
}

Terrain3DEditor::TexelResult Terrain3DEditor::_paint_color_texel(const MapBrushOp &p_op,
		Terrain3DData *p_data, const Vector3 &p_brush_position, const real_t p_brush_alpha,
		const Ref<Terrain3DRegion> &p_region, const Vector2i &p_map_pixel, const Color &p_src,
		Color &r_dest) {
	// Filter by visible texture
	if (p_op.texture_filter) {
		Image *cmap = p_region->get_map_ptr(TYPE_CONTROL);
		if (!cmap) {
			return TEXEL_SKIP;
		}
		float src_ctrl = cmap->get_pixelv(p_map_pixel).r; // Must be float
		int tex_id = (get_blend(src_ctrl) > 110 - p_op.margin) ? get_overlay(src_ctrl) : get_base(src_ctrl);
		if (tex_id != p_op.asset_id) {
			return TEXEL_SKIP;
		}
	}
	if (!p_data->is_in_slope(p_brush_position, p_op.slope_range)) {
		return TEXEL_SKIP;
	}
	switch (_tool) {
		case COLOR:
			switch (_operation) {
				case ADD: {
					r_dest = p_src.lerp(p_op.color, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
					r_dest.a = p_src.a;
					break;
				}
				case SUBTRACT: {
					r_dest = p_src.lerp(COLOR_WHITE, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
					r_dest.a = p_src.a;
					break;
				}
				case AVERAGE: {
					Color avg_col = _average(p_brush_position, p_src);
					r_dest = p_src.lerp(avg_col, CLAMP(p_brush_alpha * p_op.strength * 2.f, .02f, 1.f));
					r_dest.a = p_src.a;
					break;
				}
				default:
					break;
			}
			break;
		case ROUGHNESS:
			/* Roughness received from UI is -100 to 100. Changed to 0,1 before storing.
			 * To convert 0,1 back to -100,100 use: 200 * (color.a - 0.5)
			 * However Godot stores values as 8-bit ints. Roundtrip is = int(a*255)/255.0
			 * Roughness 0 is saved as 0.5, but retreived is 0.498, or -0.4 roughness
			 * We round the final amount in tool_settings.gd:_on_picked().
			 */
			switch (_operation) {
				case ADD: {
					real_t target = .5f + .5f * p_op.roughness;
					r_dest.a = Math::lerp(real_t(p_src.a), target, CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
					r_dest.a = float(int(r_dest.a * 255.f)) / 255.f; // Quantize explicitly so picked values match painted values
					break;
				}
				case SUBTRACT: {
					r_dest.a = Math::lerp(real_t(p_src.a), real_t(.5f), CLAMP(p_brush_alpha * p_op.strength, 0.f, 1.f));
					r_dest.a = float(int(r_dest.a * 255.f)) / 255.f;
					break;
				}
				case AVERAGE: {
					real_t avg = _average_scalar(TYPE_COLOR, p_brush_position, p_src.a, 0.5f);
					r_dest.a = Math::lerp(real_t(r_dest.a), avg, CLAMP(p_brush_alpha * p_op.strength * 2.f, .0f, 1.f));
					r_dest.a = float(int(r_dest.a * 255.f)) / 255.f;
					break;
				}
				default:
					break;
			}
			break;
		default:
			break;
	}
	return TEXEL_WRITE;
}

void Terrain3DEditor::SurfaceByteCache::flush() {
	if (image && region) {
		image->set_data(image->get_width(), image->get_height(), false, IDWEIGHT_IMAGE_FORMAT, bytes);
		// Mark the region edited so the surface map layer is uploaded to the GPU
		// texture array. Without this the painted texels stay in CPU memory and the
		// shader keeps sampling the old (all-zero) layer.
		region->set_modified(true);
	}
	image = nullptr;
	region = nullptr;
	bytes = PackedByteArray();
}

bool Terrain3DEditor::SurfaceByteCache::adopt(const Ref<Terrain3DRegion> &p_region, Image *p_map) {
	if (region == p_region.ptr()) {
		return true;
	}
	flush();
	if (p_map->get_format() != IDWEIGHT_IMAGE_FORMAT) {
		return false;
	}
	image = p_map;
	region = p_region.ptr();
	bytes = p_map->get_data();
	return true;
}

uint8_t *Terrain3DEditor::SurfaceByteCache::texel(const int p_width, const Vector2i &p_pixel,
		const int p_density, const Vector2i &p_block) {
	const int x = p_pixel.x * p_density + p_block.x;
	const int y = p_pixel.y * p_density + p_block.y;
	return bytes.ptrw() + (int64_t(y) * p_width + x) * 2;
}

// Height uses red; roughness uses the color map's alpha channel.
float Terrain3DEditor::_average_scalar(const MapType p_map_type, const Vector3 &p_global_position, const float p_base,
		const float p_nan_val) const {
	IS_DATA_INIT(NAN);
	Terrain3DData *data = _terrain->get_data();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector3 left_position = p_global_position - Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 right_position = p_global_position + Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 down_position = p_global_position - Vector3(0.f, 0.f, vertex_spacing);
	Vector3 up_position = p_global_position + Vector3(0.f, 0.f, vertex_spacing);

	const int index = p_map_type == TYPE_COLOR ? 3 : 0;

	Color pixel;
	float left, right, up, down;
	pixel = data->get_pixel(p_map_type, left_position);
	left = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(p_map_type, right_position);
	right = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(p_map_type, up_position);
	up = std::isnan(pixel.r) ? p_nan_val : pixel[index];
	pixel = data->get_pixel(p_map_type, down_position);
	down = std::isnan(pixel.r) ? p_nan_val : pixel[index];

	return (p_base + left + right + up + down) * 0.2f;
}

Color Terrain3DEditor::_average(const Vector3 &p_global_position, const Color &p_base) const {
	IS_DATA_INIT(COLOR_NAN);
	Terrain3DData *data = _terrain->get_data();
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector3 left_position = p_global_position - Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 right_position = p_global_position + Vector3(vertex_spacing, 0.f, 0.f);
	Vector3 down_position = p_global_position - Vector3(0.f, 0.f, vertex_spacing);
	Vector3 up_position = p_global_position + Vector3(0.f, 0.f, vertex_spacing);

	Color left = data->get_pixel(TYPE_COLOR, left_position).srgb_to_linear();
	if (std::isnan(left.r)) {
		left = COLOR_WHITE;
	}
	Color right = data->get_pixel(TYPE_COLOR, right_position).srgb_to_linear();
	if (std::isnan(right.r)) {
		right = COLOR_WHITE;
	}
	Color up = data->get_pixel(TYPE_COLOR, up_position).srgb_to_linear();
	if (std::isnan(up.r)) {
		up = COLOR_WHITE;
	}
	Color down = data->get_pixel(TYPE_COLOR, down_position).srgb_to_linear();
	if (std::isnan(down.r)) {
		down = COLOR_WHITE;
	}
	Color base = p_base.srgb_to_linear();
	return Color(
			(base.r + left.r + right.r + up.r + down.r) * 0.2f,
			(base.g + left.g + right.g + up.g + down.g) * 0.2f,
			(base.b + left.b + right.b + up.b + down.b) * 0.2f,
			1.f)
			.linear_to_srgb();
}
