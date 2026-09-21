// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DMaterial, part 1 of 4: the shader and the uniforms it is filled with.

// One of four files that define the resource. `_update_shader()` installs the compiled shader on
// the terrain's material and the displacement-buffer material, builds the noise and gradient
// textures the shader samples, and re-applies every saved parameter; the three uniform passes below
// it fill in the rest - `_update_vt_uniforms()` the virtual texture's samplers, block table, page
// fade and directory, `_update_uniforms()` the material's own flags and textures, and
// `_set_shader_parameters()` the dictionary form. `terrain_3d_material_shader.cpp` assembles the
// GLSL these uniforms belong to.
//
// The other halves: `terrain_3d_material_resource.cpp` (the lifecycle, the setters and save) and
// `terrain_3d_material_reflect.cpp` (the property list and the ClassDB bindings).

#include "logger.h"
#include "terrain_3d_material.h"
#include "terrain_3d_util.h"
#include "terrain_3d_virtual_texture.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/gradient.hpp>
#include <godot_cpp/classes/noise_texture2d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMaterial::_update_shader() {
	IS_INIT(VOID);
	LOG(INFO, "Updating shader");
	String code;
	// Terrain Material
	if (_shader_override_enabled && _shader_override.is_valid()) {
		if (_shader_override->get_code().is_empty()) {
			_shader_override->set_code(_generate_shader_code());
		}
		code = _shader_override->get_code();
		if (!_shader_override->is_connected("changed", callable_mp(this, &Terrain3DMaterial::_update_shader))) {
			LOG(DEBUG, "Connecting changed signal to _update_shader()");
			_shader_override->connect("changed", callable_mp(this, &Terrain3DMaterial::_update_shader));
		}
	} else {
		code = _generate_shader_code();
		if (!_needs_vt_shader()) {
			code = "#define TERRAIN_NO_VT\n" + code;
		}
	}
	_shader_uses_vt = _needs_vt_shader();
	_shader->set_code(_inject_editor_code(code));
	RS->material_set_shader(_material, get_shader_rid());
	LOG(DEBUG, "Material rid: ", _material, ", shader rid: ", get_shader_rid());

	// Displacement Buffer
	if (_terrain->get_tessellation_level() > 0) {
		if (_buffer_shader_override_enabled && _buffer_shader_override.is_valid()) {
			if (_buffer_shader_override->get_code().is_empty()) {
				_buffer_shader_override->set_code(_generate_buffer_shader_code());
			}
			code = _buffer_shader_override->get_code();
			if (!_buffer_shader_override->is_connected("changed", callable_mp(this, &Terrain3DMaterial::_update_shader))) {
				LOG(DEBUG, "Connecting changed signal to _update_shader()");
				_buffer_shader_override->connect("changed", callable_mp(this, &Terrain3DMaterial::_update_shader));
			}
		} else {
			code = _generate_buffer_shader_code();
		}
		_buffer_shader->set_code(code);
		RS->material_set_shader(_buffer_material, get_buffer_shader_rid());
		LOG(DEBUG, "Buffer Material rid: ", _buffer_material, ", buffer shader rid: ", get_buffer_shader_rid());
	} else {
		_buffer_shader->set_code(String("shader_type spatial;"));
		RS->material_set_shader(_buffer_material, RID());
	}

	// Update custom shader params in RenderingServer
	{
		// Populate _active_params, which the loop below walks. The property list itself is
		// discarded: the function fills _active_params while it walks the shader's
		// parameters, and needs a list to push the entries it builds into.
		List<PropertyInfo> discarded;
		_get_property_list(&discarded);
		LOG(EXTREME, "_active_params: ", _active_params);
		Util::print_dict("_shader_params", _shader_params, EXTREME);
	}

	// Fetch saved shader parameters, converting textures to RIDs
	for (const StringName &param : _active_params) {
		Variant value = _shader_params[param];
		if (value.get_type() == Variant::OBJECT) {
			Ref<Texture> tex = value;
			if (tex.is_valid()) {
				RS->material_set_param(_material, param, tex->get_rid());
				RS->material_set_param(_buffer_material, param, tex->get_rid());
			} else {
				RS->material_set_param(_material, param, Variant());
				RS->material_set_param(_buffer_material, param, Variant());
			}
		} else {
			RS->material_set_param(_material, param, value);
			RS->material_set_param(_buffer_material, param, value);
		}
	}

	// Set specific shader parameters
	RS->material_set_param(_material, "_background_mode", _world_background);

	// If no noise texture, generate one
	if (_active_params.has("noise_texture") && RS->material_get_param(_material, "noise_texture").get_type() == Variant::NIL) {
		LOG(INFO, "Generating default noise_texture for shader");
		Ref<FastNoiseLite> fnoise;
		fnoise.instantiate();
		fnoise->set_noise_type(FastNoiseLite::TYPE_CELLULAR);
		fnoise->set_frequency(0.03f);
		fnoise->set_cellular_jitter(3.0f);
		fnoise->set_cellular_return_type(FastNoiseLite::RETURN_CELL_VALUE);
		fnoise->set_domain_warp_enabled(true);
		fnoise->set_domain_warp_type(FastNoiseLite::DOMAIN_WARP_SIMPLEX_REDUCED);
		fnoise->set_domain_warp_amplitude(50.f);
		fnoise->set_domain_warp_fractal_type(FastNoiseLite::DOMAIN_WARP_FRACTAL_INDEPENDENT);
		fnoise->set_domain_warp_fractal_lacunarity(1.5f);
		fnoise->set_domain_warp_fractal_gain(1.f);

		Ref<Gradient> curve;
		curve.instantiate();
		PackedFloat32Array pfa;
		pfa.push_back(0.2f);
		pfa.push_back(1.0f);
		curve->set_offsets(pfa);
		PackedColorArray pca;
		pca.push_back(Color(1.f, 1.f, 1.f, 1.f));
		pca.push_back(Color(0.f, 0.f, 0.f, 1.f));
		curve->set_colors(pca);

		Ref<NoiseTexture2D> noise_tex;
		noise_tex.instantiate();
		noise_tex->set_seamless(true);
		noise_tex->set_generate_mipmaps(true);
		noise_tex->set_noise(fnoise);
		noise_tex->set_color_ramp(curve);
		_set("noise_texture", noise_tex);
	}

	notify_property_list_changed();
}

void Terrain3DMaterial::_update_vt_uniforms(const RID &p_material) {
	// Surface virtual texture. The block table is layer indexed and padded to max_regions like
	// _region_locations. `(-1, -1)` is what the shader and the producer both mean by "no block for
	// this layer" (`block.x < 0.0` in main.glsl, and _prepare_vt_block_tables() fills that value).
	// The padding below is a bare `resize()`, which zero-fills: an entry the producer never wrote
	// reaches the shader as `(0, 0)`, which its test reads as block `(0, 0)`. That is reachable -
	// `_max_regions` is a material setting clamped to 64..1024 and the producer's table is sized by
	// the data's map capacity, so the two can differ - but filling the tail with `(-1, -1)` here is
	// deliberately *not* done in this pass: no test fails without it, and the one A/B run so far
	// associated the change with the `vt_format` flake instead of with a rendering defect. See
	// "The block table's padding" in docs/terrain_optimization_audit.md before changing it.
	const bool vt_on = !_terrain->is_vt_editor_preview_active() && _terrain->is_surface_vt_enabled() && _terrain->get_surface_vt() != nullptr &&
			_terrain->get_surface_vt()->is_initialized();
	Terrain3DVirtualTexture *vt = _terrain->get_surface_vt();
	PackedVector2Array padded_blocks;
	padded_blocks.resize(_max_regions);
	if (vt_on) {
		PackedVector2Array blocks = _terrain->get_surface_vt_blocks();
		for (int i = 0; i < MIN((int)blocks.size(), _max_regions); ++i) {
			padded_blocks[i] = blocks[i];
		}
	}
	RS->material_set_param(p_material, "_surface_vt_enabled", vt_on);
	RS->material_set_param(p_material, "_avt_sectors_enabled", _terrain->is_sector_avt());
	RS->material_set_param(p_material, "_avt_feedback", _terrain->get_avt_feedback());
	RS->material_set_param(p_material, "_avt_density_scale", _terrain->get_avt_density_scale());
	RID sector_directory = _terrain->get_avt_sector_directory();
	RS->material_set_param(p_material, "_avt_sector_directory", sector_directory.is_valid() ? sector_directory : _generated_dummy_2d.get_rid());
	// Page-arrival fade: one texel per physical slot, indexed by the slot the indirection
	// already decoded. A frame count of 0 is the shader's own early out, so an unbound texture
	// is still correct - but it must be a real one, or the sampler reads nothing.
	RID page_fade = _terrain->get_vt_page_fade_rid();
	RS->material_set_param(p_material, "_surface_vt_page_fade", page_fade.is_valid() ? page_fade : _generated_dummy_2d.get_rid());
	RS->material_set_param(p_material, "_surface_vt_page_fade_frames", _terrain->get_vt_page_fade_frames());
	// The near field's anisotropy, from the one function that owns the rule: the terrain's request
	// (or the viewport's filtering level when the setting is zero, which is its "auto") clamped by
	// the page gutter. The shader clamps by the same gutter as its own physical bound, so binding
	// the effective number here and reading `vt_anisotropy_effective` from the settings cannot
	// disagree. See docs/vt_sampling_review.md.
	Camera3D *camera = _terrain->get_camera();
	RS->material_set_param(p_material, "_surface_vt_anisotropy", _terrain->get_avt_anisotropy(camera));
	RS->material_set_param(p_material, "_avt_coverage_distance", _terrain->get_surface_vt_distance());
	RS->material_set_param(p_material, "_avt_base_block_size", float(_terrain->get_avt_base_block_size()));
	// The local mip chain's last level, from the one function the plan's depth also reads. The
	// shader clamps its `top` with it, so a chain cut shorter than the block size is one number and
	// not a second spelling of the setting.
	RS->material_set_param(p_material, "_avt_mip_level_cap", _terrain->get_avt_mip_level_cap());
	PackedFloat32Array avt_distances = _terrain->get_surface_vt_mip_distances();
	RS->material_set_param(p_material, "_avt_mip_distance_count", int(avt_distances.size()));
	avt_distances.resize(16);
	RS->material_set_param(p_material, "_avt_mip_distance", avt_distances);
	RS->material_set_param(p_material, "_avt_directory_mask", _terrain->get_avt_directory_mask());
	RS->material_set_param(p_material, "_avt_root_level", _terrain->get_avt_root_level());
	RS->material_set_param(p_material, "_surface_vt_blocks", padded_blocks);
	PackedFloat32Array block_sizes = _terrain->get_surface_vt_block_sizes();
	PackedFloat32Array padded_sizes;
	padded_sizes.resize(_max_regions);
	padded_sizes.fill(float(_terrain->get_surface_vt_pages_per_axis()));
	for (int i = 0; i < MIN(block_sizes.size(), padded_sizes.size()); i++) { padded_sizes[i] = block_sizes[i]; }
	RS->material_set_param(p_material, "_surface_vt_block_sizes", padded_sizes);
	Dictionary material_pages = _terrain->get_vt_material_textures();
	RID baked_albedo = material_pages.get("albedo_height", RID());
	RID baked_normal = material_pages.get("normal_roughness", RID());
	RID baked_params = material_pages.get("params", RID());
	// Encoding metadata is published in the same locked snapshot as these RIDs.
	RS->material_set_param(p_material, "_surface_normal_encoding", material_pages.get("normal_encoding", 0));
	RS->material_set_param(p_material, "_surface_params_encoded", material_pages.get("params_encoded", false));
	RS->material_set_param(p_material, "_surface_svt_normal_encoding", material_pages.get("svt_normal_encoding", 0));
	RS->material_set_param(p_material, "_surface_svt_params_encoded", material_pages.get("svt_params_encoded", false));
	// The far field's own set. AVT and SVT store the same page pool in independent formats,
	// so each tier samples the arrays it was produced into; a tier left uncompressed resolves
	// to the staging arrays, which is what lets one tier be compressed while the other is not.
	RID svt_albedo = material_pages.get("svt_albedo_height", RID());
	RID svt_normal = material_pages.get("svt_normal_roughness", RID());
	RID svt_params = material_pages.get("svt_params", RID());
	// The three channels are one set. The producer replaces all of them at once, but each
	// getter reads the published bundle under its own lock, so a rebuild between two of them
	// can hand back a valid albedo beside an empty normal or params. Binding that pair leaves
	// the material with a texture uniform that names no texture, which the renderer reports
	// once per draw as a missing material uniform set - so a set that is not complete is
	// treated as no pages at all and the dummy array serves every channel.
	const bool pages_valid = baked_albedo.is_valid() && baked_normal.is_valid() && baked_params.is_valid();
	const bool svt_pages_valid = pages_valid && svt_albedo.is_valid() && svt_normal.is_valid() && svt_params.is_valid();
	RS->material_set_param(p_material, "_surface_material_enabled", pages_valid && !_terrain->is_vt_editor_preview_active());
	// A fresh SVT has published addresses before its protected roots have material content.
	// Keep the live source evaluator visible during that short startup window instead of
	// presenting the diagnostic checker over the entire world. Once roots are verified ready,
	// strict VT misses become diagnostic again. AVT-only scenes retain their strict contract.
	// Only a SVT-owned startup may relax the global diagnostic. In a combined AVT/SVT
	// scene doing this globally would send pending near AVT pixels through the source array
	// and violate AVT's independent feedback contract.
	const bool svt_starting = _terrain->is_surface_svt_enabled() && !_terrain->is_surface_vt_enabled() &&
			!_terrain->is_svt_startup_ready();
	RS->material_set_param(p_material, "_surface_material_required", !_terrain->is_vt_editor_preview_active() &&
			!_terrain->is_vt_debug_direct_material() && !svt_starting &&
			(_terrain->is_surface_vt_enabled() || _terrain->is_surface_svt_enabled()));
	RS->material_set_param(p_material, "_surface_material_albedo", pages_valid ? baked_albedo : _generated_dummy.get_rid());
	RS->material_set_param(p_material, "_surface_material_normal", pages_valid ? baked_normal : _generated_dummy.get_rid());
	RS->material_set_param(p_material, "_surface_material_params", pages_valid ? baked_params : _generated_dummy.get_rid());
	RS->material_set_param(p_material, "_surface_svt_material_albedo", svt_pages_valid ? svt_albedo : _generated_dummy.get_rid());
	RS->material_set_param(p_material, "_surface_svt_material_normal", svt_pages_valid ? svt_normal : _generated_dummy.get_rid());
	RS->material_set_param(p_material, "_surface_svt_material_params", svt_pages_valid ? svt_params : _generated_dummy.get_rid());
	if (vt_on) {
		RS->material_set_param(p_material, "_surface_vt_region_size", _terrain->get_region_size());
		RS->material_set_param(p_material, "_surface_vt_page_size", vt->get_page_size());
		RS->material_set_param(p_material, "_surface_vt_page_border", vt->get_page_border());
		RS->material_set_param(p_material, "_surface_vt_pages_per_axis", _terrain->get_surface_vt_pages_per_axis());
		RS->material_set_param(p_material, "_surface_vt_max_local_mip",
				TerrainVT::log2_power_of_two(_terrain->get_surface_vt_pages_per_axis()));
		RS->material_set_param(p_material, "_surface_vt_indirection_size", vt->get_indirection_size());
		RS->material_set_param(p_material, "_surface_vt_indirection", vt->get_indirection_rid());
		RS->material_set_param(p_material, "_surface_vt_atlas", vt->get_atlas_rid());
	} else {
		RS->material_set_param(p_material, "_surface_vt_indirection", _generated_dummy_2d.get_rid());
		RS->material_set_param(p_material, "_surface_vt_atlas", _generated_dummy.get_rid());
	}

	// Far field (sparse virtual texture). World-space page grid, no block table: the
	// shader derives the page from the world position and the same centre offset the
	// CPU uses.
	const bool svt_on = !_terrain->is_vt_editor_preview_active() && _terrain->is_surface_svt_enabled() && _terrain->get_surface_svt() != nullptr &&
			_terrain->get_surface_svt()->is_initialized();
	Terrain3DVirtualTexture *svt = _terrain->get_surface_svt();
	RS->material_set_param(p_material, "_surface_svt_enabled", svt_on);
	// Published outside the `svt_on` branch: a uniform that is only written while the
	// view is up would keep whatever was bound last, and the shader reads it on every
	// fragment of every variant.
	RS->material_set_param(p_material, "_svt_feedback", _terrain->get_svt_feedback());
	if (svt_on) {
		RS->material_set_param(p_material, "_surface_svt_page_world", _terrain->get_surface_svt_page_world());
		RS->material_set_param(p_material, "_surface_svt_page_size", svt->get_page_size());
		RS->material_set_param(p_material, "_surface_svt_page_border", svt->get_page_border());
		RS->material_set_param(p_material, "_surface_svt_max_mip", svt->get_world_max_mip());
		// The distance -> level table, padded to the shader's fixed array size. The
		// demand pass resolves a page's level with this same table, which is what keeps
		// the produced level and the sampled level identical.
		PackedFloat32Array mip_distances;
		mip_distances.resize(Terrain3D::SVT_MIP_DISTANCE_COUNT);
		PackedFloat32Array configured_distances = _terrain->get_surface_svt_mip_distances();
		const int distance_count = MIN(int(configured_distances.size()), Terrain3D::SVT_MIP_DISTANCE_COUNT);
		for (int i = 0; i < Terrain3D::SVT_MIP_DISTANCE_COUNT; i++) {
			mip_distances[i] = distance_count > 0 ? configured_distances[MIN(i, distance_count - 1)] : 0.f;
		}
		RS->material_set_param(p_material, "_surface_svt_mip_distance", mip_distances);
		RS->material_set_param(p_material, "_surface_svt_mip_distance_count", distance_count);
		RS->material_set_param(p_material, "_surface_svt_indirection_size", svt->get_indirection_size());
		RS->material_set_param(p_material, "_surface_svt_indirection", svt->get_indirection_rid());
		RS->material_set_param(p_material, "_surface_svt_atlas", svt->get_atlas_rid());
	} else {
		RS->material_set_param(p_material, "_surface_svt_mip_distance_count", 0);
		RS->material_set_param(p_material, "_surface_svt_indirection", _generated_dummy_2d.get_rid());
		RS->material_set_param(p_material, "_surface_svt_atlas", _generated_dummy.get_rid());
	}

}

void Terrain3DMaterial::_update_uniforms(const RID &p_material, const uint32_t p_flags) {
	IS_DATA_INIT(VOID);
	LOG(EXTREME, "Updating uniforms in shader");

	Terrain3DData *data = _terrain->get_data();
	// The chunk -> layer map is a texture, not a uniform int array: a uniform array
	// big enough for a world past 32x32 chunks runs into the uniform buffer limit
	// (64x64 would be 16 KB, 128x128 64 KB). Reading it also avoids copying a
	// REGION_MAP_SIZE squared PackedInt32Array on every uniform update.
	RS->material_set_param(p_material, "_region_map", data->get_region_directory_rid());
	RS->material_set_param(p_material, "_region_map_size", Terrain3DData::REGION_MAP_SIZE);
	if (Terrain3D::debug_level >= EXTREME) {
		LOG(EXTREME, "Region directory: ", data->get_region_directory_rid(),
				", size: ", Terrain3DData::REGION_MAP_SIZE, ", valid: ", data->is_region_directory_valid());
	}

	// The shader indexes `_region_locations` by layer index, so this must be the
	// slot table (slot -> region location), not the dense region list: a region's
	// layer is now a stable slot that outlives unrelated add/remove. Free slots are
	// never addressed by the region map and keep the padding value.
	PackedVector2Array slot_locations = data->get_slot_locations();
	PackedVector2Array padded_locations;
	padded_locations.resize(_max_regions);
	for (int i = 0; i < MIN((int)slot_locations.size(), _max_regions); ++i) {
		padded_locations[i] = slot_locations[i];
	}
	RS->material_set_param(p_material, "_region_locations", padded_locations);

	if (p_material != _material || _shader_uses_vt) {
		_update_vt_uniforms(p_material);
	} else {
		// Preserve observable enable flags while avoiding page-table arrays and
		// bindings for the built-in shader variant that has no VT resources.
		RS->material_set_param(p_material, "_surface_vt_enabled", false);
		RS->material_set_param(p_material, "_surface_svt_enabled", false);
		RS->material_set_param(p_material, "_surface_material_enabled", false);
		RS->material_set_param(p_material, "_surface_material_required", false);
	}

	real_t region_size = real_t(_terrain->get_region_size());
	LOG(EXTREME, "Setting region size in material: ", region_size);
	RS->material_set_param(p_material, "_region_size", region_size);
	RS->material_set_param(p_material, "_region_texel_size", 1.0f / region_size);
	// The stored surface payload is region_size * surface_density squared, while the
	// array fallback stays at region_size. The shader scales the virtual texture's
	// texel lookups by this and leaves the array lookup in region texels.
	RS->material_set_param(p_material, "_surface_density", _terrain->get_surface_density());

	if (p_flags & REGION_ARRAYS) {
		if (data->get_region_count() > 0) {
			RS->material_set_param(p_material, "_height_maps", data->get_height_maps_rid());
			RS->material_set_param(p_material, "_control_maps", data->get_control_maps_rid());
			RS->material_set_param(p_material, "_color_maps", data->get_color_maps_rid());
			RS->material_set_param(p_material, "_surface_maps", data->get_surface_maps_rid());
			LOG(EXTREME, "Height map RID: ", data->get_height_maps_rid());
			LOG(EXTREME, "Control map RID: ", data->get_control_maps_rid());
			LOG(EXTREME, "Color map RID: ", data->get_color_maps_rid());
			LOG(EXTREME, "Surface map RID: ", data->get_surface_maps_rid());
		} else {
			// Send dummy texture array to stop compatibility error spam
			RS->material_set_param(p_material, "_height_maps", _generated_dummy.get_rid());
			RS->material_set_param(p_material, "_control_maps", _generated_dummy.get_rid());
			RS->material_set_param(p_material, "_color_maps", _generated_dummy.get_rid());
			RS->material_set_param(p_material, "_surface_maps", _generated_dummy.get_rid());
		}
	}

	real_t spacing = _terrain->get_vertex_spacing();
	LOG(EXTREME, "Setting vertex spacing in material: ", spacing);
	RS->material_set_param(p_material, "_vertex_spacing", spacing);
	RS->material_set_param(p_material, "_vertex_density", 1.0f / spacing);

	real_t mesh_size = real_t(_terrain->get_mesh_size());
	RS->material_set_param(p_material, "_mesh_size", mesh_size);

	real_t tessellation_level = real_t(_terrain->get_tessellation_level());
	real_t subdiv = pow(2.f, tessellation_level);
	RS->material_set_param(p_material, "_subdiv", subdiv);
	RS->material_set_param(p_material, "_tessellation_level", tessellation_level);
	RS->material_set_param(p_material, "_displacement_scale", _displacement_scale);
	RS->material_set_param(p_material, "_displacement_sharpness", _displacement_sharpness);

	Ref<Terrain3DAssets> asset_list = _terrain->get_assets();
	LOG(INFO, "Updating texture arrays in shader");
	if (asset_list.is_null() || !asset_list->is_initialized()) {
		LOG(INFO, "Asset list is not initialized");
		return;
	}

	if (asset_list->get_generated_array_size() > 0) {
		if (p_flags & TEXTURE_ARRAYS) {
			RS->material_set_param(p_material, "_texture_array_albedo", asset_list->get_albedo_array_rid());
			RS->material_set_param(p_material, "_texture_array_normal", asset_list->get_normal_array_rid());
		}
		set_show_checkered(false);
		LOG(DEBUG, "Texture count >0: ", asset_list->get_generated_array_size(), ", disabling checkered view");
	} else {
		// Send dummy texture array to stop compatibility error spam
		RS->material_set_param(p_material, "_texture_array_albedo", _generated_dummy.get_rid());
		RS->material_set_param(p_material, "_texture_array_normal", _generated_dummy.get_rid());

		// Enable checkered view if texture_count is 0, disable if not
		if (_debug_view_checkered == false) {
			set_show_checkered(true);
			LOG(DEBUG, "No textures, enabling checkered view");
		}
	}

	RS->material_set_param(p_material, "_texture_color_array", asset_list->get_texture_colors());
	RS->material_set_param(p_material, "_texture_normal_depth_array", asset_list->get_texture_normal_depths());
	RS->material_set_param(p_material, "_texture_ao_strength_array", asset_list->get_texture_ao_strengths());
	RS->material_set_param(p_material, "_texture_ao_affect_array", asset_list->get_texture_ao_light_affects());
	RS->material_set_param(p_material, "_texture_roughness_mod_array", asset_list->get_texture_roughness_mods());
	RS->material_set_param(p_material, "_texture_uv_scale_array", asset_list->get_texture_uv_scales());
	RS->material_set_param(p_material, "_texture_detile_array", asset_list->get_texture_detiles());
	RS->material_set_param(p_material, "_texture_displacement_array", asset_list->get_texture_displacements());
	RS->material_set_param(p_material, "_texture_slope_params_array", asset_list->get_texture_slope_params());
}

void Terrain3DMaterial::_set_shader_parameters(const Dictionary &p_dict) {
	SET_IF_DIFF(_shader_params, p_dict);
	LOG(INFO, "Setting shader params dictionary: ", p_dict.size());
}
