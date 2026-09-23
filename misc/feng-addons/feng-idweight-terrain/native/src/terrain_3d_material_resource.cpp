// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DMaterial, part 2 of 4: the resource, its properties and save.

// One of four files that define the resource. `initialize()`, `uninitialize()`, `destroy()` and
// `update()` are the object's lifecycle, and every `set_*` the inspector, the scene file and a
// script can write is here with the corresponding read. A setter owns its side effect rather than
// only storing a value: the flags call `_update_shader()`, the outputs and debug views call
// `update(UNIFORMS_ONLY)`, and the overrides re-instantiate the override object. `save()` is here
// because it is the other side of the same coin - it decides which saved parameters still name a
// real uniform before the resource is written.
//
// The other halves: `terrain_3d_material.cpp` (the shader and its uniforms) and
// `terrain_3d_material_reflect.cpp` (the property list and the ClassDB bindings).

#include "logger.h"
#include "terrain_3d_material.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

///////////////////////////
// Public Functions
///////////////////////////

// This function serves as the constructor which is initialized by the class Terrain3D.
// Godot likes to create resource objects at startup, so this prevents it from creating
// uninitialized materials.
void Terrain3DMaterial::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing material");
	_preload_shaders();
	if (!_material.is_valid()) {
		_material = RS->material_create();
	}
	if (!_buffer_material.is_valid()) {
		_buffer_material = RS->material_create();
	}
	_shader.instantiate();
	_buffer_shader.instantiate();
	// Create dummy texture array to avoid empty sampler2DArrays
	if (!_generated_dummy.get_rid().is_valid()) {
		Ref<Image> img = Image::create(1, 1, false, Image::FORMAT_RF);
		TypedArray<Image> ia = { img };
		_generated_dummy.create(ia);
	}
	if (!_generated_dummy_2d.get_rid().is_valid()) {
		_generated_dummy_2d.create(Image::create(1, 1, false, Image::FORMAT_RF));
	}

	update(FULL_REBUILD);
}

void Terrain3DMaterial::uninitialize() {
	LOG(INFO, "Uninitializing material");
	_terrain = nullptr;
}

void Terrain3DMaterial::destroy() {
	LOG(INFO, "Destroying material");
	_terrain = nullptr;
	_shader.unref();
	_buffer_shader.unref();
	_shader_code.clear();
	_active_params.clear();
	_shader_params.clear();
	_generated_dummy.clear();
	_generated_dummy_2d.clear();
	if (_material.is_valid()) {
		RS->free_rid(_material);
		_material = RID();
	}
	if (_buffer_material.is_valid()) {
		RS->free_rid(_buffer_material);
		_buffer_material = RID();
	}
}

void Terrain3DMaterial::update(uint32_t p_flags) {
	// Both halves of the variant choice, because either one leaving the generated code is a shader
	// rebuild rather than a uniform rebind.
	if ((p_flags & (FULL_REBUILD & ~UPDATE_ARRAYS)) ||
			_shader_uses_vt != _needs_vt_shader() ||
			_clipmap_arm_changed()) {
		_update_shader();
	}
	if (_terrain && (p_flags & TEXTURE_ARRAYS)) { _terrain->invalidate_vt_materials(); }
	_update_uniforms(_material, p_flags);
	IS_INIT(VOID);
	if (_terrain->get_tessellation_level() > 0) {
		_update_uniforms(_buffer_material, p_flags);
		// Snap to update buffer
		_terrain->snap();
	}
}

void Terrain3DMaterial::set_displacement_scale(const real_t p_displacement_scale) {
	SET_IF_DIFF(_displacement_scale, CLAMP(p_displacement_scale, 0.f, 2.f));
	LOG(INFO, "Setting displacement scale: ", _displacement_scale);
	update();
}

void Terrain3DMaterial::set_displacement_sharpness(const real_t p_displacement_sharpness) {
	SET_IF_DIFF(_displacement_sharpness, CLAMP(p_displacement_sharpness, 0.f, 1.f));
	LOG(INFO, "Setting displacement sharpness: ", _displacement_sharpness);
	update();
	if (_terrain) {
		_terrain->snap();
	}
}

void Terrain3DMaterial::set_world_background(const WorldBackground p_background) {
	SET_IF_DIFF(_world_background, p_background);
	LOG(INFO, "Enable world background: ", _world_background);
	_update_shader();
}

void Terrain3DMaterial::set_texture_filtering(const TextureFiltering p_filtering) {
	SET_IF_DIFF(_texture_filtering, p_filtering);
	LOG(INFO, "Setting texture filtering: ", _texture_filtering);
	_update_shader();
}

void Terrain3DMaterial::set_auto_shader_enabled(const bool p_enabled) {
	SET_IF_DIFF(_auto_shader_enabled, p_enabled);
	LOG(INFO, "Enable auto shader: ", _auto_shader_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_dual_scaling_enabled(const bool p_enabled) {
	SET_IF_DIFF(_dual_scaling_enabled, p_enabled);
	// Serialized compatibility value; the removed material path has no runtime shader code.
}

void Terrain3DMaterial::set_macro_variation_enabled(const bool p_enabled) {
	SET_IF_DIFF(_macro_variation_enabled, p_enabled);
	LOG(INFO, "Enable macro variation: ", _macro_variation_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_projection_enabled(const bool p_enabled) {
	SET_IF_DIFF(_projection_enabled, p_enabled);
	LOG(INFO, "Enable projection: ", _projection_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_max_regions(const RegionMaximum p_max) {
	SET_IF_DIFF(_max_regions, RegionMaximum(CLAMP(closest_power_of_2(p_max), 64, 1024)));
	LOG(INFO, "Set max region count: ", _max_regions);
	_update_shader();
}

void Terrain3DMaterial::set_shader_override_enabled(const bool p_enabled) {
	SET_IF_DIFF(_shader_override_enabled, p_enabled);
	LOG(INFO, "Enable shader override: ", _shader_override_enabled);
	if (_shader_override_enabled && _shader_override.is_null()) {
		LOG(DEBUG, "Instantiating new _shader_override");
		_shader_override.instantiate();
	}
	_update_shader();
}

void Terrain3DMaterial::set_shader_override(const Ref<Shader> &p_shader) {
	SET_IF_DIFF(_shader_override, p_shader);
	LOG(INFO, "Setting override shader");
	_update_shader();
}

void Terrain3DMaterial::set_buffer_shader_override_enabled(const bool p_enabled) {
	SET_IF_DIFF(_buffer_shader_override_enabled, p_enabled);
	LOG(INFO, "Enable buffer shader override: ", _buffer_shader_override_enabled);
	if (_buffer_shader_override_enabled && _buffer_shader_override.is_null()) {
		LOG(DEBUG, "Instantiating new _buffer_shader_override");
		_buffer_shader_override.instantiate();
	}
	_update_shader();
}

void Terrain3DMaterial::set_buffer_shader_override(const Ref<Shader> &p_shader) {
	SET_IF_DIFF(_buffer_shader_override, p_shader);
	LOG(INFO, "Setting buffer override shader");
	_update_shader();
}

void Terrain3DMaterial::set_shader_param(const StringName &p_name, const Variant &p_value) {
	LOG(INFO, "Setting shader parameter: ", p_name, " = ", p_value);
	if (p_name.begins_with("_") && _material.is_valid()) {
		RS->material_set_param(_material, p_name, p_value);
	} else {
		_set(p_name, p_value);
	}
}

Variant Terrain3DMaterial::get_shader_param(const StringName &p_name) const {
	LOG(INFO, "Getting shader parameter: ", p_name);
	Variant value;
	if (p_name.begins_with("_") && _material.is_valid()) {
		value = RS->material_get_param(_material, p_name);
	} else {
		_get(p_name, value);
	}
	return value;
}

void Terrain3DMaterial::set_output_albedo_enabled(const bool p_enabled) {
	SET_IF_DIFF(_output_albedo_enabled, p_enabled);
	LOG(INFO, "Enable PBR output albedo: ", _output_albedo_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_output_roughness_enabled(const bool p_enabled) {
	SET_IF_DIFF(_output_roughness_enabled, p_enabled);
	LOG(INFO, "Enable PBR output roughness: ", _output_roughness_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_output_specular_enabled(const bool p_enabled) {
	SET_IF_DIFF(_output_specular_enabled, p_enabled);
	LOG(INFO, "Enable PBR output specular: ", _output_specular_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_output_normal_map_enabled(const bool p_enabled) {
	SET_IF_DIFF(_output_normal_map_enabled, p_enabled);
	LOG(INFO, "Enable PBR output normal map: ", _output_normal_map_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_output_ambient_occlusion_enabled(const bool p_enabled) {
	SET_IF_DIFF(_output_ambient_occlusion_enabled, p_enabled);
	LOG(INFO, "Enable PBR output ambient occlusion: ", _output_ambient_occlusion_enabled);
	_update_shader();
}

void Terrain3DMaterial::set_show_region_grid(const bool p_enabled) {
	SET_IF_DIFF(_show_region_grid, p_enabled);
	LOG(INFO, "Enable show_region_grid: ", _show_region_grid);
	_update_shader();
}

void Terrain3DMaterial::set_show_instancer_grid(const bool p_enabled) {
	SET_IF_DIFF(_show_instancer_grid, p_enabled);
	LOG(INFO, "Enable show_instancer_grid: ", _show_instancer_grid);
	_update_shader();
}

void Terrain3DMaterial::set_show_vertex_grid(const bool p_enabled) {
	SET_IF_DIFF(_show_vertex_grid, p_enabled);
	LOG(INFO, "Enable show_vertex_grid: ", _show_vertex_grid);
	_update_shader();
}

void Terrain3DMaterial::set_show_contours(const bool p_enabled) {
	SET_IF_DIFF(_show_contours, p_enabled);
	LOG(INFO, "Enable show_contours: ", _show_contours);
	_update_shader();
}

void Terrain3DMaterial::set_show_slope(const bool p_enabled) {
	SET_IF_DIFF(_show_slope, p_enabled);
	LOG(INFO, "Enable show_slope: ", _show_slope);
	_update_shader();
}

void Terrain3DMaterial::set_show_navigation(const bool p_enabled) {
	SET_IF_DIFF(_show_navigation, p_enabled);
	LOG(INFO, "Enable show_navigation: ", _show_navigation);
	_update_shader();
}

void Terrain3DMaterial::set_show_checkered(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_checkered, p_enabled);
	LOG(INFO, "Enable set_show_checkered: ", _debug_view_checkered);
	_update_shader();
}

void Terrain3DMaterial::set_show_grey(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_grey, p_enabled);
	LOG(INFO, "Enable show_grey: ", _debug_view_grey);
	_update_shader();
}

void Terrain3DMaterial::set_show_heightmap(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_heightmap, p_enabled);
	LOG(INFO, "Enable show_heightmap: ", _debug_view_heightmap);
	_update_shader();
}

void Terrain3DMaterial::set_show_jaggedness(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_jaggedness, p_enabled);
	LOG(INFO, "Enable show_jaggedness: ", _debug_view_jaggedness);
	_update_shader();
}

void Terrain3DMaterial::set_show_autoshader(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_autoshader, p_enabled);
	LOG(INFO, "Enable show_autoshader: ", _debug_view_autoshader);
	_update_shader();
}

void Terrain3DMaterial::set_show_control_texture(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_control_texture, p_enabled);
	LOG(INFO, "Enable show_control_texture: ", _debug_view_control_texture);
	_update_shader();
}

void Terrain3DMaterial::set_show_control_blend(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_control_blend, p_enabled);
	LOG(INFO, "Enable show_control_blend: ", _debug_view_control_blend);
	_update_shader();
}

void Terrain3DMaterial::set_show_control_angle(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_control_angle, p_enabled);
	LOG(INFO, "Enable show_control_angle: ", _debug_view_control_angle);
	_update_shader();
}

void Terrain3DMaterial::set_show_control_scale(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_control_scale, p_enabled);
	LOG(INFO, "Enable show_control_scale: ", _debug_view_control_scale);
	_update_shader();
}

void Terrain3DMaterial::set_show_colormap(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_colormap, p_enabled);
	LOG(INFO, "Enable show_colormap: ", _debug_view_colormap);
	_update_shader();
}

void Terrain3DMaterial::set_show_roughmap(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_roughmap, p_enabled);
	LOG(INFO, "Enable show_roughmap: ", _debug_view_roughmap);
	_update_shader();
}

void Terrain3DMaterial::set_show_displacement_buffer(const bool p_enabled) {
	SET_IF_DIFF(_debug_view_displacement_buffer, p_enabled);
	LOG(INFO, "Enable show_displacement_buffer: ", _debug_view_displacement_buffer);
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_albedo(const bool p_enabled) {
	SET_IF_DIFF(_pbr_view_tex_albedo, p_enabled);
	LOG(INFO, "Enable show_texture_albedo: ", _pbr_view_tex_albedo);
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_height(const bool p_enabled) {
	SET_IF_DIFF(_pbr_view_tex_height, p_enabled);
	LOG(INFO, "Enable show_texture_height: ", _pbr_view_tex_height);
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_normal(const bool p_enabled) {
	SET_IF_DIFF(_pbr_view_tex_normal, p_enabled);
	LOG(INFO, "Enable show_texture_normal: ", _pbr_view_tex_normal);
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_rough(const bool p_enabled) {
	SET_IF_DIFF(_pbr_view_tex_rough, p_enabled);
	LOG(INFO, "Enable show_texture_rough: ", _pbr_view_tex_rough);
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_ao(const bool p_enabled) {
	SET_IF_DIFF(_pbr_view_tex_ao, p_enabled);
	LOG(INFO, "Enable show_texture_ao: ", _pbr_view_tex_ao);
	_update_shader();
}

Error Terrain3DMaterial::save(const String &p_path) {
	if (p_path.is_empty() && get_path().is_empty()) {
		return ERR_FILE_NOT_FOUND;
	}
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path to ", p_path);
		take_over_path(p_path);
	}

	LOG(DEBUG, "Generating parameter list from shaders");
	// Get shader parameters from default shader (eg world_noise)
	Array param_list;
	param_list = RS->get_shader_parameter_list(get_shader_rid());
	// Get shader parameters from custom shader if present
	if (_shader_override.is_valid()) {
		param_list.append_array(_shader_override->get_shader_uniform_list(true));
	}
	if (_buffer_shader_override.is_valid()) {
		// Get shader parameters from custom buffer shader
		param_list.append_array(_buffer_shader_override->get_shader_uniform_list(true));
	} else {
		if (_terrain && _terrain->get_tessellation_level() > 0) {
			// Get shader parameters from default buffer shader
			param_list.append_array(RS->get_shader_parameter_list(get_buffer_shader_rid()));
		}
	}

	// Remove saved shader params that don't exist in either shader
	Array keys = _shader_params.keys();
	for (const StringName &name : keys) {
		bool has = false;
		for (const Dictionary &dict : param_list) {
			StringName dname = dict["name"];
			if (name == dname) {
				has = true;
				break;
			}
		}
		if (!has) {
			LOG(DEBUG, "'", name, "' not found in shader parameters. Removing from dictionary.");
			_shader_params.erase(name);
		}
	}

	// Save to external resource file if specified
	Error err = OK;
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save external file: " + path);
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		if (err == OK) {
			LOG(INFO, "File saved successfully: ", path);
		} else {
			LOG(ERROR, "Cannot save file: ", path, ". Error code: ", int(err), ". Look up @GlobalScope Error enum in the Godot docs");
		}
	}
	return err;
}
