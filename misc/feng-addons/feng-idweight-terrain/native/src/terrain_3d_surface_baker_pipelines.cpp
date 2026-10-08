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

#include <algorithm>

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
	uvec4 indices; // source layer, output layer, mode (0 invalid, 1 bake), height layer
	vec4 policy; // slope distance/policy factor, source grid origin x/z and texel step
};

layout(set = 0, binding = 5, std430) readonly buffer JobBuffer {
	BakeJob jobs[];
} bake_jobs;

layout(set = 0, binding = 6, rgba16f) uniform writeonly image2DArray bake_output_albedo;
layout(set = 0, binding = 7, rgba16f) uniform writeonly image2DArray bake_output_normal;
layout(set = 0, binding = 8, rgba16f) uniform writeonly image2DArray bake_output_params;

layout(push_constant, std430) uniform BakePushConstants {
	uvec4 dims; // physical size, job count, material count, reserved
	// The shape of the *source* the two payload reads fetch from. A page job's source is a stored rect
	// with a gutter, which clamps: `x` is zero and the rest is unused. A clipmap job's source is a
	// level of the ring, which wraps by the level's own ring offset - `x` is the level's texel count,
	// `y`/`z` its ring - and whose payload layer is `FORMAT_RF` holding the packed pair raw rather than
	// `R16_UNORM` holding it normalised, which is what `w` names. See `surface_bake_source_coord()`.
	uvec4 source;
	// The rect of the output layer this dispatch writes: origin x/y and extent x/y. A page's job covers
	// the layer it fills, so its origin is zero and its extent is the stored size; a clipmap job covers
	// *one rect of a level* - a fill, a strip, an invalidated area - which is what keeps a level that
	// turned a strip from paying a bake of its whole square. `dims.x` stays the source square's size
	// either way, so the clamp a page's taps take and the wrap a ring's taps take are unchanged.
	uvec4 dest;
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

// Pack exact R16/float32 CPU source pages into the existing ID and height arrays. The per-page
// header contains word offsets and the destination layer; page texels are copied bit-for-bit
// except that R16_UNORM is written from its exact normalized integer value.
static const char *SURFACE_SOURCE_UPLOAD_SHADER = R"(#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer SourceUploadBuffer {
	uint words[];
} source_upload;
layout(set = 0, binding = 1, r16) uniform writeonly image2DArray source_id_image;
layout(set = 0, binding = 2, r32f) uniform writeonly image2DArray source_height_image;

layout(push_constant, std430) uniform SourceUploadPushConstants {
	uvec4 dims; // stored size, page count, reserved, reserved
} source_upload_push;

void main() {
	const uvec3 invocation = gl_GlobalInvocationID;
	const uint size = source_upload_push.dims.x;
	const uint page_count = source_upload_push.dims.y;
	if (invocation.x >= size || invocation.y >= size || invocation.z >= page_count) {
		return;
	}
	const uint header = invocation.z * 4u;
	const uint id_base = source_upload.words[header + 0u];
	const uint height_base = source_upload.words[header + 1u];
	const uint layer = source_upload.words[header + 2u];
	const uint pixel = invocation.y * size + invocation.x;
	const uint packed_ids = source_upload.words[id_base + pixel / 2u];
	const uint id_value = (packed_ids >> ((pixel & 1u) * 16u)) & 0xFFFFu;
	const float id_normalized = float(id_value) * (1.0 / 65535.0);
	const float height_value = uintBitsToFloat(source_upload.words[height_base + pixel]);
	const ivec3 target = ivec3(ivec2(invocation.xy), int(layer));
	imageStore(source_id_image, target, vec4(id_normalized, 0.0, 0.0, 1.0));
	imageStore(source_height_image, target, vec4(height_value, 0.0, 0.0, 1.0));
}
)";

///////////////////////////
// GPU setup
///////////////////////////

// All three programs share compilation and RID creation. The bundle keeps partial
// results for its owner to release; the optional uploader can fall back to texture_update.
bool Terrain3DSurfaceBaker::_compile_compute_pipeline(const char *p_source, const String &p_name,
		RID &r_shader, RID &r_pipeline, const bool p_optional) {
	if (!_rd) {
		return false;
	}
	[[maybe_unused]] const auto level = p_optional ? WARN : ERROR;
	Ref<RDShaderSource> source;
	source.instantiate();
	source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
	source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, p_source);
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
	if (spirv.is_null()) {
		LOG(level, p_name, " shader did not compile");
		return false;
	}
	const String compile_error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	if (!compile_error.is_empty()) {
		LOG(level, p_name, " shader compile error: ", compile_error);
		return false;
	}
	r_shader = _rd->shader_create_from_spirv(spirv, p_name);
	if (r_shader.is_valid()) {
		r_pipeline = _rd->compute_pipeline_create(r_shader);
	}
	if (!r_pipeline.is_valid()) {
		LOG(level, "Could not create ", p_name, " compute pipeline");
		return false;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_compile_pipeline(ResourceBundle &r_resources) {
	return _compile_compute_pipeline(SURFACE_BAKE_SHADER, "terrain3d_surface_bake",
			r_resources.shader, r_resources.pipeline);
}

// Compiles the block encoder into its own pipeline. It is only needed when at least one tier
// resolved to a compressed format, and a build whose encoder cannot compile has to say so
// once: without it a compressed tier would produce pages no encoder ever fills.
bool Terrain3DSurfaceBaker::_compile_encode_pipeline(ResourceBundle &r_resources) {
	if (!_compile_compute_pipeline(SURFACE_ENCODE_SHADER, "terrain3d_surface_encode",
				r_resources.encode_shader, r_resources.encode_pipeline)) {
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

bool Terrain3DSurfaceBaker::_compile_source_upload_pipeline(ResourceBundle &r_resources,
		const int p_stored_size, const int p_page_count) {
	if (!_rd || p_stored_size <= 0 || p_page_count <= 0 || !r_resources.source_id_rd.is_valid() ||
			!r_resources.source_height_rd.is_valid()) {
		return false;
	}
	const uint64_t texels = uint64_t(p_stored_size) * uint64_t(p_stored_size);
	const uint64_t id_bytes = texels * 2u;
	const uint64_t height_bytes = texels * 4u;
	const uint64_t id_padded = (id_bytes + 3u) & ~uint64_t(3u);
	const uint64_t bytes_per_page = 16u + id_padded + height_bytes;
	if (bytes_per_page > SOURCE_UPLOAD_MAX_BYTES) {
		return false;
	}
	const uint32_t max_pages = uint32_t(std::min<uint64_t>(
			std::min<uint32_t>(uint32_t(p_page_count), SOURCE_UPLOAD_MAX_PAGES),
			SOURCE_UPLOAD_MAX_BYTES / bytes_per_page));
	if (max_pages == 0) {
		return false;
	}
	const uint64_t capacity = uint64_t(max_pages) * (16u + id_padded + height_bytes);
	if (capacity == 0 || capacity > SOURCE_UPLOAD_MAX_BYTES || capacity > UINT32_MAX) {
		return false;
	}

	if (!_compile_compute_pipeline(SURFACE_SOURCE_UPLOAD_SHADER, "terrain3d_surface_source_upload",
				r_resources.source_upload_shader, r_resources.source_upload_pipeline, true)) {
		return false;
	}
	r_resources.source_upload_buffer = _rd->storage_buffer_create(uint32_t(capacity));
	if (!r_resources.source_upload_buffer.is_valid()) {
		return false;
	}
	_rd->set_resource_name(r_resources.source_upload_buffer, "Surface VT Packed Source Upload");
	TypedArray<Ref<RDUniform>> uniforms;
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 0,
			r_resources.source_upload_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 1, r_resources.source_id_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 2, r_resources.source_height_rd);
	r_resources.source_upload_uniform = _rd->uniform_set_create(uniforms, r_resources.source_upload_shader, 0);
	if (!r_resources.source_upload_uniform.is_valid()) {
		return false;
	}
	r_resources.source_upload_capacity_bytes = uint32_t(capacity);
	r_resources.source_upload_max_pages = max_pages;
	r_resources.source_upload_scratch.resize(int64_t(capacity));
	_source_upload_batch.clear();
	_source_upload_batch.reserve(max_pages);
	r_resources.source_upload_enabled = true;
	return true;
}

// The albedo and normal arrays a bake samples. A supplied array the device no longer owns is dead:
// Terrain3DAssets replaces the pair and frees the previous one, while a rebuild on the render thread
// can still hold that snapshot. resolve_main_texture() would hand the raw RenderingServer RID to the
// device, which rejects the binding - and the caller retried the same snapshot every frame, so a
// single dead pair produced an error per frame for the rest of the session. Fall back to the dummy
// array instead; the caller re-publishes the current pair as soon as materials_dirty() reports the
// snapshot was not accepted.
void Terrain3DSurfaceBaker::_resolve_material_rd(const ResourceBundle &p_resources, RID &r_albedo_rd,
		RID &r_normal_rd, const RID &p_albedo_array_rs, const RID &p_normal_array_rs) const {
	RenderingServer *server = RenderingServer::get_singleton();
	r_albedo_rd = server && p_albedo_array_rs.is_valid() ? server->texture_get_rd_texture(p_albedo_array_rs, true) : RID();
	r_normal_rd = server && p_normal_array_rs.is_valid() ? server->texture_get_rd_texture(p_normal_array_rs, false) : RID();
	if (!r_albedo_rd.is_valid()) {
		const RID resolved = resolve_main_texture(p_albedo_array_rs, true);
		r_albedo_rd = _rd->texture_is_valid(resolved) ? resolved : RID();
	}
	if (!r_normal_rd.is_valid()) {
		const RID resolved = resolve_main_texture(p_normal_array_rs, false);
		r_normal_rd = _rd->texture_is_valid(resolved) ? resolved : RID();
	}
	if (!r_albedo_rd.is_valid()) {
		r_albedo_rd = p_resources.dummy_albedo_rd;
	}
	if (!r_normal_rd.is_valid()) {
		r_normal_rd = p_resources.dummy_normal_rd;
	}
}

bool Terrain3DSurfaceBaker::_rebuild_uniform_set(ResourceBundle &r_resources,
		const RID &p_albedo_array_rs, const RID &p_normal_array_rs) {
	if (!_rd || !r_resources.shader.is_valid()) {
		return false;
	}
	// Freeing a resource makes the device drop every uniform set that depended on it, so this
	// one may already be gone when an array the set bound was freed with its asset. Asking the
	// device first keeps that from being reported as freeing an invalid ID.
	free_bake_set(_rd, r_resources.uniform_set);
	RID albedo_rd;
	RID normal_rd;
	_resolve_material_rd(r_resources, albedo_rd, normal_rd, p_albedo_array_rs, p_normal_array_rs);

	TypedArray<Ref<RDUniform>> uniforms;
	append_bake_uniforms(uniforms, r_resources.sampler_nearest, r_resources.sampler_linear,
			r_resources.source_id_rd, r_resources.source_height_rd, albedo_rd, normal_rd,
			r_resources.material_buffer, r_resources.job_buffer,
			{ r_resources.output_albedo_rd, r_resources.output_normal_rd, r_resources.output_params_rd });
	r_resources.uniform_set = _rd->uniform_set_create(uniforms, r_resources.shader, 0);
	if (!r_resources.uniform_set.is_valid()) {
		LOG(ERROR, "Could not create the surface bake uniform set");
		return false;
	}
	return true;
}
