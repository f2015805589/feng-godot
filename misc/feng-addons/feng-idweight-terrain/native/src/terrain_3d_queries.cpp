// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// What other code asks the terrain: raycasts and intersections, baked meshes,
// navigation source geometry, and the configuration warnings the editor shows on
// the node. Split out of terrain_3d.cpp.

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

Vector3 Terrain3D::get_intersection(const Vector3 &p_src_pos, const Vector3 &p_direction, const bool p_gpu_mode) {
	if (p_direction.is_zero_approx() || !p_direction.is_finite()) {
		LOG(ERROR, "Invalid direction vector: ", p_direction);
		return V3_NAN;
	}
	if (!p_src_pos.is_finite()) {
		LOG(ERROR, "Invalid source vector: ", p_src_pos);
		return V3_NAN;
	}

	Vector3 direction = p_direction.normalized();
	// If looking straight down in a region, use get_height
	if (direction.y < -.99999f) {
		real_t height = _data->get_surface_height(p_src_pos);
		if (std ::isfinite(height)) {
			return Vector3(p_src_pos.x, height, p_src_pos.z);
		}
	}

	// Raymarching mode
	if (!p_gpu_mode) {
		// Must start above terrain if in a region
		real_t height = _data->get_surface_height(p_src_pos);
		if (height > p_src_pos.y) { // False if Nan
			return V3_MAX;
		}
		// Raymarch down the ray in small increments until we find the terrain height
		Vector3 point = p_src_pos;
		for (int i = 0; i < 4000; i++) {
			height = _data->get_surface_height(point);
			if (point.y - height <= 0.f) { // Nan comparison is false, which continues loop
				return point;
			}
			point += direction;
		}
		return V3_MAX;

	} else {
		// Get depth from perspective camera snapshot
		if (!_mouse_cam) {
			LOG(ERROR, "Invalid mouse camera");
			return V3_NAN;
		}
		// Position mouse cam one unit behind the requested position
		_mouse_cam->set_global_position(p_src_pos - direction);

		// If looking straight down, then we're not in a region, set rotation directly as look_at() doesn't work
		if (direction.y < -.99999f) {
			_mouse_cam->set_rotation_degrees(Vector3(-90.f, 0.f, 0.f));
		} else {
			_mouse_cam->look_at(_mouse_cam->get_global_position() + direction, V3_UP);
		}

		_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
		Ref<ViewportTexture> vp_tex = _mouse_vp->get_texture();
		Ref<Image> vp_img = vp_tex->get_image();

		// Read the depth pixel from the camera viewport
		Color screen_depth = vp_img->get_pixel(0, 0);

		// Get position from depth packed in RGB - unpack back to float.
		// Forward+ is 16bit, mobile and compatibility is 10bit.
		// Compatibility also has precision loss for values below 0.5, so
		// we use only the top half of the range, for 21bit depth encoded.
		real_t r = floor((screen_depth.r * 256.f) - 128.f);
		real_t g = floor((screen_depth.g * 256.f) - 128.f);
		real_t b = floor((screen_depth.b * 256.f) - 128.f);

		// Decode the full depth value
		real_t decoded_depth = (r + g / 127.f + b / (127.f * 127.f)) / 127.f;

		// Near-plane noise filter, or no hit (sky, underside, far clip)
		if (decoded_depth < 0.00001f || decoded_depth > 1.f) {
			// Catch editor ortho camera with src_pos.y at some random value around 500k
			if (direction.y < -.99999f && p_src_pos.y >= 100000.f) {
				return Vector3(p_src_pos.x, 0.f, p_src_pos.z);
			}
			return V3_MAX;
		}

		// Necessary for a near-far precision on hits
		if (decoded_depth > 0.99999f) {
			decoded_depth = 1.f;
		}

		// Denormalize distance to get real depth and terrain position.
		decoded_depth *= _mouse_cam->get_far();

		// Project the camera position by the depth value to get the intersection point.
		return _mouse_cam->get_global_position() + direction * decoded_depth;
	}
}

/* Returns the results of a physics raycast, optionally excluding the terrain
 *	p_src_pos (ray start position)
 *	p_direction (ray direction * magnitude), relative to src_pos
 */
Dictionary Terrain3D::get_raycast_result(const Vector3 &p_src_pos, const Vector3 &p_direction, const uint32_t p_col_mask, const bool p_exclude_self) const {
	if (!_is_inside_world) {
		return Dictionary();
	}
	PhysicsDirectSpaceState3D *space_state = get_world_3d()->get_direct_space_state();
	if (!space_state) {
		LOG(ERROR, "Invalid PhysicsDirectSpaceState3D");
		return Dictionary();
	}
	Ref<PhysicsRayQueryParameters3D> query = PhysicsRayQueryParameters3D::create(p_src_pos, p_src_pos + p_direction, p_col_mask);
	if (_collision && p_exclude_self) {
		query->set_exclude(TypedArray<RID>(_collision->get_rid()));
	}
	return space_state->intersect_ray(query);
}

/**
 * Generates a static ArrayMesh for the terrain.
 * p_lod (0-8): Determines the granularity of the generated mesh.
 * p_filter: Controls how vertices' Y coordinates are generated from the height map.
 *  HEIGHT_FILTER_NEAREST: Samples the height map in a 'nearest neighbour' fashion.
 *  HEIGHT_FILTER_MINIMUM: Samples a range of heights around each vertex and returns the lowest.
 *   This takes longer than ..._NEAREST, but can be used to create occluders, since it can guarantee the
 *   generated mesh will not extend above or outside the clipmap at any LOD.
 */
Ref<Mesh> Terrain3D::bake_mesh(const int p_lod, const Terrain3DData::HeightFilter p_filter) const {
	LOG(INFO, "Baking mesh at lod: ", p_lod, " with filter: ", p_filter);
	Ref<Mesh> result;
	ERR_FAIL_COND_V(_data == nullptr, result);

	Ref<SurfaceTool> st;
	st.instantiate();
	st->begin(Mesh::PRIMITIVE_TRIANGLES);

	PackedVector3Array vertices;
	PackedVector2Array uvs;
	_generate_triangles(vertices, &uvs, p_lod, p_filter, false, AABB());

	ERR_FAIL_COND_V(vertices.size() != uvs.size(), result);
	for (int i = 0; i < vertices.size(); ++i) {
		st->set_uv(uvs[i]);
		st->add_vertex(vertices[i]);
	}

	st->index();
	st->generate_normals();
	st->generate_tangents();
	st->optimize_indices_for_cache();
	result = st->commit();
	return result;
}

/**
 * Generates source geometry faces for input to nav mesh baking. Geometry is only generated where there
 * are no holes and the terrain has been painted as navigable.
 * p_global_aabb: If non-empty, geometry will be generated only within this AABB. If empty, geometry
 *  will be generated for the entire terrain.
 * p_require_nav: If true, this function will only generate geometry for terrain marked navigable.
 *  Otherwise, geometry is generated for the entire terrain within the AABB (which can be useful for
 *  dynamic and/or runtime nav mesh baking).
 */
PackedVector3Array Terrain3D::generate_nav_mesh_source_geometry(const AABB &p_global_aabb, const bool p_require_nav) const {
	LOG(INFO, "Generating NavMesh source geometry from terrain");
	PackedVector3Array faces;
	_generate_triangles(faces, nullptr, 0, Terrain3DData::HEIGHT_FILTER_NEAREST, p_require_nav, p_global_aabb);
	return faces;
}

void Terrain3D::set_warning(const uint8_t p_warning, const bool p_enabled) {
	if (p_enabled) {
		_warnings |= p_warning;
	} else {
		_warnings &= ~p_warning;
	}
	update_configuration_warnings();
}

PackedStringArray Terrain3D::_get_configuration_warnings() const {
	PackedStringArray psa;
	if (_data_directory.is_empty()) {
		psa.push_back("No data directory specified. Select a directory then save the scene to write data.");
	}
	if (_warnings & WARN_MISMATCHED_SIZE) {
		psa.push_back("Texture dimensions don't match. Double-click a texture in the FileSystem panel to see its size. Read Texture Prep in docs.");
	}
	if (_warnings & WARN_MISMATCHED_FORMAT) {
		psa.push_back("Texture formats don't match. Double-click a texture in the FileSystem panel to see its format. Check Import panel. Read Texture Prep in docs.");
	}
	if (_warnings & WARN_MISMATCHED_MIPMAPS) {
		psa.push_back("Texture mipmap settings don't match. Change on the Import panel.");
	}
	return psa;
}
