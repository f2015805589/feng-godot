// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Property setters for the node's configuration: regions, targets, meshes, ocean,
// displacement and rendering. Split out of terrain_3d.cpp.

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

void Terrain3D::set_debug_level(const DebugLevel p_level) {
	SET_IF_DIFF(debug_level, CLAMP(p_level, ERROR, EXTREME));
	LOG(INFO, "Setting debug level: ", debug_level);
}

void Terrain3D::set_data_directory(String p_dir) {
	String old_dir = _data_directory;
	SET_IF_DIFF(_data_directory, p_dir);
	_vt.vt_svt_catalog_loaded = false;
	_vt.vt_svt_tiles.clear();
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

void Terrain3D::set_streaming_enabled(const bool p_enabled) {
	_streaming_enabled = p_enabled;
	if (_streamer) {
		_streamer->set_enabled(p_enabled);
	}
	LOG(INFO, "Region streaming ", p_enabled ? "enabled" : "disabled");
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
	if (!_vt.vt_debug_direct_material) {
		_reset_vt_configuration();
		return;
	}
	if (_vt.surface_vt) {
		// Page contents are resolution specific, and the atlas block layout depends on
		// pages_per_axis only, so a fresh atlas is cheaper than tracking staleness.
		_vt.surface_vt->clear();
		_vt.surface_vt->initialize();
		_vt.surface_vt_blocks_dirty = true;
	}
	if (_vt.surface_svt) {
		// Same for the far field: its pages were produced from the old payload.
		_vt.surface_svt->clear();
		_vt.surface_svt->initialize();
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

void Terrain3D::set_cdlod_enabled(bool p_enabled) {
	SET_IF_DIFF(_cdlod_enabled, p_enabled);
	if (_terrain_mesher) { _terrain_mesher->snap(); }
}
void Terrain3D::set_cdlod_patch_size(int p_size) {
	const int size = int(next_power_of_2(uint32_t(CLAMP(p_size, 8, 128))));
	SET_IF_DIFF(_cdlod_patch_size, size);
	if (_terrain_mesher && _material.is_valid()) { _setup_terrain_mesher(); }
}
void Terrain3D::set_cdlod_lod_scale(real_t p_scale) {
	if (!std::isfinite(p_scale)) { return; }
	SET_IF_DIFF(_cdlod_lod_scale, CLAMP(p_scale, real_t(8), real_t(32)));
	if (_terrain_mesher) { _terrain_mesher->snap(); }
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
