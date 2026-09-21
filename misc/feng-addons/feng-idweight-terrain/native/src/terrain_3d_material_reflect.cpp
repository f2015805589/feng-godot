// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DMaterial, part 3 of 4: the property reflection and the ClassDB bindings.

// One of four files that define the resource. `_get_property_list()` is what the inspector reads:
// it turns the active shader's uniform list into grouped properties, drops the private `_`-prefixed
// ones, de-duplicates the displacement buffer's entries and rebuilds `_active_params`, which is the
// set of names `_set`/`_get` will accept. The revert hooks and `_bind_methods()` are here for the
// same reason: this is the file that says what the class looks like from outside.
//
// Note for the next reader: `_get_property_list()` and `save()` assemble overlapping parameter
// lists by *different* rules - the list requires `_shader_override_enabled` and replaces the default
// shader's parameters with the override's, while `save()` appends a *valid* override's parameters to
// the default ones whatever the flag says. The two disagree about what an override contributes; it
// is recorded in docs/terrain_optimization_audit.md rather than changed, because no test fails on it.
//
// The other halves: `terrain_3d_material.cpp` (the shader and its uniforms) and
// `terrain_3d_material_resource.cpp` (the lifecycle, the setters and save).

#include "logger.h"
#include "terrain_3d_material.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/rendering_server.hpp>

///////////////////////////
// Protected Functions
///////////////////////////

// Add shader uniforms to properties. Hides uniforms that begin with _
void Terrain3DMaterial::_get_property_list(List<PropertyInfo> *p_list) const {
	Resource::_get_property_list(p_list);
	IS_INIT(VOID);
	Array param_list;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		// Get shader parameters from custom shader
		param_list = _shader_override->get_shader_uniform_list(true);
	} else {
		// Get shader parameters from default shader (eg world_noise)
		param_list = RS->get_shader_parameter_list(get_shader_rid());
	}
	int buffer_param = param_list.size();
	if (_buffer_shader_override_enabled && _buffer_shader_override.is_valid()) {
		// Get shader parameters from custom shader
		param_list.append_array(_buffer_shader_override->get_shader_uniform_list(true));
	} else {
		if (_terrain->get_tessellation_level() > 0) {
			// Get shader parameters from default shader (eg world_noise)
			param_list.append_array(RS->get_shader_parameter_list(get_buffer_shader_rid()));
		}
	}

	TypedArray<StringName> new_active_params;
	Dictionary grouped_params;
	StringName current_group = StringName("shader_uniforms.general");
	grouped_params[current_group] = Array();
	for (int i = 0; i < param_list.size(); i++) {
		Dictionary dict = param_list[i];
		StringName name = dict["name"];

		// An empty name indicates a group being closed, reset to the "general" group.
		if (name.is_empty() && i < buffer_param) {
			current_group = StringName("shader_uniforms.general");
		}

		// Filter out private uniforms that start with _ and nulls
		if (!name.begins_with("_") && !name.is_empty()) {
			uint64_t use = dict["usage"];
			if (use == PROPERTY_USAGE_GROUP) {
				PackedStringArray split_name = name.split("::");
				dict["name"] = split_name[MAX(split_name.size() - 1, 0)].capitalize();
				// Ensure sub groups are batched with their parent group
				current_group = split_name[0].capitalize();
				dict["usage"] = name.contains("::") ? PROPERTY_USAGE_SUBGROUP : PROPERTY_USAGE_GROUP;
			} else {
				// Filter out duplicate non-groups entries from displacement buffer shader
				if (new_active_params.has(name)) {
					continue;
				}
				dict["usage"] = PROPERTY_USAGE_EDITOR;
			}
			// Filter out extraneous parameters from the inspector if they are not present in the terrain shader.
			if (i >= buffer_param && (!new_active_params.has(name) && use != PROPERTY_USAGE_GROUP) && !current_group.contains("Displacement")) {
				LOG(INFO, "Displacement buffer has active parameter: ", name, " not present in terrain shader.");
				continue;
			}
			// Write dict to grouped arrays to ensure property list groups are populated contigiously.
			Array group;
			if (grouped_params.has(current_group)) {
				group = grouped_params[current_group];
			} else {
				grouped_params[current_group] = Array();
				group = grouped_params[current_group];
			}
			group.push_back(dict);
			grouped_params[current_group] = group;

			// Populate list of public parameters for current shader
			new_active_params.push_back(name);

			// Store this param in a dictionary that is saved in the resource file
			// Initially set with default value
			// Also acts as a cache for _get
			// Property usage above set to EDITOR so it won't be redundantly saved,
			// which won't get loaded since there is no bound property.
			if (!_shader_params.has(name)) {
				_property_get_revert(name, _shader_params[name]);
			}
		}
	}
	_active_params = new_active_params;

	// Populate Godot's property list
	Array keys = grouped_params.keys();
	for (int i = 0; i < keys.size(); i++) {
		StringName key = keys[i];
		Array group = grouped_params[key];
		for (int k = 0; k < group.size(); k++) {
			Dictionary dict = group[k];
			PropertyInfo pi;
			pi.class_name = dict["class_name"];
			pi.name = dict["name"];
			pi.type = Variant::Type(int(dict["type"]));
			pi.hint = dict["hint"];
			pi.hint_string = dict["hint_string"];
			pi.usage = dict["usage"];
			p_list->push_back(pi);
		}
	}
	return;
}

// Flag uniforms with non-default values
// This is called 10x more than the others, so be efficient
bool Terrain3DMaterial::_property_can_revert(const StringName &p_name) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_property_can_revert(p_name));
	Variant default_value = RS->shader_get_parameter_default(get_shader_rid(), p_name);
	Variant current_value = RS->material_get_param(_material, p_name);
	return default_value != current_value;
}

// Provide uniform default values in r_property
bool Terrain3DMaterial::_property_get_revert(const StringName &p_name, Variant &r_property) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_property_get_revert(p_name, r_property));
	Variant prop = RS->shader_get_parameter_default(get_shader_rid(), p_name);
	// If the default is nil, check the buffer shader for the default value.
	if (prop.get_type() == Variant::NIL) {
		prop = RS->shader_get_parameter_default(get_buffer_shader_rid(), p_name);
	}
	r_property = prop;
	return true;
}

bool Terrain3DMaterial::_set(const StringName &p_name, const Variant &p_property) {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_set(p_name, p_property));
	if (p_property.get_type() == Variant::NIL) {
		RS->material_set_param(_material, p_name, Variant());
		_shader_params.erase(p_name);
		return true;
	}

	// If value is an object, assume a Texture. RS only wants RIDs, but
	// Inspector wants the object, so set the RID and save the latter for _get
	if (p_property.get_type() == Variant::OBJECT) {
		Ref<Texture> tex = p_property;
		if (tex.is_valid()) {
			_shader_params[p_name] = tex;
			RS->material_set_param(_material, p_name, tex->get_rid());
			RS->material_set_param(_buffer_material, p_name, tex->get_rid());
		} else {
			RS->material_set_param(_material, p_name, Variant());
			RS->material_set_param(_buffer_material, p_name, Variant());
		}
	} else {
		_shader_params[p_name] = p_property;
		RS->material_set_param(_material, p_name, p_property);
		RS->material_set_param(_buffer_material, p_name, p_property);
	}
	return true;
}

// This is called 200x more than the others, every second the material is open in the
// inspector, so be efficient
bool Terrain3DMaterial::_get(const StringName &p_name, Variant &r_property) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_get(p_name, r_property));
	r_property = RS->material_get_param(_material, p_name);
	// Material server only has RIDs, but inspector needs objects for things like Textures
	// So if its an RID, return the object
	if (r_property.get_type() == Variant::RID && _shader_params.has(p_name)) {
		r_property = _shader_params[p_name];
	}
	if (r_property.get_type() == Variant::NIL) {
		r_property = RS->shader_get_parameter_default(get_shader_rid(), p_name);
	}
	return true;
}

void Terrain3DMaterial::_bind_methods() {
	BIND_ENUM_CONSTANT(NONE);
	BIND_ENUM_CONSTANT(FLAT);
	BIND_ENUM_CONSTANT(NOISE);
	BIND_ENUM_CONSTANT(MAX_REGIONS_64);
	BIND_ENUM_CONSTANT(MAX_REGIONS_128);
	BIND_ENUM_CONSTANT(MAX_REGIONS_256);
	BIND_ENUM_CONSTANT(MAX_REGIONS_512);
	BIND_ENUM_CONSTANT(MAX_REGIONS_1024);
	BIND_ENUM_CONSTANT(LINEAR_ANISOTROPIC);
	BIND_ENUM_CONSTANT(LINEAR);
	BIND_ENUM_CONSTANT(NEAREST_ANISOTROPIC);
	BIND_ENUM_CONSTANT(NEAREST);
	BIND_ENUM_CONSTANT(UNIFORMS_ONLY);
	BIND_ENUM_CONSTANT(TEXTURE_ARRAYS);
	BIND_ENUM_CONSTANT(REGION_ARRAYS);
	BIND_ENUM_CONSTANT(UPDATE_ARRAYS);
	BIND_ENUM_CONSTANT(FULL_REBUILD);

	// Private
	ClassDB::bind_method(D_METHOD("_set_shader_parameters", "dict"), &Terrain3DMaterial::_set_shader_parameters);
	ClassDB::bind_method(D_METHOD("_get_shader_parameters"), &Terrain3DMaterial::_get_shader_parameters);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_shader_parameters", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "_set_shader_parameters", "_get_shader_parameters");

	// Public
	ClassDB::bind_method(D_METHOD("update", "flags"), &Terrain3DMaterial::update, DEFVAL(Terrain3DMaterial::UNIFORMS_ONLY));
	ClassDB::bind_method(D_METHOD("get_material_rid"), &Terrain3DMaterial::get_material_rid);
	ClassDB::bind_method(D_METHOD("get_shader_rid"), &Terrain3DMaterial::get_shader_rid);
	ClassDB::bind_method(D_METHOD("get_buffer_material_rid"), &Terrain3DMaterial::get_buffer_material_rid);
	ClassDB::bind_method(D_METHOD("get_buffer_shader_rid"), &Terrain3DMaterial::get_buffer_shader_rid);

	ClassDB::bind_method(D_METHOD("set_world_background", "background"), &Terrain3DMaterial::set_world_background);
	ClassDB::bind_method(D_METHOD("get_world_background"), &Terrain3DMaterial::get_world_background);
	ClassDB::bind_method(D_METHOD("set_texture_filtering", "filtering"), &Terrain3DMaterial::set_texture_filtering);
	ClassDB::bind_method(D_METHOD("get_texture_filtering"), &Terrain3DMaterial::get_texture_filtering);
	ClassDB::bind_method(D_METHOD("set_auto_shader_enabled", "enabled"), &Terrain3DMaterial::set_auto_shader_enabled);
	ClassDB::bind_method(D_METHOD("get_auto_shader_enabled"), &Terrain3DMaterial::get_auto_shader_enabled);
	ClassDB::bind_method(D_METHOD("set_dual_scaling_enabled", "enabled"), &Terrain3DMaterial::set_dual_scaling_enabled);
	ClassDB::bind_method(D_METHOD("get_dual_scaling_enabled"), &Terrain3DMaterial::get_dual_scaling_enabled);
	ClassDB::bind_method(D_METHOD("set_macro_variation_enabled", "enabled"), &Terrain3DMaterial::set_macro_variation_enabled);
	ClassDB::bind_method(D_METHOD("get_macro_variation_enabled"), &Terrain3DMaterial::get_macro_variation_enabled);
	ClassDB::bind_method(D_METHOD("set_projection_enabled", "enabled"), &Terrain3DMaterial::set_projection_enabled);
	ClassDB::bind_method(D_METHOD("get_projection_enabled"), &Terrain3DMaterial::get_projection_enabled);
	ClassDB::bind_method(D_METHOD("set_max_regions", "count"), &Terrain3DMaterial::set_max_regions);
	ClassDB::bind_method(D_METHOD("get_max_regions"), &Terrain3DMaterial::get_max_regions);

	ClassDB::bind_method(D_METHOD("set_shader_override_enabled", "enabled"), &Terrain3DMaterial::set_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DMaterial::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_buffer_shader_override_enabled", "enabled"), &Terrain3DMaterial::set_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("is_buffer_shader_override_enabled"), &Terrain3DMaterial::is_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override", "shader"), &Terrain3DMaterial::set_buffer_shader_override);
	ClassDB::bind_method(D_METHOD("get_buffer_shader_override"), &Terrain3DMaterial::get_buffer_shader_override);
	ClassDB::bind_method(D_METHOD("set_displacement_scale", "scale"), &Terrain3DMaterial::set_displacement_scale);
	ClassDB::bind_method(D_METHOD("get_displacement_scale"), &Terrain3DMaterial::get_displacement_scale);
	ClassDB::bind_method(D_METHOD("set_displacement_sharpness", "sharpness"), &Terrain3DMaterial::set_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("get_displacement_sharpness"), &Terrain3DMaterial::get_displacement_sharpness);

	ClassDB::bind_method(D_METHOD("set_shader_param", "name", "value"), &Terrain3DMaterial::set_shader_param);
	ClassDB::bind_method(D_METHOD("get_shader_param", "name"), &Terrain3DMaterial::get_shader_param);

	// PBR Material Output
	ClassDB::bind_method(D_METHOD("set_output_albedo_enabled", "enabled"), &Terrain3DMaterial::set_output_albedo_enabled);
	ClassDB::bind_method(D_METHOD("get_output_albedo_enabled"), &Terrain3DMaterial::get_output_albedo_enabled);
	ClassDB::bind_method(D_METHOD("set_output_roughness_enabled", "enabled"), &Terrain3DMaterial::set_output_roughness_enabled);
	ClassDB::bind_method(D_METHOD("get_output_roughness_enabled"), &Terrain3DMaterial::get_output_roughness_enabled);
	ClassDB::bind_method(D_METHOD("set_output_specular_enabled", "enabled"), &Terrain3DMaterial::set_output_specular_enabled);
	ClassDB::bind_method(D_METHOD("get_output_specular_enabled"), &Terrain3DMaterial::get_output_specular_enabled);
	ClassDB::bind_method(D_METHOD("set_output_normal_map_enabled", "enabled"), &Terrain3DMaterial::set_output_normal_map_enabled);
	ClassDB::bind_method(D_METHOD("get_output_normal_map_enabled"), &Terrain3DMaterial::get_output_normal_map_enabled);
	ClassDB::bind_method(D_METHOD("set_output_ambient_occlusion_enabled", "enabled"), &Terrain3DMaterial::set_output_ambient_occlusion_enabled);
	ClassDB::bind_method(D_METHOD("get_output_ambient_occlusion_enabled"), &Terrain3DMaterial::get_output_ambient_occlusion_enabled);

	// Overlays
	ClassDB::bind_method(D_METHOD("set_show_region_grid", "enabled"), &Terrain3DMaterial::set_show_region_grid);
	ClassDB::bind_method(D_METHOD("get_show_region_grid"), &Terrain3DMaterial::get_show_region_grid);
	ClassDB::bind_method(D_METHOD("set_show_instancer_grid", "enabled"), &Terrain3DMaterial::set_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("get_show_instancer_grid"), &Terrain3DMaterial::get_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3DMaterial::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3DMaterial::get_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("set_show_contours", "enabled"), &Terrain3DMaterial::set_show_contours);
	ClassDB::bind_method(D_METHOD("get_show_contours"), &Terrain3DMaterial::get_show_contours);
	ClassDB::bind_method(D_METHOD("set_show_slope", "enabled"), &Terrain3DMaterial::set_show_slope);
	ClassDB::bind_method(D_METHOD("get_show_slope"), &Terrain3DMaterial::get_show_slope);
	ClassDB::bind_method(D_METHOD("set_show_navigation", "enabled"), &Terrain3DMaterial::set_show_navigation);
	ClassDB::bind_method(D_METHOD("get_show_navigation"), &Terrain3DMaterial::get_show_navigation);

	// Debug Views
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3DMaterial::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3DMaterial::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3DMaterial::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3DMaterial::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3DMaterial::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3DMaterial::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_jaggedness", "enabled"), &Terrain3DMaterial::set_show_jaggedness);
	ClassDB::bind_method(D_METHOD("get_show_jaggedness"), &Terrain3DMaterial::get_show_jaggedness);
	ClassDB::bind_method(D_METHOD("set_show_autoshader", "enabled"), &Terrain3DMaterial::set_show_autoshader);
	ClassDB::bind_method(D_METHOD("get_show_autoshader"), &Terrain3DMaterial::get_show_autoshader);
	ClassDB::bind_method(D_METHOD("set_show_control_texture", "enabled"), &Terrain3DMaterial::set_show_control_texture);
	ClassDB::bind_method(D_METHOD("get_show_control_texture"), &Terrain3DMaterial::get_show_control_texture);
	ClassDB::bind_method(D_METHOD("set_show_control_blend", "enabled"), &Terrain3DMaterial::set_show_control_blend);
	ClassDB::bind_method(D_METHOD("get_show_control_blend"), &Terrain3DMaterial::get_show_control_blend);
	ClassDB::bind_method(D_METHOD("set_show_control_angle", "enabled"), &Terrain3DMaterial::set_show_control_angle);
	ClassDB::bind_method(D_METHOD("get_show_control_angle"), &Terrain3DMaterial::get_show_control_angle);
	ClassDB::bind_method(D_METHOD("set_show_control_scale", "enabled"), &Terrain3DMaterial::set_show_control_scale);
	ClassDB::bind_method(D_METHOD("get_show_control_scale"), &Terrain3DMaterial::get_show_control_scale);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3DMaterial::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3DMaterial::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3DMaterial::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3DMaterial::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_displacement_buffer", "enabled"), &Terrain3DMaterial::set_show_displacement_buffer);
	ClassDB::bind_method(D_METHOD("get_show_displacement_buffer"), &Terrain3DMaterial::get_show_displacement_buffer);

	// PBR Debug Views
	ClassDB::bind_method(D_METHOD("set_show_texture_albedo", "enabled"), &Terrain3DMaterial::set_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("get_show_texture_albedo"), &Terrain3DMaterial::get_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3DMaterial::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3DMaterial::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3DMaterial::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3DMaterial::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3DMaterial::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3DMaterial::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_texture_ao", "enabled"), &Terrain3DMaterial::set_show_texture_ao);
	ClassDB::bind_method(D_METHOD("get_show_texture_ao"), &Terrain3DMaterial::get_show_texture_ao);

	ClassDB::bind_method(D_METHOD("save", "path"), &Terrain3DMaterial::save, DEFVAL(""));

	// These must be different from the names of uniform groups
	ADD_PROPERTY(PropertyInfo(Variant::INT, "world_background", PROPERTY_HINT_ENUM, "None,Flat,Noise"), "set_world_background", "get_world_background");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "texture_filtering", PROPERTY_HINT_ENUM, "Linear Anisotropic,Linear,Nearest Anisotropic,Nearest"), "set_texture_filtering", "get_texture_filtering");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_shader_enabled"), "set_auto_shader_enabled", "get_auto_shader_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "dual_scaling_enabled", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_dual_scaling_enabled", "get_dual_scaling_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "macro_variation_enabled"), "set_macro_variation_enabled", "get_macro_variation_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "projection_enabled"), "set_projection_enabled", "get_projection_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_regions", PROPERTY_HINT_ENUM, "64:64,128:128,256:256,512:512,1024:1024"), "set_max_regions", "get_max_regions");

	ADD_GROUP("PBR Output", "output_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "output_albedo"), "set_output_albedo_enabled", "get_output_albedo_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "output_roughness"), "set_output_roughness_enabled", "get_output_roughness_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "output_specular"), "set_output_specular_enabled", "get_output_specular_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "output_normal_map"), "set_output_normal_map_enabled", "get_output_normal_map_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "output_ambient_occlusion"), "set_output_ambient_occlusion_enabled", "get_output_ambient_occlusion_enabled");

	ADD_GROUP("Custom Shader", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled"), "set_shader_override_enabled", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

	// Hidden in Material, aliased in Terrain3D
	//ADD_GROUP("Overlays", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_region_grid", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_region_grid", "get_show_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_instancer_grid", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_instancer_grid", "get_show_instancer_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_vertex_grid", "get_show_vertex_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_contours", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_contours", "get_show_contours");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_slope", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_slope", "get_show_slope");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_navigation", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_navigation", "get_show_navigation");

	// Below here properties are hidden in Material, aliased in Terrain3D

	// Displacement settings
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_scale", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_displacement_scale", "get_displacement_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_sharpness", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_displacement_sharpness", "get_displacement_sharpness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "buffer_shader_override_enabled", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_buffer_shader_override_enabled", "is_buffer_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "buffer_shader_override", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_buffer_shader_override", "get_buffer_shader_override");

	//ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_jaggedness", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_jaggedness", "get_show_jaggedness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_autoshader", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_autoshader", "get_show_autoshader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_texture", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_control_texture", "get_show_control_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_blend", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_control_blend", "get_show_control_blend");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_angle", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_control_angle", "get_show_control_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_scale", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_control_scale", "get_show_control_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_displacement_buffer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_displacement_buffer", "get_show_displacement_buffer");

	//ADD_SUBGROUP("PBR Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_albedo", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_texture_albedo", "get_show_texture_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_ao", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NO_EDITOR), "set_show_texture_ao", "get_show_texture_ao");
}
