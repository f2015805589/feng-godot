// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 3 of 6: the two GPU programs.
//
// One of six files that define Terrain3DSurfaceBaker. The bake pipeline, the block encoder, the
// GLSL both are compiled from, and the uniform sets they read. The sources are here because this
// is the only place that compiles them: `shaders/idweight_r16.glsl` and
// `shaders/surface_bake.glsl` are concatenated into the bake source so the packed-ID routines
// keep one definition shared with the material shader, and `shaders/bc_encode.glsl` is the
// encoder the storage half dispatches.
//
// The other halves: terrain_3d_surface_baker.cpp (the device and its objects),
// terrain_3d_surface_baker_bundle.cpp (the ResourceBundle's lifetime),
// terrain_3d_surface_baker_storage.cpp, terrain_3d_surface_baker_queue.cpp and
// terrain_3d_surface_baker_frame.cpp.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

// The codec vocabulary, the shared constants and the small helpers of the halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

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

// The block encoder, compiled into its own pipeline. It is the reason page compression costs
// the CPU nothing: the staging page stays on the GPU, the encoder reads it through a sampler
// and writes the codec's own block words into a storage buffer, and only those words - a
// sixteenth of the half-float page at BC7 - travel back to be uploaded into the sampling
// array. See shaders/bc_encode.glsl for the codecs and their layouts.
static const char *SURFACE_ENCODE_SHADER =
#include "shaders/bc_encode.glsl"
		;

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

// Compiles the block encoder into its own pipeline. It is only needed when at least one tier
// resolved to a compressed format, and a build whose encoder cannot compile has to say so
// once: without it a compressed tier would produce pages no encoder ever fills.
bool Terrain3DSurfaceBaker::_compile_encode_pipeline(ResourceBundle &r_resources) {
	if (!_rd) {
		return false;
	}
	Ref<RDShaderSource> source;
	source.instantiate();
	source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
	source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, SURFACE_ENCODE_SHADER);
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
	if (spirv.is_null()) {
		LOG(ERROR, "Surface block encoder shader did not compile");
		return false;
	}
	const String compile_error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	if (!compile_error.is_empty()) {
		LOG(ERROR, "Surface block encoder compile error: ", compile_error);
		return false;
	}
	r_resources.encode_shader = _rd->shader_create_from_spirv(spirv, "terrain3d_surface_encode");
	if (!r_resources.encode_shader.is_valid()) {
		LOG(ERROR, "Could not create the surface block encoder shader");
		return false;
	}
	r_resources.encode_pipeline = _rd->compute_pipeline_create(r_resources.encode_shader);
	if (!r_resources.encode_pipeline.is_valid()) {
		LOG(ERROR, "Could not create the surface block encoder compute pipeline");
		return false;
	}
	// One region per channel of every page that may be in flight at once. The buffer is a
	// few hundred kilobytes per page at the widest codec, which is what lets a compressed
	// tier cost one small allocation instead of a second page-sized array beside the staging
	// pool. Its depth is derived from the caller's page budget (see ENCODE_PAGES_MIN).
	const uint32_t ring_bytes = uint32_t(_encode_ring_allocated.load() * ENCODE_CHANNELS * _encode_region_bytes);
	r_resources.encode_buffer = _rd->storage_buffer_create(ring_bytes);
	if (!r_resources.encode_buffer.is_valid() || _encode_region_words <= 0) {
		LOG(ERROR, "Could not allocate the surface block encoder output buffer");
		return false;
	}
	_rd->set_resource_name(r_resources.encode_buffer, "Surface VT Block Encoder Output (ring of page layers)");
	for (int channel = 0; channel < ENCODE_CHANNELS; ++channel) {
		TypedArray<Ref<RDUniform>> uniforms;
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
				r_resources.sampler_nearest, _staging_rd_of(r_resources, channel));
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 1, r_resources.encode_buffer);
		// Parameter packing reads canonical roughness from the normal staging layer. Keep this
		// descriptor in every set so the shader layout stays stable while raw channels skip their
		// dispatches.
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
				r_resources.sampler_nearest, r_resources.output_normal_rd);
		r_resources.encode_uniform[channel] = _rd->uniform_set_create(uniforms, r_resources.encode_shader, 0);
		if (!r_resources.encode_uniform[channel].is_valid()) {
			LOG(ERROR, "Could not create the surface block encoder uniform set");
			return false;
		}
	}
	return true;
}

bool Terrain3DSurfaceBaker::_rebuild_uniform_set(ResourceBundle &r_resources,
		const RID &p_albedo_array_rs, const RID &p_normal_array_rs) {
	if (!_rd || !r_resources.shader.is_valid()) {
		return false;
	}
	// Freeing a resource makes the device drop every uniform set that depended on it, so this
	// one may already be gone when an array the set bound was freed with its asset. Asking the
	// device first keeps that from being reported as freeing an invalid ID.
	if (r_resources.uniform_set.is_valid() && _rd->uniform_set_is_valid(r_resources.uniform_set)) {
		_rd->free_rid(r_resources.uniform_set);
	}
	r_resources.uniform_set = RID();
	RenderingServer *server = RenderingServer::get_singleton();
	RID albedo_rd = server && p_albedo_array_rs.is_valid() ? server->texture_get_rd_texture(p_albedo_array_rs, true) : RID();
	RID normal_rd = server && p_normal_array_rs.is_valid() ? server->texture_get_rd_texture(p_normal_array_rs, false) : RID();
	// A supplied array the device no longer owns is dead: Terrain3DAssets replaces the pair
	// and frees the previous one, while a rebuild on the render thread can still hold that
	// snapshot. resolve_main_texture() would hand the raw RenderingServer RID to the device,
	// which rejects the binding - and the caller retried the same snapshot every frame, so a
	// single dead pair produced an error per frame for the rest of the session. Fall back to
	// the dummy array instead; the caller re-publishes the current pair as soon as
	// materials_dirty() reports the snapshot was not accepted.
	if (!albedo_rd.is_valid()) {
		const RID resolved = resolve_main_texture(p_albedo_array_rs, true);
		albedo_rd = _rd->texture_is_valid(resolved) ? resolved : RID();
	}
	if (!normal_rd.is_valid()) {
		const RID resolved = resolve_main_texture(p_normal_array_rs, false);
		normal_rd = _rd->texture_is_valid(resolved) ? resolved : RID();
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
