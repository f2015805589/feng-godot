// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_EDITOR_CLASS_H
#define TERRAIN3D_EDITOR_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

#include "terrain_3d.h"
#include "terrain_3d_region.h"

class Terrain3DEditor : public Object {
	GDCLASS(Terrain3DEditor, Object);
	CLASS_NAME();

public: // Constants
	enum Tool {
		REGION,
		SCULPT,
		HEIGHT,
		TEXTURE,
		COLOR,
		ROUGHNESS,
		AUTOSHADER,
		HOLES,
		NAVIGATION,
		INSTANCER,
		ANGLE, // used for picking, TODO change to a picking tool
		SCALE, // used for picking
		TOOL_MAX,
	};

	static inline const char *TOOLNAME[] = {
		"Region",
		"Sculpt",
		"Height",
		"Texture",
		"Color",
		"Roughness",
		"Auto Shader",
		"Holes",
		"Navigation",
		"Instancer",
		"Angle",
		"Scale",
		"TOOL_MAX",
	};

	enum Operation {
		ADD,
		SUBTRACT,
		REPLACE,
		AVERAGE,
		GRADIENT,
		OP_MAX,
	};

	static inline const char *OPNAME[] = {
		"Add",
		"Subtract",
		"Replace",
		"Average",
		"Gradient",
		"OP_MAX",
	};

private:
	Terrain3D *_terrain = nullptr;

	// Painter settings & variables
	Tool _tool = REGION;
	Operation _operation = ADD;
	Dictionary _brush_data;
	Vector3 _operation_position = V3_ZERO;
	Vector3 _operation_movement = V3_ZERO;
	Array _operation_movement_history;
	bool _is_operating = false;
	uint64_t _last_region_bounds_error = 0;
	TypedArray<Terrain3DRegion> _original_regions; // Queue for undo
	TypedArray<Terrain3DRegion> _edited_regions; // Queue for redo
	TypedArray<Vector2i> _added_removed_locations; // Queue for added/removed locations
	Dictionary _undo_data; // See _get_undo_data for definition
	uint64_t _last_pen_tick = 0;

	// The IdWeight R16 surface map is authored as raw bytes rather than through
	// Image::set_pixelv(): one region texel is a whole density x density block, and
	// set_pixelv() would decode and re-encode the packed word one component at a
	// time. Image::get_data() hands back a copy-on-write view, so the bytes are
	// cached while the brush stays inside one region and written back when it
	// leaves. See _paint_control_texel().
	struct SurfaceByteCache {
		Image *image = nullptr;
		Terrain3DRegion *region = nullptr;
		PackedByteArray bytes;

		void flush();
		// Adopts p_map's bytes, flushing the previous region first. False when the
		// map is not the R16 UNORM format the IdWeight contract requires.
		bool adopt(const Ref<Terrain3DRegion> &p_region, Image *p_map);
		// Writable first texel of the density x density block at p_pixel + p_block.
		uint8_t *texel(const int p_width, const Vector2i &p_pixel, const int p_density,
				const Vector2i &p_block = Vector2i());
	};

	// Everything _operate_map() reads out of the brush dictionary once, so the
	// per-texel handlers can be plain functions instead of a 300 line double loop.
	struct MapBrushOp {
		MapType map_type = TYPE_MAX;
		Vector2i region_size_v;
		real_t region_size = 0.f;
		real_t vertex_spacing = 1.f;
		real_t brush_size = 0.f;
		real_t strength = 0.f;
		real_t height = 0.f;
		real_t roughness = 0.f;
		real_t gamma = 1.f;
		real_t rotation = 0.f;
		Color color;
		Vector2 slope_range;
		PackedVector3Array gradient_points;
		PackedFloat32Array brush_mask;
		Vector2i brush_mask_size;
		bool texture_filter = false;
		bool modifier_alt = false;
		int margin = 0;
		int asset_id = 0;
		int pair_overlay_id = 0;
		int pair_background_id = 0;
		int pair_mode = 0;
		int pair_weight_level = 8;
	};

	// What one brush texel decided, so the loop can act on it.
	enum TexelResult {
		TEXEL_WRITE, // r_dest holds the pixel to store
		TEXEL_SKIP, // this texel is done, or was written by the handler itself
		TEXEL_ABORT, // the whole operation cannot continue
	};

	void _send_region_aabb(const Vector2i &p_region_loc, const Vector2 &p_height_range = V2_ZERO);
	Ref<Terrain3DRegion> _operate_region(const Vector2i &p_region_loc);
	void _operate_map(const Vector3 &p_global_position, const real_t p_camera_direction);
	TexelResult _paint_height_texel(const MapBrushOp &p_op, const Vector3 &p_cursor,
			const Vector3 &p_brush_position, const Vector2 &p_brush_offset, const real_t p_brush_alpha,
			const real_t p_src, Terrain3DRegion *p_region, Terrain3DData *p_data,
			Vector3 &r_edited_position, Color &r_dest);
	TexelResult _paint_control_texel(const MapBrushOp &p_op, Terrain3DData *p_data,
			const Vector3 &p_brush_position, const real_t p_brush_alpha,
			const Ref<Terrain3DRegion> &p_region, Image *p_map, const Vector2i &p_map_pixel,
			const Color &p_src, SurfaceByteCache &r_surface, Color &r_dest);
	TexelResult _paint_color_texel(const MapBrushOp &p_op, Terrain3DData *p_data,
			const Vector3 &p_brush_position, const real_t p_brush_alpha,
			const Ref<Terrain3DRegion> &p_region, const Vector2i &p_map_pixel, const Color &p_src,
			Color &r_dest);
	void _finish_map_operation(const MapBrushOp &p_op, Terrain3DData *p_data,
			const int p_regions_added_removed, const AABB &p_edited_area, SurfaceByteCache &r_surface);
	MapType _get_map_type() const;
	bool _is_in_bounds(const Point2i &p_pixel, const Point2i &p_size) const;
	Vector2 _get_uv_position(const Vector3 &p_global_position, const int p_region_size, const real_t p_vertex_spacing) const;
	Vector2 _get_rotated_uv(const Vector2 &p_uv, const real_t p_angle) const;
	void _store_undo();
	// IdWeight pair painting helpers
	bool _paint_surface_pair(uint8_t *p_texel, const real_t p_brush_alpha,
			const real_t p_strength, const int p_overlay_id, const int p_background_id,
			const int p_pair_mode, const int p_weight_level, const bool p_modifier_alt);
	void _apply_undo(const Dictionary &p_data);
	float _average_scalar(const MapType p_map_type, const Vector3 &p_global_position, const float p_base, const float p_nan_val) const;
	Color _average(const Vector3 &p_global_position, const Color &p_base) const;

public:
	Terrain3DEditor() {}
	~Terrain3DEditor() {}

	void set_terrain(Terrain3D *p_terrain) { _terrain = p_terrain; }
	Terrain3D *get_terrain() const { return _terrain; }

	void set_brush_data(const Dictionary &p_data);
	Dictionary get_brush_data() const { return _brush_data; }
	void set_tool(const Tool p_tool);
	Tool get_tool() const { return _tool; }
	void set_operation(const Operation p_operation);
	Operation get_operation() const { return _operation; }

	void start_operation(const Vector3 &p_global_position);
	bool is_operating() const { return _is_operating; }
	void operate(const Vector3 &p_global_position, const real_t p_camera_direction);
	void backup_region(const Ref<Terrain3DRegion> &p_region);
	void stop_operation();

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DEditor::Operation);
VARIANT_ENUM_CAST(Terrain3DEditor::Tool);

// Inline functions

inline MapType Terrain3DEditor::_get_map_type() const {
	switch (_tool) {
		case SCULPT:
		case HEIGHT:
		case INSTANCER:
			return TYPE_HEIGHT;
			break;
		case TEXTURE:
		case AUTOSHADER:
		case HOLES:
		case NAVIGATION:
		case ANGLE:
		case SCALE:
			return TYPE_CONTROL;
			break;
		case COLOR:
		case ROUGHNESS:
			return TYPE_COLOR;
			break;
		default:
			return TYPE_MAX;
	}
}

inline bool Terrain3DEditor::_is_in_bounds(const Point2i &p_pixel, const Point2i &p_size) const {
	bool positive = p_pixel.x >= 0 && p_pixel.y >= 0;
	bool less_than_max = p_pixel.x < p_size.x && p_pixel.y < p_size.y;
	return positive && less_than_max;
}

inline Vector2 Terrain3DEditor::_get_uv_position(const Vector3 &p_global_position, const int p_region_size, const real_t p_vertex_spacing) const {
	Vector2 descaled_position_2d = Vector2(p_global_position.x, p_global_position.z) / p_vertex_spacing;
	Vector2 region_position = descaled_position_2d / real_t(p_region_size);
	region_position = region_position.floor();
	Vector2 uv_position = (descaled_position_2d / real_t(p_region_size)) - region_position;
	return uv_position;
}

inline Vector2 Terrain3DEditor::_get_rotated_uv(const Vector2 &p_uv, const real_t p_angle) const {
	Vector2 rotation_offset = V2(0.5f);
	Vector2 uv = (p_uv - rotation_offset).rotated(p_angle) + rotation_offset;
	return uv.clamp(V2_ZERO, V2(1.f));
}

#endif // TERRAIN3D_EDITOR_CLASS_H
