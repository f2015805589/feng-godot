// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DMaterial, part 4 of 4: the shader source pipeline.
//
// One of four files that define the resource: this one turns the shader inserts
// (auto_shader, backgrounds, editor_functions, debug views), the material's own snippets
// and the editor/debug view selection into the final GLSL the material compiles, including
// the comment stripper and the VT-sampler decision. The resource itself is the other three:
// `terrain_3d_material.cpp` (the shader and its uniforms), `terrain_3d_material_resource.cpp`
// (the lifecycle, the property setters and save) and `terrain_3d_material_reflect.cpp` (the
// property list and the ClassDB bindings).
//
// This file includes what it uses, not the family's old shared block: that block named Engine,
// FastNoiseLite, Gradient, ImageTexture, NoiseTexture2D, RenderingServer, ResourceSaver,
// terrain_3d_util.h and terrain_3d_virtual_texture.h, none of which appears in its 550 lines.
// The two RegEx headers are the reason they were ever in the block at all - the comment stripper
// is the only RegEx user in the family.

#include "terrain_3d.h"
#include <godot_cpp/classes/reg_ex.hpp>
#include <godot_cpp/classes/reg_ex_match.hpp>
#include "logger.h"
#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_material.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMaterial::_preload_shaders() {
	// Preprocessor loading of external shader inserts
	_parse_shader(
#include "shaders/auto_shader.glsl"
			, "auto_shader");
	_parse_shader(
#include "shaders/backgrounds.glsl"
			, "backgrounds");
	_parse_shader(
#include "shaders/editor_functions.glsl"
			, "editor_functions");
// Debug views are only needed by editor/debug extension builds. Keeping the include
// behind DEBUG_ENABLED removes the raw GLSL (and its parsed snippets) from release
// binaries; _apply_inserts still omits DEBUG_* markers from generated base shaders.
#ifdef DEBUG_ENABLED
	_parse_shader(
#include "shaders/debug_views.glsl"
			, "debug_views");
#endif
	_parse_shader(
#include "shaders/displacement.glsl"
			, "displacement");
	_parse_shader(
#include "shaders/macro_variation.glsl"
			, "macro_variation");
	_parse_shader(
#include "shaders/max_regions.glsl"
			, "max_regions");
	_parse_shader(
#include "shaders/overlays.glsl"
			, "overlays");
	_parse_shader(
#include "shaders/pbr_views.glsl"
			, "pbr_views");
	_parse_shader(
#include "shaders/projection.glsl"
			, "projection");
	_parse_shader(
#include "shaders/samplers.glsl"
			, "samplers");
	_parse_shader(
#include "shaders/idweight_r16.glsl"
			, "idweight_r16");

	// Load main code
	_shader_code["main"] = String(
#include "shaders/main.glsl"
	);
	_shader_code["displacement_buffer"] = String(
#include "shaders/displacement_buffer.glsl"
	);

	if (Terrain3D::debug_level >= DEBUG) {
		Array keys = _shader_code.keys();
		for (const StringName &key : keys) {
			LOG(DEBUG, "Loaded shader insert: ", key);
		}
	}
}

/**
 *	All `//INSERT: ID` blocks in p_shader are loaded into the DB _shader_code
 */
void Terrain3DMaterial::_parse_shader(const String &p_shader, const String &p_name) {
	if (p_name.is_empty()) {
		LOG(ERROR, "No dictionary key for saving shader snippets specified");
		return;
	}
	PackedStringArray parsed = p_shader.split("//INSERT:");
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			_shader_code[p_name] = parsed[0];
		} else {
			// There is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();
			// Process the insert
			if (!id.is_empty() && !segment[1].is_empty()) {
				_shader_code[id] = segment[1];
			}
		}
	}
	return;
}

/**
 *	`//INSERT: ID` blocks in p_shader are replaced by the entry in the DB
 *	returns a shader string with inserts applied
 *  Skips `EDITOR_*` and `DEBUG_*` inserts
 */
String Terrain3DMaterial::_apply_inserts(const String &p_shader, const Array &p_excludes) const {
	PackedStringArray parsed = p_shader.split("//INSERT:");
	String shader;
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			shader = parsed[0];
		} else {
			// There is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();

			// Process the insert
			if (!id.is_empty() && !p_excludes.has(id) && _shader_code.has(id)) {
				if (!id.begins_with("DEBUG_") && !id.begins_with("EDITOR_")) {
					String str = _shader_code[id];
					shader += str;
				}
			}
			shader += segment[1];
		}
	}
	return shader;
}

void Terrain3DMaterial::_append_layout_excludes(Array &excludes) const {
	switch (_max_regions) {
		case MAX_REGIONS_64:
			excludes.push_back("MAX_REGIONS_128");
			excludes.push_back("MAX_REGIONS_256");
			excludes.push_back("MAX_REGIONS_512");
			excludes.push_back("MAX_REGIONS_1024");
			break;
		case MAX_REGIONS_128:
			excludes.push_back("MAX_REGIONS_64");
			excludes.push_back("MAX_REGIONS_256");
			excludes.push_back("MAX_REGIONS_512");
			excludes.push_back("MAX_REGIONS_1024");
			break;
		case MAX_REGIONS_256:
			excludes.push_back("MAX_REGIONS_64");
			excludes.push_back("MAX_REGIONS_128");
			excludes.push_back("MAX_REGIONS_512");
			excludes.push_back("MAX_REGIONS_1024");
			break;
		case MAX_REGIONS_512:
			excludes.push_back("MAX_REGIONS_64");
			excludes.push_back("MAX_REGIONS_128");
			excludes.push_back("MAX_REGIONS_256");
			excludes.push_back("MAX_REGIONS_1024");
			break;
		case MAX_REGIONS_1024:
			excludes.push_back("MAX_REGIONS_64");
			excludes.push_back("MAX_REGIONS_128");
			excludes.push_back("MAX_REGIONS_256");
			excludes.push_back("MAX_REGIONS_512");
			break;
	}
	switch (_texture_filtering) {
		case LINEAR_ANISOTROPIC:
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST");
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST_ANISOTROPIC");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR");
			break;
		case LINEAR:
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST");
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST_ANISOTROPIC");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR_ANISOTROPIC");
			break;
		case NEAREST_ANISOTROPIC:
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR_ANISOTROPIC");
			break;
		case NEAREST:
			excludes.push_back("TEXTURE_SAMPLERS_NEAREST_ANISOTROPIC");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR");
			excludes.push_back("TEXTURE_SAMPLERS_LINEAR_ANISOTROPIC");
			break;
	}
}

String Terrain3DMaterial::_generate_shader_code() const {
	LOG(INFO, "Generating default shader code");
	Array excludes;
	_append_layout_excludes(excludes);
	if (_world_background != NONE) {
		excludes.push_back("NONE_FUNCTIONS");
		excludes.push_back("NONE_CHECK");
	}
	if (_world_background == NONE) {
		excludes.push_back("FLAT_UNIFORMS");
		excludes.push_back("FLAT_FUNCTIONS");
		excludes.push_back("FLAT_VERTEX");
		excludes.push_back("FLAT_FRAGMENT");
	}
	if (_world_background != NOISE) {
		excludes.push_back("WORLD_NOISE_UNIFORMS");
		excludes.push_back("WORLD_NOISE_FUNCTIONS");
		excludes.push_back("WORLD_NOISE_VERTEX");
		excludes.push_back("WORLD_NOISE_FRAGMENT");
	}
	if (!_auto_shader_enabled) {
		excludes.push_back("AUTO_SHADER_UNIFORMS");
		excludes.push_back("AUTO_SHADER");
	}
	if (!_macro_variation_enabled) {
		excludes.push_back("MACRO_VARIATION_UNIFORMS");
		excludes.push_back("MACRO_VARIATION");
	}
	if (!_projection_enabled) {
		excludes.push_back("PROJECTION");
	}
	if (_terrain->get_tessellation_level() == 0) {
		excludes.push_back("DISPLACEMENT_UNIFORMS");
		excludes.push_back("DISPLACEMENT_FUNCTIONS");
		excludes.push_back("DISPLACEMENT_VERTEX");
	}
	if (!_output_albedo_enabled) {
		excludes.push_back("OUTPUT_ALBEDO");
	} else {
		excludes.push_back("OUTPUT_ALBEDO_GREY");
	}
	if (!_output_roughness_enabled) {
		excludes.push_back("OUTPUT_ROUGHNESS");
	}
	if (!_output_specular_enabled) {
		excludes.push_back("OUTPUT_SPECULAR");
	} else {
		excludes.push_back("OUTPUT_SPECULAR_NONE");
	}
	if (!_output_normal_map_enabled) {
		excludes.push_back("OUTPUT_NORMAL_MAP");
	}
	if (!_output_ambient_occlusion_enabled) {
		excludes.push_back("OUTPUT_AMBIENT_OCCLUSION");
	}
	String shader = _apply_inserts(_shader_code["main"], excludes);
	return shader;
}

// Ripped from ShaderPreprocessor::CommentRemover::strip()
String Terrain3DMaterial::_strip_comments(const String &p_shader) const {
	Vector<char32_t> stripped;
	String code = p_shader;
	int index = 0;
	int line = 0;
	int comment_line_open = 0;
	int comments_open = 0;
	int strings_open = 0;
	const char32_t CURSOR = 0xFFFF;

	// Embedded supporting functions

	auto peek = [&]() { return (index < code.length()) ? code[index] : 0; };

	auto advance = [&](char32_t p_what) {
		while (index < code.length()) {
			char32_t c = code[index++];
			if (c == '\n') {
				line++;
				stripped.push_back('\n');
			}
			if (c == p_what) {
				return true;
			}
		}
		return false;
	};

	auto vector_to_string = [](const Vector<char32_t> &p_v, int p_start = 0, int p_end = -1) {
		const int stop = (p_end == -1) ? p_v.size() : p_end;
		const int count = stop - p_start;
		String result;
		result.resize(count + 1);
		for (int i = 0; i < count; i++) {
			result[i] = p_v[p_start + i];
		}
		result[count] = 0; // Ensure string is null terminated for length() to work.
		return result;
	};

	// Main function

	while (index < code.length()) {
		char32_t c = code[index++];
		if (c == CURSOR) {
			// Cursor. Maintain.
			stripped.push_back(c);
		} else if (c == '"') {
			if (strings_open <= 0) {
				strings_open++;
			} else {
				strings_open--;
			}
			stripped.push_back(c);
		} else if (c == '/' && strings_open == 0) {
			char32_t p = peek();
			if (p == '/') { // Single line comment.
				advance('\n');
			} else if (p == '*') { // Start of a block comment.
				index++;
				comment_line_open = line;
				comments_open++;
				while (advance('*')) {
					if (peek() == '/') { // End of a block comment.
						comments_open--;
						index++;
						break;
					}
				}
			} else {
				stripped.push_back(c);
			}
		} else if (c == '*' && strings_open == 0) {
			if (peek() == '/') { // Unmatched end of a block comment.
				comment_line_open = line;
				comments_open--;
			} else {
				stripped.push_back(c);
			}
		} else if (c == '\n') {
			line++;
			stripped.push_back(c);
		} else {
			stripped.push_back(c);
		}
	}
	return vector_to_string(stripped);
}

String Terrain3DMaterial::_generate_buffer_shader_code() const {
	LOG(INFO, "Generating default displacement buffer shader code");
	Array excludes;
	_append_layout_excludes(excludes);
	if (_world_background != NONE) {
		excludes.push_back("NONE_FUNCTIONS");
		excludes.push_back("NONE_CHECK");
	}
	if (_world_background == NONE) {
		excludes.push_back("FLAT_UNIFORMS");
		excludes.push_back("FLAT_FUNCTIONS");
		excludes.push_back("FLAT_FRAGMENT");
	}
	if (!_auto_shader_enabled) {
		excludes.push_back("AUTO_SHADER_UNIFORMS");
		excludes.push_back("AUTO_SHADER");
	}
	if (!_projection_enabled) {
		excludes.push_back("PROJECTION");
	}
	String shader = _apply_inserts(_shader_code["displacement_buffer"], excludes);
	return shader;
}

String Terrain3DMaterial::_inject_editor_code(const String &p_shader) const {
	String shader = _strip_comments(p_shader);

	// Insert after render_mode
	Ref<RegEx> regex;
	regex.instantiate();
	regex->compile("render_mode.*;?");
	Ref<RegExMatch> match = regex->search(shader);
	int idx = match.is_valid() ? match->get_end() : -1;
	if (idx < 0) {
		LOG(DEBUG, "No render mode; cannot inject editor code");
		return shader;
	}
	Array insert_names;

	// Insert before vertex()
	regex->compile("void\\s+vertex\\s*\\(");
	match = regex->search(shader);
	idx = match.is_valid() ? match->get_start() - 1 : -1;
	if (idx < 0) {
		LOG(DEBUG, "No void vertex(); cannot inject editor code");
		return shader;
	}
	if (_terrain && _terrain->get_editor()) {
		insert_names.push_back("EDITOR_DECAL_SETUP");
	}
#ifdef DEBUG_ENABLED
	if (_debug_view_heightmap) {
		insert_names.push_back("DEBUG_HEIGHTMAP_SETUP");
	}
#endif
	if (_show_contours) {
		insert_names.push_back("OVERLAY_CONTOURS_SETUP");
	}
	if (_show_slope) {
		insert_names.push_back("OVERLAY_SLOPE_SETUP");
	}
	// Apply pending inserts
	for (const String &name : insert_names) {
		String insert = _shader_code[name];
		shader = shader.insert(idx, "\n" + insert);
		idx += insert.length();
	}
	insert_names.clear();

	// Insert at the end of `fragment(){ }`
	// Check for each nested {} pair until the closing } is found.
	regex->compile("void\\s*fragment\\s*\\(\\s*\\)\\s*{");
	match = regex->search(shader);
	idx = -1;
	if (match.is_valid()) {
		int start_idx = match->get_end() - 1;
		int pair = 0;
		for (int i = start_idx; i < shader.length(); i++) {
			if (shader[i] == '{') {
				pair++;
			} else if (shader[i] == '}') {
				pair--;
			}
			if (pair == 0) {
				idx = i;
				break;
			}
		}
	}
	if (idx < 0) {
		LOG(DEBUG, "No ending bracket; cannot inject editor code");
		return shader;
	}

	// Debug Views
#ifdef DEBUG_ENABLED
	if (_debug_view_checkered) {
		insert_names.push_back("DEBUG_CHECKERED");
	}
	if (_debug_view_grey) {
		insert_names.push_back("DEBUG_GREY");
	}
	if (_debug_view_heightmap) {
		insert_names.push_back("DEBUG_HEIGHTMAP");
	}
	if (_debug_view_jaggedness) {
		insert_names.push_back("DEBUG_JAGGEDNESS");
	}
	if (_debug_view_autoshader) {
		insert_names.push_back("DEBUG_AUTOSHADER");
	}
	if (_debug_view_control_texture) {
		insert_names.push_back("DEBUG_CONTROL_TEXTURE");
	}
	if (_debug_view_control_blend) {
		insert_names.push_back("DEBUG_CONTROL_BLEND");
	}
	if (_debug_view_control_angle) {
		insert_names.push_back("DEBUG_CONTROL_ANGLE");
	}
	if (_debug_view_control_scale) {
		insert_names.push_back("DEBUG_CONTROL_SCALE");
	}
	if (_debug_view_colormap) {
		insert_names.push_back("DEBUG_COLORMAP");
	}
	if (_debug_view_roughmap) {
		insert_names.push_back("DEBUG_ROUGHMAP");
	}
	// PBR views
	if (_pbr_view_tex_albedo) {
		insert_names.push_back("PBR_TEXTURE_ALBEDO");
	}
	if (_pbr_view_tex_height) {
		insert_names.push_back("PBR_TEXTURE_HEIGHT");
	}
	if (_pbr_view_tex_normal) {
		insert_names.push_back("PBR_TEXTURE_NORMAL");
	}
	if (_pbr_view_tex_ao) {
		insert_names.push_back("PBR_TEXTURE_AO");
	}
	if (_pbr_view_tex_rough) {
		insert_names.push_back("PBR_TEXTURE_ROUGHNESS");
	}
	if (_debug_view_displacement_buffer) {
		insert_names.push_back("DEBUG_DISPLACEMENT_BUFFER");
	}
#endif
	// Overlays
	if (_show_contours) {
		insert_names.push_back("OVERLAY_CONTOURS_RENDER");
	}
	if (_show_slope) {
		insert_names.push_back("OVERLAY_SLOPE_RENDER");
	}
	if (_show_navigation || (_terrain && _terrain->get_editor() && _terrain->get_editor()->get_tool() == Terrain3DEditor::NAVIGATION)) {
		insert_names.push_back("EDITOR_NAVIGATION");
	}
	if (_show_instancer_grid) {
		insert_names.push_back("OVERLAY_INSTANCER_GRID");
	}
	if (_show_vertex_grid) {
		insert_names.push_back("OVERLAY_VERTEX_GRID");
	}
	// Region-tool selection must not override the explicit grid visibility toggle.
	if (_show_region_grid) {
		insert_names.push_back("EDITOR_REGION_GRID");
	}
	if (_terrain && _terrain->get_editor()) {
		insert_names.push_back("EDITOR_DECAL_RENDER");
	}
	// Apply pending inserts
	for (const String &name : insert_names) {
		String insert = _shader_code[name];
		shader = shader.insert(idx, "\n" + insert);
		idx += insert.length();
	}
	return shader;
}

bool Terrain3DMaterial::_needs_vt_shader() const {
	// Overrides retain the full interface, including when first populated from
	// the default shader. Their source must not freeze an editor-preview variant.
	return !_terrain || (_shader_override_enabled && _shader_override.is_valid()) ||
			(!_terrain->is_vt_editor_preview_active() && _terrain->needs_vt_shader_arms());
}

// One channel group's own arm, on the same three cases: a group the editor preview is holding still,
// or a shader override that owns its own code, keeps the interface rather than losing it. The
// question is per group and read from the matrix (`clipmap_arm_used()`), so it names no channel: the
// channel a group's layer carries is the source's business.
bool Terrain3DMaterial::_needs_clipmap_arm(const int p_group) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return false;
	}
	return !_terrain || (_shader_override_enabled && _shader_override.is_valid()) ||
			(!_terrain->is_vt_editor_preview_active() && _terrain->clipmap_arm_used(TerrainVT::ChannelGroup(p_group)));
}

// Whether the group's arm is compiled in the **Atlas** implementation's shape. It is the same delivery
// and the same gate as above - a group whose cells name neither band compiles neither arm - with the
// layer's implementation selector deciding which of the two *storages* the compiled arm addresses. A
// switch therefore regenerates the variant, which is exactly what "the debug and the render follow the
// setting" means on the shader side: the ring's level table and the atlas's rect table are different
// code, not one branch on a uniform.
bool Terrain3DMaterial::_needs_clipmap_atlas_arm(const int p_group) const {
	if (!_needs_clipmap_arm(p_group)) {
		return false;
	}
	if (!_terrain || (_shader_override_enabled && _shader_override.is_valid())) {
		// A shader override owns its own code and keeps the interface: the arm is compiled so the
		// names exist, and both are declared because the override may read either.
		return true;
	}
	return _terrain->get_vt_clipmap_implementation() == int(TerrainClipmap::Implementation::Atlas);
}

bool Terrain3DMaterial::_clipmap_arm_changed() const {
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		if (_shader_clipmap[group] != _needs_clipmap_arm(group)) {
			return true;
		}
		if (_shader_clipmap_atlas[group] != _needs_clipmap_atlas_arm(group)) {
			return true;
		}
	}
	return false;
}
