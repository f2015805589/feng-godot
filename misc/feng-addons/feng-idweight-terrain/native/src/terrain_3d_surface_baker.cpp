// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_surface_baker.h"
#include <godot_cpp/classes/engine.hpp>

#include "logger.h"

#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <algorithm>
#include <cmath>
#include <utility>

namespace {
// Keep diagnostic scopes balanced on upload failures and early returns.
struct SurfaceVTLabel {
	RenderingDevice *rd;
	SurfaceVTLabel(RenderingDevice *p_rd, const String &p_name) :
			rd(p_rd) {
		rd->draw_command_begin_label(p_name, Color(0.3f, 0.7f, 0.9f));
	}
	~SurfaceVTLabel() { rd->draw_command_end_label(); }
};
} // namespace

// The helper source is concatenated after this preamble and before the bake body.
// Keeping idweight_r16.glsl as the single source of the packed-ID routines prevents
// this offline/runtime evaluator from drifting from the material shader.
static const char *SURFACE_BAKE_SHADER =
		R"(#version 450
#define TAU 6.283185307179586476925286766559

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2DArray bake_idweights;
layout(set = 0, binding = 1) uniform sampler2DArray bake_height;
layout(set = 0, binding = 2) uniform sampler2DArray bake_albedo;
layout(set = 0, binding = 3) uniform sampler2DArray bake_normal;

struct MaterialParams {
	vec4 color;
	vec4 normal_ao_rough;
	vec4 uv_detile;
	vec4 slope;
};

layout(set = 0, binding = 4, std430) readonly buffer MaterialBuffer {
	MaterialParams materials[];
} bake_materials;

struct BakeJob {
	vec4 world_rect; // world origin x/z, core page size x/z
	vec4 page; // world texel size x/z, core texel size, physical border
	uvec4 indices; // source layer, output layer, mode (0 invalid, 1 bake), reserved
	vec4 policy; // slope distance/policy factor, reserved
};

layout(set = 0, binding = 5, std430) readonly buffer JobBuffer {
	BakeJob jobs[];
} bake_jobs;

layout(set = 0, binding = 6, rgba16f) uniform writeonly image2DArray bake_output_albedo;
layout(set = 0, binding = 7, rgba16f) uniform writeonly image2DArray bake_output_normal;
layout(set = 0, binding = 8, rgba16f) uniform writeonly image2DArray bake_output_params;

layout(push_constant, std430) uniform BakePushConstants {
	uvec4 dims; // physical size, job count, material count, reserved
} bake_push;
)"
#include "shaders/idweight_r16.glsl"
#include "shaders/surface_bake.glsl"
		;

namespace {

static constexpr int MATERIAL_COUNT = 32;
static constexpr int MATERIAL_STRIDE = 64;
static constexpr int JOB_STRIDE = 64;
static constexpr int IDWEIGHT_FORMAT_VALUE = 39; // Godot's extension R16_UNORM surface format.

static RID resolve_main_texture(const RID &p_rid, bool p_srgb = false) {
	if (!p_rid.is_valid()) {
		return RID();
	}
	RenderingServer *server = RenderingServer::get_singleton();
	if (server) {
		RID rd_rid = server->texture_get_rd_texture(p_rid, p_srgb);
		if (rd_rid.is_valid()) {
			return rd_rid;
		}
	}
	// This fallback also makes the API usable by a renderer-side caller that already
	// owns a main-device RID rather than an RS texture wrapper.
	return p_rid;
}

static void append_uniform(TypedArray<Ref<RDUniform>> &r_uniforms,
		RenderingDevice::UniformType p_type, int p_binding, const RID &p_id,
		const RID &p_second_id = RID()) {
	Ref<RDUniform> uniform;
	uniform.instantiate();
	uniform->set_uniform_type(p_type);
	uniform->set_binding(p_binding);
	if (p_id.is_valid()) {
		uniform->add_id(p_id);
	}
	if (p_second_id.is_valid()) {
		uniform->add_id(p_second_id);
	}
	r_uniforms.push_back(uniform);
}

static void encode_vec4(PackedByteArray &r_data, int64_t p_offset, float p_x, float p_y,
		float p_z, float p_w) {
	r_data.encode_float(p_offset + 0, p_x);
	r_data.encode_float(p_offset + 4, p_y);
	r_data.encode_float(p_offset + 8, p_z);
	r_data.encode_float(p_offset + 12, p_w);
}

} // namespace

///////////////////////////
// Resource management
///////////////////////////

RID Terrain3DSurfaceBaker::_create_texture(RenderingDevice *p_rd, RenderingDevice::DataFormat p_format,
		int p_size, int p_layers, uint64_t p_usage, const PackedByteArray &p_first_layer) {
	if (!p_rd || p_size <= 0 || p_layers <= 0) {
		return RID();
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(p_format);
	format->set_width(uint32_t(p_size));
	format->set_height(uint32_t(p_size));
	format->set_depth(1);
	format->set_array_layers(uint32_t(p_layers));
	format->set_mipmaps(1);
	format->set_usage_bits(static_cast<BitField<RenderingDevice::TextureUsageBits>>(p_usage));
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> data;
	if (p_first_layer.size() > 0) {
		data.push_back(p_first_layer);
	}
	return p_rd->texture_create(format, view, data);
}

RID Terrain3DSurfaceBaker::_create_sampler(RenderingDevice *p_rd,
		RenderingDevice::SamplerFilter p_filter, RenderingDevice::SamplerRepeatMode p_repeat,
		float p_max_lod) {
	if (!p_rd) {
		return RID();
	}
	Ref<RDSamplerState> state;
	state.instantiate();
	state->set_mag_filter(p_filter);
	state->set_min_filter(p_filter);
	state->set_mip_filter(p_filter);
	state->set_repeat_u(p_repeat);
	state->set_repeat_v(p_repeat);
	state->set_repeat_w(p_repeat);
	state->set_min_lod(0.0f);
	state->set_max_lod(p_max_lod);
	return p_rd->sampler_create(state);
}

void Terrain3DSurfaceBaker::_free_bundle(RenderingDevice *p_rd, const ResourceBundle &p_resources) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (server) {
		if (p_resources.output_albedo_rs.is_valid()) {
			server->free_rid(p_resources.output_albedo_rs);
		}
		if (p_resources.output_normal_rs.is_valid()) {
			server->free_rid(p_resources.output_normal_rs);
		}
		if (p_resources.output_params_rs.is_valid()) {
			server->free_rid(p_resources.output_params_rs);
		}
	}
	if (!p_rd) {
		return;
	}
	// Drop descriptor/pipeline objects before the resources they reference.  The
	// RenderingDevice dependency tracker may invalidate a uniform set when one of its
	// textures is freed; freeing the texture first would make the later explicit
	// uniform-set free report an "invalid ID" during teardown.
	const RID dependent_rids[] = { p_resources.uniform_set, p_resources.cell_pipeline, p_resources.cell_shader, p_resources.pipeline, p_resources.shader };
	for (const RID &rid : dependent_rids) {
		if (rid.is_valid()) {
			p_rd->free_rid(rid);
		}
	}
	const RID rd_rids[] = {
		p_resources.output_albedo_rd, p_resources.output_normal_rd, p_resources.output_params_rd,
		p_resources.source_id_rd, p_resources.source_height_rd, p_resources.material_buffer,
		p_resources.job_buffer, p_resources.dummy_albedo_rd, p_resources.dummy_normal_rd,
		p_resources.sampler_nearest, p_resources.sampler_linear
	};
	for (const RID &rid : rd_rids) {
		if (rid.is_valid()) {
			p_rd->free_rid(rid);
		}
	}
}

void Terrain3DSurfaceBaker::_free_deferred(const RID &p_output_albedo_rd, const RID &p_output_normal_rd,
		const RID &p_output_params_rd, const RID &p_output_albedo_rs, const RID &p_output_normal_rs,
		const RID &p_output_params_rs, const RID &p_source_id_rd, const RID &p_source_height_rd,
		const RID &p_material_buffer, const RID &p_job_buffer, const RID &p_dummy_albedo_rd,
		const RID &p_dummy_normal_rd, const RID &p_uniform_set, const RID &p_pipeline,
		const RID &p_shader, const RID &p_sampler_nearest, const RID &p_sampler_linear, const RID &p_cell_shader, const RID &p_cell_pipeline) {
	ResourceBundle resources;
	resources.cell_shader = p_cell_shader;
	resources.cell_pipeline = p_cell_pipeline;
	resources.output_albedo_rd = p_output_albedo_rd;
	resources.output_normal_rd = p_output_normal_rd;
	resources.output_params_rd = p_output_params_rd;
	resources.output_albedo_rs = p_output_albedo_rs;
	resources.output_normal_rs = p_output_normal_rs;
	resources.output_params_rs = p_output_params_rs;
	resources.source_id_rd = p_source_id_rd;
	resources.source_height_rd = p_source_height_rd;
	resources.material_buffer = p_material_buffer;
	resources.job_buffer = p_job_buffer;
	resources.dummy_albedo_rd = p_dummy_albedo_rd;
	resources.dummy_normal_rd = p_dummy_normal_rd;
	resources.uniform_set = p_uniform_set;
	resources.pipeline = p_pipeline;
	resources.shader = p_shader;
	resources.sampler_nearest = p_sampler_nearest;
	resources.sampler_linear = p_sampler_linear;
	RenderingServer *server = RenderingServer::get_singleton();
	_free_bundle(server ? server->get_rendering_device() : nullptr, resources);
}

void Terrain3DSurfaceBaker::_take_resources(ResourceBundle &r_resources) {
	std::lock_guard<std::mutex> lock(_mutex);
	r_resources = _resources;
	_resources = ResourceBundle();
	_resource_generation = 0;
}

Terrain3DSurfaceBaker::~Terrain3DSurfaceBaker() {
	clear();
}

void Terrain3DSurfaceBaker::clear() {
	ResourceBundle current, retired;
	RenderingDevice *resource_rd = nullptr;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		resource_rd = _rd;
		current = _resources;
		retired = _retired_resources;
		_retired_resources = ResourceBundle();
		_retire_ready = false;
		_resources = ResourceBundle();
		_resource_generation = 0;
		_configured = false;
		_pending.clear();
		_ready.clear();
		_slot_sequence.clear();
		_invalidate_all = false;
		++_generation;
		_rd = nullptr;
	}
	for (const ResourceBundle &resources : {current, retired}) {
		if (!resources.shader.is_valid() && !resources.output_albedo_rd.is_valid() &&
				!resources.output_albedo_rs.is_valid()) {
			continue;
		}
		RenderingServer *server = RenderingServer::get_singleton();
		if (!server || server->is_on_render_thread()) {
			_free_bundle(resource_rd, resources);
			continue;
		}
		server->call_on_render_thread(callable_mp_static(&Terrain3DSurfaceBaker::_free_deferred)
											  .bind(resources.output_albedo_rd, resources.output_normal_rd, resources.output_params_rd,
													  resources.output_albedo_rs, resources.output_normal_rs, resources.output_params_rs,
													  resources.source_id_rd, resources.source_height_rd, resources.material_buffer,
													  resources.job_buffer, resources.dummy_albedo_rd, resources.dummy_normal_rd,
													  resources.uniform_set, resources.pipeline, resources.shader,
													  resources.sampler_nearest, resources.sampler_linear, resources.cell_shader, resources.cell_pipeline));
	}
}

///////////////////////////
// GPU setup
///////////////////////////

bool Terrain3DSurfaceBaker::_compile_pipeline(ResourceBundle &r_resources) {
	if (!_rd) {
		return false;
	}
	Ref<RDShaderSource> source;
	source.instantiate();
	source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
	source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, SURFACE_BAKE_SHADER);
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
	if (spirv.is_null()) {
		LOG(ERROR, "Surface bake shader did not compile");
		return false;
	}
	const String compile_error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	if (!compile_error.is_empty()) {
		LOG(ERROR, "Surface bake shader compile error: ", compile_error);
		return false;
	}
	r_resources.shader = _rd->shader_create_from_spirv(spirv, "terrain3d_surface_bake");
	if (!r_resources.shader.is_valid()) {
		LOG(ERROR, "Could not create the surface bake shader");
		return false;
	}
	r_resources.pipeline = _rd->compute_pipeline_create(r_resources.shader);
	if (!r_resources.pipeline.is_valid()) {
		LOG(ERROR, "Could not create the surface bake compute pipeline");
		return false;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_rebuild_uniform_set(ResourceBundle &r_resources,
		const RID &p_albedo_array_rs, const RID &p_normal_array_rs) {
	if (!_rd || !r_resources.shader.is_valid()) {
		return false;
	}
	if (r_resources.uniform_set.is_valid()) {
		_rd->free_rid(r_resources.uniform_set);
		r_resources.uniform_set = RID();
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RID albedo_rd = server && p_albedo_array_rs.is_valid() ? server->texture_get_rd_texture(p_albedo_array_rs, true) : RID();
	RID normal_rd = server && p_normal_array_rs.is_valid() ? server->texture_get_rd_texture(p_normal_array_rs, false) : RID();
	if (!albedo_rd.is_valid()) {
		albedo_rd = resolve_main_texture(p_albedo_array_rs, true);
	}
	if (!normal_rd.is_valid()) {
		normal_rd = resolve_main_texture(p_normal_array_rs, false);
	}
	if (!albedo_rd.is_valid()) {
		albedo_rd = r_resources.dummy_albedo_rd;
	}
	if (!normal_rd.is_valid()) {
		normal_rd = r_resources.dummy_normal_rd;
	}

	TypedArray<Ref<RDUniform>> uniforms;
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
			r_resources.sampler_nearest, r_resources.source_id_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
			r_resources.sampler_nearest, r_resources.source_height_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
			r_resources.sampler_linear, albedo_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3,
			r_resources.sampler_linear, normal_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 4, r_resources.material_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 5, r_resources.job_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 6, r_resources.output_albedo_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 7, r_resources.output_normal_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 8, r_resources.output_params_rd);
	r_resources.uniform_set = _rd->uniform_set_create(uniforms, r_resources.shader, 0);
	if (!r_resources.uniform_set.is_valid()) {
		LOG(ERROR, "Could not create the surface bake uniform set");
		return false;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_ensure_resources(uint64_t p_generation,
		int p_page_count, int p_stored_size, const RID &p_albedo_array_rs, const RID &p_normal_array_rs,
		const PackedByteArray &p_material_bytes) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server) {
		return false;
	}
	if (!_rd) {
		RenderingDevice *main_rd = server->get_rendering_device();
		std::lock_guard<std::mutex> lock(_mutex);
		if (!_rd) {
			_rd = main_rd;
		}
	}
	if (!_rd) {
		LOG(ERROR, "No main RenderingDevice available for surface bake");
		return false;
	}
	bool growing = false;
	int old_count = 0;
	ResourceBundle old;
	std::vector<uint8_t> ready;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_resource_generation == p_generation && _resources.pipeline.is_valid()) {
			if (_resource_page_count >= p_page_count || _retired_resources.output_albedo_rd.is_valid()) { return true; }
			growing = true; old_count = _resource_page_count;
			old = _resources; ready = _ready;
		}
	}
	if (!growing) {
		_take_resources(old);
		_free_bundle(_rd, old);
	}
	ResourceBundle next;
	const uint64_t sampled_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT;
	const uint64_t output_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT;
	PackedByteArray dummy_albedo;
	dummy_albedo.resize(4);
	dummy_albedo[0] = 255;
	dummy_albedo[1] = 255;
	dummy_albedo[2] = 255;
	dummy_albedo[3] = 255;
	PackedByteArray dummy_normal;
	dummy_normal.resize(4);
	dummy_normal[0] = 128;
	dummy_normal[1] = 128;
	dummy_normal[2] = 255;
	dummy_normal[3] = 255;
	next.dummy_albedo_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, 1, 1,
			sampled_usage, dummy_albedo);
	next.dummy_normal_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, 1, 1,
			sampled_usage, dummy_normal);
	next.sampler_nearest = _create_sampler(_rd, RenderingDevice::SAMPLER_FILTER_NEAREST,
			RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, 0.0f);
	next.sampler_linear = _create_sampler(_rd, RenderingDevice::SAMPLER_FILTER_LINEAR,
			RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT, 1000.0f);
	next.source_id_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16_UNORM, p_stored_size,
			p_page_count, sampled_usage);
	next.source_height_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R32_SFLOAT, p_stored_size,
			p_page_count, sampled_usage);
	next.output_albedo_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, p_page_count, output_usage);
	next.output_normal_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, p_page_count, output_usage);
	next.output_params_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, p_page_count, output_usage);
	if (!next.dummy_albedo_rd.is_valid() || !next.dummy_normal_rd.is_valid() ||
			!next.sampler_nearest.is_valid() || !next.sampler_linear.is_valid() ||
			!next.source_id_rd.is_valid() || !next.source_height_rd.is_valid() ||
			!next.output_albedo_rd.is_valid() || !next.output_normal_rd.is_valid() ||
			!next.output_params_rd.is_valid()) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not allocate surface bake textures");
		return false;
	}
	_rd->set_resource_name(next.source_id_rd, "Surface VT Source IDWeights (layer = physical slot)");
	_rd->set_resource_name(next.source_height_rd, "Surface VT Source Height (layer = physical slot)");
	_rd->set_resource_name(next.output_albedo_rd, "Surface VT Albedo Height (layer = physical slot)");
	_rd->set_resource_name(next.output_normal_rd, "Surface VT Normal Roughness (layer = physical slot)");
	_rd->set_resource_name(next.output_params_rd, "Surface VT Parameters (layer = physical slot)");
	next.output_albedo_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_albedo_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	next.output_normal_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_normal_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	next.output_params_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_params_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	if (!next.output_albedo_rs.is_valid() || !next.output_normal_rs.is_valid() ||
			!next.output_params_rs.is_valid()) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not wrap surface bake arrays as RS textures");
		return false;
	}
	PackedByteArray initial_materials = p_material_bytes;
	if (initial_materials.size() != MATERIAL_COUNT * MATERIAL_STRIDE) {
		initial_materials.resize(MATERIAL_COUNT * MATERIAL_STRIDE);
		for (int64_t i = 0; i < initial_materials.size(); i++) {
			initial_materials[i] = 0;
		}
	}
	next.material_buffer = _rd->storage_buffer_create(uint32_t(initial_materials.size()), initial_materials);
	next.job_buffer = _rd->storage_buffer_create(uint32_t(std::max(1, p_page_count) * JOB_STRIDE));
	if (!next.material_buffer.is_valid() || !next.job_buffer.is_valid() || !_compile_pipeline(next) ||
			!_rebuild_uniform_set(next, p_albedo_array_rs, p_normal_array_rs)) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not allocate surface bake buffers or pipeline");
		return false;
	}
	_rd->set_resource_name(next.job_buffer, "Surface VT Jobs (64 bytes: world rect, texel size, slot, mode)");
	_rd->set_resource_name(next.material_buffer, "Surface VT Material Parameters");
	_rd->set_resource_name(next.shader, "Surface VT Page Baker");
	// A fresh output has no valid pages.  Clearing all channels is recorded on the
	// main device; no submit or sync is performed here.
	_rd->texture_clear(next.output_albedo_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(p_page_count));
	_rd->texture_clear(next.output_normal_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(p_page_count));
	_rd->texture_clear(next.output_params_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(p_page_count));
	if (growing) {
		// Resource migration copies existing results; it does not rerun a page
		// shader or restart source work. Keep the old output alive until the next
		// material update has bound the new arrays, including already prepared draws.
		uint64_t copied = 0;
		for (int slot = 0; slot < old_count; ++slot) {
			if (slot >= int(ready.size()) || !ready[slot]) { continue; }
			const Vector3 extent(p_stored_size, p_stored_size, 1);
			if (_rd->texture_copy(old.output_albedo_rd, next.output_albedo_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK ||
					_rd->texture_copy(old.output_normal_rd, next.output_normal_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK ||
					_rd->texture_copy(old.output_params_rd, next.output_params_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK) {
				_free_bundle(_rd, next); return false;
			}
			++copied;
		}
		std::lock_guard<std::mutex> lock(_mutex);
		_retired_resources = old;
		_retire_ready = false;
		_migrated_pages += copied;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_resources = next;
		_resource_generation = p_generation;
		_resource_page_count = p_page_count;
		_page_count = p_page_count;
		_ready.resize(size_t(p_page_count), 0);
		_slot_sequence.resize(size_t(p_page_count), 0);
	}
	return true;
}

bool Terrain3DSurfaceBaker::_upload_materials(const PackedByteArray &p_material_bytes) {
	if (!_rd || !_resources.material_buffer.is_valid() ||
			p_material_bytes.size() != MATERIAL_COUNT * MATERIAL_STRIDE) {
		return false;
	}
	return _rd->buffer_update(_resources.material_buffer, 0, uint32_t(p_material_bytes.size()),
				   p_material_bytes) == OK;
}

///////////////////////////
// CPU queue and uploads
///////////////////////////

void Terrain3DSurfaceBaker::configure(int p_page_size, int p_border, int p_page_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_page_size = std::max(1, p_page_size);
	_border = std::max(0, p_border);
	_page_count = std::max(1, p_page_count);
	_requested_capacity = _page_count;
	_stored_size = _page_size + 2 * _border;
	_configured = true;
	++_generation;
	_pending.clear();
	_ready.assign(size_t(_page_count), 0);
	_slot_sequence.assign(size_t(_page_count), 0);
	_next_sequence = 1;
	_invalidate_all = true;
	_resource_generation = 0;
}

void Terrain3DSurfaceBaker::request_capacity(int p_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_requested_capacity = std::max(_requested_capacity, p_count);
}
int Terrain3DSurfaceBaker::get_capacity() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _page_count;
}

void Terrain3DSurfaceBaker::acknowledge_output(const RID &p_albedo) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (p_albedo == _resources.output_albedo_rs) { _retire_ready = true; }
}

void Terrain3DSurfaceBaker::set_materials(const RID &p_albedo_array_rid, const RID &p_normal_array_rid,
		const PackedColorArray &p_colors, const PackedFloat32Array &p_normal_depths,
		const PackedFloat32Array &p_ao_strengths, const PackedFloat32Array &p_ao_affects,
		const PackedFloat32Array &p_roughness_mods, const PackedFloat32Array &p_uv_scales,
		const PackedVector2Array &p_detiles, const PackedVector3Array &p_slope_params) {
	PackedByteArray bytes;
	bytes.resize(MATERIAL_COUNT * MATERIAL_STRIDE);
	for (int i = 0; i < MATERIAL_COUNT; i++) {
		Color color(1.0f, 1.0f, 1.0f, 1.0f);
		if (i < p_colors.size()) {
			color = p_colors[i];
		}
		float normal_depth = i < p_normal_depths.size() ? p_normal_depths[i] : 1.0f;
		float ao_strength = i < p_ao_strengths.size() ? p_ao_strengths[i] : 0.5f;
		float ao_affect = i < p_ao_affects.size() ? p_ao_affects[i] : 0.0f;
		float roughness_mod = i < p_roughness_mods.size() ? p_roughness_mods[i] : 0.0f;
		float uv_scale = i < p_uv_scales.size() ? p_uv_scales[i] : 0.1f;
		Vector2 detile;
		if (i < p_detiles.size()) {
			detile = p_detiles[i];
		}
		Vector3 slope(1000.0f, 0.0f, 0.0f);
		if (i < p_slope_params.size()) {
			slope = p_slope_params[i];
		}
		const int64_t offset = int64_t(i) * MATERIAL_STRIDE;
		encode_vec4(bytes, offset, color.r, color.g, color.b, color.a);
		encode_vec4(bytes, offset + 16, normal_depth, ao_strength, ao_affect, roughness_mod);
		encode_vec4(bytes, offset + 32, uv_scale, detile.x, detile.y, 0.0f);
		encode_vec4(bytes, offset + 48, slope.x, slope.y, slope.z, 0.0f);
	}
	std::lock_guard<std::mutex> lock(_mutex);
	_material_albedo_rs = p_albedo_array_rid;
	_material_normal_rs = p_normal_array_rid;
	_material_bytes = bytes;
	_material_count = std::min(MATERIAL_COUNT, std::max<int>({ int(p_colors.size()), int(p_normal_depths.size()), int(p_ao_strengths.size()), int(p_ao_affects.size()), int(p_roughness_mods.size()), int(p_uv_scales.size()), int(p_detiles.size()), int(p_slope_params.size()) }));
	_material_version++;
	_materials_dirty = true;
	_invalidate_all = true;
	std::fill(_ready.begin(), _ready.end(), uint8_t(0));
}

void Terrain3DSurfaceBaker::queue_page(int p_slot, const Ref<Image> &p_idweights,
		const Ref<Image> &p_height, const Rect2 &p_world_rect, float p_slope_factor, Vector3 p_source_grid) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || p_idweights.is_null() || p_height.is_null()) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_BAKE;
	job.idweights = p_idweights;
	job.height = p_height;
	job.world_rect = p_world_rect;
	job.source_grid = p_source_grid;
	job.slope_factor = std::clamp(p_slope_factor, 0.0f, 1.0f);
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cached_page(int p_slot, const Dictionary &p_channels) {
	Ref<Image> albedo = p_channels.get("albedo_height", Variant());
	Ref<Image> normal = p_channels.get("normal_roughness", Variant());
	Ref<Image> params = p_channels.get("params", Variant());
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || albedo.is_null() || normal.is_null() || params.is_null()) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CACHED;
	job.albedo_height = albedo;
	job.normal_roughness = normal;
	job.params = params;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CELL;
	job.cells = p_cells;
	job.world_rect = p_rect;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::invalidate_slot(int p_slot) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_INVALIDATE;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
}

PackedByteArray Terrain3DSurfaceBaker::_image_bytes(const Ref<Image> &p_image,
		Image::Format p_expected_format, int p_bytes_per_pixel) const {
	if (p_image.is_null() || p_image->is_empty() || p_image->get_width() != _stored_size ||
			p_image->get_height() != _stored_size || p_image->has_mipmaps()) {
		return PackedByteArray();
	}
	PackedByteArray bytes = p_image->get_data();
	const int64_t expected_size = int64_t(_stored_size) * _stored_size * p_bytes_per_pixel;
	if (p_image->get_format() == p_expected_format && bytes.size() == expected_size) {
		return bytes;
	}
	// Main-RD outputs are RGBA16F.  Cached files may use RGBAF for portability; a
	// temporary Image conversion keeps texture_update's byte layout exact without
	// mutating the caller's cache resource.
	if (p_expected_format == Image::FORMAT_RGBAH &&
			(p_image->get_format() == Image::FORMAT_RGBAF || p_image->get_format() == Image::FORMAT_RGBA8 ||
					p_image->get_format() == Image::FORMAT_RGBAH)) {
		Ref<Image> converted = Image::create_from_data(_stored_size, _stored_size, false,
				p_image->get_format(), bytes);
		if (converted.is_valid() && converted->get_format() != p_expected_format) {
			converted->convert(p_expected_format);
		}
		if (converted.is_valid()) {
			bytes = converted->get_data();
			if (bytes.size() == expected_size) {
				return bytes;
			}
		}
	}
	return PackedByteArray();
}

bool Terrain3DSurfaceBaker::_upload_source_page(const PendingJob &p_job, int p_layer) {
	if (!_rd || !_resources.source_id_rd.is_valid() || !_resources.source_height_rd.is_valid()) {
		return false;
	}
	SurfaceVTLabel label(_rd, "VT Source Upload - slot " + String::num_int64(p_job.slot));
	PackedByteArray id_bytes = _image_bytes(p_job.idweights, Image::Format(IDWEIGHT_FORMAT_VALUE), 2);
	PackedByteArray height_bytes = _image_bytes(p_job.height, Image::FORMAT_RF, 4);
	if (id_bytes.is_empty() || height_bytes.is_empty()) {
		LOG(WARN, "Skipping invalid surface bake source page ", p_job.slot,
				"; expected ", _stored_size, "x", _stored_size, " R16/RF images");
		return false;
	}
	if (_rd->texture_update(_resources.source_id_rd, uint32_t(p_layer), id_bytes) != OK ||
			_rd->texture_update(_resources.source_height_rd, uint32_t(p_layer), height_bytes) != OK) {
		LOG(WARN, "Could not upload surface bake source page ", p_job.slot);
		return false;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_source_uploads++;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_upload_cached_page(const PendingJob &p_job) {
	if (!_rd || !_resources.output_albedo_rd.is_valid() || !_resources.output_normal_rd.is_valid() ||
			!_resources.output_params_rd.is_valid()) {
		return false;
	}
	PackedByteArray albedo = _image_bytes(p_job.albedo_height, Image::FORMAT_RGBAH, 8);
	PackedByteArray normal = _image_bytes(p_job.normal_roughness, Image::FORMAT_RGBAH, 8);
	PackedByteArray params = _image_bytes(p_job.params, Image::FORMAT_RGBAH, 8);
	if (albedo.is_empty() || normal.is_empty() || params.is_empty()) {
		LOG(WARN, "Skipping invalid cached surface page ", p_job.slot);
		return false;
	}
	SurfaceVTLabel label(_rd, "SVT Cached Page Upload - slot " + String::num_int64(p_job.slot));
	if (_rd->texture_update(_resources.output_albedo_rd, uint32_t(p_job.slot), albedo) != OK ||
			_rd->texture_update(_resources.output_normal_rd, uint32_t(p_job.slot), normal) != OK ||
			_rd->texture_update(_resources.output_params_rd, uint32_t(p_job.slot), params) != OK) {
		LOG(WARN, "Could not upload cached surface page ", p_job.slot);
		return false;
	}
	return true;
}

// Copy cropped offline mip regions into runtime pages, area-weighting cells
// when a coarse pixel spans multiple source cells. No material rebake here.
bool Terrain3DSurfaceBaker::_copy_cell_page(const PendingJob &p_job) {
	if (!_resources.cell_pipeline.is_valid()) {
		Ref<RDShaderSource> source;
		source.instantiate();
		source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
		source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, R"(#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D src_a;
layout(set=0,binding=1) uniform sampler2D src_n;
layout(set=0,binding=2) uniform sampler2D src_p;
layout(rgba16f,set=0,binding=3) uniform image2DArray dst_a;
layout(rgba16f,set=0,binding=4) uniform image2DArray dst_n;
layout(rgba16f,set=0,binding=5) uniform image2DArray dst_p;
layout(push_constant,std430) uniform Push { vec4 page; vec4 cell; vec4 source; ivec4 config; } pc;
void main() {
 ivec2 pixel=ivec2(gl_GlobalInvocationID.xy);
 int size=pc.config.x+2*pc.config.y;
 if(any(greaterThanEqual(pixel,ivec2(size)))) return;
 if(pc.config.w==1) {
  ivec3 dst=ivec3(pixel,pc.config.z);
  vec4 params=imageLoad(dst_p,dst);
  if(params.a>0.000001) {
   imageStore(dst_a,dst,imageLoad(dst_a,dst)/params.a);
   imageStore(dst_n,dst,imageLoad(dst_n,dst)/params.a);
   imageStore(dst_p,dst,vec4(params.rgb/params.a,1));
  }
  return;
 }
 float step=pc.page.z/float(pc.config.x);
 vec2 lo=pc.page.xy+(vec2(pixel)-float(pc.config.y))*step;
 vec2 first=max(lo,pc.cell.xy), last=min(lo+step,pc.cell.xy+pc.cell.zw);
 vec2 extent=max(vec2(0),last-first);
 float weight=extent.x*extent.y/(step*step);
 if(weight<=0.0) return;
 vec2 uv=((first+last)*0.5-pc.source.xy)/pc.source.zw;
 vec2 inset=vec2(0.5)/vec2(textureSize(src_a,0));
 uv=clamp(uv,inset,vec2(1)-inset);
 ivec3 dst=ivec3(pixel,pc.config.z);
 imageStore(dst_a,dst,imageLoad(dst_a,dst)+textureLod(src_a,uv,0)*weight);
 imageStore(dst_n,dst,imageLoad(dst_n,dst)+textureLod(src_n,uv,0)*weight);
 imageStore(dst_p,dst,imageLoad(dst_p,dst)+textureLod(src_p,uv,0)*weight);
}
)");
		Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
		if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
			return false;
		}
		_resources.cell_shader = _rd->shader_create_from_spirv(spirv, "svt_cell_copy");
		_resources.cell_pipeline = _rd->compute_pipeline_create(_resources.cell_shader);
		if (!_resources.cell_pipeline.is_valid()) {
			return false;
		}
	}
	for (RID target : { _resources.output_albedo_rd, _resources.output_normal_rd, _resources.output_params_rd }) {
		_rd->texture_clear(target, Color(0, 0, 0, 0), 0, 1, p_job.slot, 1);
	}
	int piece_index = 0;
	for (const Dictionary &piece : p_job.cells) {
		std::vector<RID> textures;
		for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
			Ref<Image> image = piece[name];
			Ref<RDTextureFormat> format;
			format.instantiate();
			format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
			format->set_width(image->get_width());
			format->set_height(image->get_height());
			format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
			format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT);
			Ref<RDTextureView> view;
			view.instantiate();
			TypedArray<PackedByteArray> data;
			data.push_back(image->get_data());
			textures.push_back(_rd->texture_create(format, view, data));
		}
		TypedArray<Ref<RDUniform>> uniforms;
		for (int i = 0; i < 3; ++i) {
			append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, i, _resources.sampler_linear, textures[i]);
		}
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 3, _resources.output_albedo_rd);
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 4, _resources.output_normal_rd);
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 5, _resources.output_params_rd);
		RID uniform = _rd->uniform_set_create(uniforms, _resources.cell_shader, 0);
		PackedByteArray push;
		push.resize(64);
		Rect2 rects[] = { p_job.world_rect, piece.get("coverage_rect", piece["cell_rect"]), piece["source_rect"] };
		for (int i = 0; i < 3; ++i) {
			push.encode_float(i * 16, rects[i].position.x);
			push.encode_float(i * 16 + 4, rects[i].position.y);
			push.encode_float(i * 16 + 8, rects[i].size.x);
			push.encode_float(i * 16 + 12, rects[i].size.y);
		}
		push.encode_s32(48, _page_size);
		push.encode_s32(52, _border);
		push.encode_s32(56, p_job.slot);
		push.encode_s32(60, 0);
		int64_t list = _rd->compute_list_begin();
		_rd->compute_list_bind_compute_pipeline(list, _resources.cell_pipeline);
		_rd->compute_list_bind_uniform_set(list, uniform, 0);
		_rd->compute_list_set_push_constant(list, push, 64);
		_rd->compute_list_dispatch(list, (_stored_size + 7) / 8, (_stored_size + 7) / 8, 1);
		_rd->compute_list_end();
		if (++piece_index == p_job.cells.size()) {
			push.encode_s32(60, 1);
			list = _rd->compute_list_begin();
			_rd->compute_list_bind_compute_pipeline(list, _resources.cell_pipeline);
			_rd->compute_list_bind_uniform_set(list, uniform, 0);
			_rd->compute_list_set_push_constant(list, push, 64);
			_rd->compute_list_dispatch(list, (_stored_size + 7) / 8, (_stored_size + 7) / 8, 1);
			_rd->compute_list_end();
		}
		_rd->free_rid(uniform);
		for (RID texture : textures) {
			_rd->free_rid(texture);
		}
	}
	return true;
}

///////////////////////////
// Render callback
///////////////////////////

bool Terrain3DSurfaceBaker::_record_jobs(std::vector<PendingJob> &p_jobs, uint64_t p_generation,
		int p_page_size, int p_border, int p_stored_size, int p_material_count) {
	if (!_rd || p_jobs.empty() || !_resources.job_buffer.is_valid() || !_resources.uniform_set.is_valid() ||
			!_resources.pipeline.is_valid()) {
		return false;
	}
	PackedByteArray job_bytes;
	SurfaceVTLabel batch_label(_rd, "Surface VT Page Updates - " + String::num_int64(p_jobs.size()) + " pages");
	job_bytes.resize(int64_t(p_jobs.size()) * JOB_STRIDE);
	for (size_t index = 0; index < p_jobs.size(); index++) {
		PendingJob &job = p_jobs[index];
		const int64_t offset = int64_t(index) * JOB_STRIDE;
		uint32_t mode = 0u;
		if (job.kind == PENDING_BAKE && p_material_count > 0 && _upload_source_page(job, job.slot)) {
			mode = 1u;
		} else if (job.kind == PENDING_BAKE) {
			job.kind = PENDING_INVALIDATE;
		}
		const float texel_x = p_page_size > 0 ? job.world_rect.size.x / float(p_page_size) : 1.0f;
		const float texel_z = p_page_size > 0 ? job.world_rect.size.y / float(p_page_size) : 1.0f;
		encode_vec4(job_bytes, offset, job.world_rect.position.x, job.world_rect.position.y,
				job.world_rect.size.x, job.world_rect.size.y);
		encode_vec4(job_bytes, offset + 16, texel_x, texel_z, float(p_page_size), float(p_border));
		job_bytes.encode_u32(offset + 32, uint32_t(std::max(0, job.slot)));
		job_bytes.encode_u32(offset + 36, uint32_t(std::max(0, job.slot)));
		job_bytes.encode_u32(offset + 40, mode);
		job_bytes.encode_u32(offset + 44, 0);
		encode_vec4(job_bytes, offset + 48, std::clamp(job.slope_factor, 0.0f, 1.0f), job.source_grid.x, job.source_grid.y, job.source_grid.z);
	}
	if (_rd->buffer_update(_resources.job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
		LOG(WARN, "Could not upload surface bake jobs");
		return false;
	}
	PackedByteArray push;
	push.resize(16);
	push.encode_u32(0, uint32_t(p_stored_size));
	push.encode_u32(4, uint32_t(p_jobs.size()));
	push.encode_u32(8, uint32_t(std::max(0, p_material_count)));
	push.encode_u32(12, uint32_t(p_generation & 0xFFFFFFFFu));
	SurfaceVTLabel dispatch_label(_rd, "Bake / Invalidate Pages - Dispatch Z = job index");
	const int64_t compute_list = _rd->compute_list_begin();
	if (compute_list < 0) {
		LOG(WARN, "Could not begin surface bake compute list");
		return false;
	}
	_rd->compute_list_bind_compute_pipeline(compute_list, _resources.pipeline);
	_rd->compute_list_bind_uniform_set(compute_list, _resources.uniform_set, 0);
	_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
	_rd->compute_list_dispatch(compute_list,
			uint32_t((p_stored_size + 7) / 8), uint32_t((p_stored_size + 7) / 8),
			uint32_t(p_jobs.size()));
	_rd->compute_list_end();
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_dispatch_count++;
	}
	return true;
}

void Terrain3DSurfaceBaker::_set_ready(int p_slot, bool p_ready, uint64_t p_generation,
		uint64_t p_material_version, uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (p_generation != _generation || p_material_version != _material_version ||
			p_slot < 0 || p_slot >= int(_ready.size()) || p_slot >= int(_slot_sequence.size()) ||
			(p_sequence != 0 && _slot_sequence[size_t(p_slot)] != p_sequence) ||
			(p_sequence == 0 && _slot_sequence[size_t(p_slot)] != 0)) {
		return;
	}
	_ready[size_t(p_slot)] = p_ready ? 1 : 0;
}

void Terrain3DSurfaceBaker::render_pending(const Ref<RefCounted> &p_keep_alive) {
	(void)p_keep_alive;
	std::map<int, PendingJob> pending;
	uint64_t generation;
	uint64_t material_version;
	PackedByteArray material_bytes;
	RID material_albedo;
	RID material_normal;
	int page_size;
	int border;
	int page_count;
	int requested_capacity;
	int stored_size;
	int material_count;
	bool invalidate_all;
	bool materials_dirty;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (!_configured) {
			return;
		}
		generation = _generation;
		material_version = _material_version;
		material_bytes = _material_bytes;
		material_albedo = _material_albedo_rs;
		material_normal = _material_normal_rs;
		material_count = _material_count;
		page_size = _page_size;
		border = _border;
		page_count = _page_count;
		requested_capacity = _requested_capacity;
		stored_size = _stored_size;
		invalidate_all = _invalidate_all;
		materials_dirty = _materials_dirty;
		pending.swap(_pending);
		_invalidate_all = false;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || !server->is_on_render_thread()) {
		// Parent registration should always route this method to the render thread.  Do
		// not touch a main RD from a game thread; restore the snapshot for a later call.
		std::lock_guard<std::mutex> lock(_mutex);
		for (const auto &entry : pending) {
			_pending.emplace(entry.first, entry.second);
		}
		_invalidate_all = _invalidate_all || invalidate_all;
		return;
	}
	ResourceBundle retired;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_retire_ready) { retired = _retired_resources; _retired_resources = ResourceBundle(); _retire_ready = false; }
	}
	if (retired.output_albedo_rd.is_valid()) { _free_bundle(_rd, retired); }
	if (!_ensure_resources(generation, page_count, stored_size,
				material_albedo, material_normal, material_bytes)) {
		std::lock_guard<std::mutex> lock(_mutex);
		for (const auto &entry : pending) {
			_pending.emplace(entry.first, entry.second);
		}
		_invalidate_all = _invalidate_all || invalidate_all;
		return;
	}
	if (materials_dirty) {
		if (!_upload_materials(material_bytes) || !_rebuild_uniform_set(_resources, material_albedo, material_normal)) {
			std::lock_guard<std::mutex> lock(_mutex);
			for (const auto &entry : pending) {
				_pending.emplace(entry.first, entry.second);
			}
			_invalidate_all = true;
			return;
		}
		std::lock_guard<std::mutex> lock(_mutex);
		if (_material_version == material_version) {
			_materials_dirty = false;
		}
	}

	// Material updates invalidate every old result, but a newer operation for a slot
	// supersedes that invalidation.  Keeping one operation per slot also avoids races
	// between two z slices of the compute dispatch.
	std::vector<PendingJob> jobs;
	jobs.reserve(size_t(page_count));
	if (invalidate_all) {
		for (int slot = 0; slot < page_count; slot++) {
			auto found = pending.find(slot);
			if (found != pending.end()) {
				jobs.push_back(found->second);
			} else {
				PendingJob invalid;
				invalid.slot = slot;
				invalid.kind = PENDING_INVALIDATE;
				invalid.generation = generation;
				jobs.push_back(invalid);
			}
		}
	} else {
		for (const auto &entry : pending) {
			jobs.push_back(entry.second);
		}
	}

	std::vector<PendingJob> compute_jobs;
	compute_jobs.reserve(jobs.size());
	// Invalidation only needs to clear readiness, not shade every cache texel.
	const bool cleared_all = invalidate_all && _rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, 0, page_count) == OK;
	const uint64_t frame = Engine::get_singleton()->get_frames_drawn();
	if (_render_frame != frame) { _render_frame = frame; _frame_page_updates = 0; }
	for (const PendingJob &job : jobs) {
		if (job.generation != generation || job.slot < 0 || job.slot >= page_count) {
			continue;
		}
		if (job.kind == PENDING_INVALIDATE && (cleared_all ||
				_rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) == OK)) {
			_set_ready(job.slot, false, generation, material_version, job.sequence);
			{ std::lock_guard<std::mutex> lock(_mutex); ++_invalidated_pages; }
			continue;
		}
		if (job.kind != PENDING_INVALIDATE) {
			if (_frame_page_updates >= 16) {
				{ std::lock_guard<std::mutex> lock(_mutex); _pending.emplace(job.slot, job); }
				// A reused slot must not expose its previous material while deferred.
				PendingJob invalid = job;
				invalid.kind = PENDING_INVALIDATE;
				if (!cleared_all && _rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) != OK) {
					compute_jobs.push_back(invalid);
				}
				continue;
			}
			++_frame_page_updates;
		}
		if (job.kind == PENDING_CACHED || job.kind == PENDING_CELL) {
			if (job.kind == PENDING_CELL ? _copy_cell_page(job) : _upload_cached_page(job)) {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_cached_uploads++;
				}
				_set_ready(job.slot, true, generation, material_version, job.sequence);
			} else {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_invalidated_pages++;
				}
				PendingJob invalid = job;
				invalid.kind = PENDING_INVALIDATE;
				compute_jobs.push_back(invalid);
				_set_ready(job.slot, false, generation, material_version, job.sequence);
			}
		} else {
			compute_jobs.push_back(job);
		}
	}
	if (!compute_jobs.empty()) {
		std::vector<PendingJob> original_jobs = compute_jobs;
		if (!_record_jobs(compute_jobs, generation, page_size, border, stored_size, material_count)) {
			std::lock_guard<std::mutex> lock(_mutex);
			if (_generation == generation) {
				for (const PendingJob &job : original_jobs) {
					_pending.emplace(job.slot, job);
				}
				_invalidate_all = _invalidate_all || invalidate_all;
			}
			return;
		}
		for (const PendingJob &job : compute_jobs) {
			if (job.kind == PENDING_BAKE) {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_baked_pages++;
				}
				_set_ready(job.slot, true, generation, material_version, job.sequence);
			} else {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_invalidated_pages++;
				}
				_set_ready(job.slot, false, generation, material_version, job.sequence);
			}
		}
	}
	if (requested_capacity > page_count) {
		// Migrate after this frame's writes so both the still-bound old arrays and
		// the newly published arrays contain the same completed page contents.
		_ensure_resources(generation, requested_capacity, stored_size, material_albedo, material_normal, material_bytes);
	}
}

///////////////////////////
// Read-only state and explicit export
///////////////////////////

RID Terrain3DSurfaceBaker::get_albedo_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	return _resources.output_albedo_rs;
}

RID Terrain3DSurfaceBaker::get_normal_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	return _resources.output_normal_rs;
}

RID Terrain3DSurfaceBaker::get_params_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	return _resources.output_params_rs;
}

bool Terrain3DSurfaceBaker::is_page_ready(int p_slot) const {
	std::lock_guard<std::mutex> lock(_mutex);
	return p_slot >= 0 && p_slot < int(_ready.size()) && _ready[size_t(p_slot)] != 0;
}

Dictionary Terrain3DSurfaceBaker::export_page(int p_slot) const {
	Dictionary result;
	result["valid"] = false;
	result["generation"] = int64_t(0);
	if (!is_page_ready(p_slot)) {
		return result;
	}
	RID albedo;
	RID normal;
	RID params;
	uint64_t generation;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (p_slot < 0 || p_slot >= int(_ready.size()) || !_ready[size_t(p_slot)]) {
			return result;
		}
		albedo = _resources.output_albedo_rs;
		normal = _resources.output_normal_rs;
		params = _resources.output_params_rs;
		generation = _generation;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || !albedo.is_valid() || !normal.is_valid() || !params.is_valid()) {
		return result;
	}
	// This is intentionally the only synchronous readback path.  Runtime render
	// callbacks never call export_page; offline/editor code may call it once a slot is
	// ready to serialize the persistent SVT channels.
	Ref<Image> albedo_image = server->texture_2d_layer_get(albedo, p_slot);
	Ref<Image> normal_image = server->texture_2d_layer_get(normal, p_slot);
	Ref<Image> params_image = server->texture_2d_layer_get(params, p_slot);
	if (albedo_image.is_null() || normal_image.is_null() || params_image.is_null()) {
		return result;
	}
	result["albedo_height"] = albedo_image;
	result["normal_roughness"] = normal_image;
	result["params"] = params_image;
	result["valid"] = true;
	result["generation"] = int64_t(generation);
	return result;
}

Ref<Image> Terrain3DSurfaceBaker::get_page_preview(int p_slot) const {
	Dictionary page = export_page(p_slot);
	return page.get("albedo_height", Ref<Image>());
}

bool Terrain3DSurfaceBaker::has_render_work() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _configured && (!_pending.empty() || _invalidate_all || _materials_dirty ||
			_requested_capacity > _page_count || _retire_ready);
}

Dictionary Terrain3DSurfaceBaker::get_stats() const {
	std::lock_guard<std::mutex> lock(_mutex);
	Dictionary stats;
	stats["configured"] = _configured;
	stats["page_size"] = _page_size;
	stats["border"] = _border;
	stats["page_count"] = _page_count;
	stats["pending"] = int64_t(_pending.size());
	stats["generation"] = int64_t(_generation);
	stats["ready_pages"] = int64_t(std::count(_ready.begin(), _ready.end(), uint8_t(1)));
	stats["baked_pages"] = int64_t(_baked_pages);
	stats["cached_uploads"] = int64_t(_cached_uploads);
	stats["migrated_pages"] = int64_t(_migrated_pages);
	stats["invalidated_pages"] = int64_t(_invalidated_pages);
	stats["source_uploads"] = int64_t(_source_uploads);
	stats["dispatch_count"] = int64_t(_dispatch_count);
	return stats;
}

///////////////////////////
// Godot bindings
///////////////////////////

void Terrain3DSurfaceBaker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "page_size", "border", "page_count"),
			&Terrain3DSurfaceBaker::configure);
	ClassDB::bind_method(D_METHOD("set_materials", "albedo_array_rid", "normal_array_rid", "colors",
								 "normal_depths", "ao_strengths", "ao_affects", "roughness_mods", "uv_scales", "detiles",
								 "slope_params"),
			&Terrain3DSurfaceBaker::set_materials);
	ClassDB::bind_method(D_METHOD("queue_page", "slot", "idweights", "height", "world_rect", "slope_factor", "source_grid"),
			&Terrain3DSurfaceBaker::queue_page, DEFVAL(1.0f), DEFVAL(Vector3()));
	ClassDB::bind_method(D_METHOD("queue_cached_page", "slot", "channels"),
			&Terrain3DSurfaceBaker::queue_cached_page);
	ClassDB::bind_method(D_METHOD("invalidate_slot", "slot"), &Terrain3DSurfaceBaker::invalidate_slot);
	ClassDB::bind_method(D_METHOD("render_pending", "keep_alive"), &Terrain3DSurfaceBaker::render_pending,
			DEFVAL(Ref<RefCounted>()));
	ClassDB::bind_method(D_METHOD("get_albedo_rid"), &Terrain3DSurfaceBaker::get_albedo_rid);
	ClassDB::bind_method(D_METHOD("get_normal_rid"), &Terrain3DSurfaceBaker::get_normal_rid);
	ClassDB::bind_method(D_METHOD("get_params_rid"), &Terrain3DSurfaceBaker::get_params_rid);
	ClassDB::bind_method(D_METHOD("is_page_ready", "slot"), &Terrain3DSurfaceBaker::is_page_ready);
	ClassDB::bind_method(D_METHOD("export_page", "slot"), &Terrain3DSurfaceBaker::export_page);
	ClassDB::bind_method(D_METHOD("get_page_preview", "slot"), &Terrain3DSurfaceBaker::get_page_preview);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DSurfaceBaker::get_stats);
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DSurfaceBaker::clear);
}
