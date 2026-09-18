// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D, part 2 of 3: the subsystem nodes and GPU objects this node owns.

// One of three files that define the node. Every function here either creates or releases one
// subsystem node or GPU object - the terrain and ocean meshers, the displacement buffer and its
// SubViewport, the collision body, the mouse-picking state, the label containers, and the
// instancer and streamer - in the order `_notification()` needs them. All of them are idempotent
// (each checks what is already valid before creating) because the notification they answer can
// arrive more than once.
//
// The other two: `terrain_3d.cpp` (the node and its frame schedule) and
// `terrain_3d_monitors.cpp` (the debug monitors).

#include "terrain_3d.h"

#include "logger.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3D::_destroy_collision(const bool p_final) {
	LOG(INFO, "Destroying Collision");
	if (_collision) {
		_collision->destroy();
	}
	if (p_final) {
		memdelete_safely(_collision);
	}
}

void Terrain3D::_setup_terrain_mesher() {
	if (!_terrain_mesher) {
		LOG(DEBUG, "Creating mesher");
		_terrain_mesher = new Terrain3DMesher();
	}
	_terrain_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing, _material->get_material_rid(), _render_layers, true);
}

void Terrain3D::_destroy_terrain_mesher(const bool p_final) {
	LOG(INFO, "Destroying terrain mesher");
	if (_terrain_mesher) {
		_terrain_mesher->destroy();
		if (p_final) {
			delete _terrain_mesher;
			_terrain_mesher = nullptr;
		}
	}
}

void Terrain3D::_setup_ocean_mesher() {
	if (_ocean_enabled) {
		if (!_ocean_mesher) {
			LOG(DEBUG, "Creating mesher");
			_ocean_mesher = new Terrain3DMesher();
		}
		_ocean_mesher->initialize(this, _ocean_mesh_size, _ocean_mesh_lods, _ocean_tessellation_level, _ocean_vertex_spacing, _ocean_material.is_valid() ? _ocean_material->get_rid() : RID(), _ocean_render_layers);
		_ocean_mesher->update_aabbs(_ocean_cull_margin, V2_ZERO);
		if (_ocean_material.is_valid()) {
			ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
			if (ocean_shader_mat) {
				ocean_shader_mat->set_shader_parameter("_mesh_size", _ocean_mesh_size);
				ocean_shader_mat->set_shader_parameter("_vertex_spacing", _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_vertex_density", 1.0f / _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_subdiv", pow(2.f, real_t(_ocean_tessellation_level)));
			}
		}
	}
}

void Terrain3D::_destroy_ocean_mesher(const bool p_final) {
	LOG(INFO, "Destroying ocean mesher");
	if (_ocean_mesher) {
		_ocean_mesher->destroy();
		if (p_final) {
			delete _ocean_mesher;
			_ocean_mesher = nullptr;
		}
	}
}

void Terrain3D::_setup_displacement_buffer() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping displacement buffer setup");
		return;
	}
	_destroy_displacement_buffer();
	LOG(INFO, "Setting up displacement buffer");
	_d_buffer_vp = memnew(SubViewport);
	_d_buffer_vp->set_name("DBufferViewport");
	add_child(_d_buffer_vp, true);
	_d_buffer_vp->set_size(Vector2i(2, 2));
	_d_buffer_vp->set_disable_3d(true);
	_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_d_buffer_vp->set_disable_input(true);
	_d_buffer_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);

	_d_buffer_rect = memnew(ColorRect);
	_d_buffer_rect->set_name("DBufferRect");
	_d_buffer_vp->add_child(_d_buffer_rect, true);
	_d_buffer_rect->set_anchors_preset(Control::PRESET_FULL_RECT);
}

void Terrain3D::_update_displacement_buffer() {
	if (!_d_buffer_vp) {
		return;
	}
	if (_tessellation_level == 0) {
		_d_buffer_vp->set_size(V2I_ZERO);
		_d_buffer_rect->set_size(V2I_ZERO);
	} else {
		_d_buffer_vp->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		_d_buffer_rect->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		LOG(INFO, "Updating displacement buffer to Size: ", _d_buffer_vp->get_size());
		if (_material.is_valid() && _material->get_material_rid().is_valid()) {
			RS->canvas_item_set_material(_d_buffer_rect->get_canvas_item(), _material->get_buffer_material_rid());
			RS->material_set_param(_material->get_material_rid(), "_displacement_buffer", _d_buffer_vp->get_texture()->get_rid());
		}
	}
}

void Terrain3D::_build_containers() {
	_label_parent = memnew(Node3D);
	_label_parent->set_name("Labels");
	add_child(_label_parent, true);
}

void Terrain3D::_destroy_containers() {
	memdelete_safely(_label_parent);
}

void Terrain3D::_destroy_labels() {
	Array labels = _label_parent->get_children();
	LOG(DEBUG, "Destroying ", labels.size(), " region labels");
	for (const Variant &var : labels) {
		Node *label = cast_to<Node>(var);
		memdelete_safely(label);
	}
}

void Terrain3D::_destroy_displacement_buffer() {
	LOG(DEBUG, "Freeing d_buffer_rect");
	memdelete_safely(_d_buffer_rect);
	LOG(DEBUG, "Freeing d_buffer_vp");
	memdelete_safely(_d_buffer_vp);
}

void Terrain3D::_setup_mouse_picking() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping mouse setup");
		return;
	}
	LOG(INFO, "Setting up mouse picker and get_intersection viewport, camera & screen quad");
	_mouse_vp = memnew(SubViewport);
	_mouse_vp->set_name("MouseViewport");
	add_child(_mouse_vp, true);
	_mouse_vp->set_size(V2I(2));
	_mouse_vp->set_scaling_3d_mode(Viewport::SCALING_3D_MODE_BILINEAR);
	_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_mouse_vp->set_disable_input(true);
	_mouse_vp->set_canvas_cull_mask(0);
	_mouse_vp->set_use_hdr_2d(true);
	_mouse_vp->set_anisotropic_filtering_level(Viewport::ANISOTROPY_DISABLED);
	_mouse_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);
	_mouse_vp->set_positional_shadow_atlas_size(0);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(0, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(1, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(2, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(3, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);

	_mouse_cam = memnew(Camera3D);
	_mouse_cam->set_name("MouseCamera");
	_mouse_vp->add_child(_mouse_cam, true);
	Ref<Environment> env;
	env.instantiate();
	env->set_tonemapper(Environment::TONE_MAPPER_LINEAR);
	_mouse_cam->set_environment(env);
	Ref<Compositor> comp;
	comp.instantiate();
	_mouse_cam->set_compositor(comp);
	_mouse_cam->set_projection(Camera3D::PROJECTION_ORTHOGONAL);
	_mouse_cam->set_size(0.1f);
	_mouse_cam->set_far(100000.f);

	_mouse_quad = memnew(MeshInstance3D);
	_mouse_quad->set_name("MouseQuad");
	_mouse_cam->add_child(_mouse_quad, true);
	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(V2(0.1f));
	_mouse_quad->set_mesh(quad);
	String shader_code = String(
#include "shaders/gpu_depth.glsl"
	);
	Ref<Shader> shader;
	shader.instantiate();
	shader->set_code(shader_code);
	Ref<ShaderMaterial> shader_material;
	shader_material.instantiate();
	shader_material->set_shader(shader);
	_mouse_quad->set_surface_override_material(0, shader_material);
	_mouse_quad->set_position(Vector3(0.f, 0.f, -0.5f));

	// Set terrain, terrain shader, mouse camera, and screen quad to mouse layer
	uint32_t force_update_layer = _mouse_layer;
	_mouse_layer = 0u;
	set_mouse_layer(force_update_layer);
}

void Terrain3D::_destroy_mouse_picking() {
	LOG(DEBUG, "Freeing mouse_quad");
	memdelete_safely(_mouse_quad);
	LOG(DEBUG, "Freeing mouse_cam");
	memdelete_safely(_mouse_cam);
	LOG(DEBUG, "Freeing mouse_vp");
	memdelete_safely(_mouse_vp);
}

void Terrain3D::_destroy_instancer() {
	LOG(INFO, "Destroying Instancer");
	memdelete_safely(_instancer);
}

void Terrain3D::_destroy_streamer() {
	LOG(INFO, "Destroying Streamer");
	memdelete_safely(_streamer);
	_streaming_enabled = false;
}
