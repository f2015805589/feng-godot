// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

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
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

// Initialize static member variable
Terrain3D::DebugLevel Terrain3D::debug_level{ ERROR };

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3D::_initialize() {
	LOG(INFO, "Instantiating main subsystems");
	// Make blank objects if needed
	if (!_data) {
		LOG(DEBUG, "Creating blank data object");
		_data = memnew(Terrain3DData);
	}
	if (_material.is_null()) {
		LOG(DEBUG, "Creating blank material");
		_material.instantiate();
	}
	if (_assets.is_null()) {
		LOG(DEBUG, "Creating blank texture list");
		_assets.instantiate();
	}
	if (_assets->get_terrain() && _assets->get_terrain() != this) {
		_assets = _assets->duplicate(true);
	}
	if (!_collision) {
		LOG(DEBUG, "Creating collision manager");
		_collision = memnew(Terrain3DCollision);
	}
	if (!_instancer) {
		LOG(DEBUG, "Creating instancer");
		_instancer = memnew(Terrain3DInstancer);
	}
	if (!_streamer) {
		LOG(DEBUG, "Creating region streamer");
		_streamer = memnew(Terrain3DStreamer);
	}
	_setup_surface_vt();
	_setup_surface_svt();
	// Connect signals
	// Any region was changed, update region labels
	if (!_data->is_connected("region_map_changed", callable_mp(this, &Terrain3D::update_region_labels))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to set_show_region_locations()");
		_data->connect("region_map_changed", callable_mp(this, &Terrain3D::update_region_labels));
	}
	// Any region was changed, regenerate collision if enabled
	if (!_data->is_connected("region_map_changed", callable_mp(_collision, &Terrain3DCollision::build))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to build()");
		_data->connect("region_map_changed", callable_mp(_collision, &Terrain3DCollision::build));
	}
	// Any map was regenerated or regions changed, update material uniforms without rebuilding shaders
	if (!_data->is_connected("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::REGION_ARRAYS))) {
		LOG(DEBUG, "Connecting _data::maps_changed signal to _material->_update()");
		_data->connect("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::REGION_ARRAYS));
	}
	// Height map was regenerated, update aabbs
	if (!_data->is_connected("height_maps_changed", callable_mp(this, &Terrain3D::_update_mesher_aabbs))) {
		LOG(DEBUG, "Connecting _data::height_maps_changed signal to update_aabbs()");
		_data->connect("height_maps_changed", callable_mp(this, &Terrain3D::_update_mesher_aabbs));
	}
	// Texture assets changed, update material uniforms without rebuilding shaders
	if (!_assets->is_connected("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::TEXTURE_ARRAYS))) {
		LOG(DEBUG, "Connecting _assets.textures_changed to _material->update()");
		_assets->connect("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::TEXTURE_ARRAYS));
	}
	// Initialize the system
	if (!_initialized && _is_inside_world && is_inside_tree()) {
		LOG(INFO, "Initializing main subsystems");
		_data->initialize(this);
		_material->initialize(this);
		_assets->initialize(this);
		_collision->initialize(this);
		_instancer->initialize(this);
		_streamer->initialize(this);
		_streamer->set_enabled(_streaming_enabled);
		_setup_terrain_mesher();
		_setup_ocean_mesher();
		_update_displacement_buffer();
		_initialized = true;
		snap();
	}
	update_configuration_warnings();
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
void Terrain3D::__physics_process(const double p_delta) {
	if (!_initialized) {
		return;
	}
	if (!_camera.is_valid()) {
		LOG(DEBUG, "Camera is null, getting the current one");
		_grab_camera();
	}
	if (_tessellation_level > 0) {
		if (_terrain_mesher && _d_buffer_vp && _material.is_valid()) {
			// If clipmap target has moved enough, re-center buffer on the target.
			Vector2 target_pos_2d = v3v2(get_clipmap_target_position());
			real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
			real_t vertex_spacing = _vertex_spacing * tessellation_density;
			if (!(MAX(std::abs(_last_buffer_position.x - target_pos_2d.x), std::abs(_last_buffer_position.y - target_pos_2d.y)) < vertex_spacing)) {
				_last_buffer_position = target_pos_2d;
				RS->material_set_param(_material->get_buffer_material_rid(), "_target_pos", get_clipmap_target_position());
				_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
				// Only call snap on _mesher if the buffer has snapped, prevents stuttering.
				_terrain_mesher->snap();
			}
		}
	} else if (_terrain_mesher) {
		_terrain_mesher->snap();
	}
	if (_ocean_enabled && _ocean_mesher) {
		_ocean_mesher->snap();
	}
	if (_light_target.is_valid()) {
		DirectionalLight3D *light = cast_to<DirectionalLight3D>(_light_target.ptr());
		if (light) {
			Color color = light->get_color() * light->get_param(DirectionalLight3D::PARAM_ENERGY);
			Vector3 direction = light->get_global_basis().get_column(2);
			if (_material.is_valid()) {
				_material->set_shader_param("_light_color", color);
				_material->set_shader_param("_light_direction", direction);
			}
			if (_ocean_material.is_valid()) {
				ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
				if (ocean_shader_mat) {
					ocean_shader_mat->set_shader_parameter("_light_color", color);
					ocean_shader_mat->set_shader_parameter("_light_direction", direction);
				}
			}
		}
	}
	if (_collision && _collision->is_dynamic_mode()) {
		_collision->update();
	}
	// Stream regions around the clipmap target, one budgeted step per tick.
	if (_streaming_enabled && _streamer && _streamer->is_enabled()) {
		_streamer->update(get_clipmap_target_position());
	}
	_update_vt_service();
	// VT Setting supplies one production budget for both addressing views.
	int vt_remaining = _vt_debug_direct_material ? 4 : _vt_pages_per_update;
	const bool svt_baking = !_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty();
	const auto demand_pool = !_vt_debug_direct_material && _surface_vt ? _surface_vt->get_page_pool() : nullptr;
	if (demand_pool) { demand_pool->begin_demand(); }
	if (_surface_vt_enabled) {
		vt_remaining -= update_surface_vt(_surface_svt_enabled ? MAX(1, vt_remaining / 2) : vt_remaining);
	}
	// Refresh the far field: a world-space page grid that spans regions.
	if (_surface_svt_enabled && vt_remaining > 0) {
		vt_remaining -= update_surface_svt(vt_remaining);
	}
	if (svt_baking) {
		_surface_svt->set_allocation_budget(MAX(0, vt_remaining));
		_process_svt_bake(MAX(0, vt_remaining));
	}
	if (demand_pool) { demand_pool->end_demand(); }
}

/**
 * If running in the editor, grab the first editor viewport camera.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Terrain3D::_grab_camera() {
	if (IS_EDITOR) {
		_camera.set_target(EditorInterface::get_singleton()->get_editor_viewport_3d(0)->get_camera_3d());
		LOG(DEBUG, "Grabbing the first editor viewport camera: ", _camera.get_target());
	} else {
		_camera.set_target(get_viewport()->get_camera_3d());
		LOG(DEBUG, "Grabbing the in-game viewport camera: ", _camera.get_target());
	}
	if (!_camera.is_valid() && !_clipmap_target.is_valid()) {
		set_physics_process(false); // No target to follow, disable snapping until one set
		LOG(ERROR, "Cannot find clipmap target or active camera. LODs won't be updated. Set manually with set_clipmap_target() or set_camera()");
	}
}

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
	_terrain_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing, _material->get_material_rid(), _render_layers);
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

void Terrain3D::set_streaming_enabled(const bool p_enabled) {
	_streaming_enabled = p_enabled;
	if (_streamer) {
		_streamer->set_enabled(p_enabled);
	}
	LOG(INFO, "Region streaming ", p_enabled ? "enabled" : "disabled");
}

///////////////////////////
// Surface virtual texture
///////////////////////////

void Terrain3D::_setup_surface_vt() {
	if (_surface_vt || !_data) {
		return;
	}
	LOG(DEBUG, "Creating surface virtual texture");
	_surface_vt = memnew(Terrain3DVirtualTexture);
	_surface_vt->set_page_size(_surface_vt_page_size);
	_surface_vt->set_page_border(_surface_vt_page_border);
	_surface_vt->set_page_count(_surface_vt_page_count);
	// One page per axis per sector is legal (a 1x1 virtual image), which is what a
	// region whose surface map is already page-sized wants.
	_surface_vt->set_minimal_block(1);
	_surface_vt->set_indirection_size(MAX(64, _surface_vt_page_count * 4));
	_surface_vt->set_format(Image::Format(39));
	_surface_vt->initialize();
}

void Terrain3D::_destroy_surface_vt() {
	LOG(INFO, "Destroying surface virtual texture");
	memdelete_safely(_surface_vt);
	_surface_vt_enabled = false;
}

void Terrain3D::_setup_surface_svt() {
	if (_surface_svt || !_data) {
		return;
	}
	LOG(DEBUG, "Creating far-field surface virtual texture");
	_surface_svt = memnew(Terrain3DVirtualTexture);
	_surface_svt->set_world_space(true);
	_surface_svt->set_page_size(_surface_svt_page_size);
	_surface_svt->set_page_border(_surface_svt_page_border);
	_surface_svt->set_page_count(_surface_svt_page_count);
	// A world grid needs no allocator, so the indirection is sized directly: enough
	// pages to hold the reach, with headroom for the LRU.
	_surface_svt->set_indirection_size(MAX(64, _surface_svt_page_count * 4));
	_surface_svt->set_format(Image::Format(39));
	if (_surface_svt_max_mip >= 0) {
		_surface_svt->set_world_max_mip(_surface_svt_max_mip);
	}
	_surface_svt->initialize();
}

void Terrain3D::_destroy_surface_svt() {
	LOG(INFO, "Destroying far-field surface virtual texture");
	memdelete_safely(_surface_svt);
	_surface_svt_enabled = false;
}

void Terrain3D::set_surface_svt_enabled(const bool p_enabled) {
	_surface_svt_enabled = p_enabled;
	LOG(INFO, "Far-field surface virtual texture ", p_enabled ? "enabled" : "disabled");
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::set_surface_svt_page_world(const real_t p_size) {
	_surface_svt_page_world = CLAMP(p_size, 1.f, 65536.f);
	if (!_vt_debug_direct_material) {
		_reset_vt_configuration();
		return;
	}
	if (_surface_svt) {
		// Page contents are world aligned, so a different page size invalidates every
		// page; a fresh atlas is cheaper than tracking that.
		_surface_svt->clear();
		_surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_size(const int p_size) {
	if (!_vt_debug_direct_material) { set_vt_page_size(p_size); _surface_vt_page_size = _surface_svt_page_size = _vt_page_size; return; }
	_surface_svt_page_size = CLAMP(p_size, 1, 4096);
	if (_surface_svt) {
		_surface_svt->set_page_size(_surface_svt_page_size);
		_surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_border(const int p_border) {
	if (!_vt_debug_direct_material) { set_vt_page_border(p_border); _surface_vt_page_border = _surface_svt_page_border = _vt_page_border; return; }
	_surface_svt_page_border = CLAMP(p_border, 0, 64);
	if (_surface_svt) {
		_surface_svt->set_page_border(_surface_svt_page_border);
		_surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_count(const int p_count) {
	if (!_vt_debug_direct_material) { set_vt_page_count(p_count); _surface_vt_page_count = _surface_svt_page_count = _vt_page_count; return; }
	_surface_svt_page_count = CLAMP(p_count, 1, 1024);
	if (_surface_svt) {
		_surface_svt->set_page_count(_surface_svt_page_count);
		_surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_max_mip(const int p_mip) {
	_surface_svt_max_mip = p_mip;
	if (!_vt_debug_direct_material) {
		if (_surface_svt) { _surface_svt->set_world_max_mip(p_mip); }
		_reset_vt_configuration();
		return;
	}
	if (_surface_svt) {
		_surface_svt->set_world_max_mip(p_mip);
		_surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_distance(const real_t p_distance) {
	_surface_svt_distance = MAX(0.f, p_distance);
}

void Terrain3D::set_surface_svt_root_mips(const int p_mips) {
	int mips = CLAMP(p_mips, 0, 16);
	if (_surface_svt_root_mips == mips) { return; }
	_surface_svt_root_mips = mips;
	if (!_vt_debug_direct_material) { _reset_vt_configuration(); }
}

// Explicit far-field level bands. Entry m is the largest camera distance (metres) at
// which world mip m is sampled; the last entry is the furthest distance the far field
// keeps detail for, and everything beyond it uses that last level (the protected roots
// still serve as the coarser fallback). No entry is ever required: an empty table keeps
// the automatic page-size rule, so this is purely additive.
void Terrain3D::set_surface_svt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array distances;
	distances.resize(p_distances.size());
	for (int i = 0; i < int(p_distances.size()); i++) {
		// Strictly increasing with at least a metre per band. A table that is not
		// monotonic has no meaning (level m would never be selected), and a zero-width
		// band would make the level ambiguous.
		const real_t previous = i > 0 ? distances[i - 1] : 0.f;
		distances[i] = MAX(real_t(p_distances[i]), previous + 1.f);
	}
	if (_surface_svt_mip_distances == distances) { return; }
	_surface_svt_mip_distances = distances;
	// Pages are world aligned, so a page produced for a level stays valid whatever the
	// table says; only the level the shader samples changes. That is a uniform update,
	// not a rebake, so editing the table never throws away produced pages.
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::UNIFORMS_ONLY);
	}
}

void Terrain3D::set_surface_array_enabled(const bool p_enabled) {
	_surface_array_enabled = p_enabled;
	LOG(INFO, "Surface region texture array ", p_enabled ? "enabled" : "disabled");
	if (!p_enabled && !_surface_vt_enabled && !_surface_svt_enabled) {
		LOG(WARN, "Both surface virtual textures are off, so the region texture array keeps "
				  "carrying the surface channel until one of them is enabled.");
	}
	if (_data) {
		// Re-upload (or blank) every surface layer so the change takes effect now.
		_data->update_maps(TYPE_MAX, true, false);
	}
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

// Both virtual textures cache a region's surface, so an edit has to drop the pages that
// carry it. Without this, an array-free configuration would keep rendering the material
// the page was produced with until the LRU happened to evict it.
void Terrain3D::invalidate_surface_pages(const Vector2i &p_region_loc) {
	_invalidate_vt_region(p_region_loc);
	const real_t vertex_spacing = MAX(0.0001f, _vertex_spacing);
	const real_t region_world = real_t(_region_size) * vertex_spacing;
	// Near field: the sector is the region, so every page of every level is stale.
	if (_surface_vt && _surface_vt->is_initialized() && _surface_vt->has_sector(p_region_loc)) {
		const int block = _surface_vt->get_sector_block_size(p_region_loc);
		const int max_mip = block > 0 ? TerrainVT::log2_power_of_two(block) : 0;
		for (int mip = 0; mip <= max_mip; mip++) {
			const int pages = MAX(1, block >> mip);
			for (int py = 0; py < pages; py++) {
				for (int px = 0; px < pages; px++) {
					_surface_vt->release_page(p_region_loc, mip, px, py);
				}
			}
		}
	}
	// Far field: every page of every level that overlaps the region, plus one page of
	// margin because a page's border texels are filled from its neighbours.
	if (_surface_svt && _surface_svt->is_initialized()) {
		const real_t page_world = MAX(1.f, _surface_svt_page_world);
		const real_t x0 = real_t(p_region_loc.x) * region_world;
		const real_t z0 = real_t(p_region_loc.y) * region_world;
		const int max_mip = _surface_svt->get_world_max_mip();
		for (int mip = 0; mip <= max_mip; mip++) {
			const real_t mip_world = page_world * real_t(1 << mip);
			const int px0 = int(Math::floor(x0 / mip_world)) - 1;
			const int px1 = int(Math::floor((x0 + region_world) / mip_world)) + 1;
			const int pz0 = int(Math::floor(z0 / mip_world)) - 1;
			const int pz1 = int(Math::floor((z0 + region_world) / mip_world)) + 1;
			for (int pz = pz0; pz <= pz1; pz++) {
				for (int px = px0; px <= px1; px++) {
					// release_world_page takes a mip 0 page coordinate, so shift the
					// level's page back up; any mip 0 page inside it maps to the same
					// indirection texel.
					_surface_svt->release_world_page(px << mip, pz << mip, mip);
				}
			}
		}
	}
}

// The far field's one distance -> level rule. Every consumer resolves a level through
// this function: the demand pass (which level to produce), the legacy grid scan and the
// shader uniform (which level to sample). An explicit table states the bands directly;
// without one, a mip m page covers `page_world * 2^m` metres, so level m is the right
// choice out to twice that distance and the bands follow the page size automatically.
// `p_max_mip` -1 means the level the far field currently publishes; the demand pass
// passes the indirection's absolute limit while it plans a frame, so a plan never depends
// on the level cap it is about to change.
int Terrain3D::get_surface_svt_mip_for_distance(const real_t p_distance, const int p_max_mip) const {
	const int max_mip = p_max_mip >= 0
			? p_max_mip
			: (_surface_svt ? MAX(0, _surface_svt->get_world_max_mip()) : MAX(0, _surface_svt_max_mip));
	if (_surface_svt_mip_distances.is_empty()) {
		int mip = 0;
		real_t threshold = MAX(1.f, _surface_svt_page_world * 2.f);
		while (mip < max_mip && p_distance > threshold) {
			threshold *= 2.f;
			mip++;
		}
		return mip;
	}
	const int last = int(_surface_svt_mip_distances.size()) - 1;
	int mip = 0;
	while (mip < last && p_distance > _surface_svt_mip_distances[mip]) {
		mip++;
	}
	return MIN(mip, max_mip);
}

// Furthest distance an explicit table still serves with a produced page; 0 means the
// automatic rule, which coarsens without a limit of its own.
real_t Terrain3D::get_surface_svt_mip_reach() const {
	if (_surface_svt_mip_distances.is_empty()) {
		return 0.f;
	}
	const int max_mip = _surface_svt ? MAX(0, _surface_svt->get_world_max_mip()) : MAX(0, _surface_svt_max_mip);
	return _surface_svt_mip_distances[MIN(int(_surface_svt_mip_distances.size()) - 1, max_mip)];
}

// One far-field demand pass. Pages are world aligned, so the set is a plain grid walk
// around the clipmap target; the mip comes from the page's distance, and only the pages
// this pass actually allocated are produced.
int Terrain3D::update_surface_svt(int p_max_pages) {
	if (!_vt_shared_ready || _vt_materials_dirty) { _update_vt_service(); }
	if (!_surface_svt || !_data) {
		return 0;
	}
	if (!_surface_svt->is_initialized()) {
		_surface_svt->initialize();
		if (!_surface_svt->is_initialized()) {
			return 0;
		}
	}
	_surface_svt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	if (!_vt_debug_direct_material) { return _update_visible_svt(p_max_pages); }
	const bool legacy_full_grid = _vt_debug_direct_material;
	const real_t page_world = MAX(1.f, _surface_svt_page_world);
	const real_t reach = MAX(page_world, _surface_svt_distance);
	const Vector3 target = get_clipmap_target_position();
	// The level rule measures from the camera the shader renders with, so the diagnostic
	// scan has to measure from the same point: otherwise it publishes pages at levels the
	// shader does not start at, and the far field renders from whatever ancestor the walk
	// finds instead of from the page that was produced. Without a camera (CPU
	// diagnostics) the clipmap target stays the reference.
	Camera3D *reference_camera = get_camera();
	const Vector3 reference = (reference_camera && reference_camera->is_inside_tree())
			? reference_camera->get_global_position()
			: target;
	// Keep the public world-page API's int coordinates in a range where adding the
	// indirection half and multiplying by a mip scale cannot overflow. The old nested
	// loops converted an arbitrary distance directly to int, so a large editor distance
	// could wrap before the allocator had a chance to enforce its page budget.
	const int64_t coordinate_limit = int64_t(INT32_MAX) / 2;
	auto clamp_page_coordinate = [coordinate_limit](const double p_value) -> int64_t {
		if (p_value <= -double(coordinate_limit)) {
			return -coordinate_limit;
		}
		if (p_value >= double(coordinate_limit)) {
			return coordinate_limit;
		}
		return int64_t(p_value);
	};
	// Match the arithmetic right shift used by world_page_to_virtual(), including for
	// negative world pages. This is used only for the auto root candidates; detail pages
	// still go through Terrain3DVirtualTexture's canonical conversion.
	auto floor_shift = [](const int64_t p_value, const int p_shift) -> int64_t {
		if (p_shift <= 0) {
			return p_value;
		}
		const int64_t scale = int64_t(1) << p_shift;
		if (p_value >= 0) {
			return p_value >> p_shift;
		}
		return -(((-p_value) + scale - 1) >> p_shift);
	};

	int64_t first_x = clamp_page_coordinate(Math::floor((double(reference.x) - double(reach)) / double(page_world)));
	int64_t last_x = clamp_page_coordinate(Math::floor((double(reference.x) + double(reach)) / double(page_world)));
	int64_t first_y = clamp_page_coordinate(Math::floor((double(reference.z) - double(reach)) / double(page_world)));
	int64_t last_y = clamp_page_coordinate(Math::floor((double(reference.z) + double(reach)) / double(page_world)));

	// Automatic mode only needs roots and detail pages for regions that are actually
	// loaded. Besides avoiding empty-world work, this keeps a large distance setting
	// from turning into an unbounded page-grid walk. The direct-material mode retains
	// the historical whole-grid root semantics used by the sparse CPU tests.
	TypedArray<Vector2i> region_locations = _data->get_region_locations();
	const real_t region_world = MAX(0.0001f, real_t(_region_size) * _vertex_spacing);
	bool has_loaded_bounds = false;
	int64_t loaded_first_x = coordinate_limit;
	int64_t loaded_last_x = -coordinate_limit;
	int64_t loaded_first_y = coordinate_limit;
	int64_t loaded_last_y = -coordinate_limit;
	if (!legacy_full_grid) {
		for (int i = 0; i < region_locations.size(); i++) {
			const Vector2i location = region_locations[i];
			const double min_world_x = double(location.x) * double(region_world);
			const double min_world_y = double(location.y) * double(region_world);
			const double max_world_x = (double(location.x) + 1.0) * double(region_world);
			const double max_world_y = (double(location.y) + 1.0) * double(region_world);
			const int64_t region_first_x = clamp_page_coordinate(Math::floor(min_world_x / double(page_world)));
			const int64_t region_last_x = clamp_page_coordinate(Math::ceil(max_world_x / double(page_world)) - 1.0);
			const int64_t region_first_y = clamp_page_coordinate(Math::floor(min_world_y / double(page_world)));
			const int64_t region_last_y = clamp_page_coordinate(Math::ceil(max_world_y / double(page_world)) - 1.0);
			if (region_first_x > region_last_x || region_first_y > region_last_y) {
				continue;
			}
			has_loaded_bounds = true;
			loaded_first_x = MIN(loaded_first_x, region_first_x);
			loaded_last_x = MAX(loaded_last_x, region_last_x);
			loaded_first_y = MIN(loaded_first_y, region_first_y);
			loaded_last_y = MAX(loaded_last_y, region_last_y);
		}
		if (has_loaded_bounds) {
			first_x = loaded_first_x;
			last_x = loaded_last_x;
			first_y = loaded_first_y;
			last_y = loaded_last_y;
		} else {
			first_x = 1;
			last_x = 0;
			first_y = 1;
			last_y = 0;
		}
	}

	// A target/configuration key invalidates both cursors. Include the effective detail
	// bounds and loaded-region count so adding/removing streamed regions starts a fresh
	// pass without storing another lifetime-sensitive observer in Terrain3D.
	auto mix_hash = [](const uint32_t p_hash, const uint32_t p_value) -> uint32_t {
		return p_hash ^ (p_value + 0x9e3779b9u + (p_hash << 6) + (p_hash >> 2));
	};
	auto mix_i64 = [&mix_hash](uint32_t p_hash, const int64_t p_value) -> uint32_t {
		const uint64_t bits = uint64_t(p_value);
		p_hash = mix_hash(p_hash, uint32_t(bits));
		return mix_hash(p_hash, uint32_t(bits >> 32));
	};
	uint32_t scan_hash = 2166136261u;
	scan_hash = mix_i64(scan_hash, _surface_svt->get_indirection_size());
	scan_hash = mix_i64(scan_hash, _surface_svt->get_world_max_mip());
	scan_hash = mix_i64(scan_hash, _surface_svt_root_mips);
	scan_hash = mix_i64(scan_hash, _surface_svt->get_page_count());
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(page_world))));
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(reach))));
	scan_hash = mix_i64(scan_hash, region_locations.size());
	scan_hash = mix_i64(scan_hash, first_x);
	scan_hash = mix_i64(scan_hash, last_x);
	scan_hash = mix_i64(scan_hash, first_y);
	scan_hash = mix_i64(scan_hash, last_y);
	scan_hash = mix_i64(scan_hash, legacy_full_grid ? 1 : 0);
	const Vector3i scan_key(int(clamp_page_coordinate(Math::floor(double(target.x) / double(page_world)))),
			int(clamp_page_coordinate(Math::floor(double(target.z) / double(page_world)))),
			int(scan_hash & 0x7fffffffu));
	if (_surface_svt_scan_key != scan_key) {
		_surface_svt_scan_key = scan_key;
		_surface_svt_root_cursor = 0;
		_surface_svt_detail_cursor = 0;
	}

	int produced = 0;
	int allocations = 0;
	const int physical_page_count = MAX(1, _surface_svt->get_page_count());
	const Dictionary residency = _surface_svt->get_stats();
	int protected_count = MAX(0, int(residency.get("protected_count", 0)));
	const int protected_limit = physical_page_count / 2;
	int root_protection_budget = MAX(0, protected_limit - protected_count);

	const int root_max_mip = MAX(0, _surface_svt->get_world_max_mip());
	const int root_mip_count = CLAMP(_surface_svt_root_mips, 0, root_max_mip + 1);
	const int first_root = root_mip_count > 0 ? root_max_mip - root_mip_count + 1 : root_max_mip + 1;
	int64_t root_total = 0;
	if (root_mip_count > 0) {
		if (legacy_full_grid) {
			for (int mip = root_max_mip; mip >= first_root; mip--) {
				const int64_t level_size = MAX(1, _surface_svt->get_indirection_size() >> mip);
				root_total += level_size * level_size;
			}
		} else {
			root_total = int64_t(region_locations.size()) * root_mip_count;
		}
	}
	// A finite CPU budget is separate from the allocation budget. It bounds an extreme
	// root_mips=16/full-grid or distance=huge frame even when most candidates are hits.
	const int root_scan_budget = legacy_full_grid ? MAX(256, MIN(4096, physical_page_count * 4)) :
			MAX(64, MIN(1024, physical_page_count * 2));
	const int detail_scan_budget = legacy_full_grid ? MAX(256, MIN(4096, physical_page_count * 4)) :
			MAX(64, MIN(1024, physical_page_count * 2));

	// A completed cursor is normally left at the end while the pool is full. If an
	// invalidation removes a protected root, the reduced protected count opens budget
	// again; restart then so the missing root can be found without scanning every frame
	// while the cache is settled. Small legacy root sets retain their historical repeat
	// walk, which also lets an invalidated page be repaired on the next update.
	if (root_total > 0 && _surface_svt_root_cursor >= root_total && root_protection_budget > 0) {
		_surface_svt_root_cursor = 0;
	}

	int root_scanned = 0;
	while (_surface_svt_root_cursor < root_total && root_scanned < root_scan_budget &&
			root_protection_budget > 0 && (p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t root_index = _surface_svt_root_cursor++;
		root_scanned++;
		int mip = first_root;
		int virtual_x = 0;
		int virtual_y = 0;
		if (legacy_full_grid) {
			int64_t level_index = root_index;
			for (mip = root_max_mip; mip >= first_root; mip--) {
				const int level_size = MAX(1, _surface_svt->get_indirection_size() >> mip);
				const int64_t level_cells = int64_t(level_size) * level_size;
				if (level_index < level_cells) {
					virtual_x = int(level_index % level_size);
					virtual_y = int(level_index / level_size);
					break;
				}
				level_index -= level_cells;
			}
		} else {
			const int64_t region_index = root_index / root_mip_count;
			const int root_level = int(root_index % root_mip_count);
			mip = root_max_mip - root_level;
			if (region_index < 0 || region_index >= region_locations.size()) {
				continue;
			}
			const Vector2i location = region_locations[int(region_index)];
			const int64_t base_x = clamp_page_coordinate(Math::floor((double(location.x) + 0.5) * double(region_world) / double(page_world)));
			const int64_t base_y = clamp_page_coordinate(Math::floor((double(location.y) + 0.5) * double(region_world) / double(page_world)));
			virtual_x = int(floor_shift(base_x + (int64_t(_surface_svt->get_indirection_size()) >> 1), mip));
			virtual_y = int(floor_shift(base_y + (int64_t(_surface_svt->get_indirection_size()) >> 1), mip));
		}
		const int level_size = MAX(1, _surface_svt->get_indirection_size() >> mip);
		if (virtual_x < 0 || virtual_y < 0 || virtual_x >= level_size || virtual_y >= level_size) {
			continue;
		}
		bool was_miss = false;
		const int slot = _surface_svt->request_virtual_page_internal(virtual_x, virtual_y, mip, &was_miss);
		if (slot < 0) {
			// A full protected pool cannot make progress in this pass. Leave the cursor
			// at the next candidate so a later unprotection can retry without rescanning
			// the whole level.
			break;
		}
		if (!was_miss) {
			if (!_surface_svt->is_page_protected(slot) && root_protection_budget > 0) {
				_surface_svt->protect_page(slot, true);
				protected_count++;
				root_protection_budget--;
			}
			continue;
		}
		allocations++;
		// A newly acquired physical slot may have an output from an evicted AVT/SVT
		// page. Invalidate that material result before the new page can be sampled.
		_invalidate_vt_slot(slot);
		const int half_at_mip = (_surface_svt->get_indirection_size() >> 1) >> mip;
		const Vector2i address((virtual_x - half_at_mip) << mip, (virtual_y - half_at_mip) << mip);
		Ref<Image> page;
		if (_data->produce_sparse_surface_page(address.x, address.y, mip, page_world,
				_surface_svt->get_page_size(), _surface_svt->get_page_border(), page) < 0 ||
				!_surface_svt->write_page(slot, page)) {
			_surface_svt->release_world_page(address.x, address.y, mip);
			continue;
		}
		const float span = page_world * float(1 << mip);
		_queue_vt_material_page(slot, page, Rect2(Vector2(address) * page_world, Vector2(span, span)), true, mip, address);
		// A root page is the fallback of last resort. Protecting it leaves at least
		// half of the shared pool available to AVT, detail SVT, and offline baking.
		_surface_svt->protect_page(slot, true);
		protected_count++;
		root_protection_budget--;
		produced++;
	}
	if (root_protection_budget <= 0) {
		// No further root can be made resident under the shared-pool cap. Avoid
		// repeatedly walking a potentially million-cell full-grid root on every tick.
		_surface_svt_root_cursor = root_total;
	}

	int64_t detail_width = 0;
	int64_t detail_height = 0;
	int64_t detail_total = 0;
	if (first_x <= last_x && first_y <= last_y) {
		detail_width = last_x - first_x + 1;
		detail_height = last_y - first_y + 1;
		if (detail_width > 0 && detail_height > 0 && detail_width <= INT64_MAX / detail_height) {
			detail_total = detail_width * detail_height;
		}
	}
	int detail_scanned = 0;
	while (_surface_svt_detail_cursor < detail_total && detail_scanned < detail_scan_budget &&
			(p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t detail_index = _surface_svt_detail_cursor++;
		detail_scanned++;
		const int64_t page_x64 = first_x + detail_index % detail_width;
		const int64_t page_y64 = first_y + detail_index / detail_width;
		if (page_x64 < -coordinate_limit || page_x64 > coordinate_limit ||
				page_y64 < -coordinate_limit || page_y64 > coordinate_limit) {
			continue;
		}
		const int page_x = int(page_x64);
		const int page_y = int(page_y64);
		const real_t center_x = (real_t(page_x) + 0.5f) * page_world;
		const real_t center_z = (real_t(page_y) + 0.5f) * page_world;
		// Same measurement the shader makes for a fragment: the distance from the camera
		// to the page, with the page sampled on the ground plane.
		const real_t distance = Vector3(center_x, 0.f, center_z).distance_to(reference);
		if (legacy_full_grid && distance > reach) {
			continue;
		}
		// Same distance -> level table the shader and the camera-visible pass use. This
		// diagnostic grid measures from the clipmap target rather than the camera, so
		// it stays usable without a rendering camera; production goes through
		// _update_visible_svt(), which measures from the camera the shader reports.
		const int mip = get_surface_svt_mip_for_distance(distance);
		bool was_miss = false;
		const int slot = _surface_svt->request_world_page_internal(page_x, page_y, mip, &was_miss);
		if (slot < 0) {
			break;
		}
		if (!was_miss) {
			continue;
		}
		allocations++;
		_invalidate_vt_slot(slot);
		Ref<Image> page;
		if (_data->produce_sparse_surface_page(page_x, page_y, mip, page_world,
				_surface_svt->get_page_size(), _surface_svt->get_page_border(), page) < 0 ||
				!_surface_svt->write_page(slot, page)) {
			_surface_svt->release_world_page(page_x, page_y, mip);
			continue;
		}
		const float span = page_world * float(1 << mip);
		const Vector2i address((page_x >> mip) << mip, (page_y >> mip) << mip);
		_queue_vt_material_page(slot, page, Rect2(Vector2(address) * page_world, Vector2(span, span)), true, mip, address);
		produced++;
	}
	if (detail_total > 0 && _surface_svt_detail_cursor >= detail_total) {
		_surface_svt_detail_cursor = 0;
	}

	_surface_svt->commit();
	// Both views may share the physical pool. An SVT allocation can evict an AVT
	// owner and dirty its indirection, so publish both tables before the next draw.
	if (_surface_vt && _surface_vt->is_initialized()) {
		_surface_vt->commit();
	}
	_surface_svt->set_allocation_budget(-1);
	return produced;
}

void Terrain3D::set_surface_vt_enabled(const bool p_enabled) {
	_surface_vt_enabled = p_enabled;
	LOG(INFO, "Surface virtual texture ", p_enabled ? "enabled" : "disabled");
	if (_initialized && _material.is_valid()) {
		// The shader's `_surface_vt_enabled` uniform and its block table have to follow
		// the toggle, otherwise the material keeps sampling the atlas after it is off.
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::set_surface_vt_page_count(const int p_count) {
	if (!_vt_debug_direct_material) { set_vt_page_count(p_count); _surface_vt_page_count = _surface_svt_page_count = _vt_page_count; return; }
	_surface_vt_page_count = CLAMP(p_count, 1, 1024);
	if (_surface_vt) {
		_surface_vt->set_page_count(_surface_vt_page_count);
		_surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_page_size(const int p_size) {
	if (!_vt_debug_direct_material) { set_vt_page_size(p_size); _surface_vt_page_size = _surface_svt_page_size = _vt_page_size; return; }
	_surface_vt_page_size = CLAMP(p_size, 1, 4096);
	if (_surface_vt) {
		_surface_vt->set_page_size(_surface_vt_page_size);
		_surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_page_border(const int p_border) {
	if (!_vt_debug_direct_material) { set_vt_page_border(p_border); _surface_vt_page_border = _surface_svt_page_border = _vt_page_border; return; }
	_surface_vt_page_border = CLAMP(p_border, 0, 64);
	if (_surface_vt) {
		_surface_vt->set_page_border(_surface_vt_page_border);
		_surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_pages_per_axis(const int p_pages) {
	// Power of two: the page grid halves per mip.
	int pages = 1;
	while (pages * 2 <= CLAMP(p_pages, 1, 64)) {
		pages *= 2;
	}
	_surface_vt_pages_per_axis = pages;
}

void Terrain3D::set_surface_vt_distance(const real_t p_distance) {
	_surface_vt_distance = MAX(0.f, p_distance);
}

static bool terrain_region_in_frustum(Terrain3DData *p_data, const Vector2i &p_location,
		float p_region_world, const TypedArray<Plane> &p_planes) {
	Ref<Terrain3DRegion> region = p_data->get_region(p_location);
	if (region.is_null() || region->is_deleted()) { return false; }
	const Vector2 heights = region->get_height_range();
	const Vector3 lo(p_location.x * p_region_world, heights.x - 1.f, p_location.y * p_region_world);
	const Vector3 hi(lo.x + p_region_world, heights.y + 1.f, lo.z + p_region_world);
	for (int i = 0; i < p_planes.size(); ++i) {
		const Plane plane = p_planes[i];
		const Vector3 closest(plane.normal.x > 0.f ? lo.x : hi.x,
				plane.normal.y > 0.f ? lo.y : hi.y, plane.normal.z > 0.f ? lo.z : hi.z);
		if (plane.is_point_over(closest)) { return false; }
	}
	return true;
}

Rect2i Terrain3D::get_surface_vt_region_rect() const {
	// Inspector property reads can occur while the edited scene is being removed.
	if (!is_inside_tree() || !_is_inside_world) { return Rect2i(); }
	const float region_world = MAX(0.0001f, float(_region_size) * _vertex_spacing);
	Vector3 target = get_clipmap_target_position();
	Node3D *anchor = _clipmap_target.is_valid() ? cast_to<Node3D>(_clipmap_target.ptr()) : get_camera();
	Camera3D *camera = get_camera();
	if (_surface_vt_selection_mode == 0 && camera && _data) {
		const TypedArray<Plane> planes = camera->get_frustum();
		const TerrainVT::VisibleView view(camera);
		float best_score = 1e30f;
		float previous_score = 1e30f;
		Vector2i best;
		for (const Vector2i &location : _data->get_region_locations()) {
			if (!terrain_region_in_frustum(_data, location, region_world, planes)) { continue; }
			TerrainVT::VisiblePatch visible;
			if (!view.sample(Rect2(Vector2(location) * region_world, Vector2(region_world, region_world)),
					_data->get_region(location)->get_height_range(), visible)) { continue; }
			const float score = visible.distance;
			if (score < best_score) { best_score = score; best = location; }
			if (_vt_view_focus_valid && location == _vt_view_focus) { previous_score = score; }
		}
		if (best_score == 1e30f) { _vt_view_focus_valid = false; return Rect2i(); }
		// Small distance hysteresis stabilizes adjoining visible region edges.
		if (_vt_view_focus_valid && previous_score <= best_score * 1.03f + 0.01f) { best = _vt_view_focus; }
		_vt_view_focus = best;
		_vt_view_focus_valid = true;
		target.x = (best.x + 0.5f) * region_world;
		target.z = (best.y + 0.5f) * region_world;
		anchor = camera;
	}
	if (anchor && !Math::is_zero_approx(_surface_vt_forward_regions)) {
		Vector3 forward = -anchor->get_global_basis().get_column(2);
		forward.y = 0.f;
		if (forward.length_squared() > 0.0001f) { target += forward.normalized() * (_surface_vt_forward_regions * region_world); }
	}
	const Vector2i center(int(Math::floor(target.x / region_world)), int(Math::floor(target.z / region_world)));
	return Rect2i(center + _surface_vt_region_offset - _surface_vt_region_grid / 2, _surface_vt_region_grid);
}

void Terrain3D::set_surface_vt_force_mip(const bool p_enabled, const int p_mip) {
	_surface_vt_force_mip = p_enabled;
	_surface_vt_mip = CLAMP(p_mip, 0, 16);
}

void Terrain3D::set_surface_vt_feedback_enabled(const bool p_enabled) {
	_surface_vt_feedback_enabled = p_enabled;
	LOG(INFO, "Surface virtual texture GPU feedback ", p_enabled ? "enabled" : "disabled");
}

void Terrain3D::set_surface_vt_feedback_interval(const int p_updates) {
	_surface_vt_feedback_interval = CLAMP(p_updates, 1, 120);
}

void Terrain3D::set_surface_vt_feedback_grid_chunks(const int p_chunks) {
	_surface_vt_feedback_grid_chunks = CLAMP(p_chunks, 1, 64);
	if (_surface_vt_feedback) {
		// The grid size is baked into the texture and the pipeline.
		memdelete_safely(_surface_vt_feedback);
	}
}

void Terrain3D::set_surface_vt_feedback_min_extent(const real_t p_extent) {
	_surface_vt_feedback_min_extent = CLAMP(p_extent, 0.f, 1024.f);
}

// Runs the demand pass and makes its result available. The readback of a local device is
// delivered by sync(), so this is a stall; the interval exists to amortise it, and the
// demand pass keeps using the last result in between.
bool Terrain3D::_update_surface_vt_feedback(const Vector3 &p_target) {
	if (!_surface_vt_feedback_enabled) {
		return false;
	}
	Camera3D *camera = get_camera();
	if (!camera) {
		return false;
	}
	if (_surface_vt_feedback_tick++ % _surface_vt_feedback_interval != 0) {
		return _surface_vt_feedback != nullptr && _surface_vt_feedback->has_result();
	}
	const int pages_per_axis = _surface_vt_pages_per_axis;
	const int grid = _surface_vt_feedback_grid_chunks * pages_per_axis;
	if (!_surface_vt_feedback) {
		_surface_vt_feedback = memnew(Terrain3DVTFeedback);
		if (_surface_vt_feedback->initialize(grid, grid) != OK) {
			memdelete_safely(_surface_vt_feedback);
			_surface_vt_feedback_enabled = false;
			return false;
		}
	} else if (_surface_vt_feedback->get_grid_width() != grid) {
		_surface_vt_feedback->initialize(grid, grid);
	}
	if (!_surface_vt_feedback->is_initialized()) {
		return false;
	}

	// The grid is a window of chunks centred on the camera's chunk.
	const Vector2i camera_chunk = _data->get_region_location(p_target);
	_surface_vt_feedback_origin = camera_chunk - Vector2i(_surface_vt_feedback_grid_chunks / 2,
													_surface_vt_feedback_grid_chunks / 2);
	const Projection view_projection = camera->get_camera_projection() *
			Projection(camera->get_global_transform().affine_inverse());
	const real_t page_world_size = real_t(_region_size) * _vertex_spacing / real_t(pages_per_axis);
	Viewport *viewport = camera->get_viewport();
	const Vector2i viewport_size = viewport ? viewport->get_visible_rect().size : Vector2i(1920, 1080);

	if (_surface_vt_feedback->dispatch(view_projection, pages_per_axis, real_t(_region_size),
				page_world_size, _surface_vt->get_page_size(),
				TerrainVT::log2_power_of_two(pages_per_axis), _surface_vt_feedback_origin,
				viewport_size, _surface_vt_feedback_min_extent) != OK) {
		return false;
	}
	_surface_vt_feedback->request_readback();
	// dispatch + request + sync is the only order that works: the copy is a draw graph
	// node, so the submit has to come after the request.
	_surface_vt_feedback->sync();
	return _surface_vt_feedback->has_result();
}

int Terrain3D::_surface_vt_mip_for_page(const Vector2i &p_region_loc, const int p_page_x0,
		const int p_page_y0, const real_t p_distance, const real_t p_page_world_size,
		const int p_max_local_mip) {
	if (_surface_vt_force_mip) {
		return MIN(_surface_vt_mip, p_max_local_mip);
	}
	if (!_vt_debug_direct_material) { return 0; }
	if (_surface_vt_feedback_enabled && _surface_vt_feedback &&
			_surface_vt_feedback->has_result()) {
		const int mip = _surface_vt_feedback->get_mip_for_page(p_region_loc, _surface_vt_pages_per_axis,
				p_page_x0, p_page_y0, _surface_vt_feedback_origin);
		// -1 means the pass culled this page: off screen, behind the camera or too
		// small to be worth a page. That is the point of using it over the distance
		// rule, so it is honoured rather than treated as a failure.
		return mip;
	}
	// Distance fallback. A mip 0 page covers region_size / pages_per_axis metres, and
	// each doubling of that threshold steps one mip.
	int mip = 0;
	const real_t threshold = MAX(1.f, p_page_world_size * 2.f);
	while (mip < p_max_local_mip && p_distance > threshold * real_t(1 << mip)) {
		mip++;
	}
	return mip;
}

// One demand pass. The page contract is the same whichever rule picks the mips:
// request -> produce -> write -> commit.
int Terrain3D::update_surface_vt(int p_max_pages) {
	if (!_vt_shared_ready || _vt_materials_dirty) { _update_vt_service(); }
	if (!_surface_vt || !_data) {
		return 0;
	}
	if (!_surface_vt->is_initialized()) {
		_surface_vt->initialize();
		if (!_surface_vt->is_initialized()) {
			return 0;
		}
	}
	int max_pages_per_axis = _surface_vt_pages_per_axis;
	_surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	// Rebuild the layer -> block origin table the shader indexes. Sectors are never
	// unregistered (the virtual atlas is large and the entries are only read for
	// resident chunks), so this is a fresh map of the current resident set.
	const int capacity = _data->get_map_capacity();
	if (capacity > 0 && _surface_vt_blocks.size() != capacity) {
		_surface_vt_blocks.resize(capacity);
		_surface_vt_blocks_dirty = true;
	}
	PackedVector2Array next_blocks;
	next_blocks.resize(_surface_vt_blocks.size());
	next_blocks.fill(Vector2(-1.f, -1.f));
	PackedFloat32Array next_sizes;
	next_sizes.resize(_surface_vt_blocks.size());
	next_sizes.fill(1.f);
	const Vector3 target = get_clipmap_target_position();
	if (_vt_debug_direct_material) { _update_surface_vt_feedback(target); }

	int requested = 0;
	int produced = 0;
	const real_t reach_squared = _surface_vt_distance * _surface_vt_distance;
	const Rect2i avt_regions = get_surface_vt_region_rect();
	Dictionary eligible_regions;
	if (!_vt_debug_direct_material) {
		Camera3D *camera = get_camera();
		const bool view_selection = _surface_vt_selection_mode == 0 && camera;
		const TypedArray<Plane> planes = view_selection ? camera->get_frustum() : TypedArray<Plane>();
		for (const Vector2i &location : _data->get_region_locations()) {
			if (avt_regions.has_point(location) && (!view_selection ||
					terrain_region_in_frustum(_data, location, _region_size * _vertex_spacing, planes))) {
				eligible_regions[location] = true;
			}
		}
	}
	Dictionary adaptive_sizes;
	if (_vt_adaptive_enabled && !_vt_debug_direct_material && !_surface_vt_force_mip && get_camera()) {
		TerrainVT::VisibleView view(get_camera());
		struct SectorDemand { Vector2i location; int size; float distance; };
		std::vector<SectorDemand> demands;
		const float world = _region_size * _vertex_spacing;
		const int capacity = _surface_svt_enabled ? MAX(1, _surface_vt->get_page_count() / 2) : _surface_vt->get_page_count();
		auto cost = [](int size) { return (4 * size * size - 1) / 3; };
		int total = 0;
		for (const Variant &key : eligible_regions.keys()) {
			Vector2i location = key;
			TerrainVT::VisiblePatch visible;
			if (!view.sample(Rect2(Vector2(location) * world, Vector2(world, world)), _data->get_region(location)->get_height_range(), visible)) {
				// Explicit Target Grid can include off-screen sectors; retain a base page.
				visible.density = 0.f;
			}
			const float wanted = world * visible.density * _surface_vt_texels_per_pixel / _surface_vt->get_page_size();
			int size = 1;
			while (size < max_pages_per_axis && size < wanted) { size <<= 1; }
			// Separate grow/shrink thresholds avoid toggling at projection boundaries.
			if (_surface_vt->has_sector(location)) {
				int previous = _surface_vt->get_sector_block_size(location);
				if (wanted >= previous * 0.4f && wanted <= previous * 1.1f) { size = MIN(previous, max_pages_per_axis); }
			}
			demands.push_back({ location, size, visible.distance });
			total += cost(size);
		}
		// Reserve the complete mip hierarchy, including coverage while finer pages
		// are produced. Reduce the least visible detail first, never discard sectors.
		while (total > capacity) {
			int reduce = -1;
			for (int i = 0; i < int(demands.size()); ++i) {
				if (demands[i].size > 1 && (reduce < 0 || demands[i].distance > demands[reduce].distance)) { reduce = i; }
			}
			if (reduce < 0) { break; }
			total -= cost(demands[reduce].size);
			demands[reduce].size >>= 1;
			total += cost(demands[reduce].size);
		}
		for (const SectorDemand &demand : demands) { adaptive_sizes[demand.location] = demand.size; }
	}
	if (!_vt_debug_direct_material) {
		// Return virtual address blocks when terrain streams out or leaves AVT
		// coverage; otherwise a long traversal eventually exhausts the atlas.
		for (const Variant &key : _vt_registered_sectors.keys()) {
			Vector2i location = key;
			if (_data->get_region_id(location) < 0 || !eligible_regions.has(location)) {
				_surface_vt->unregister_sector(location);
				_vt_registered_sectors.erase(key);
			}
		}
	}

	for (const Vector2i &region_loc : _data->get_region_locations()) {
		const Vector3 center((real_t(region_loc.x) + 0.5f) * _region_size * _vertex_spacing, 0.f,
				(real_t(region_loc.y) + 0.5f) * _region_size * _vertex_spacing);
		const Vector2 flat(center.x - target.x, center.z - target.z);
		const real_t distance_squared = flat.length_squared();
		if (_vt_debug_direct_material ? distance_squared > reach_squared : !eligible_regions.has(region_loc)) {
			continue;
		}
		int pages_per_axis = adaptive_sizes.get(region_loc, max_pages_per_axis);
		const float region_world = _region_size * _vertex_spacing;
		if (!_surface_vt->has_sector(region_loc)) {
			if (!_surface_vt->register_sector(region_loc, pages_per_axis)) {
				continue;
			}
			_surface_vt_blocks_dirty = true;
		} else if (_surface_vt->get_sector_block_size(region_loc) != pages_per_axis) {
			_surface_vt->resize_sector(region_loc, pages_per_axis);
			// Resizing keeps world footprints while changing their mip addresses.
			// Keep the inspector's records consistent with the remapped page table.
			for (const Variant &key : _vt_page_records.keys()) {
				for (const Dictionary &owner : _surface_vt->get_slot_owner_metadata(int(key))) {
					if (bool(owner["world_space"]) || Vector2i(owner["sector"]) != region_loc) { continue; }
					const int mip = owner["mip"];
					Dictionary record = _vt_page_records[key];
					record["mip"] = mip;
					record["address"] = Vector2i(owner["virtual"]) - Vector2i(
							_surface_vt->get_sector_block_origin_x(region_loc) >> mip,
							_surface_vt->get_sector_block_origin_y(region_loc) >> mip);
				}
			}
		}
		if (!_vt_debug_direct_material) { _vt_registered_sectors[region_loc] = true; }
		pages_per_axis = _surface_vt->get_sector_block_size(region_loc);
		const int max_local_mip = TerrainVT::log2_power_of_two(pages_per_axis);
		const real_t page_world_size = region_world / real_t(pages_per_axis);
		// Publish the block so the shader can resolve this chunk's pages.
		const int slot = _data->get_region_id(region_loc);
		if (slot >= 0 && slot < _surface_vt_blocks.size()) {
			const Vector2 block(real_t(_surface_vt->get_sector_block_origin_x(region_loc)),
					real_t(_surface_vt->get_sector_block_origin_y(region_loc)));
			next_blocks[slot] = block;
			next_sizes[slot] = float(pages_per_axis);
		}
		// Per-page mips: the feedback varies within a sector, which is the whole point
		// of it over a per-sector distance rule. Resolve every mip 0 page first, then
		// collect the pages actually needed at each level.
		std::vector<int> mip0(size_t(pages_per_axis) * pages_per_axis, -1);
		const real_t distance = Math::sqrt(distance_squared);
		for (int page_y0 = 0; page_y0 < pages_per_axis; page_y0++) {
			for (int page_x0 = 0; page_x0 < pages_per_axis; page_x0++) {
				mip0[size_t(page_y0) * pages_per_axis + page_x0] = _surface_vt_mip_for_page(
						region_loc, page_x0, page_y0, distance, page_world_size, max_local_mip);
			}
		}
		std::vector<Vector3i> requests;
		for (int mip = 0; mip <= max_local_mip; mip++) {
			const int at = MAX(1, pages_per_axis >> mip);
			std::vector<uint8_t> need(size_t(at) * at, 0);
			for (int page_y0 = 0; page_y0 < pages_per_axis; page_y0++) {
				for (int page_x0 = 0; page_x0 < pages_per_axis; page_x0++) {
					const int page_mip = mip0[size_t(page_y0) * pages_per_axis + page_x0];
					// Exactly one level per mip 0 page: the shader walks mips fine to
					// coarse, so a page resolved to level L is served by the level L
					// page and needs no ancestor. -1 is culled, which leaves the
					// indirection entry alone and lets the array path serve the texel.
					if (page_mip != mip) {
						continue;
					}
					need[size_t(page_y0 >> mip) * at + (page_x0 >> mip)] = 1;
				}
			}
			for (int page_y = 0; page_y < at; page_y++) {
				for (int page_x = 0; page_x < at; page_x++) {
					if (need[size_t(page_y) * at + page_x]) {
						requests.push_back(Vector3i(page_x, page_y, mip));
					}
				}
			}
		}
		if (!_vt_debug_direct_material && _vt_adaptive_enabled && !_surface_vt_force_mip) {
			// Keep an AVT mip chain resident. Growth remaps existing pages to their
			// new mip addresses; the shader keeps sampling them during refinement.
			requests.clear();
			for (int mip = max_local_mip; mip >= 0; --mip) {
				int at = MAX(1, pages_per_axis >> mip);
				for (int y = 0; y < at; ++y) {
					for (int x = 0; x < at; ++x) { requests.push_back(Vector3i(x, y, mip)); }
				}
			}
		}
		// Only produce the pages this pass actually allocated. A hit already holds
		// content, and re-producing it every tick would swamp the atlas uploads.
		std::vector<Vector3i> missing;
		for (const Vector3i &request : requests) {
			bool was_miss = false;
			const int slot = _surface_vt->request_page_internal(region_loc, request.z, request.x,
					request.y, &was_miss);
			requested++;
			if (slot >= 0 && was_miss) {
				_invalidate_vt_slot(slot);
				missing.push_back(request);
			}
		}
		if (missing.empty()) {
			continue;
		}
		std::vector<Ref<Image>> pages;
		if (_data->produce_surface_page_set(region_loc, pages_per_axis, _surface_vt->get_page_size(),
					_surface_vt->get_page_border(), missing, pages) < 0) {
			for (const Vector3i &request : missing) { _surface_vt->release_page(region_loc, request.z, request.x, request.y); }
			continue;
		}
		for (int i = 0; i < int(missing.size()) && i < int(pages.size()); i++) {
			const int slot = _surface_vt->lookup_page(region_loc, missing[i].z, missing[i].x, missing[i].y);
			if (slot >= 0 && _surface_vt->write_page(slot, pages[i])) {
				float span = region_world / float(MAX(1, pages_per_axis >> missing[i].z));
				Rect2 rect(Vector2(region_loc) * region_world + Vector2(missing[i].x, missing[i].y) * span, Vector2(span, span));
				_queue_vt_material_page(slot, pages[i], rect, false, missing[i].z, Vector2i(missing[i].x, missing[i].y));
				produced++;
			} else {
				_surface_vt->release_page(region_loc, missing[i].z, missing[i].x, missing[i].y);
			}
		}
	}
	if (_surface_vt_blocks != next_blocks) {
		_surface_vt_blocks = next_blocks;
		_surface_vt_blocks_dirty = true;
	}
	if (_surface_vt_block_sizes != next_sizes) {
		_surface_vt_block_sizes = next_sizes;
		_surface_vt_blocks_dirty = true;
	}
	// Publish block origins/sizes in the same update as the remapped page table.
	// Direct callers must not expose a new table with yesterday's shader block.
	if (_surface_vt_blocks_dirty && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_surface_vt_blocks_dirty = false;
	}
	_surface_vt->commit();
	if (_surface_svt && _surface_svt->is_initialized()) { _surface_svt->commit(); }
	_surface_vt->set_allocation_budget(-1);
	return produced;
}

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

void Terrain3D::set_debug_level(const DebugLevel p_level) {
	SET_IF_DIFF(debug_level, CLAMP(p_level, ERROR, EXTREME));
	LOG(INFO, "Setting debug level: ", debug_level);
}

void Terrain3D::set_data_directory(String p_dir) {
	String old_dir = _data_directory;
	SET_IF_DIFF(_data_directory, p_dir);
	_vt_svt_catalog_loaded = false;
	_vt_svt_tiles.clear();
	_reset_vt_configuration();
	LOG(INFO, "Setting data directory to ", _data_directory);
	// If _data_directory was empty and now specified, and has no data
	// assume we want to retain the current data.
	// Otherwise, clear data and reload dir
	if (!old_dir.is_empty() || Util::get_files(p_dir, "terrain3d*.res").size() > 0) {
		_initialized = false;
		_destroy_labels();
		_destroy_collision();
		_destroy_instancer();
		memdelete_safely(_data);
		_initialize();
	}
	update_configuration_warnings();
}

void Terrain3D::set_assets(const Ref<Terrain3DAssets> &p_assets) {
	SET_IF_DIFF(_assets, p_assets);
	LOG(INFO, "Setting asset list");
	_initialized = false;
	_initialize();
	LOG(DEBUG, "Emitting assets_changed");
	emit_signal("assets_changed");
}

void Terrain3D::set_editor(Terrain3DEditor *p_editor) {
	if (p_editor && p_editor->is_queued_for_deletion()) {
		LOG(ERROR, "Attempted to set a node queued for deletion");
		return;
	}
	SET_IF_DIFF(_editor, p_editor);
	LOG(INFO, "Setting Terrain3DEditor: ", _editor);
	if (_material.is_valid()) {
		_material->update(Terrain3DMaterial::FULL_REBUILD);
	}
}

void Terrain3D::set_plugin(Object *p_plugin) {
	if (p_plugin && p_plugin->is_queued_for_deletion()) {
		LOG(ERROR, "Attempted to set a node queued for deletion");
		return;
	}
	SET_IF_DIFF(_editor_plugin, p_plugin);
	LOG(INFO, "Setting Editor Plugin: ", _editor_plugin);
}

void Terrain3D::set_region_size(const RegionSize p_size) {
	if (!is_valid_region_size(p_size)) {
		LOG(ERROR, "Invalid region size: ", p_size, ". Must be power of 2, 64-2048");
		return;
	}
	SET_IF_DIFF(_region_size, p_size);
	LOG(INFO, "Setting region size: ", _region_size);
	if (_data) {
		_data->_region_size = _region_size;
		_data->_region_sizev = V2I(_region_size);
	}
	if (_material.is_valid()) {
		_material->update();
	}
	_update_displacement_buffer();
}

void Terrain3D::set_surface_density(const int p_density) {
	const int density = CLAMP(p_density, Terrain3DRegion::SURFACE_DENSITY_MIN, Terrain3DRegion::SURFACE_DENSITY_MAX);
	SET_IF_DIFF(_surface_density, density);
	LOG(INFO, "Setting surface density: ", _surface_density);
	if (_material.is_valid()) {
		// The shader scales its surface texel lookups by the density, so the uniform
		// has to follow even when no region is resident yet.
		_material->update();
	}
}

// Adopts a new surface resolution everywhere. Unlike set_surface_density this also
// resamples every resident region payload and drops the virtual texture's pages,
// which were produced from the old payload.
void Terrain3D::change_surface_density(const int p_density) {
	set_surface_density(p_density);
	if (_data) {
		_data->change_surface_density(_surface_density);
	}
	if (!_vt_debug_direct_material) {
		_reset_vt_configuration();
		return;
	}
	if (_surface_vt) {
		// Page contents are resolution specific, and the atlas block layout depends on
		// pages_per_axis only, so a fresh atlas is cheaper than tracking staleness.
		_surface_vt->clear();
		_surface_vt->initialize();
		_surface_vt_blocks_dirty = true;
	}
	if (_surface_svt) {
		// Same for the far field: its pages were produced from the old payload.
		_surface_svt->clear();
		_surface_svt->initialize();
	}
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::set_save_16_bit(const bool p_enabled) {
	SET_IF_DIFF(_save_16_bit, p_enabled);
	LOG(INFO, "Save heightmaps as 16-bit: ", _save_16_bit);
	TypedArray<Terrain3DRegion> regions = _data->get_regions_active();
	for (Ref<Terrain3DRegion> region : regions) {
		region->set_modified(true);
	}
}

void Terrain3D::set_label_distance(const real_t p_distance) {
	SET_IF_DIFF(_label_distance, CLAMP(p_distance, 0.f, 100000.f));
	LOG(INFO, "Setting region label distance: ", _label_distance);
	update_region_labels();
}

void Terrain3D::set_label_size(const int p_size) {
	SET_IF_DIFF(_label_size, CLAMP(p_size, 24, 128));
	LOG(INFO, "Setting region label size: ", _label_size);
	update_region_labels();
}

void Terrain3D::update_region_labels() {
	_destroy_labels();
	if (_label_distance > 0.f && _data) {
		TypedArray<Vector2i> region_locations = _data->get_region_locations();
		LOG(DEBUG, "Creating ", region_locations.size(), " region labels");
		for (const Vector2i &region_loc : region_locations) {
			Label3D *label = memnew(Label3D);
			String text = region_loc;
			label->set_name("Label3D" + text.replace(" ", ""));
			label->set_pixel_size(.001f);
			label->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
			label->set_draw_flag(Label3D::FLAG_DOUBLE_SIDED, true);
			label->set_draw_flag(Label3D::FLAG_DISABLE_DEPTH_TEST, true);
			label->set_draw_flag(Label3D::FLAG_FIXED_SIZE, true);
			label->set_render_priority(127);
			label->set_outline_render_priority(126);
			label->set_text(text);
			label->set_modulate(Color(1.f, 1.f, 1.f, .5f));
			label->set_outline_modulate(Color(0.f, 0.f, 0.f, .5f));
			label->set_font_size(_label_size);
			label->set_outline_size(_label_size / 6);
			label->set_visibility_range_end(_label_distance);
			label->set_visibility_range_end_margin(_label_distance / 10.f);
			label->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
			_label_parent->add_child(label, true);
			Vector3 pos = Vector3(real_t(region_loc.x) + .5f, 0.f, real_t(region_loc.y) + .5f) * _region_size * _vertex_spacing;
			real_t height = _data->get_surface_height(pos);
			pos.y = (std::isnan(height)) ? 0.f : height;
			label->set_position(pos);
		}
	}
}

void Terrain3D::set_camera(Camera3D *p_camera) {
	if (_camera.ptr() != p_camera) {
		LOG(EXTREME, "Setting camera: ", p_camera);
		_camera.set_target(p_camera);
		if (_clipmap_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

void Terrain3D::set_clipmap_target(Node3D *p_node) {
	if (_clipmap_target.ptr() != p_node) {
		LOG(INFO, "Setting clipmap target: ", p_node);
		_clipmap_target.set_target(p_node);
		if (_clipmap_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

Vector3 Terrain3D::get_clipmap_target_position() const {
	// In Editor, or no clipmap target, use camera
	if (IS_EDITOR || !_clipmap_target.get_target()) {
		if (Node3D *cam = _camera.get_target()) {
			return cam->get_global_position();
		}
	}
	if (Node3D *target = _clipmap_target.get_target()) {
		return target->get_global_position();
	}
	return V3_ZERO;
}

void Terrain3D::set_collision_target(Node3D *p_node) {
	if (_collision_target.ptr() != p_node) {
		LOG(INFO, "Setting collision target: ", p_node);
		_collision_target.set_target(p_node);
		if (_collision_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

Vector3 Terrain3D::get_collision_target_position() const {
	// In Editor, always prefer camera
	if (IS_EDITOR) {
		if (Node3D *cam = _camera.get_target()) {
			return cam->get_global_position();
		}
	}
	if (Node3D *target = _collision_target.get_target()) {
		return target->get_global_position();
	}
	if (Node3D *target = _clipmap_target.get_target()) {
		return target->get_global_position();
	}
	if (Node3D *cam = _camera.get_target()) {
		return cam->get_global_position();
	}
	return V3_ZERO;
}

void Terrain3D::set_light_target(Node3D *p_node) {
	if (_light_target.ptr() != p_node) {
		LOG(INFO, "Setting directional light target: ", p_node);
		_light_target.set_target(p_node);
		if (_light_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

void Terrain3D::snap() {
	if (_terrain_mesher) {
		_terrain_mesher->reset_target_position();
	}
	if (_ocean_enabled && _ocean_mesher) {
		_ocean_mesher->reset_target_position();
	}
	if (_collision) {
		_collision->reset_target_position();
	}
	if (_tessellation_level > 0) {
		_last_buffer_position = V2_MAX;
	}
}

void Terrain3D::set_material(const Ref<Terrain3DMaterial> &p_material) {
	SET_IF_DIFF(_material, p_material);
	LOG(INFO, "Setting material");
	_initialized = false;
	_initialize();
	LOG(DEBUG, "Emitting material_changed");
	emit_signal("material_changed");
}

void Terrain3D::set_mesh_lods(const int p_count) {
	SET_IF_DIFF(_mesh_lods, CLAMP(p_count, 1, 10));
	LOG(INFO, "Setting mesh levels: ", _mesh_lods);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update();
		_setup_terrain_mesher();
	}
}

void Terrain3D::set_tessellation_level(const int p_level) {
	SET_IF_DIFF(_tessellation_level, CLAMP(p_level, 0, 6));
	LOG(INFO, "Setting tessellation level: ", p_level);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update(Terrain3DMaterial::FULL_REBUILD);
		_setup_terrain_mesher();
		_update_displacement_buffer();
	}
	notify_property_list_changed();
}

void Terrain3D::set_mesh_size(const int p_size) {
	SET_IF_DIFF(_mesh_size, CLAMP(p_size & ~1, 8, 256)); // Ensure even
	LOG(INFO, "Setting mesh size: ", _mesh_size);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update();
		_setup_terrain_mesher();
		_update_displacement_buffer();
	}
}

void Terrain3D::set_vertex_spacing(const real_t p_spacing) {
	SET_IF_DIFF(_vertex_spacing, CLAMP(p_spacing, 0.25f, 100.0f));
	LOG(INFO, "Setting vertex spacing: ", _vertex_spacing);
	if (_collision && _data && _instancer && _material.is_valid()) {
		_instancer->_update_vertex_spacing(_vertex_spacing);
		_data->_vertex_spacing = _vertex_spacing;
		update_region_labels();
		_material->update();
		_setup_terrain_mesher();
		_collision->destroy();
		_collision->build();
		_update_displacement_buffer();
	}
}

void Terrain3D::set_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_cull_margin, CLAMP(p_margin, 0.f, 100000.f));
	LOG(INFO, "Setting extra cull margin: ", _cull_margin);
	if (_terrain_mesher) {
		_terrain_mesher->update_aabbs();
	}
}

void Terrain3D::set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_cast_shadows, p_cast_shadows);
	if (_terrain_mesher) {
		_terrain_mesher->update();
	}
}

void Terrain3D::set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_gi_mode, p_gi_mode);
	if (_terrain_mesher) {
		_terrain_mesher->update();
	}
}

void Terrain3D::set_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_render_layers, p_layers);
	LOG(INFO, "Setting terrain render layers to: ", p_layers);
	if (_terrain_mesher) {
		_terrain_mesher->update();
	}
}

void Terrain3D::set_ocean_enabled(const bool p_enabled) {
	SET_IF_DIFF(_ocean_enabled, p_enabled);
	LOG(INFO, "Setting ocean enabled: ", _ocean_enabled);
	if (_ocean_enabled) {
		if (_ocean_material.is_null()) {
			String ocean_mat_path = ProjectSettings::get_singleton()->globalize_path(OCEAN_MATERIAL_PATH);
			ResourceLoader *rl = ResourceLoader::get_singleton();
			if (rl->exists(ocean_mat_path)) {
				Ref<ShaderMaterial> ocean_mat = rl->load(ocean_mat_path);
				if (ocean_mat.is_valid()) {
					_ocean_material = ocean_mat;
				}
			}
		}
		_setup_ocean_mesher();
	} else {
		_destroy_ocean_mesher(false);
	}
	notify_property_list_changed();
}

void Terrain3D::set_ocean_mesh_lods(const int p_count) {
	SET_IF_DIFF(_ocean_mesh_lods, CLAMP(p_count, 1, 10));
	LOG(INFO, "Setting ocean mesh levels: ", _ocean_mesh_lods);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_ocean_tessellation_level(const int p_level) {
	SET_IF_DIFF(_ocean_tessellation_level, CLAMP(p_level, 0, 6));
	LOG(INFO, "Setting ocean tessellation level: ", p_level);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_ocean_mesh_size(const int p_size) {
	SET_IF_DIFF(_ocean_mesh_size, CLAMP(p_size & ~1, 8, 256)); // Ensure even
	LOG(INFO, "Setting ocean mesh size: ", _ocean_mesh_size);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_ocean_vertex_spacing(const real_t p_spacing) {
	SET_IF_DIFF(_ocean_vertex_spacing, CLAMP(p_spacing, 0.25f, 100.0f));
	LOG(INFO, "Setting ocean vertex spacing: ", _ocean_vertex_spacing);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_ocean_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_ocean_cull_margin, CLAMP(p_margin, 0.f, 100000.f));
	LOG(INFO, "Setting extra cull margin: ", _ocean_cull_margin);
	if (_ocean_mesher) {
		_ocean_mesher->update_aabbs(_ocean_cull_margin, V2_ZERO);
	}
}

void Terrain3D::set_ocean_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_ocean_cast_shadows, p_cast_shadows);
	if (_ocean_mesher) {
		_ocean_mesher->update();
	}
}

void Terrain3D::set_ocean_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_ocean_gi_mode, p_gi_mode);
	if (_ocean_mesher) {
		_ocean_mesher->update();
	}
}

void Terrain3D::set_ocean_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_ocean_render_layers, p_layers);
	LOG(INFO, "Setting ocean render layers to: ", p_layers);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_ocean_material(const Ref<Material> &p_material) {
	SET_IF_DIFF(_ocean_material, p_material);
	LOG(INFO, "Setting ocean material");
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Terrain3D::set_mouse_layer(const uint32_t p_layer) {
	SET_IF_DIFF(_mouse_layer, CLAMP(p_layer, 21, 32));
	uint32_t mouse_mask = 1 << (_mouse_layer - 1);
	LOG(INFO, "Setting mouse layer: ", _mouse_layer, " (", mouse_mask,
			") on terrain mesh, material, mouse camera, mouse quad");

	// Set terrain meshes to mouse layer
	// Mask off editor render layers by ORing user layers 1-20 and current mouse layer
	set_render_layers((_render_layers & 0xFFFFF) | mouse_mask);
	// Set terrain shader to exclude mouse camera from showing holes
	if (_material.is_valid()) {
		_material->set_shader_param("_mouse_layer", mouse_mask);
	}
	// Set mouse camera to see only mouse layer
	if (_mouse_cam) {
		_mouse_cam->set_cull_mask(mouse_mask);
	}
	// Set screenquad to mouse layer
	if (_mouse_quad) {
		_mouse_quad->set_layer_mask(mouse_mask);
	}
}

/* Returns the point a ray intersects the ground using either raymarching or the GPU depth texture
 *	p_src_pos (camera position)
 *	p_direction (camera direction looking at the terrain)
 *  p_gpu_mode - false: use raymarching, true: use GPU mode
 * Returns Vec3(NAN) on error or vec3(3.402823466e+38F) on no intersection. Test w/ if (var.x < 3.4e38)
 */
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

///////////////////////////
// Protected Functions
///////////////////////////

// Notifications are defined in individual classes: Object, Node, Node3D
// Listed below in order of operation
void Terrain3D::_notification(const int p_what) {
	switch (p_what) {
			/// Startup notifications

		case NOTIFICATION_POSTINITIALIZE: {
			// Object initialized, before script is attached
			LOG(INFO, "NOTIFICATION_POSTINITIALIZE");
			_build_containers();
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			// Node3D registered to new World3D resource
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			// Node entered a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			set_as_top_level(true); // Don't inherit transforms from parent. Global only.
			set_notify_transform(true);
			set_meta("_edit_lock_", true);
			_setup_mouse_picking();
			_setup_displacement_buffer();
			// Reload editor textures - Also see READY
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid() && !_assets->get_path().is_empty() && !_assets->get_path().contains("Terrain3DAssets")) {
				LOG(INFO, "free_editor_textures enabled, reloading Assets path: ", _assets->get_path());
				_assets = ResourceLoader::get_singleton()->load(_assets->get_path(), "", ResourceLoader::CACHE_MODE_IGNORE);
			}
			_initialize(); // Rebuild anything freed: meshes, collision, instancer
			set_physics_process(true);
			break;
		}

		case NOTIFICATION_READY: {
			// Node is ready
			LOG(INFO, "NOTIFICATION_READY");
			// Optional: Run the testing suite
			//#include "unit_testing.h"
			//test_differs();

			// Clear editor textures - also see ENTER_TREE
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid()) {
				if (_assets->get_path().contains("Terrain3DAssets")) {
					LOG(WARN, "free_editor_textures requires `Assets` be saved to a file. Do so, or disable the former to turn off this warning");
				} else {
					LOG(INFO, "free_editor_textures enabled, clearing texture assets");
					_assets->clear_textures();
				}
			}
			break;
		}

			/// Game Loop notifications

		case NOTIFICATION_PHYSICS_PROCESS: {
			// Node is processing one physics frame
			__physics_process(get_physics_process_delta_time());
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			// Node3D or parent transform changed
			if (get_transform() != Transform3D()) {
				set_transform(Transform3D());
			}
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			// Node3D visibility changed
			LOG(INFO, "NOTIFICATION_VISIBILITY_CHANGED");
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			if (_ocean_mesher) {
				_ocean_mesher->update();
			}
			if (_instancer) {
				if (!is_visible_in_tree()) {
					_instancer->destroy();
				} else {
					_instancer->update_mmis(-1, V2I_MAX, true);
				}
			}
			break;
		}

		case NOTIFICATION_EXTENSION_RELOADED: {
			// Object finished hot reloading
			LOG(INFO, "NOTIFICATION_EXTENSION_RELOADED");
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			// Editor Node is about to save the current scene
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (_data_directory.is_empty()) {
				LOG(ERROR, "Data directory is empty. Set it to save regions to disk.");
			} else if (!_data) {
				LOG(DEBUG, "Save requested, but no valid data object. Skipping");
			} else {
				_data->save_directory(_data_directory);
			}
			if (!_material.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid material. Skipping");
			} else {
				_material->save();
			}
			if (!_assets.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid texture list. Skipping");
			} else {
				_assets->save();
			}
			break;
		}

		case NOTIFICATION_EDITOR_POST_SAVE: {
			// Editor Node finished saving current scene
			break;
		}

		case NOTIFICATION_CRASH: {
			// Godot's crash handler reports engine is about to crash
			// Only works on desktop if the crash handler is enabled
			LOG(INFO, "NOTIFICATION_CRASH");
			break;
		}

			/// Shut down notifications

		case NOTIFICATION_EXIT_TREE: {
			_destroy_vt_service();
			// Node is about to exit a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			set_physics_process(false);
			_destroy_terrain_mesher();
			_destroy_ocean_mesher();
			_destroy_instancer();
			_destroy_streamer();
			_destroy_surface_vt();
			_destroy_surface_svt();
			_destroy_mouse_picking();
			_destroy_displacement_buffer();
			if (_assets.is_valid()) {
				_assets->uninitialize();
			}
			if (_material.is_valid()) {
				_material->uninitialize();
			}
			_initialized = false;
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			// Node3D unregistered from current World3D
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_is_inside_world = false;
			break;
		}

		case NOTIFICATION_PREDELETE: {
			_destroy_vt_service();
			// Object is about to be deleted
			LOG(INFO, "NOTIFICATION_PREDELETE");
			_destroy_terrain_mesher(true);
			_destroy_ocean_mesher(true);
			_destroy_instancer();
			_destroy_streamer();
			_destroy_surface_vt();
			_destroy_surface_svt();
			_destroy_collision(true);
			_assets.unref();
			_material.unref();
			memdelete_safely(_data);
			_destroy_labels();
			_destroy_containers();
			break;
		}

		default:
			break;
	}
}

void Terrain3D::_validate_property(PropertyInfo &p_property) const {
	if (_tessellation_level == 0) {
		// Hide all displacement properties
		if (p_property.name == StringName("displacement_scale") ||
				p_property.name == StringName("displacement_sharpness") ||
				p_property.name == StringName("buffer_shader_override_enabled") ||
				p_property.name == StringName("buffer_shader_override")) {
			p_property.usage = PROPERTY_USAGE_NO_EDITOR;
		}
	}
	// Hide all ocean properties if not enabled
	if (!_ocean_enabled && p_property.name != StringName("ocean_enabled") &&
			p_property.name.begins_with("ocean_")) {
		p_property.usage = PROPERTY_USAGE_NO_EDITOR;
	}
}

void Terrain3D::_bind_methods() {
	_bind_vt_methods();
	BIND_ENUM_CONSTANT(ERROR);
	BIND_ENUM_CONSTANT(INFO);
	BIND_ENUM_CONSTANT(DEBUG);
	BIND_ENUM_CONSTANT(EXTREME);

	BIND_ENUM_CONSTANT(SIZE_64);
	BIND_ENUM_CONSTANT(SIZE_128);
	BIND_ENUM_CONSTANT(SIZE_256);
	BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	BIND_ENUM_CONSTANT(SIZE_2048);

	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3D::get_version);
	ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &Terrain3D::set_debug_level);
	ClassDB::bind_method(D_METHOD("get_debug_level"), &Terrain3D::get_debug_level);
	ClassDB::bind_method(D_METHOD("set_data_directory", "directory"), &Terrain3D::set_data_directory);
	ClassDB::bind_method(D_METHOD("get_data_directory"), &Terrain3D::get_data_directory);

	// Object references
	ClassDB::bind_method(D_METHOD("get_data"), &Terrain3D::get_data);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Terrain3D::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Terrain3D::get_material);
	ClassDB::bind_method(D_METHOD("set_assets", "assets"), &Terrain3D::set_assets);
	ClassDB::bind_method(D_METHOD("get_assets"), &Terrain3D::get_assets);
	ClassDB::bind_method(D_METHOD("get_collision"), &Terrain3D::get_collision);
	ClassDB::bind_method(D_METHOD("get_instancer"), &Terrain3D::get_instancer);
	ClassDB::bind_method(D_METHOD("get_streamer"), &Terrain3D::get_streamer);
	ClassDB::bind_method(D_METHOD("set_streaming_enabled", "enabled"), &Terrain3D::set_streaming_enabled);
	ClassDB::bind_method(D_METHOD("is_streaming_enabled"), &Terrain3D::is_streaming_enabled);
	ClassDB::bind_method(D_METHOD("get_surface_vt"), &Terrain3D::get_surface_vt);
	ClassDB::bind_method(D_METHOD("set_surface_vt_enabled", "enabled"), &Terrain3D::set_surface_vt_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_vt_enabled"), &Terrain3D::is_surface_vt_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_count", "count"), &Terrain3D::set_surface_vt_page_count);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_count"), &Terrain3D::get_surface_vt_page_count);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_size", "size"), &Terrain3D::set_surface_vt_page_size);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_size"), &Terrain3D::get_surface_vt_page_size);
	ClassDB::bind_method(D_METHOD("set_surface_vt_page_border", "border"), &Terrain3D::set_surface_vt_page_border);
	ClassDB::bind_method(D_METHOD("get_surface_vt_page_border"), &Terrain3D::get_surface_vt_page_border);
	ClassDB::bind_method(D_METHOD("set_surface_vt_pages_per_axis", "pages"), &Terrain3D::set_surface_vt_pages_per_axis);
	ClassDB::bind_method(D_METHOD("get_surface_vt_pages_per_axis"), &Terrain3D::get_surface_vt_pages_per_axis);
	ClassDB::bind_method(D_METHOD("set_surface_vt_distance", "distance"), &Terrain3D::set_surface_vt_distance);
	ClassDB::bind_method(D_METHOD("get_surface_vt_distance"), &Terrain3D::get_surface_vt_distance);
	ClassDB::bind_method(D_METHOD("set_surface_vt_region_grid", "grid"), &Terrain3D::set_surface_vt_region_grid);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_grid"), &Terrain3D::get_surface_vt_region_grid);
	ClassDB::bind_method(D_METHOD("set_surface_vt_selection_mode", "mode"), &Terrain3D::set_surface_vt_selection_mode);
	ClassDB::bind_method(D_METHOD("get_surface_vt_selection_mode"), &Terrain3D::get_surface_vt_selection_mode);
	ClassDB::bind_method(D_METHOD("set_surface_vt_region_offset", "offset"), &Terrain3D::set_surface_vt_region_offset);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_offset"), &Terrain3D::get_surface_vt_region_offset);
	ClassDB::bind_method(D_METHOD("set_surface_vt_forward_regions", "regions"), &Terrain3D::set_surface_vt_forward_regions);
	ClassDB::bind_method(D_METHOD("get_surface_vt_forward_regions"), &Terrain3D::get_surface_vt_forward_regions);
	ClassDB::bind_method(D_METHOD("get_surface_vt_region_rect"), &Terrain3D::get_surface_vt_region_rect);
	ClassDB::bind_method(D_METHOD("set_surface_vt_texels_per_pixel", "value"), &Terrain3D::set_surface_vt_texels_per_pixel);
	ClassDB::bind_method(D_METHOD("get_surface_vt_texels_per_pixel"), &Terrain3D::get_surface_vt_texels_per_pixel);
	ClassDB::bind_method(D_METHOD("set_surface_vt_force_mip", "enabled", "mip"), &Terrain3D::set_surface_vt_force_mip, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_surface_vt_force_mip"), &Terrain3D::is_surface_vt_force_mip);
	ClassDB::bind_method(D_METHOD("get_surface_vt_mip"), &Terrain3D::get_surface_vt_mip);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_enabled", "enabled"), &Terrain3D::set_surface_vt_feedback_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_vt_feedback_enabled"), &Terrain3D::is_surface_vt_feedback_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_interval", "updates"), &Terrain3D::set_surface_vt_feedback_interval);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_interval"), &Terrain3D::get_surface_vt_feedback_interval);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_grid_chunks", "chunks"), &Terrain3D::set_surface_vt_feedback_grid_chunks);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_grid_chunks"), &Terrain3D::get_surface_vt_feedback_grid_chunks);
	ClassDB::bind_method(D_METHOD("set_surface_vt_feedback_min_extent", "extent"), &Terrain3D::set_surface_vt_feedback_min_extent);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback_min_extent"), &Terrain3D::get_surface_vt_feedback_min_extent);
	ClassDB::bind_method(D_METHOD("get_surface_vt_feedback"), &Terrain3D::get_surface_vt_feedback);
	ClassDB::bind_method(D_METHOD("update_surface_vt", "max_pages"), &Terrain3D::update_surface_vt, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_surface_svt"), &Terrain3D::get_surface_svt);
	ClassDB::bind_method(D_METHOD("set_surface_svt_enabled", "enabled"), &Terrain3D::set_surface_svt_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_svt_enabled"), &Terrain3D::is_surface_svt_enabled);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_world", "size"), &Terrain3D::set_surface_svt_page_world);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_world"), &Terrain3D::get_surface_svt_page_world);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_size", "size"), &Terrain3D::set_surface_svt_page_size);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_size"), &Terrain3D::get_surface_svt_page_size);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_border", "border"), &Terrain3D::set_surface_svt_page_border);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_border"), &Terrain3D::get_surface_svt_page_border);
	ClassDB::bind_method(D_METHOD("set_surface_svt_page_count", "count"), &Terrain3D::set_surface_svt_page_count);
	ClassDB::bind_method(D_METHOD("get_surface_svt_page_count"), &Terrain3D::get_surface_svt_page_count);
	ClassDB::bind_method(D_METHOD("set_surface_svt_max_mip", "mip"), &Terrain3D::set_surface_svt_max_mip);
	ClassDB::bind_method(D_METHOD("get_surface_svt_max_mip"), &Terrain3D::get_surface_svt_max_mip);
	ClassDB::bind_method(D_METHOD("set_surface_svt_distance", "distance"), &Terrain3D::set_surface_svt_distance);
	ClassDB::bind_method(D_METHOD("get_surface_svt_distance"), &Terrain3D::get_surface_svt_distance);
	ClassDB::bind_method(D_METHOD("update_surface_svt", "max_pages"), &Terrain3D::update_surface_svt, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_surface_svt_root_mips", "mips"), &Terrain3D::set_surface_svt_root_mips);
	ClassDB::bind_method(D_METHOD("get_surface_svt_root_mips"), &Terrain3D::get_surface_svt_root_mips);
	ClassDB::bind_method(D_METHOD("set_surface_svt_mip_distances", "distances"), &Terrain3D::set_surface_svt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_distances"), &Terrain3D::get_surface_svt_mip_distances);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_distance_count"), &Terrain3D::get_surface_svt_mip_distance_count);
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_for_distance", "distance", "max_mip"), &Terrain3D::get_surface_svt_mip_for_distance, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("get_surface_svt_mip_reach"), &Terrain3D::get_surface_svt_mip_reach);
	ClassDB::bind_method(D_METHOD("set_surface_array_enabled", "enabled"), &Terrain3D::set_surface_array_enabled);
	ClassDB::bind_method(D_METHOD("is_surface_array_enabled"), &Terrain3D::is_surface_array_enabled);
	ClassDB::bind_method(D_METHOD("invalidate_surface_pages", "region_location"), &Terrain3D::invalidate_surface_pages);
	ClassDB::bind_method(D_METHOD("set_editor", "editor"), &Terrain3D::set_editor);
	ClassDB::bind_method(D_METHOD("get_editor"), &Terrain3D::get_editor);
	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &Terrain3D::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &Terrain3D::get_plugin);

	// Regions
	ClassDB::bind_method(D_METHOD("change_region_size", "size"), &Terrain3D::change_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3D::get_region_size);
	ClassDB::bind_method(D_METHOD("set_surface_density", "density"), &Terrain3D::set_surface_density);
	ClassDB::bind_method(D_METHOD("get_surface_density"), &Terrain3D::get_surface_density);
	ClassDB::bind_method(D_METHOD("change_surface_density", "density"), &Terrain3D::change_surface_density);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Terrain3D::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Terrain3D::get_save_16_bit);
	ClassDB::bind_method(D_METHOD("set_label_distance", "distance"), &Terrain3D::set_label_distance);
	ClassDB::bind_method(D_METHOD("get_label_distance"), &Terrain3D::get_label_distance);
	ClassDB::bind_method(D_METHOD("set_label_size", "size"), &Terrain3D::set_label_size);
	ClassDB::bind_method(D_METHOD("get_label_size"), &Terrain3D::get_label_size);

	// Target Tracking
	ClassDB::bind_method(D_METHOD("set_camera", "camera"), &Terrain3D::set_camera);
	ClassDB::bind_method(D_METHOD("get_camera"), &Terrain3D::get_camera);
	ClassDB::bind_method(D_METHOD("set_clipmap_target", "node"), &Terrain3D::set_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target"), &Terrain3D::get_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target_position"), &Terrain3D::get_clipmap_target_position);
	ClassDB::bind_method(D_METHOD("set_collision_target", "node"), &Terrain3D::set_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target"), &Terrain3D::get_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target_position"), &Terrain3D::get_collision_target_position);
	ClassDB::bind_method(D_METHOD("set_light_target", "node"), &Terrain3D::set_light_target);
	ClassDB::bind_method(D_METHOD("get_light_target"), &Terrain3D::get_light_target);
	ClassDB::bind_method(D_METHOD("snap"), &Terrain3D::snap);

	// Collision
	ClassDB::bind_method(D_METHOD("set_collision_mode", "mode"), &Terrain3D::set_collision_mode);
	ClassDB::bind_method(D_METHOD("get_collision_mode"), &Terrain3D::get_collision_mode);
	ClassDB::bind_method(D_METHOD("set_collision_shape_size", "size"), &Terrain3D::set_collision_shape_size);
	ClassDB::bind_method(D_METHOD("get_collision_shape_size"), &Terrain3D::get_collision_shape_size);
	ClassDB::bind_method(D_METHOD("set_collision_radius", "radius"), &Terrain3D::set_collision_radius);
	ClassDB::bind_method(D_METHOD("get_collision_radius"), &Terrain3D::get_collision_radius);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layers"), &Terrain3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Terrain3D::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Terrain3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Terrain3D::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_priority", "priority"), &Terrain3D::set_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_priority"), &Terrain3D::get_collision_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Terrain3D::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Terrain3D::get_physics_material);

	// Terrain Mesh
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Terrain3D::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Terrain3D::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Terrain3D::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Terrain3D::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_tessellation_level", "size"), &Terrain3D::set_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_tessellation_level"), &Terrain3D::get_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "scale"), &Terrain3D::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Terrain3D::get_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Terrain3D::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Terrain3D::get_cull_margin);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "shadow_casting_setting"), &Terrain3D::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Terrain3D::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_gi_mode", "gi_mode"), &Terrain3D::set_gi_mode);
	ClassDB::bind_method(D_METHOD("get_gi_mode"), &Terrain3D::get_gi_mode);
	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Terrain3D::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Terrain3D::get_render_layers);

	// Terrain Displacement
	ClassDB::bind_method(D_METHOD("set_displacement_scale", "scale"), &Terrain3D::set_displacement_scale);
	ClassDB::bind_method(D_METHOD("get_displacement_scale"), &Terrain3D::get_displacement_scale);
	ClassDB::bind_method(D_METHOD("set_displacement_sharpness", "sharpness"), &Terrain3D::set_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("get_displacement_sharpness"), &Terrain3D::get_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override_enabled", "enabled"), &Terrain3D::set_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("is_buffer_shader_override_enabled"), &Terrain3D::is_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override", "shader"), &Terrain3D::set_buffer_shader_override);
	ClassDB::bind_method(D_METHOD("get_buffer_shader_override"), &Terrain3D::get_buffer_shader_override);

	// Ocean Mesh
	ClassDB::bind_method(D_METHOD("set_ocean_enabled", "enabled"), &Terrain3D::set_ocean_enabled);
	ClassDB::bind_method(D_METHOD("is_ocean_enabled"), &Terrain3D::is_ocean_enabled);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_lods", "count"), &Terrain3D::set_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_lods"), &Terrain3D::get_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_ocean_tessellation_level", "size"), &Terrain3D::set_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_ocean_tessellation_level"), &Terrain3D::get_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_size", "size"), &Terrain3D::set_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_size"), &Terrain3D::get_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("set_ocean_vertex_spacing", "scale"), &Terrain3D::set_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_ocean_vertex_spacing"), &Terrain3D::get_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_ocean_cull_margin", "margin"), &Terrain3D::set_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("get_ocean_cull_margin"), &Terrain3D::get_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("set_ocean_cast_shadows", "shadow_casting_setting"), &Terrain3D::set_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_ocean_cast_shadows"), &Terrain3D::get_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_ocean_gi_mode", "gi_mode"), &Terrain3D::set_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("get_ocean_gi_mode"), &Terrain3D::get_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("set_ocean_render_layers", "layers"), &Terrain3D::set_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("get_ocean_render_layers"), &Terrain3D::get_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("set_ocean_material", "material"), &Terrain3D::set_ocean_material);
	ClassDB::bind_method(D_METHOD("get_ocean_material"), &Terrain3D::get_ocean_material);

	// Rendering
	ClassDB::bind_method(D_METHOD("set_mouse_layer", "layer"), &Terrain3D::set_mouse_layer);
	ClassDB::bind_method(D_METHOD("get_mouse_layer"), &Terrain3D::get_mouse_layer);
	ClassDB::bind_method(D_METHOD("set_free_editor_textures"), &Terrain3D::set_free_editor_textures);
	ClassDB::bind_method(D_METHOD("get_free_editor_textures"), &Terrain3D::get_free_editor_textures);
	ClassDB::bind_method(D_METHOD("set_instancer_mode", "mode"), &Terrain3D::set_instancer_mode);
	ClassDB::bind_method(D_METHOD("get_instancer_mode"), &Terrain3D::get_instancer_mode);

	// Overlays
	ClassDB::bind_method(D_METHOD("set_show_region_grid", "enabled"), &Terrain3D::set_show_region_grid);
	ClassDB::bind_method(D_METHOD("get_show_region_grid"), &Terrain3D::get_show_region_grid);
	ClassDB::bind_method(D_METHOD("set_show_instancer_grid", "enabled"), &Terrain3D::set_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("get_show_instancer_grid"), &Terrain3D::get_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3D::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3D::get_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("set_show_contours", "enabled"), &Terrain3D::set_show_contours);
	ClassDB::bind_method(D_METHOD("get_show_contours"), &Terrain3D::get_show_contours);
	ClassDB::bind_method(D_METHOD("set_show_slope", "enabled"), &Terrain3D::set_show_slope);
	ClassDB::bind_method(D_METHOD("get_show_slope"), &Terrain3D::get_show_slope);
	ClassDB::bind_method(D_METHOD("set_show_navigation", "enabled"), &Terrain3D::set_show_navigation);
	ClassDB::bind_method(D_METHOD("get_show_navigation"), &Terrain3D::get_show_navigation);

	// Debug Views
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3D::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3D::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3D::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3D::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3D::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3D::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_jaggedness", "enabled"), &Terrain3D::set_show_jaggedness);
	ClassDB::bind_method(D_METHOD("get_show_jaggedness"), &Terrain3D::get_show_jaggedness);
	ClassDB::bind_method(D_METHOD("set_show_autoshader", "enabled"), &Terrain3D::set_show_autoshader);
	ClassDB::bind_method(D_METHOD("get_show_autoshader"), &Terrain3D::get_show_autoshader);
	ClassDB::bind_method(D_METHOD("set_show_control_texture", "enabled"), &Terrain3D::set_show_control_texture);
	ClassDB::bind_method(D_METHOD("get_show_control_texture"), &Terrain3D::get_show_control_texture);
	ClassDB::bind_method(D_METHOD("set_show_control_blend", "enabled"), &Terrain3D::set_show_control_blend);
	ClassDB::bind_method(D_METHOD("get_show_control_blend"), &Terrain3D::get_show_control_blend);
	ClassDB::bind_method(D_METHOD("set_show_control_angle", "enabled"), &Terrain3D::set_show_control_angle);
	ClassDB::bind_method(D_METHOD("get_show_control_angle"), &Terrain3D::get_show_control_angle);
	ClassDB::bind_method(D_METHOD("set_show_control_scale", "enabled"), &Terrain3D::set_show_control_scale);
	ClassDB::bind_method(D_METHOD("get_show_control_scale"), &Terrain3D::get_show_control_scale);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3D::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3D::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3D::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3D::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_displacement_buffer", "enabled"), &Terrain3D::set_show_displacement_buffer);
	ClassDB::bind_method(D_METHOD("get_show_displacement_buffer"), &Terrain3D::get_show_displacement_buffer);

	// PBR Views
	ClassDB::bind_method(D_METHOD("set_show_texture_albedo", "enabled"), &Terrain3D::set_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("get_show_texture_albedo"), &Terrain3D::get_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3D::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3D::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3D::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3D::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3D::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3D::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_texture_ao", "enabled"), &Terrain3D::set_show_texture_ao);
	ClassDB::bind_method(D_METHOD("get_show_texture_ao"), &Terrain3D::get_show_texture_ao);

	// Utility
	ClassDB::bind_method(D_METHOD("get_intersection", "src_pos", "direction", "gpu_mode"), &Terrain3D::get_intersection, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_raycast_result", "src_pos", "direction", "collision_mask", "exclude_terrain"),
			&Terrain3D::get_raycast_result, DEFVAL(0xFFFFFFFF), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("bake_mesh", "lod", "filter"), &Terrain3D::bake_mesh, DEFVAL(Terrain3DData::HEIGHT_FILTER_NEAREST));
	ClassDB::bind_method(D_METHOD("generate_nav_mesh_source_geometry", "global_aabb", "require_nav"), &Terrain3D::generate_nav_mesh_source_geometry, DEFVAL(true));

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Extreme"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "data_directory", PROPERTY_HINT_DIR), "set_data_directory", "get_data_directory");

	// Object references
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DMaterial"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "assets", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DAssets"), "set_assets", "get_assets");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "data", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY, "Terrain3DData"), "", "get_data");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DCollision"), "", "get_collision");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "instancer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DInstancer"), "", "get_instancer");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "streamer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DStreamer"), "", "get_streamer");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "streaming_enabled"), "set_streaming_enabled", "is_streaming_enabled");
	ADD_GROUP("Surface VT", "");
	ADD_SUBGROUP("VT Setting", "vt_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_size", PROPERTY_HINT_RANGE, "16,1024,16"), "set_vt_page_size", "get_vt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_border", PROPERTY_HINT_RANGE, "1,16,1"), "set_vt_page_border", "get_vt_page_border");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_page_count", PROPERTY_HINT_RANGE, "8,1024,1"), "set_vt_page_count", "get_vt_page_count");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vt_pages_per_update", PROPERTY_HINT_RANGE, "1,64,1"), "set_vt_pages_per_update", "get_vt_pages_per_update");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "vt_debug_direct_material"), "set_vt_debug_direct_material", "is_vt_debug_direct_material");
	ADD_SUBGROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_array_enabled"), "set_surface_array_enabled", "is_surface_array_enabled");
	ADD_SUBGROUP("AVT", "surface_vt_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_adaptive_enabled"), "set_vt_adaptive_enabled", "is_vt_adaptive_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "surface_vt", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Terrain3DVirtualTexture"), "", "get_surface_vt");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_texels_per_pixel", PROPERTY_HINT_RANGE, "0.25,64,0.25,or_greater"), "set_surface_vt_texels_per_pixel", "get_surface_vt_texels_per_pixel");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_enabled"), "set_surface_vt_enabled", "is_surface_vt_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_count", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_count", "get_surface_vt_page_count");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_size", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_size", "get_surface_vt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_page_border", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_page_border", "get_surface_vt_page_border");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_pages_per_axis"), "set_surface_vt_pages_per_axis", "get_surface_vt_pages_per_axis");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_selection_mode", PROPERTY_HINT_ENUM, "Visible Terrain,Target Grid"), "set_surface_vt_selection_mode", "get_surface_vt_selection_mode");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "surface_vt_region_grid"), "set_surface_vt_region_grid", "get_surface_vt_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "surface_vt_region_offset"), "set_surface_vt_region_offset", "get_surface_vt_region_offset");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_forward_regions", PROPERTY_HINT_RANGE, "-64,64,0.25"), "set_surface_vt_forward_regions", "get_surface_vt_forward_regions");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_distance", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_distance", "get_surface_vt_distance");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_vt_feedback_enabled", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_enabled", "is_surface_vt_feedback_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_feedback_interval", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_interval", "get_surface_vt_feedback_interval");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_vt_feedback_grid_chunks", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_grid_chunks", "get_surface_vt_feedback_grid_chunks");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_vt_feedback_min_extent", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_vt_feedback_min_extent", "get_surface_vt_feedback_min_extent");
	ADD_SUBGROUP("SVT", "surface_svt_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_svt_auto_bake"), "set_svt_auto_bake", "is_svt_auto_bake");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "surface_svt_enabled"), "set_surface_svt_enabled", "is_surface_svt_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_svt_page_world", PROPERTY_HINT_RANGE, "1.0,65536.0,1.0,or_greater"), "set_surface_svt_page_world", "get_surface_svt_page_world");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_size", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_size", "get_surface_svt_page_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_border", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_border", "get_surface_svt_page_border");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_page_count", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_page_count", "get_surface_svt_page_count");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_max_mip"), "set_surface_svt_max_mip", "get_surface_svt_max_mip");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "surface_svt_distance", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_surface_svt_distance", "get_surface_svt_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_svt_root_mips", PROPERTY_HINT_RANGE, "0,16,1"), "set_surface_svt_root_mips", "get_surface_svt_root_mips");
	// One entry per world mip level, in metres: the largest camera distance still
	// sampled at that level. Empty = automatic (one level per doubling of the page).
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "surface_svt_mip_distances", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT, "float"), "set_surface_svt_mip_distances", "get_surface_svt_mip_distances");
	ADD_SUBGROUP("VT Page", "vt_page_");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "vt_page_status", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_vt_settings");
	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "light_target", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_light_target", "get_light_target");

	ADD_GROUP("Regions", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64,128:128,256:256,512:512,1024:1024,2048:2048", PROPERTY_USAGE_EDITOR), "change_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_density", PROPERTY_HINT_ENUM, "1 texel/m:1,2 texels/m:2,4 texels/m:4,8 texels/m:8", PROPERTY_USAGE_EDITOR), "change_surface_density", "get_surface_density");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16_bit"), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "label_distance", PROPERTY_HINT_RANGE, "0.0,10000.0,0.5,or_greater"), "set_label_distance", "get_label_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "label_size", PROPERTY_HINT_RANGE, "24,128,1"), "set_label_size", "get_label_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grid"), "set_show_region_grid", "get_show_region_grid");

	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_collision_mode", "get_collision_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_collision_shape_size", "get_collision_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_collision_radius", "get_collision_radius");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_collision_target", "get_collision_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_collision_priority", "get_collision_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");

	ADD_GROUP("Terrain Mesh", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "clipmap_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_clipmap_target", "get_clipmap_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,or_greater"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_cull_margin", "get_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_gi_mode", "get_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");

	ADD_SUBGROUP("Displacement", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_scale", PROPERTY_HINT_RANGE, "0.0, 2.0, 0.01"), "set_displacement_scale", "get_displacement_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_sharpness", PROPERTY_HINT_RANGE, "0.0, 1.0, 0.01"), "set_displacement_sharpness", "get_displacement_sharpness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "buffer_shader_override_enabled"), "set_buffer_shader_override_enabled", "is_buffer_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "buffer_shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_buffer_shader_override", "get_buffer_shader_override");

	ADD_GROUP("Ocean Mesh", "ocean_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ocean_enabled"), "set_ocean_enabled", "is_ocean_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_ocean_mesh_lods", "get_ocean_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_ocean_tessellation_level", "get_ocean_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_ocean_mesh_size", "get_ocean_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_ocean_vertex_spacing", "get_ocean_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_ocean_cull_margin", "get_ocean_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_ocean_cast_shadows", "get_ocean_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_ocean_gi_mode", "get_ocean_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_ocean_render_layers", "get_ocean_render_layers");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "ocean_material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,BaseMaterial3D"), "set_ocean_material", "get_ocean_material");

	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mouse_layer", PROPERTY_HINT_RANGE, "21, 32"), "set_mouse_layer", "get_mouse_layer");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "free_editor_textures"), "set_free_editor_textures", "get_free_editor_textures");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "instancer_mode", PROPERTY_HINT_ENUM, "Disabled,Normal"), "set_instancer_mode", "get_instancer_mode");

	ADD_GROUP("Overlays", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_region_grid"), "set_show_region_grid", "get_show_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_instancer_grid"), "set_show_instancer_grid", "get_show_instancer_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid"), "set_show_vertex_grid", "get_show_vertex_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_contours"), "set_show_contours", "get_show_contours");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_slope"), "set_show_slope", "get_show_slope");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_navigation"), "set_show_navigation", "get_show_navigation");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered"), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey"), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap"), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_jaggedness"), "set_show_jaggedness", "get_show_jaggedness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_autoshader"), "set_show_autoshader", "get_show_autoshader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_texture"), "set_show_control_texture", "get_show_control_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_blend"), "set_show_control_blend", "get_show_control_blend");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_angle"), "set_show_control_angle", "get_show_control_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_scale"), "set_show_control_scale", "get_show_control_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap"), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap"), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_displacement_buffer"), "set_show_displacement_buffer", "get_show_displacement_buffer");

	ADD_SUBGROUP("PBR Maps", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_albedo"), "set_show_texture_albedo", "get_show_texture_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height"), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal"), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough"), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_ao"), "set_show_texture_ao", "get_show_texture_ao");

	ADD_SIGNAL(MethodInfo("material_changed"));
	ADD_SIGNAL(MethodInfo("assets_changed"));
}
