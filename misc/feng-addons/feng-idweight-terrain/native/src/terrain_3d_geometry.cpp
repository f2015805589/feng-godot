// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Geometry helpers that walk the region grid and append triangles: the shared body
// of bake_mesh() and generate_nav_mesh_source_geometry(). Split out of terrain_3d.cpp.

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_util.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

void Terrain3D::_generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
		const Terrain3DData::HeightFilter p_filter, const bool p_require_nav, const AABB &p_global_aabb) const {
	ERR_FAIL_COND(_data == nullptr);
	int32_t step = 1 << CLAMP(p_lod, 0, 8);

	// Bake whole mesh, e.g. bake_mesh and painted navigation
	if (!p_global_aabb.has_volume()) {
		int32_t region_size = (int32_t)_region_size;

		TypedArray<Vector2i> region_locations = _data->get_region_locations();
		for (const Vector2i &region_loc : region_locations) {
			Vector2i region_pos = region_loc * region_size;
			for (int32_t z = region_pos.y; z < region_pos.y + region_size; z += step) {
				for (int32_t x = region_pos.x; x < region_pos.x + region_size; x += step) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	} else {
		// Bake within an AABB
		const real_t vs = _vertex_spacing;
		const int32_t start_x = int32_t(Math::ceil(p_global_aabb.position.x / vs));
		const int32_t start_z = int32_t(Math::ceil(p_global_aabb.position.z / vs));
		const int32_t end_x = int32_t(Math::floor(p_global_aabb.get_end().x / vs)) + 1;
		const int32_t end_z = int32_t(Math::floor(p_global_aabb.get_end().z / vs)) + 1;

		for (int32_t z = start_z; z < end_z; ++z) {
			for (int32_t x = start_x; x < end_x; ++x) {
				const real_t height = _data->get_modified_height(Vector2i(x, z));
				if (std::isnan(height)) {
					continue;
				}

				if (height >= p_global_aabb.position.y && height <= p_global_aabb.get_end().y) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	}
}

// Generates two triangles: Top 124, Bottom 143
//		1  __  2
//		  |\ |
//		  | \|
//		3  --  4
// p_vertices is assumed to exist and the destination for data
// p_uvs might not exist, so a pointer is fine
// p_require_nav is false for the runtime baker, which ignores navigation
void Terrain3D::_generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs,
		const int32_t p_lod, const Terrain3DData::HeightFilter p_filter, const bool p_require_nav,
		const int32_t x, const int32_t z) const {
	const int32_t step = 1 << CLAMP(p_lod, 0, 8);
	const Vector2i v1g(x, z);
	const Vector2i v2g(x + step, z);
	const Vector2i v3g(x, z + step);
	const Vector2i v4g(x + step, z + step);
	real_t h1 = _data->get_mesh_vertex_height(p_lod, p_filter, v1g);
	if (std::isnan(h1)) {
		return;
	}
	real_t h2 = _data->get_mesh_vertex_height(p_lod, p_filter, v2g);
	real_t h3 = _data->get_mesh_vertex_height(p_lod, p_filter, v3g);
	real_t h4 = _data->get_mesh_vertex_height(p_lod, p_filter, v4g);
	bool nan2 = std::isnan(h2);
	bool nan3 = std::isnan(h3);
	bool nan4 = std::isnan(h4);
	// If on the region edge, duplicate the edge pixels
	// Check #2 upper right
	if (nan2) {
		h2 = h1;
	}
	// Check #3 lower left
	if (nan3) {
		h3 = h1;
	}
	// Check #4 lower right
	if (nan4) {
		if (!nan2) {
			h4 = h2;
		} else if (!nan3) {
			h4 = h3;
		} else {
			h4 = h1;
		}
	}

	// Get control pixels. Always float: control map is packed as a float32
	// Color component regardless of engine precision.
	float val = _data->get_pixel_descaled(TYPE_CONTROL, v1g).r;
	uint32_t ctrl1 = (std::isnan(val)) ? UINT32_MAX : as_uint(val);
	val = _data->get_pixel_descaled(TYPE_CONTROL, v2g).r;
	uint32_t ctrl2 = (std::isnan(val)) ? UINT32_MAX : as_uint(val);
	val = _data->get_pixel_descaled(TYPE_CONTROL, v3g).r;
	uint32_t ctrl3 = (std::isnan(val)) ? UINT32_MAX : as_uint(val);
	val = _data->get_pixel_descaled(TYPE_CONTROL, v4g).r;
	uint32_t ctrl4 = (std::isnan(val)) ? UINT32_MAX : as_uint(val);

	// Holes are only where the control map is valid and the bit is set
	bool hole1 = ctrl1 != UINT32_MAX && is_hole(ctrl1);
	bool hole2 = ctrl2 != UINT32_MAX && is_hole(ctrl2);
	bool hole3 = ctrl3 != UINT32_MAX && is_hole(ctrl3);
	bool hole4 = ctrl4 != UINT32_MAX && is_hole(ctrl4);

	// Navigation is where the control map is valid and the bit is set, or it's the region edge and nav1 is set
	bool nav1 = (ctrl1 != UINT32_MAX && is_nav(ctrl1));
	bool nav2 = (ctrl2 != UINT32_MAX && is_nav(ctrl2)) || (nan2 && nav1);
	bool nav3 = (ctrl3 != UINT32_MAX && is_nav(ctrl3)) || (nan3 && nav1);
	bool nav4 = (ctrl4 != UINT32_MAX && is_nav(ctrl4)) || (nan4 && nav1);

	const real_t vs = _vertex_spacing;
	Vector3 v1(v1g.x * vs, h1, v1g.y * vs);
	Vector3 v2(v2g.x * vs, h2, v2g.y * vs);
	Vector3 v3(v3g.x * vs, h3, v3g.y * vs);
	Vector3 v4(v4g.x * vs, h4, v4g.y * vs);

	//Bottom 143 triangle
	if (!(hole1 || hole4 || hole3) && (!p_require_nav || (nav1 && nav4 && nav3))) {
		p_vertices.push_back(v1);
		p_vertices.push_back(v4);
		p_vertices.push_back(v3);
		if (p_uvs) {
			p_uvs->push_back(Vector2(v1.x, v1.z));
			p_uvs->push_back(Vector2(v4.x, v4.z));
			p_uvs->push_back(Vector2(v3.x, v3.z));
		}
	}
	// Top 124 triangle
	if (!(hole1 || hole2 || hole4) && (!p_require_nav || (nav1 && nav2 && nav4))) {
		p_vertices.push_back(v1);
		p_vertices.push_back(v2);
		p_vertices.push_back(v4);
		if (p_uvs) {
			p_uvs->push_back(Vector2(v1.x, v1.z));
			p_uvs->push_back(Vector2(v2.x, v2.z));
			p_uvs->push_back(Vector2(v4.x, v4.z));
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3D::Terrain3D() {
	LOG(INFO, "Terrain3D v", _version, " - https://github.com/TokisanGames/Terrain3D");
	// Process the command line
	PackedStringArray args = OS::get_singleton()->get_cmdline_args();
	for (int i = args.size() - 1; i >= 0; i--) {
		String arg = args[i];
		if (arg.begins_with("--terrain3d-debug=")) {
			String value = arg.rsplit("=")[1];
			if (value == "ERROR") {
				set_debug_level(ERROR);
			} else if (value == "INFO") {
				set_debug_level(INFO);
			} else if (value == "DEBUG") {
				set_debug_level(DEBUG);
			} else if (value == "EXTREME") {
				set_debug_level(EXTREME);
			}
		}
	}
}
