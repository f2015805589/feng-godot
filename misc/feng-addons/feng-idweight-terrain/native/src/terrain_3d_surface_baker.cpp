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

// Atlas codecs, in the same order and naming as Terrain3DAssets::TextureArrayCompression,
// so the inspector shows one vocabulary for every terrain texture array. Only the entries
// whose channels are RGBA are usable for material pages: each of the three arrays carries
// an alpha value the shader reads (material height, roughness, and the params validity
// bit), and a codec without alpha would silently drop it.
//
// `gpu_codec` is the block encoder's own id for the entry and `block_words` the words it
// writes per 4x4 block, or GPU_CODEC_NONE when shaders/bc_encode.glsl implements no encoder
// for it. Page compression runs on the GPU - that is what keeps a produced page at CPU cost
// of a small buffer copy - so a codec without an encoder here has no producer at all and is
// refused by the resolver rather than silently left blank.
static constexpr uint32_t GPU_CODEC_NONE = 0xffffffffu;

struct AtlasCodec {
	const char *name;
	Image::CompressMode mode;
	Image::UsedChannels channels;
	bool hdr;
	Image::ASTCFormat block;
	uint32_t gpu_codec;
	int block_words;
	RenderingDevice::DataFormat rd_format;
};
const AtlasCodec ATLAS_CODECS[] = {
	{"Uncompressed", Image::COMPRESS_MAX, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"BC7", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, 4u, 4, RenderingDevice::DATA_FORMAT_BC7_UNORM_BLOCK},
	{"BC1 RGB", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, 0u, 2, RenderingDevice::DATA_FORMAT_BC1_RGB_UNORM_BLOCK},
	{"BC3 RGBA", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, 1u, 4, RenderingDevice::DATA_FORMAT_BC3_UNORM_BLOCK},
	{"BC4 R", Image::COMPRESS_S3TC, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4, 2u, 2, RenderingDevice::DATA_FORMAT_BC4_UNORM_BLOCK},
	{"BC5 RG", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4, 3u, 4, RenderingDevice::DATA_FORMAT_BC5_UNORM_BLOCK},
	{"BC6H HDR RGB", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGB, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC1 RGB", Image::COMPRESS_ETC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC2 RGB", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC2 RGBA", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"EAC R11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"EAC RG11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 4x4 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 8x8 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_8x8, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 4x4 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 8x8 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_8x8, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX},
};
constexpr int ATLAS_CODEC_COUNT = int(sizeof(ATLAS_CODECS) / sizeof(AtlasCodec));
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

// The block encoder, compiled into its own pipeline. It is the reason page compression costs
// the CPU nothing: the staging page stays on the GPU, the encoder reads it through a sampler
// and writes the codec's own block words into a storage buffer, and only those words - a
// sixteenth of the half-float page at BC7 - travel back to be uploaded into the sampling
// array. See shaders/bc_encode.glsl for the codecs and their layouts.
static const char *SURFACE_ENCODE_SHADER =
#include "shaders/bc_encode.glsl"
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

void Terrain3DSurfaceBaker::_collect_bundle_rids(const ResourceBundle &p_resources,
		Array &r_rs_rids, Array &r_rd_rids) {
	for (const RID &wrapper : { p_resources.output_albedo_rs, p_resources.output_normal_rs,
				 p_resources.output_params_rs }) {
		if (wrapper.is_valid()) {
			r_rs_rids.push_back(wrapper);
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		for (const RID &wrapper : { p_resources.sampled[tier].albedo_rs,
					 p_resources.sampled[tier].normal_rs, p_resources.sampled[tier].params_rs }) {
			if (wrapper.is_valid()) {
				r_rs_rids.push_back(wrapper);
			}
		}
	}
	// Drop descriptor and pipeline objects before the resources they reference. The
	// RenderingDevice dependency tracker may invalidate a uniform set when one of its
	// textures is freed; freeing the texture first would make the later explicit
	// uniform-set free report an "invalid ID" during teardown.
	for (const RID &rid : { p_resources.uniform_set, p_resources.cell_pipeline, p_resources.cell_shader,
				 p_resources.pipeline, p_resources.shader }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (int channel = 0; channel < ENCODE_CHANNELS; ++channel) {
		if (p_resources.encode_uniform[channel].is_valid()) {
			r_rd_rids.push_back(p_resources.encode_uniform[channel]);
		}
	}
	for (const RID &rid : { p_resources.encode_pipeline, p_resources.encode_shader }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (const RID &rid : { p_resources.output_albedo_rd, p_resources.output_normal_rd, p_resources.output_params_rd,
				 p_resources.source_id_rd, p_resources.source_height_rd, p_resources.material_buffer,
				 p_resources.job_buffer, p_resources.dummy_albedo_rd, p_resources.dummy_normal_rd,
				 p_resources.sampler_nearest, p_resources.sampler_linear, p_resources.encode_buffer }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		for (const RID &rid : { p_resources.sampled[tier].albedo_rd, p_resources.sampled[tier].normal_rd,
					 p_resources.sampled[tier].params_rd }) {
			if (rid.is_valid()) {
				r_rd_rids.push_back(rid);
			}
		}
	}
}

void Terrain3DSurfaceBaker::_free_rids(RenderingDevice *p_rd, const Array &p_rs_rids,
		const Array &p_rd_rids) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (server) {
		for (int i = 0; i < p_rs_rids.size(); ++i) {
			const RID rid = p_rs_rids[i];
			if (rid.is_valid()) {
				server->free_rid(rid);
			}
		}
	}
	if (!p_rd) {
		return;
	}
	for (int i = 0; i < p_rd_rids.size(); ++i) {
		const RID rid = p_rd_rids[i];
		if (rid.is_valid()) {
			p_rd->free_rid(rid);
		}
	}
}

void Terrain3DSurfaceBaker::_free_bundle(RenderingDevice *p_rd, const ResourceBundle &p_resources) {
	Array rs_rids;
	Array rd_rids;
	_collect_bundle_rids(p_resources, rs_rids, rd_rids);
	_free_rids(p_rd, rs_rids, rd_rids);
}

void Terrain3DSurfaceBaker::_free_deferred(const Array &p_rs_rids, const Array &p_rd_rids) {
	RenderingServer *server = RenderingServer::get_singleton();
	_free_rids(server ? server->get_rendering_device() : nullptr, p_rs_rids, p_rd_rids);
}

uint64_t Terrain3DSurfaceBaker::_take_resources(ResourceBundle &r_resources) {
	std::lock_guard<std::mutex> lock(_mutex);
	const uint64_t generation = _resource_generation;
	r_resources = _resources;
	_resources = ResourceBundle();
	_resource_generation = 0;
	return generation;
}

Terrain3DSurfaceBaker::~Terrain3DSurfaceBaker() {
	clear();
}

void Terrain3DSurfaceBaker::clear() {
	std::vector<ResourceBundle> doomed;
	RenderingDevice *resource_rd = nullptr;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		resource_rd = _rd;
		if (_resources.output_albedo_rd.is_valid() || _resources.shader.is_valid()) {
			doomed.push_back(_resources);
		}
		for (const std::pair<uint64_t, ResourceBundle> &entry : _retired) {
			doomed.push_back(entry.second);
		}
		_retired.clear();
		_acknowledged_generation = 0;
		_retire_ready = false;
		_resources = ResourceBundle();
		_resource_generation = 0;
		_configured = false;
		_pending.clear();
		_ready.clear();
		_sampled_channel_mask.clear();
		_slot_sequence.clear();
		_slot_tier.clear();
		_slot_scratch.clear();
		_staging_layers = 0;
		_encode_pending.clear();
		{
			std::lock_guard<std::mutex> encode_lock(_encode_mutex);
			_encoded_layers.clear();
			// Sized to the deepest ring any budget can ask for; the admitted depth is
			// `_encode_ring_capacity`, which a bundle derives from the page budget.
			_encode_ring_held.assign(ENCODE_PAGES_MAX, 0);
		}
		_encode_region_bytes = 0;
		_encode_region_words = 0;
		_invalidate_all = false;
		++_generation;
		_rd = nullptr;
	}
	for (const ResourceBundle &resources : doomed) {
		if (!resources.shader.is_valid() && !resources.output_albedo_rd.is_valid() &&
				!resources.output_albedo_rs.is_valid()) {
			continue;
		}
		RenderingServer *server = RenderingServer::get_singleton();
		if (!server || server->is_on_render_thread()) {
			_free_bundle(resource_rd, resources);
			continue;
		}
		Array rs_rids;
		Array rd_rids;
		_collect_bundle_rids(resources, rs_rids, rd_rids);
		server->call_on_render_thread(callable_mp_static(&Terrain3DSurfaceBaker::_free_deferred)
											  .bind(rs_rids, rd_rids));
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
	uint64_t old_generation = 0;
	ResourceBundle old;
	std::vector<uint8_t> ready;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_resource_generation == p_generation && _resources.pipeline.is_valid()) {
			if (_resource_page_count >= p_page_count || !_retired.empty()) { return true; }
			growing = true; old_count = _resource_page_count;
			old = _resources; old_generation = _resource_generation; ready = _ready;
		}
	}
	if (!growing) {
		old_generation = _take_resources(old);
		if (old.output_albedo_rd.is_valid()) {
			// Keep the previous pair alive: the published RIDs are still what the
			// material samples until the main thread rebinds it after this rebuild.
			std::lock_guard<std::mutex> lock(_mutex);
			_retire_ready = false;
			_retired.push_back({ old_generation, old });
		} else {
			_free_bundle(_rd, old);
		}
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
	// Compressed copies of the three channels, one set per tier whose codec resolved. These
	// are the sampling targets of the block encoder, and the material samples them in place
	// of the staging arrays for the tier that owns them. A tier left uncompressed keeps an
	// empty set and samples the staging arrays directly, so an uncompressed tier costs
	// nothing at all - and it is also what keeps the staging arrays page sized.
	//
	// The encoder's output region is a function of the stored page size, and every codec it
	// implements writes at most four words per block.
	_encode_region_bytes = ((p_stored_size + 3) / 4) * ((p_stored_size + 3) / 4) * 4 * int(sizeof(uint32_t));
	_encode_region_words = _encode_region_bytes / int(sizeof(uint32_t));
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		_tiers[tier].applied.store(0);
		SampledSet &set = next.sampled[tier];
		const int mode = _tiers[tier].effective.load();
		const RenderingDevice::DataFormat format = _tiers[tier].format.load();
		if (mode == 0 || format == RenderingDevice::DATA_FORMAT_MAX) {
			continue;
		}
		// Sampling, update, and readback. Copy-from is what lets a resident page be exported
		// (the dock preview, the offline bake) once the scratch pool has reused the layer it
		// was produced in: the page's content is then its block words. On D3D12 copy-from sets
		// no resource flag at all; copy-*to* would, and it is the one that has to stay off.
		const uint64_t compressed_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
				RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
				RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
		set.albedo_rd = _create_texture(_rd, format, p_stored_size, p_page_count, compressed_usage);
		set.normal_rd = _create_texture(_rd, format, p_stored_size, p_page_count, compressed_usage);
		set.params_rd = _create_texture(_rd, format, p_stored_size, p_page_count, compressed_usage);
		const String tier_name = tier == TIER_SVT ? String("SVT") : String("AVT");
		if (set.albedo_rd.is_valid() && set.normal_rd.is_valid() && set.params_rd.is_valid()) {
			_rd->set_resource_name(set.albedo_rd, "Surface VT " + tier_name + " Albedo Height (compressed)");
			_rd->set_resource_name(set.normal_rd, "Surface VT " + tier_name + " Normal Roughness (compressed)");
			_rd->set_resource_name(set.params_rd, "Surface VT " + tier_name + " Parameters (compressed)");
			set.albedo_rs = RenderingServer::get_singleton()->texture_rd_create(
					set.albedo_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
			set.normal_rs = RenderingServer::get_singleton()->texture_rd_create(
					set.normal_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
			set.params_rs = RenderingServer::get_singleton()->texture_rd_create(
					set.params_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
			if (set.albedo_rs.is_valid() && set.normal_rs.is_valid() && set.params_rs.is_valid()) {
				_tiers[tier].applied.store(mode);
				continue;
			}
			// Fall back rather than render from an unwritable pair: drop the RS wrappers
			// and let _free_bundle release the RD textures with the bundle.
			set = SampledSet();
			_tiers[tier].effective.store(0);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			LOG(WARN, "Could not wrap the compressed surface arrays; keeping ", tier_name, " pages uncompressed");
		} else {
			// The capability probe only answers for a usage pair, not for this allocation
			// size and layer count, so a device can still refuse the real array. Report the
			// codec as unavailable instead of claiming a format the pages are not stored in.
			_tiers[tier].effective.store(0);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			LOG(WARN, "Could not allocate the compressed surface arrays; keeping ", tier_name, " pages uncompressed");
		}
	}
	// The half-float staging arrays are page sized only while something samples them by slot.
	// With every tier compressed they exist to be encoded and nothing else, so they come down
	// to the encoder ring and the resident pool loses its largest allocation. A tier that
	// failed to build its arrays above keeps `applied` at 0 and samples staging by slot, which
	// is why the count is decided here and not from the request.
	//
	// The ring depth is derived from the page budget so that the budget, not the ring, decides
	// the page rate, and it is capped by bytes because under the scratch regime these layers
	// are the largest allocation in the design. It is also kept to half the slot count, so a
	// compressed pool always costs at most half of what the page sized pool would - a small
	// pool with a large budget is the one case where those two rules meet.
	_encode_ring_allocated.store(CLAMP(MIN(_derive_encode_ring_pages(), MAX(p_page_count / 2, ENCODE_PAGES_MIN)),
			ENCODE_PAGES_MIN, ENCODE_PAGES_MAX));
	_staging_layers = _staging_is_scratch() ? _encode_ring_allocated.load() : p_page_count;
	_refresh_encode_ring_capacity();
	next.source_id_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16_UNORM, p_stored_size,
			_staging_layers, sampled_usage);
	next.source_height_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R32_SFLOAT, p_stored_size,
			_staging_layers, sampled_usage);
	next.output_albedo_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	next.output_normal_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	next.output_params_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	if (!next.dummy_albedo_rd.is_valid() || !next.dummy_normal_rd.is_valid() ||
			!next.sampler_nearest.is_valid() || !next.sampler_linear.is_valid() ||
			!next.source_id_rd.is_valid() || !next.source_height_rd.is_valid() ||
			!next.output_albedo_rd.is_valid() || !next.output_normal_rd.is_valid() ||
			!next.output_params_rd.is_valid()) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not allocate surface bake textures");
		return false;
	}
	const String layer_note = _staging_is_scratch()
			? String(" (scratch layer = encoder ring page)")
			: String(" (layer = physical slot)");
	_rd->set_resource_name(next.source_id_rd, "Surface VT Source IDWeights" + layer_note);
	_rd->set_resource_name(next.source_height_rd, "Surface VT Source Height" + layer_note);
	_rd->set_resource_name(next.output_albedo_rd, "Surface VT Albedo Height" + layer_note);
	_rd->set_resource_name(next.output_normal_rd, "Surface VT Normal Roughness" + layer_note);
	_rd->set_resource_name(next.output_params_rd, "Surface VT Parameters" + layer_note);
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
	// The block encoder is only built when a tier actually resolved to a compressed format.
	// A build whose encoder cannot compile drops both tiers back to uncompressed: a page
	// that samples an array nothing ever fills renders as the missing-page diagnostic, which
	// is worse than the memory the codec would have saved.
	if ((_tiers[TIER_AVT].applied.load() != 0 || _tiers[TIER_SVT].applied.load() != 0) && !_compile_encode_pipeline(next)) {
		for (int tier = 0; tier < TIER_COUNT; ++tier) {
			_tiers[tier].applied.store(0);
			_tiers[tier].effective.store(0);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			next.sampled[tier] = SampledSet();
		}
		_free_bundle(_rd, next);
		LOG(WARN, "Could not build the surface block encoder; keeping every page uncompressed");
		return false;
	}
	_rd->set_resource_name(next.job_buffer, "Surface VT Jobs (64 bytes: world rect, texel size, slot, mode)");
	_rd->set_resource_name(next.material_buffer, "Surface VT Material Parameters");
	_rd->set_resource_name(next.shader, "Surface VT Page Baker");
	// A fresh output has no valid pages.  Clearing all channels is recorded on the
	// main device; no submit or sync is performed here.
	_rd->texture_clear(next.output_albedo_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	_rd->texture_clear(next.output_normal_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	_rd->texture_clear(next.output_params_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	if (growing) {
		// Resource migration copies existing results; it does not rerun a page
		// shader or restart source work. Keep the old output alive until the next
		// material update has bound the new arrays, including already prepared draws.
		//
		// Under the scratch regime there is nothing to copy: a page's half-float content only
		// ever lives in the ring, and the compressed layers cannot be copied (a block format
		// cannot carry the unordered-access flag `texture_copy` needs on D3D12). Every page is
		// re-produced instead, which is what the block above already marked not ready.
		uint64_t copied = 0;
		if (!_staging_is_scratch()) {
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
		}
		std::lock_guard<std::mutex> lock(_mutex);
		_retire_ready = false;
		_retired.push_back({ old_generation, old });
		_migrated_pages += copied;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_resources = next;
		_resource_generation = p_generation;
		_resource_page_count = p_page_count;
		_page_count = p_page_count;
		_ready.resize(size_t(p_page_count), 0);
		_sampled_channel_mask.resize(size_t(p_page_count), 0);
		_slot_sequence.resize(size_t(p_page_count), 0);
		_slot_tier.resize(size_t(p_page_count), uint8_t(TIER_AVT));
		_slot_scratch.assign(size_t(p_page_count), uint8_t(ENCODE_RING_NONE));
		// A rebuilt bundle starts with empty compressed arrays. A grown bundle migrated the
		// staging content of every ready page, so encode it again into the new arrays; a
		// block-compressed layer cannot be copied between formats, and the staging copy is
		// what carries the content across the resize. Without this every page that was ready
		// before a capacity change would sample a zeroed compressed layer for the session.
		//
		// Under the scratch regime there is nothing to migrate: a page's half-float content
		// only ever lives in the ring, and the ring belongs to the bundle that was just
		// replaced. Every page is therefore re-produced, exactly as the compressed arrays
		// require anyway.
		_encode_pending.assign(size_t(p_page_count), 0);
		{
			// The ring is the encoder's own state, so it is guarded by the encode mutex.
			// Lock order is _mutex then _encode_mutex everywhere; the readback callback
			// takes them in separate scopes and never holds one while taking the other.
			std::lock_guard<std::mutex> encode_lock(_encode_mutex);
			_encode_ring_held.assign(ENCODE_PAGES_MAX, 0);
		}
		if (_staging_is_scratch()) {
			std::fill(_ready.begin(), _ready.end(), uint8_t(0));
			std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
		}
		for (size_t slot = 0; slot < _ready.size(); ++slot) {
			if (_ready[slot] && _slot_tier[slot] < TIER_COUNT && _tiers[_slot_tier[slot]].applied.load() != 0) {
				_encode_pending[slot] = 1;
			}
		}
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

// Frames a replaced page-array bundle is kept after the material acknowledged its successor.
// The renderer builds the draws of a frame before the material's new pair has necessarily
// reached them, so releasing on the acknowledgment itself - or on the very next frame - is
// reported once per draw as a missing material uniform set. Three frames matches the depth
// the device keeps in flight; the cost is a transient extra bundle during a format change.
static const uint64_t RETIRE_FRAME_MARGIN = 3;

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
	_sampled_channel_mask.assign(size_t(_page_count), 0);
	_slot_sequence.assign(size_t(_page_count), 0);
	_slot_tier.assign(size_t(_page_count), uint8_t(TIER_AVT));
	_slot_scratch.assign(size_t(_page_count), ENCODE_RING_NONE);
	_encode_pending.assign(size_t(_page_count), 0);
	_next_sequence = 1;
	_invalidate_all = true;
	_resource_generation = 0;
}

void Terrain3DSurfaceBaker::set_tier_compression(const int p_tier, const int p_mode) {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int mode = CLAMP(p_mode, 0, ATLAS_CODEC_COUNT - 1);
	if (mode == _tiers[tier].requested && _configured) {
		return;
	}
	_tiers[tier].requested = mode;
	_resolve_tier_compression(tier);
	LOG(INFO, "Surface page compression requested for ", tier == TIER_SVT ? "SVT" : "AVT", ": ",
			ATLAS_CODECS[_tiers[tier].requested].name,
			"; effective: ", ATLAS_CODECS[_tiers[tier].effective.load()].name,
			_tiers[tier].reason.is_empty() ? String() : String(" (") + _tiers[tier].reason + ")");
	if (_configured) {
		// The pages of that tier live in the previous format, so every page of the tier is
		// stale. Both tiers share the pool, and the bundle is rebuilt as one, so the whole
		// pool is re-produced rather than trying to keep the other tier's pages alive across
		// the rebuild.
		std::lock_guard<std::mutex> lock(_mutex);
		++_generation;
		_materials_dirty = true;
		_invalidate_all = true;
		_resource_generation = 0;
		std::fill(_ready.begin(), _ready.end(), uint8_t(0));
		std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
	}
}

// Resolves one tier's request against the block encoder this build ships and this device's
// sampling support. The encoder is a compute shader, so the codecs it implements decide what
// a page array can be stored in; a codec it does not implement has no producer and is
// reported as unavailable instead of leaving pages that no encoder ever fills. The device
// then has to be able to sample and update the resulting format, exactly as the engine's own
// compressed texture storage does.
void Terrain3DSurfaceBaker::_resolve_tier_compression(const int p_tier) {
	TierState &tier = _tiers[p_tier];
	const String tier_name = p_tier == TIER_SVT ? String("SVT") : String("AVT");
	tier.effective = 0;
	tier.format = RenderingDevice::DATA_FORMAT_MAX;
	tier.reason = String();
	if (tier.requested == 0) {
		return;
	}
	const AtlasCodec &codec = ATLAS_CODECS[tier.requested];
	if (codec.channels != Image::USED_CHANNELS_RGBA) {
		tier.reason = String(codec.name) +
				" keeps no alpha channel, and the material pages store height, roughness and the validity bit in alpha";
		return;
	}
	if (codec.gpu_codec == GPU_CODEC_NONE) {
		// The pages are encoded by shaders/bc_encode.glsl on the GPU. A codec it has no
		// encoder for would need a CPU block encoder per page, which is the cost this path
		// exists to remove, so it is refused rather than silently paid.
		tier.reason = String(codec.name) + " has no GPU block encoder, and page compression never runs a CPU codec";
		return;
	}
	// The renderer format comes from the codec table, so the table stays the single
	// vocabulary for every terrain texture array.
	const RenderingDevice::DataFormat format = codec.rd_format;
	if (format == RenderingDevice::DATA_FORMAT_MAX) {
		tier.reason = String(codec.name) + " has no renderer format";
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server ? server->get_rendering_device() : nullptr;
	if (rd && !rd->texture_is_format_supported_for_usage(format,
					  RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT)) {
		tier.reason = String(codec.name) + " cannot be sampled and updated on this rendering device";
		return;
	}
	tier.effective = tier.requested;
	tier.format = format;
	LOG(DEBUG, "Surface page compression for ", tier_name, " resolved to ", codec.name);
}

Dictionary Terrain3DSurfaceBaker::get_tier_compression_info(const int p_tier) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const TierState &state = _tiers[tier];
	Dictionary info;
	info["tier"] = tier;
	info["requested"] = state.requested;
	// `available` is what the block encoder and this device can store and sample; `applied`
	// is what the tier's page arrays are actually kept in. The two differ while the arrays
	// have not been built yet, and they also differ when the device refused the real
	// allocation after accepting the capability query, so the reported state never claims a
	// format the pages are not stored in.
	const int available = state.effective.load();
	info["available"] = available;
	info["applied"] = state.applied.load();
	info["name"] = String(ATLAS_CODECS[available].name);
	String reason = state.reason;
	if (reason.is_empty() && available == 0 && state.requested != 0) {
		reason = String(ATLAS_CODECS[state.requested].name) +
				String(" was resolved for this device, but the compressed page arrays could not be created");
	}
	info["reason"] = reason;
	info["rd_format"] = int(state.format.load());
	return info;
}

RID Terrain3DSurfaceBaker::_staging_rd_of(const ResourceBundle &p_resources, const int p_channel) {
	switch (p_channel) {
		case 0:
			return p_resources.output_albedo_rd;
		case 1:
			return p_resources.output_normal_rd;
		default:
			return p_resources.output_params_rd;
	}
}

RID Terrain3DSurfaceBaker::_staging_rd(const int p_channel) const {
	return _staging_rd_of(_resources, p_channel);
}

RID Terrain3DSurfaceBaker::_sampled_rd(const int p_tier, const int p_channel) const {
	const SampledSet &set = _resources.sampled[CLAMP(p_tier, 0, TIER_COUNT - 1)];
	switch (p_channel) {
		case 0:
			return set.albedo_rd;
		case 1:
			return set.normal_rd;
		default:
			return set.params_rd;
	}
}

RID Terrain3DSurfaceBaker::_sampled_rs(const int p_tier, const int p_channel) const {
	const SampledSet &set = _resources.sampled[CLAMP(p_tier, 0, TIER_COUNT - 1)];
	switch (p_channel) {
		case 0:
			return set.albedo_rs;
		case 1:
			return set.normal_rs;
		default:
			return set.params_rs;
	}
}

// True when this tier's pages are stored in its own compressed set and not in the staging
// arrays. A tier that did not resolve to a codec samples the staging arrays, which is why
// an uncompressed tier costs no memory at all beyond the pool it already has.
bool Terrain3DSurfaceBaker::_tier_uses_sampled(const int p_tier) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	return _tiers[tier].applied.load() != 0 && _resources.sampled[tier].albedo_rs.is_valid();
}

// True when every tier resolved to a compressed format, so no consumer samples the RGBA16F
// staging arrays by slot and they can shrink to the encoder ring. Decided from the resolved
// state, not from `applied`: the arrays are allocated before a bundle becomes the current one,
// and the answer has to be the same for the arrays and for the code that indexes them.
bool Terrain3DSurfaceBaker::_staging_is_scratch() const {
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		if (_tiers[tier].effective.load() == 0 ||
				_tiers[tier].format.load() == RenderingDevice::DATA_FORMAT_MAX) {
			return false;
		}
	}
	return true;
}

// Bytes one ring position costs. The encoder writes three channel regions per page, and
// under the scratch regime the same position also owns the half-float staging layer the page
// is produced into, which is the larger of the two and the one that decides the ceiling.
int64_t Terrain3DSurfaceBaker::_encode_page_bytes() const {
	const int64_t regions = int64_t(_encode_region_bytes) * ENCODE_CHANNELS;
	if (!_staging_is_scratch()) {
		return regions;
	}
	return regions + int64_t(_stored_size) * _stored_size * 30;
}

// Depth the ring needs so that the caller's page budget, not the ring, decides how many
// pages a frame finishes: a page's regions are held for about two frames, so the ring has to
// hold two budgets' worth. Bounded by bytes, because the same positions are the staging pool
// under the scratch regime.
int Terrain3DSurfaceBaker::_derive_encode_ring_pages() const {
	const int64_t page_bytes = _encode_page_bytes();
	const int64_t affordable = page_bytes > 0 ? ENCODE_RING_BUDGET_BYTES / page_bytes
											  : int64_t(ENCODE_PAGES_MAX);
	const int ceiling = int(CLAMP(affordable, int64_t(ENCODE_PAGES_MIN), int64_t(ENCODE_PAGES_MAX)));
	const int wanted = _page_budget.load() * ENCODE_READBACK_FRAMES;
	return CLAMP(MIN(wanted, ceiling), ENCODE_PAGES_MIN, ENCODE_PAGES_MAX);
}

void Terrain3DSurfaceBaker::_refresh_encode_ring_capacity() {
	int capacity = CLAMP(MIN(_derive_encode_ring_pages(), _encode_ring_allocated.load()),
			ENCODE_PAGES_MIN, ENCODE_PAGES_MAX);
	// The scratch regime indexes the staging layers that were allocated with the bundle, so
	// the admitted depth can never exceed them.
	const int layers = _staging_layers;
	if (layers > 0) {
		capacity = MIN(capacity, layers);
	}
	_encode_ring_capacity.store(capacity);
}

// Bytes the three compressed arrays of one tier cost in the current bundle's slot count.
// Only the tiers that resolved contribute; a tier left uncompressed samples the staging pool.
int64_t Terrain3DSurfaceBaker::_tier_sampled_bytes(const int p_tier) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int mode = _tiers[tier].applied.load();
	if (mode == 0 || !_resources.sampled[tier].albedo_rd.is_valid()) {
		return 0;
	}
	const AtlasCodec &codec = ATLAS_CODECS[mode];
	if (codec.block_words == 0) {
		return 0;
	}
	// `block_words` is words per 4x4 block, so bytes per texel is block_words / 4.
	const int64_t blocks = (int64_t(_stored_size) + 3) / 4;
	return blocks * blocks * codec.block_words * int64_t(sizeof(uint32_t)) * ENCODE_CHANNELS * _page_count;
}

void Terrain3DSurfaceBaker::_mark_sampled_channel_ready(const int p_tier, const int p_slot,
		const int p_channel, const uint64_t p_generation, const uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_generation != p_generation || p_slot < 0 || p_slot >= int(_ready.size()) ||
			p_slot >= int(_sampled_channel_mask.size()) || p_slot >= int(_slot_sequence.size()) ||
			_slot_sequence[size_t(p_slot)] != p_sequence ||
			_slot_tier[size_t(p_slot)] != uint8_t(CLAMP(p_tier, 0, TIER_COUNT - 1))) {
		return;
	}
	_sampled_channel_mask[size_t(p_slot)] |= uint8_t(1u << uint32_t(p_channel));
	if (_sampled_channel_mask[size_t(p_slot)] == 0x7u) {
		_ready[size_t(p_slot)] = 1;
	}
}

// A page whose encode did not land is reported as not ready, so the tier that owns it
// produces it again instead of sampling a layer nothing ever filled. The flag was cleared
// when the page was produced (a compressed page is only ready once its blocks arrive), so
// this is what restores the retry the demand passes rely on.
void Terrain3DSurfaceBaker::_mark_encode_failed(const int p_slot, const uint64_t p_generation,
		const uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_generation != p_generation || p_slot < 0 || p_slot >= int(_ready.size()) ||
			p_slot >= int(_slot_sequence.size()) || _slot_sequence[size_t(p_slot)] != p_sequence) {
		return;
	}
	_ready[size_t(p_slot)] = 0;
	if (p_slot < int(_sampled_channel_mask.size())) {
		_sampled_channel_mask[size_t(p_slot)] = 0;
	}
}

// The recording-time half of the encode. The readback callback only queues the blocks it
// received; this uploads them into the tier's sampling array while the frame's draw graph is
// recording, because an update recorded outside one is dropped by the render graph.
bool Terrain3DSurfaceBaker::_upload_encoded_layer(const int p_tier, const int p_channel,
		const int p_slot, const uint64_t p_generation, const uint64_t p_sequence,
		const PackedByteArray &p_data) {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_generation != p_generation || p_slot < 0 || p_slot >= _page_count ||
				p_slot >= int(_slot_sequence.size()) || _slot_sequence[size_t(p_slot)] != p_sequence ||
				_slot_tier[size_t(p_slot)] != uint8_t(tier)) {
			return false;
		}
	}
	const RID target = _sampled_rd(tier, p_channel);
	if (!_rd || _tiers[tier].applied.load() == 0 || !target.is_valid() || p_data.is_empty()) {
		return false;
	}
	if (_rd->texture_update(target, uint32_t(p_slot), p_data) != OK) {
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Could not upload a compressed material page; compressed pages will stay blank");
		}
		_encode_failures++;
		return false;
	}
	_encode_updates++;
	_mark_sampled_channel_ready(tier, p_slot, p_channel, p_generation, p_sequence);
	return true;
}

// Uploads the layers the readback callbacks compressed. Called from the render callback
// while its draw graph is recording; a layer encoded against an array bundle that has since
// been replaced is dropped, because a rebuild invalidates every page and re-encodes it.
void Terrain3DSurfaceBaker::_flush_encodes(uint64_t p_generation) {
	std::vector<EncodedLayer> layers;
	{
		std::lock_guard<std::mutex> lock(_encode_mutex);
		if (_encoded_layers.empty()) {
			return;
		}
		layers.swap(_encoded_layers);
	}
	for (const EncodedLayer &layer : layers) {
		if (layer.generation != p_generation) {
			continue;
		}
		_upload_encoded_layer(layer.tier, layer.channel, layer.slot, layer.generation, layer.sequence, layer.data);
	}
}

// Records the block-encoder dispatches for every pending page that can be given an output
// region, and requests one buffer readback per channel. A synchronous readback is not safe
// from inside the render callback, and a block-compressed texture cannot be a storage image,
// so the words have to travel through a buffer - a few tens of kilobytes per layer instead of
// the whole half-float page.
void Terrain3DSurfaceBaker::_request_encodes() {
	if (!_rd || !_resources.encode_pipeline.is_valid() || _encode_region_words <= 0) {
		return;
	}
	bool any_sampled = false;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		any_sampled = any_sampled || _tier_uses_sampled(tier);
	}
	if (!any_sampled) {
		return;
	}
	int64_t compute_list = -1;
	for (size_t slot = 0; slot < _encode_pending.size(); ++slot) {
		if (!_encode_pending[slot]) {
			continue;
		}
		uint64_t generation = 0;
		uint64_t sequence = 0;
		int tier = 0;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if (slot >= _slot_sequence.size() || slot >= _slot_tier.size()) {
				continue;
			}
			tier = _slot_tier[slot];
			if (tier >= TIER_COUNT) {
				continue;
			}
			generation = _generation;
			sequence = _slot_sequence[slot];
		}
		if (!_tier_uses_sampled(tier)) {
			// The tier is stored uncompressed, so its pages already sample the staging
			// arrays and there is nothing to encode.
			_encode_pending[slot] = 0;
			continue;
		}
		const AtlasCodec &codec = ATLAS_CODECS[_tiers[tier].applied.load()];
		const int blocks = (_stored_size + 3) / 4;
		// Under the scratch regime the page already owns a ring page: it was taken when the
		// page was produced, it is the layer the production wrote into, and it is what holds
		// that layer until the readbacks below have been delivered. Otherwise only the
		// encoder's output region has to be reserved, and the staging layer is the slot.
		int ring_page = -1;
		int source_layer = int(slot);
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if (slot < _slot_scratch.size() && _slot_scratch[slot] != ENCODE_RING_NONE) {
				ring_page = int(_slot_scratch[slot]);
				source_layer = ring_page;
			}
		}
		if (ring_page < 0) {
			// Reserve one ring page per pending page. Without a free page the page waits for
			// a later frame: its readbacks have not been delivered, so reusing the regions
			// would let a readback observe a later page's blocks. The ring is as deep as the
			// page budget needs it to be, so this is a frame's worth of readback latency
			// rather than the production rate.
			const int ring_depth = _encode_ring_capacity.load();
			std::lock_guard<std::mutex> lock(_encode_mutex);
			for (int page_index = 0; page_index < ring_depth; ++page_index) {
				if (_encode_ring_held[size_t(page_index)] != 0) {
					continue;
				}
				ring_page = page_index;
				_encode_ring_held[size_t(page_index)] = uint8_t(ENCODE_CHANNELS);
				break;
			}
		}
		if (ring_page < 0) {
			// Keep the flag set so a later frame encodes this page.
			continue;
		}
		if (compute_list < 0) {
			compute_list = _rd->compute_list_begin();
			if (compute_list < 0) {
				_hold_encode_page(ring_page, 0);
				return;
			}
			_rd->compute_list_bind_compute_pipeline(compute_list, _resources.encode_pipeline);
		}
		SurfaceVTLabel label(_rd, "Surface Block Encode - slot " + String::num_int64(int(slot)));
		PackedByteArray push;
		push.resize(32);
		push.encode_u32(0, uint32_t(_stored_size));
		push.encode_u32(4, uint32_t(source_layer));
		push.encode_u32(8, codec.gpu_codec);
		push.encode_u32(12, uint32_t(blocks));
		int outstanding = 0;
		bool requested = true;
		for (int channel = 0; channel < ENCODE_CHANNELS && requested; ++channel) {
			const int region = ring_page * ENCODE_CHANNELS + channel;
			push.encode_u32(16, uint32_t(region * _encode_region_words));
			push.encode_u32(20, 0u);
			push.encode_u32(24, 0u);
			push.encode_u32(28, 0u);
			if (!_resources.encode_uniform[channel].is_valid()) {
				requested = false;
				break;
			}
			_rd->compute_list_bind_uniform_set(compute_list, _resources.encode_uniform[channel], 0);
			_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
			_rd->compute_list_dispatch(compute_list, uint32_t((blocks * blocks + 63) / 64), 1, 1);
			// The encoder reads the staging layer this frame's bake or cell copy wrote, so
			// this dispatch has to be ordered after that write, not merely recorded after it.
			_rd->compute_list_add_barrier(compute_list);
			const uint32_t offset = uint32_t(region * _encode_region_bytes);
			const uint32_t layer_bytes = uint32_t(blocks * blocks * codec.block_words * int(sizeof(uint32_t)));
			requested = _rd->buffer_get_data_async(_resources.encode_buffer,
							   callable_mp(this, &Terrain3DSurfaceBaker::_on_encode_readback)
									   .bind(int(slot), channel, tier, ring_page, generation, sequence),
							   offset, layer_bytes) == OK;
			if (requested) {
				++outstanding;
			}
		}
		if (requested) {
			_encode_pending[slot] = 0;
			_encode_requests++;
			continue;
		}
		// The readback was refused (or a uniform set is missing): the page keeps its pending
		// flag so a later frame retries it, and the ring page drops back to the readbacks that
		// really are in flight - releasing all three here would leave the callbacks of the
		// ones that were issued with nothing to decrement, and the page would never free.
		_hold_encode_page(ring_page, outstanding);
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Could not request a block encoder readback; compressed pages will stay blank");
		}
	}
	if (compute_list >= 0) {
		_rd->compute_list_end();
	}
}

// Takes the scratch layer a page about to be produced writes its half-float channels into.
// Under the page-sized staging arrays that is the slot itself and nothing has to be held;
// under the scratch regime it is a ring page, held until that page's block readbacks have
// been delivered, because the half-float content only exists for as long as the encode needs
// it. Returns -1 when every ring page is held, which defers the production to a later frame.
int Terrain3DSurfaceBaker::_take_staging_layer(const int p_slot) {
	if (!_staging_is_scratch()) {
		if (p_slot >= 0 && p_slot < int(_slot_scratch.size())) {
			_slot_scratch[size_t(p_slot)] = ENCODE_RING_NONE;
		}
		return p_slot;
	}
	std::lock_guard<std::mutex> lock(_encode_mutex);
	for (int page = 0; page < _encode_ring_capacity.load(); ++page) {
		if (_encode_ring_held[size_t(page)] != 0) {
			continue;
		}
		_encode_ring_held[size_t(page)] = uint8_t(ENCODE_CHANNELS);
		if (p_slot >= 0 && p_slot < int(_slot_scratch.size())) {
			_slot_scratch[size_t(p_slot)] = uint8_t(page);
		}
		return page;
	}
	return -1;
}

// Sets one ring page's outstanding readback count. Takes the encode mutex alone.
void Terrain3DSurfaceBaker::_hold_encode_page(const int p_page, const int p_outstanding) {
	std::lock_guard<std::mutex> lock(_encode_mutex);
	if (p_page < 0 || p_page >= int(_encode_ring_held.size())) {
		return;
	}
	_encode_ring_held[size_t(p_page)] = uint8_t(CLAMP(p_outstanding, 0, ENCODE_CHANNELS));
}

// Releases one ring page's regions. Only the completion callback calls this, and it never
// holds the world mutex, so the ring is released under the encode mutex alone.
void Terrain3DSurfaceBaker::_release_encode_page(const int p_page) {
	std::lock_guard<std::mutex> lock(_encode_mutex);
	if (p_page < 0 || p_page >= int(_encode_ring_held.size()) || _encode_ring_held[size_t(p_page)] == 0) {
		// The ring was rebuilt under this callback, so the count belongs to a bundle that no
		// longer exists.
		return;
	}
	_encode_ring_held[size_t(p_page)]--;
}

void Terrain3DSurfaceBaker::_on_encode_readback(const PackedByteArray &p_data, const int p_slot,
		const int p_channel, const int p_tier, const int p_page, const uint64_t p_generation,
		const uint64_t p_sequence) {
	_release_encode_page(p_page);
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	bool stale = false;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		stale = _generation != p_generation || p_slot < 0 || p_slot >= int(_slot_sequence.size()) ||
				_slot_sequence[size_t(p_slot)] != p_sequence;
	}
	if (stale) {
		return;
	}
	const AtlasCodec &codec = ATLAS_CODECS[_tiers[tier].applied.load()];
	const int blocks = (_stored_size + 3) / 4;
	const int64_t expected = int64_t(blocks) * blocks * codec.block_words * int64_t(sizeof(uint32_t));
	if (codec.block_words == 0 || p_data.size() != expected) {
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Block encoder readback size ", int64_t(p_data.size()), " does not match ", expected);
		}
		_encode_failures++;
		_mark_encode_failed(p_slot, p_generation, p_sequence);
		return;
	}
	_encode_readbacks++;
	// This callback runs inside the frame stall, where the draw graph has already been
	// ended: queue the blocks and let the next render callback, which records, upload them.
	EncodedLayer layer;
	layer.channel = p_channel;
	layer.slot = p_slot;
	layer.tier = tier;
	layer.generation = p_generation;
	layer.sequence = p_sequence;
	layer.data = p_data;
	{
		std::lock_guard<std::mutex> lock(_encode_mutex);
		if (_encoded_layers.size() >= size_t(MAX(4, _page_count) * 3)) {
			_encode_failures++;
			_mark_encode_failed(p_slot, p_generation, p_sequence);
			return;
		}
		_encoded_layers.push_back(std::move(layer));
	}
}

// Compresses and decodes one image through the codec a tier resolved to, reporting the error
// it introduced. This is the CPU reference for the codec's error bound: the page pipeline
// itself never runs a CPU codec (the block encoder does that on the GPU), so the probe is
// what a test can call to state how lossy a codec is. Uncompressed - and every refused
// request - must round trip exactly.
Dictionary Terrain3DSurfaceBaker::probe_tier_compression(const int p_tier, const Ref<Image> &p_image) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	Dictionary result;
	result["tier"] = tier;
	result["mode"] = _tiers[tier].effective.load();
	result["applied"] = _tiers[tier].applied.load();
	result["name"] = String(ATLAS_CODECS[_tiers[tier].effective.load()].name);
	result["valid"] = false;
	result["max_error"] = 0.0;
	result["mean_error"] = 0.0;
	if (p_image.is_null()) {
		return result;
	}
	const AtlasCodec &codec = ATLAS_CODECS[_tiers[tier].effective.load()];
	if (codec.mode == Image::COMPRESS_MAX || codec.channels != Image::USED_CHANNELS_RGBA) {
		result["valid"] = true;
		return result;
	}
	Ref<Image> source = p_image->duplicate();
	source->convert(Image::FORMAT_RGBA8);
	Ref<Image> decoded = source->duplicate();
	if (decoded->compress_from_channels(codec.mode, codec.channels, codec.block) != OK || !decoded->is_compressed() ||
			decoded->decompress() != OK) {
		return result;
	}
	const int width = source->get_width();
	const int height = source->get_height();
	double max_error = 0.0;
	double total = 0.0;
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			const Color reference = source->get_pixel(x, y);
			const Color actual = decoded->get_pixel(x, y);
			for (int channel = 0; channel < 4; ++channel) {
				const double error = Math::abs(double(reference[channel]) - double(actual[channel]));
				max_error = MAX(max_error, error);
				total += error;
			}
		}
	}
	result["valid"] = true;
	result["max_error"] = max_error;
	result["mean_error"] = total / double(width * height * 4);
	return result;
}

void Terrain3DSurfaceBaker::set_page_budget(const int p_pages) {
	_page_budget.store(CLAMP(p_pages, 1, 16));
	// A budget change moves the depth the ring has to hold for that budget to be the rate
	// that decides page production. It never exceeds what the bundle allocated, so this only
	// ever re-admits positions the allocation already has.
	_refresh_encode_ring_capacity();
}

void Terrain3DSurfaceBaker::request_capacity(int p_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_requested_capacity = std::max(_requested_capacity, p_count);
}
int Terrain3DSurfaceBaker::get_capacity() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _page_count;
}

bool Terrain3DSurfaceBaker::has_pending_capacity() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _configured && _requested_capacity > _page_count;
}

bool Terrain3DSurfaceBaker::materials_stale() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _materials_stale;
}

void Terrain3DSurfaceBaker::acknowledge_output(const RID &p_albedo) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!p_albedo.is_valid()) {
		return;
	}
	// Which bundle the material bound, not which bundle exists now. The render thread can
	// rebuild between the caller reading the RID and this call, and acknowledging the newer
	// generation would let the release below free the arrays the material is actually
	// sampling - the renderer then reports a missing material uniform set for one frame.
	// Both RIDs a bundle can publish are matched, because a bundle built before a format
	// change carries no compressed pair while the current setting says there is one.
	auto bundle_generation = [](const ResourceBundle &p_bundle, const RID &p_rid) -> bool {
		if (p_bundle.output_albedo_rs == p_rid) {
			return true;
		}
		for (int tier = 0; tier < TIER_COUNT; ++tier) {
			if (p_bundle.sampled[tier].albedo_rs == p_rid) {
				return true;
			}
		}
		return false;
	};
	uint64_t generation = 0;
	if (bundle_generation(_resources, p_albedo)) {
		generation = _resource_generation;
	} else {
		for (const std::pair<uint64_t, ResourceBundle> &entry : _retired) {
			if (bundle_generation(entry.second, p_albedo)) {
				generation = entry.first;
				break;
			}
		}
	}
	if (generation == 0) {
		return;
	}
	_acknowledged_generation = MAX(_acknowledged_generation, generation);
	_acknowledged_frame = Engine::get_singleton()->get_frames_drawn();
	_retire_ready = true;
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
	// A fresh snapshot replaces whatever the render thread could not bind.
	_materials_stale = false;
	_invalidate_all = true;
	std::fill(_ready.begin(), _ready.end(), uint8_t(0));
	std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
}

void Terrain3DSurfaceBaker::queue_page(int p_slot, const Ref<Image> &p_idweights,
		const Ref<Image> &p_height, const Rect2 &p_world_rect, float p_slope_factor, Vector3 p_source_grid,
		int p_tier) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || p_idweights.is_null() || p_height.is_null()) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_BAKE;
	job.tier = tier;
	job.idweights = p_idweights;
	job.height = p_height;
	job.world_rect = p_world_rect;
	job.source_grid = p_source_grid;
	job.slope_factor = std::clamp(p_slope_factor, 0.0f, 1.0f);
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cached_page(int p_slot, const Dictionary &p_channels, int p_tier) {
	Ref<Image> albedo = p_channels.get("albedo_height", Variant());
	Ref<Image> normal = p_channels.get("normal_roughness", Variant());
	Ref<Image> params = p_channels.get("params", Variant());
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || albedo.is_null() || normal.is_null() || params.is_null()) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CACHED;
	job.tier = tier;
	job.albedo_height = albedo;
	job.normal_roughness = normal;
	job.params = params;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect, int p_tier) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CELL;
	job.tier = tier;
	job.cells = p_cells;
	job.world_rect = p_rect;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::invalidate_slot(int p_slot) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_INVALIDATE;
	// An invalidation clears a slot's content, it does not hand the slot to the other view:
	// the tier stays whatever last filled it until the next queue call names a producer.
	job.tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
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
	const int layer = p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot;
	if (_rd->texture_update(_resources.output_albedo_rd, uint32_t(layer), albedo) != OK ||
			_rd->texture_update(_resources.output_normal_rd, uint32_t(layer), normal) != OK ||
			_rd->texture_update(_resources.output_params_rd, uint32_t(layer), params) != OK) {
		LOG(WARN, "Could not upload cached surface page ", p_job.slot);
		return false;
	}
	return true;
}

// Copy cropped cell sources into runtime pages, area-weighting cells when a coarse pixel
// spans several source cells. A piece that names a resident cell is copied straight from
// the GPU cell store; a piece that carries images is uploaded first, which is the path an
// offline bake that has not been published into the store still uses. No material rebake
// happens either way.
bool Terrain3DSurfaceBaker::_copy_cell_page(const PendingJob &p_job, Terrain3DCellStore *p_store) {
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
		_rd->texture_clear(target, Color(0, 0, 0, 0), 0, 1, p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot, 1);
	}
	int piece_index = 0;
	for (const Dictionary &piece : p_job.cells) {
		std::vector<RID> textures;
		// Views into the cell store belong to this call and are freed with it; uploaded
		// textures are ours as well, so one list of owned RIDs covers both.
		std::vector<RID> owned;
		const int layer = int(piece.get("layer", -1));
		const int level = int(piece.get("level", 0));
		for (int channel = 0; channel < 3; ++channel) {
			if (layer >= 0 && p_store) {
				const RID view = p_store->create_sample_view(channel, layer, level);
				textures.push_back(view);
				if (view.is_valid()) { owned.push_back(view); }
				continue;
			}
			Ref<Image> image = piece[String(channel == 0 ? "albedo_height" : (channel == 1 ? "normal_roughness" : "params"))];
			if (image.is_null()) {
				textures.push_back(RID());
				continue;
			}
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
			const RID texture = _rd->texture_create(format, view, data);
			textures.push_back(texture);
			if (texture.is_valid()) { owned.push_back(texture); }
		}
		bool sources_valid = true;
		for (const RID &texture : textures) {
			if (!texture.is_valid()) { sources_valid = false; }
		}
		if (!sources_valid) {
			for (const RID &rid : owned) { _rd->free_rid(rid); }
			continue;
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
		push.encode_s32(56, p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot);
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
		for (RID texture : owned) {
			_rd->free_rid(texture);
		}
	}
	return true;
}

void Terrain3DSurfaceBaker::set_cell_store(const Ref<Terrain3DCellStore> &p_store) {
	std::lock_guard<std::mutex> lock(_mutex);
	_cell_store = p_store;
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
		const int layer = job.staging_layer >= 0 ? job.staging_layer : job.slot;
		uint32_t mode = 0u;
		if (job.kind == PENDING_BAKE && p_material_count > 0 && _upload_source_page(job, layer)) {
			mode = 1u;
		} else if (job.kind == PENDING_BAKE) {
			job.kind = PENDING_INVALIDATE;
		}
		const float texel_x = p_page_size > 0 ? job.world_rect.size.x / float(p_page_size) : 1.0f;
		const float texel_z = p_page_size > 0 ? job.world_rect.size.y / float(p_page_size) : 1.0f;
		encode_vec4(job_bytes, offset, job.world_rect.position.x, job.world_rect.position.y,
				job.world_rect.size.x, job.world_rect.size.y);
		encode_vec4(job_bytes, offset + 16, texel_x, texel_z, float(p_page_size), float(p_border));
		job_bytes.encode_u32(offset + 32, uint32_t(std::max(0, layer)));
		job_bytes.encode_u32(offset + 36, uint32_t(std::max(0, layer)));
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
	if (!p_ready) {
		_ready[size_t(p_slot)] = 0;
		if (p_slot < int(_sampled_channel_mask.size())) {
			_sampled_channel_mask[size_t(p_slot)] = 0;
		}
		return;
	}
	// A tier stored uncompressed produces straight into the staging arrays the material
	// samples, so recording its successful write makes the page ready. A tier stored
	// compressed produces into a different array set and becomes ready only once all three
	// encoded layers have uploaded - and the flag is *not* cleared while an encode is in
	// flight, because a demand pass that reads it as "not ready" produces the page again and
	// the page then never settles.
	const int tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
	_ready[size_t(p_slot)] = _tier_uses_sampled(tier) ? 0 : 1;
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
	Ref<Terrain3DCellStore> cell_store;
	// The device drops a uniform set when a texture it bound is freed, and an asset edit frees
	// the arrays this set binds. Rebuild it through the materials path instead of dispatching
	// with a set the device no longer has: the renderer reports that as a null uniform set on
	// the bind and a missing set 0 on the dispatch. Reporting the materials as stale as well
	// asks the caller for the current pair, which is what makes the rebuild bind live arrays.
	if (_resources.pipeline.is_valid() && !_resources.uniform_set.is_valid()) {
		std::lock_guard<std::mutex> lock(_mutex);
		_materials_dirty = true;
		_materials_stale = true;
	}
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
		// Kept alive for the whole callback: a queued cell copy names a layer of this store.
		cell_store = _cell_store;
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
		std::vector<ResourceBundle> retiring;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			// Everything older than the bundle the material currently samples is
			// unreferenced and can go. Nothing is freed while the material has not
			// acknowledged a published pair yet, because these are exactly the arrays
			// its already prepared draws may still bind. The acknowledgment is only
			// honoured from the frame after it arrived: the material's new pair is
			// published on the main thread and reaches the drawn material during that
			// frame's render, in which this pass runs.
			const uint64_t frames_drawn = Engine::get_singleton()->get_frames_drawn();
			const uint64_t acknowledged = frames_drawn > _acknowledged_frame + RETIRE_FRAME_MARGIN ? _acknowledged_generation : 0;
			if (acknowledged != 0) {
				for (size_t index = 0; index < _retired.size();) {
					if (_retired[index].first < acknowledged) {
						retiring.push_back(_retired[index].second);
						_retired.erase(_retired.begin() + index);
						continue;
					}
					++index;
				}
			}
			if (!retiring.empty()) { _retire_ready = false; }
		}
		for (const ResourceBundle &bundle : retiring) { _free_bundle(_rd, bundle); }
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
			// The snapshot named an array the asset system already replaced and freed. Forget
			// the cached pair so no later snapshot repeats it, and report the staleness: the
			// caller publishes the current pair, which also invalidates the pages this pass
			// would otherwise have baked from the fallback array.
			_material_albedo_rs = RID();
			_material_normal_rs = RID();
			_materials_stale = true;
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
	// Invalidation only needs to clear readiness, not shade every cache texel. Under the
	// scratch regime nothing samples the staging arrays at all - the compressed layer of a
	// re-assigned slot keeps the previous page's material for the frame or two until its own
	// encode lands, exactly as it does with page-sized staging - so an invalidation never has
	// to touch a layer, and the layers it could name are not the slot's anyway.
	const bool scratch = _staging_is_scratch();
	const int cleared_layers = scratch ? _staging_layers : page_count;
	const bool cleared_all = invalidate_all && _rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, 0, uint32_t(cleared_layers)) == OK;
	const uint64_t frame = Engine::get_singleton()->get_frames_drawn();
	if (_render_frame != frame) { _render_frame = frame; _frame_page_updates = 0; }
	// Compressed page production happens here, inside the recording, in two halves: the
	// layers a readback callback compressed since the last callback are uploaded first, so
	// the frames this callback's own production does not cover already sample real data;
	// the readbacks for the pages produced below are then requested from this same
	// recording, which is what makes a page compressed by the frame that produced it.
	_flush_encodes(generation);
	for (PendingJob &job : jobs) {
		if (job.generation != generation || job.slot < 0 || job.slot >= page_count) {
			continue;
		}
		if (job.kind == PENDING_INVALIDATE && (cleared_all || scratch ||
				_rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) == OK)) {
			_set_ready(job.slot, false, generation, material_version, job.sequence);
			{ std::lock_guard<std::mutex> lock(_mutex); ++_invalidated_pages; }
			continue;
		}
		if (job.kind != PENDING_INVALIDATE) {
			if (_frame_page_updates >= _page_budget.load()) {
				{ std::lock_guard<std::mutex> lock(_mutex); _pending.emplace(job.slot, job); }
				// A reused slot must not expose its previous material while deferred.
				PendingJob invalid = job;
				invalid.kind = PENDING_INVALIDATE;
				if (!cleared_all && !scratch &&
						_rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) != OK) {
					compute_jobs.push_back(invalid);
				}
				continue;
			}
			// The layer this page is shaded into: the slot under page-sized staging, a ring
			// page under the scratch regime - and a ring page that is held until this page's
			// block readbacks arrive, because the half-float content only exists that long.
			const int layer = _take_staging_layer(job.slot);
			if (layer < 0) {
				// Every ring page is waiting on readbacks. Defer the page exactly as the
				// budget does, so a later frame produces it with a layer of its own.
				{ std::lock_guard<std::mutex> lock(_mutex); _pending.emplace(job.slot, job); }
				continue;
			}
			job.staging_layer = layer;
			++_frame_page_updates;
		}
		if (job.kind == PENDING_CACHED || job.kind == PENDING_CELL) {
			if (job.kind == PENDING_CELL ? _copy_cell_page(job, cell_store.ptr()) : _upload_cached_page(job)) {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_cached_uploads++;
				}
				// Both far-field paths end with the three channels in the staging arrays -
				// the cached path uploads them, the cell path accumulated them there - so the
				// block encoder is the only thing that turns them into the SVT page. This is
				// where a far-field page is compressed, once per production: an SVT page's
				// content is final, so nothing re-encodes it while the slot keeps its page.
				if (_tier_uses_sampled(job.tier) && job.slot >= 0 && job.slot < int(_encode_pending.size())) {
					_encode_pending[size_t(job.slot)] = 1;
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
	// A pure invalidation has nothing to shade under the scratch regime: its only effect is
	// the readiness clear above, and dispatching it would write zeros into whichever scratch
	// layer the shader named, which may belong to a page whose encode is still in flight.
	if (scratch) {
		compute_jobs.erase(std::remove_if(compute_jobs.begin(), compute_jobs.end(),
								   [](const PendingJob &p_job) { return p_job.kind == PENDING_INVALIDATE; }),
				compute_jobs.end());
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
				// The bake dispatch is recorded just above, so the encoder dispatch requested
				// below reads the staging layer this same recording wrote.
				if (_tier_uses_sampled(job.tier) && job.slot >= 0 && job.slot < int(_encode_pending.size())) {
					_encode_pending[size_t(job.slot)] = 1;
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
	// Every page produced by this callback (bake or cell copy) is read back here, in the
	// same recording that wrote it.
	_request_encodes();
	if (requested_capacity > page_count) {
		// Migrate after this frame's writes so both the still-bound old arrays and
		// the newly published arrays contain the same completed page contents.
		_ensure_resources(generation, requested_capacity, stored_size, material_albedo, material_normal, material_bytes);
	}
}

///////////////////////////
// Read-only state and explicit export
///////////////////////////

// Single-channel getters kept for callers that predate the bundle read. They report the AVT
// tier, which is the tier the legacy single compression setting addresses; anything that has
// to bind both tiers at once reads get_published_arrays() instead.
RID Terrain3DSurfaceBaker::get_albedo_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_uses_sampled(TIER_AVT)) {
		return _resources.sampled[TIER_AVT].albedo_rs;
	}
	return _resources.output_albedo_rs;
}

// The three sampled arrays of one bundle, read under a single lock. The three getters above
// take the mutex separately, and the render thread replaces the whole bundle between two of
// them, so a caller that used them one by one could bind the albedo of one generation beside
// the normal of the next. That mix is the material sampling an array the release below is
// about to free, which the renderer reports once per draw as a missing material uniform set.
//
// Both tiers are published at once: the AVT arrays under the legacy keys, the SVT arrays
// under an `svt_` prefix. A tier that is stored uncompressed resolves to the staging arrays,
// which is what makes one setting able to be compressed while the other is not.
Dictionary Terrain3DSurfaceBaker::get_published_arrays() const {
	std::lock_guard<std::mutex> lock(_mutex);
	Dictionary result;
	if (_resource_generation != _generation) {
		return result;
	}
	auto publish = [this](Dictionary &r_result, int p_tier, const String &p_prefix) {
		const bool compressed = _tiers[p_tier].applied.load() != 0;
		r_result[p_prefix + String("albedo_height")] = (compressed && _resources.sampled[p_tier].albedo_rs.is_valid())
				? _resources.sampled[p_tier].albedo_rs
				: _resources.output_albedo_rs;
		r_result[p_prefix + String("normal_roughness")] = (compressed && _resources.sampled[p_tier].normal_rs.is_valid())
				? _resources.sampled[p_tier].normal_rs
				: _resources.output_normal_rs;
		r_result[p_prefix + String("params")] = (compressed && _resources.sampled[p_tier].params_rs.is_valid())
				? _resources.sampled[p_tier].params_rs
				: _resources.output_params_rs;
	};
	publish(result, TIER_AVT, String());
	publish(result, TIER_SVT, String("svt_"));
	result["generation"] = int64_t(_resource_generation);
	return result;
}

// Generation of the arrays get_published_arrays() hands out. A material has to rebind whenever
// this changes, not only when the near field's albedo does: both tiers' sets are replaced as a
// bundle, and a far-field-only change would otherwise leave the material sampling freed arrays.
uint64_t Terrain3DSurfaceBaker::get_published_generation() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _resource_generation == _generation ? _resource_generation : 0;
}

RID Terrain3DSurfaceBaker::get_normal_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_uses_sampled(TIER_AVT)) {
		return _resources.sampled[TIER_AVT].normal_rs;
	}
	return _resources.output_normal_rs;
}

RID Terrain3DSurfaceBaker::get_params_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_uses_sampled(TIER_AVT)) {
		return _resources.sampled[TIER_AVT].params_rs;
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
	int tier = TIER_AVT;
	bool scratch = false;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (p_slot < 0 || p_slot >= int(_ready.size()) || !_ready[size_t(p_slot)]) {
			return result;
		}
		tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
		scratch = _staging_is_scratch();
		if (scratch && _tier_uses_sampled(tier)) {
			// Under the scratch regime a slot's half-float layer is long gone: it was reused
			// by the next page the frame produced. The page's content is its block words, so
			// the export reads those and decodes them.
			albedo = _sampled_rs(tier, 0);
			normal = _sampled_rs(tier, 1);
			params = _sampled_rs(tier, 2);
		} else {
			albedo = _resources.output_albedo_rs;
			normal = _resources.output_normal_rs;
			params = _resources.output_params_rs;
		}
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
	// A block-compressed layer comes back compressed, and every caller wants texels: the
	// offline SVT bake crops the border off and generates mipmaps from them.
	for (Ref<Image> *image : { &albedo_image, &normal_image, &params_image }) {
		if ((*image)->is_compressed() && (*image)->decompress() != OK) {
			return result;
		}
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
	return _configured && (!_pending.empty() || _invalidate_all || _materials_dirty || _materials_stale ||
			_requested_capacity > _page_count || !_retired.empty() || _retire_ready);
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
	// Replaced arrays still alive because the material has not been rebound yet. This
	// has to read 0 in a settled frame, otherwise a rebuild is leaking its predecessor.
	stats["retired_bundles"] = int64_t(_retired.size());
	// A snapshot whose arrays were freed before the render thread bound them. It must return
	// to false on the following publish; a stuck true means the bake is using the fallback
	// array and the material pages it produces are not the artist's material.
	stats["materials_stale"] = _materials_stale;
	// The AVT tier under the legacy keys, both tiers under their own. `applied` is what the
	// tier's pages are actually stored in, which is what a test checks against the request.
	stats["atlas_compression"] = _tiers[TIER_AVT].requested;
	stats["atlas_compression_available"] = _tiers[TIER_AVT].effective.load();
	stats["atlas_compression_applied"] = _tiers[TIER_AVT].applied.load();
	stats["atlas_compression_name"] = String(ATLAS_CODECS[_tiers[TIER_AVT].effective.load()].name);
	stats["atlas_compression_reason"] = get_tier_compression_info(TIER_AVT).get("reason", String());
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const String prefix = tier == TIER_SVT ? String("svt_compression") : String("avt_compression");
		const Dictionary info = get_tier_compression_info(tier);
		stats[prefix + String("_requested")] = info.get("requested", 0);
		stats[prefix + String("_available")] = info.get("available", 0);
		stats[prefix + String("_applied")] = info.get("applied", 0);
		stats[prefix + String("_name")] = info.get("name", String());
		stats[prefix + String("_reason")] = info.get("reason", String());
	}
	stats["encode_pending"] = int64_t(std::count(_encode_pending.begin(), _encode_pending.end(), uint8_t(1)));
	// The half-float pool's shape: page sized while a tier samples it by slot, the encoder
	// ring once every tier is compressed. `staging_bytes` is what the pool costs - the
	// three RGBA16F outputs at 8 bytes per texel plus the R16/R32F sources at 6 - and
	// `material_bytes` is what the page arrays cost in total, which is the number the
	// compression settings move: the pool plus one compressed copy per tier that resolved.
	stats["staging_layers"] = _staging_layers;
	stats["staging_scratch"] = _staging_is_scratch();
	const int64_t staging_bytes = int64_t(_staging_layers) * _stored_size * _stored_size * 30;
	stats["staging_bytes"] = staging_bytes;
	int64_t compressed_bytes = 0;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const int64_t tier_bytes = _tier_sampled_bytes(tier);
		compressed_bytes += tier_bytes;
		const String tier_key = tier == TIER_SVT ? String("svt_") : String("avt_");
		stats[tier_key + String("bytes")] = tier_bytes;
	}
	stats["compressed_bytes"] = compressed_bytes;
	stats["material_bytes"] = staging_bytes + compressed_bytes;
	// Pool occupancy per tier: the slots whose content was produced for that tier, and how
	// many of those hold a page the material can sample. With the pool shared, a setting is
	// only worth its memory if the pages that use it are the ones resident.
	int64_t tier_slots[TIER_COUNT] = { 0, 0 };
	int64_t tier_ready[TIER_COUNT] = { 0, 0 };
	for (size_t slot = 0; slot < _slot_sequence.size(); ++slot) {
		if (_slot_sequence[slot] == 0) {
			continue;
		}
		const int tier = slot < _slot_tier.size() && _slot_tier[slot] < TIER_COUNT ? _slot_tier[slot] : TIER_AVT;
		tier_slots[tier]++;
		if (slot < _ready.size() && _ready[slot]) {
			tier_ready[tier]++;
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const String tier_key = tier == TIER_SVT ? String("svt_") : String("avt_");
		stats[tier_key + String("slots")] = tier_slots[tier];
		stats[tier_key + String("ready_slots")] = tier_ready[tier];
	}
	stats["encode_ring_capacity"] = _encode_ring_capacity.load();
	stats["encode_ring_allocated"] = _encode_ring_allocated.load();
	stats["encode_requests"] = int64_t(_encode_requests);
	stats["encode_readbacks"] = int64_t(_encode_readbacks);
	stats["encode_updates"] = int64_t(_encode_updates);
	stats["encode_failures"] = int64_t(_encode_failures);
	stats["encode_ring_pages"] = int64_t(std::count_if(_encode_ring_held.begin(), _encode_ring_held.end(),
			[](uint8_t p_held) { return p_held != 0; }));
	return stats;
}

int64_t Terrain3DSurfaceBaker::get_material_bytes() const {
	std::lock_guard<std::mutex> lock(_mutex);
	int64_t total = int64_t(_staging_layers) * _stored_size * _stored_size * 30;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		total += _tier_sampled_bytes(tier);
	}
	return total;
}

int Terrain3DSurfaceBaker::get_ready_page_count() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return int(std::count(_ready.begin(), _ready.end(), uint8_t(1)));
}

int Terrain3DSurfaceBaker::get_pending_page_count() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return int(_pending.size());
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
	ClassDB::bind_method(D_METHOD("queue_page", "slot", "idweights", "height", "world_rect", "slope_factor", "source_grid", "tier"),
			&Terrain3DSurfaceBaker::queue_page, DEFVAL(1.0f), DEFVAL(Vector3()), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("queue_cached_page", "slot", "channels", "tier"),
			&Terrain3DSurfaceBaker::queue_cached_page, DEFVAL(1));
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
