// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_BAKER_INTERNAL_H
#define TERRAIN3D_SURFACE_BAKER_INTERNAL_H

#include "constants.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_surface_idweight.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <cstdint>
#include <vector>

// The prologue the six translation units of Terrain3DSurfaceBaker share. It is a header rather
// than a fifth .cpp because every half needs a part of it and a second copy would be a second
// vocabulary: the codec table below decides both what a tier may be stored in and what the
// inspector reports, so the list, the translation to a page codec and the lookup have to be one
// definition. Everything here is `inline`, so all four units share the one object.
//
// What each half owns, in fill order:
//   terrain_3d_surface_baker.cpp            the device and the objects on it
//   terrain_3d_surface_baker_bundle.cpp     the ResourceBundle: its inventory, adoption and free
//   terrain_3d_surface_baker_pipelines.cpp  the bake pipeline, the block encoder, the uniform sets
//   terrain_3d_surface_baker_storage.cpp    page storage, the codec resolver and the block encoder
//   terrain_3d_surface_baker_queue.cpp      the caller-facing queue and the uploads that drain it
//   terrain_3d_surface_baker_frame.cpp      one frame's jobs, publication and the read-only state
//
// Include this after terrain_3d_surface_baker.h and add `using namespace terrain_surface_baker;`
// so the halves read as the single file they were, which is also what keeps their bodies
// byte-identical to that file.
namespace terrain_surface_baker {

// Keep diagnostic scopes balanced on upload failures and early returns.
struct SurfaceVTLabel {
	RenderingDevice *rd;
	SurfaceVTLabel(RenderingDevice *p_rd, const String &p_name) :
			rd(p_rd) {
		rd->draw_command_begin_label(p_name, Color(0.3f, 0.7f, 0.9f));
	}
	~SurfaceVTLabel() { rd->draw_command_end_label(); }
};

// The codec vocabulary of the terrain texture arrays, in the same order and naming as
// Terrain3DAssets::TextureArrayCompression, so a page setting and the asset inspector cannot
// drift apart. It is the *shared* list: it covers every codec the engine's own CPU encoders
// can apply to an authored array, which is a different question from what a material page can
// be stored in - see SurfacePageCompression and PAGE_CODEC_ATLAS below for that.
//
// `gpu_codec` is the block encoder's own id for the entry and `block_words` the words it
// writes per 4x4 block, or GPU_CODEC_NONE when shaders/bc_encode.glsl implements no encoder
// for it. Only the entries a page codec maps to have a GPU encoder at all; an entry without
// one can still be a valid setting for an authored texture array, where the CPU compresses it.
inline constexpr uint32_t GPU_CODEC_NONE = 0xffffffffu;

struct AtlasCodec {
	const char *name;
	Image::CompressMode mode;
	Image::UsedChannels channels;
	bool hdr;
	Image::ASTCFormat block;
	uint32_t gpu_codec;
	int block_words;
	// The linear renderer format, used by the normal and parameter pages, and the sRGB one,
	// used by the albedo page. DATA_FORMAT_MAX means the codec has no format of that kind;
	// a codec that cannot store a colour in sRGB is refused as a page codec, because a
	// block codec spends its bits in whatever space it is handed and linear darks fall below
	// its first step.
	RenderingDevice::DataFormat rd_format;
	RenderingDevice::DataFormat rd_format_srgb;
};
inline constexpr AtlasCodec ATLAS_CODECS[] = {
	{"Uncompressed", Image::COMPRESS_MAX, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"BC7", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, 4u, 4, RenderingDevice::DATA_FORMAT_BC7_UNORM_BLOCK, RenderingDevice::DATA_FORMAT_BC7_SRGB_BLOCK},
	{"BC1 RGB", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, 0u, 2, RenderingDevice::DATA_FORMAT_BC1_RGB_UNORM_BLOCK, RenderingDevice::DATA_FORMAT_BC1_RGB_SRGB_BLOCK},
	{"BC3 RGBA", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, 1u, 4, RenderingDevice::DATA_FORMAT_BC3_UNORM_BLOCK, RenderingDevice::DATA_FORMAT_BC3_SRGB_BLOCK},
	{"BC4 R", Image::COMPRESS_S3TC, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4, 2u, 2, RenderingDevice::DATA_FORMAT_BC4_UNORM_BLOCK, RenderingDevice::DATA_FORMAT_MAX},
	{"BC5 RG", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4, 3u, 4, RenderingDevice::DATA_FORMAT_BC5_UNORM_BLOCK, RenderingDevice::DATA_FORMAT_MAX},
	{"BC6H HDR RGB", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGB, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC1 RGB", Image::COMPRESS_ETC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC2 RGB", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ETC2 RGBA", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"EAC R11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"EAC RG11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 4x4 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 8x8 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_8x8, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 4x4 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
	{"ASTC 8x8 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_8x8, GPU_CODEC_NONE, 0, RenderingDevice::DATA_FORMAT_MAX, RenderingDevice::DATA_FORMAT_MAX},
};
inline constexpr int ATLAS_CODEC_COUNT = int(sizeof(ATLAS_CODECS) / sizeof(AtlasCodec));

// The page codecs, in the order the page settings offer them, mapped to their entry in the
// shared vocabulary above. The two lists differ on purpose: the array vocabulary is the asset
// inspector's and covers everything the engine's CPU encoders apply to a texture array, while
// a page is produced by this build's GPU block encoder and stored in one of its RGBA codecs.
// Keeping the mapping explicit is what lets a page setting name only codecs that have a
// producer, instead of offering an entry that the resolver then has to refuse.
inline constexpr int PAGE_CODEC_ATLAS[SURFACE_PAGE_COUNT] = {
	0, // SURFACE_PAGE_UNCOMPRESSED - samples the staging arrays, no codec involved.
	1, // SURFACE_PAGE_BC7 - 16 bytes per 4x4 block, the higher quality of the two.
	3, // SURFACE_PAGE_BC3 - 16 bytes per 4x4 block, the same storage size as BC7.
};
static_assert(PAGE_CODEC_ATLAS[SURFACE_PAGE_UNCOMPRESSED] < ATLAS_CODEC_COUNT &&
				PAGE_CODEC_ATLAS[SURFACE_PAGE_BC7] < ATLAS_CODEC_COUNT &&
				PAGE_CODEC_ATLAS[SURFACE_PAGE_BC3] < ATLAS_CODEC_COUNT,
		"every page codec must name an entry of the shared codec table");
static_assert(ATLAS_CODECS[PAGE_CODEC_ATLAS[SURFACE_PAGE_BC7]].gpu_codec != GPU_CODEC_NONE &&
				ATLAS_CODECS[PAGE_CODEC_ATLAS[SURFACE_PAGE_BC3]].gpu_codec != GPU_CODEC_NONE,
		"every page codec must have a GPU block encoder, or no page could ever be stored in it");

inline int page_codec_atlas(const int p_codec) {
	return PAGE_CODEC_ATLAS[CLAMP(p_codec, 0, int(SURFACE_PAGE_COUNT) - 1)];
}

inline const AtlasCodec &page_codec(const int p_codec) {
	return ATLAS_CODECS[page_codec_atlas(p_codec)];
}

// Normal pages use the same GPU block encoder with a different source transform. BC5 stores
// oct.x/y in its two alpha-style channels; BC3N uses BC3's A/G channels for devices that do not
// expose BC5. The normal setting is intentionally separate from page_codec(), whose ids are the
// diffuse request vocabulary.
inline int normal_codec_atlas(const int p_codec) {
	static constexpr int NORMAL_CODEC_ATLAS[SURFACE_NORMAL_COUNT] = {
		0, // uncompressed
		5, // BC5 RG
		3, // BC3N uses the BC3 block layout
		1, // BC7 RG octahedral normal
	};
	return NORMAL_CODEC_ATLAS[CLAMP(p_codec, 0, int(SURFACE_NORMAL_COUNT) - 1)];
}

inline const AtlasCodec &normal_codec(const int p_codec) {
	return ATLAS_CODECS[normal_codec_atlas(p_codec)];
}

inline int normal_mode_for_page_codec(const int p_page_codec) {
	switch (p_page_codec) {
		case SURFACE_PAGE_BC7:
			return SURFACE_NORMAL_BC7;
		case SURFACE_PAGE_BC3:
			return SURFACE_NORMAL_BC3N;
		default:
			return SURFACE_NORMAL_UNCOMPRESSED;
	}
}

// Parameter pages use the selected diffuse codec when it is compressed. When only the normal
// channel is compressed, BC7 is the fallback parameter codec because the diffuse channel has no
// page codec to select. A raw tier samples canonical parameters without a compressed array.
inline int params_codec_for_channels(const int p_diffuse_mode, const int p_normal_mode) {
	const int diffuse = CLAMP(p_diffuse_mode, 0, int(SURFACE_PAGE_COUNT) - 1);
	const int normal = CLAMP(p_normal_mode, 0, int(SURFACE_NORMAL_COUNT) - 1);
	if (diffuse == SURFACE_PAGE_UNCOMPRESSED && normal == SURFACE_NORMAL_UNCOMPRESSED) {
		return PAGE_CODEC_ATLAS[SURFACE_PAGE_UNCOMPRESSED];
	}
	const int selected = diffuse == SURFACE_PAGE_UNCOMPRESSED ? SURFACE_PAGE_BC7 : diffuse;
	return page_codec_atlas(selected);
}

inline const char *normal_codec_name(const int p_codec) {
	return p_codec == SURFACE_NORMAL_BC3N ? "BC3N" : normal_codec(p_codec).name;
}


// The material vocabulary's size is the packed-ID contract's own (`terrain_surface_idweight.h`):
// a page's material list and an encoded id/weight pair have to agree on it, and the two used to
// be two literals of the same value. `MATERIAL_STRIDE` is this producer's own.
inline constexpr int MATERIAL_COUNT = TerrainSurfaceIdWeight::MATERIAL_COUNT;
inline constexpr int MATERIAL_STRIDE = 64;
inline constexpr int JOB_STRIDE = 64;

// The bake shader's `BakeJob` (`shaders/surface_bake.glsl`) is the only reader of the buffer
// these jobs are written into, so its words are pinned here rather than left to a comment: the
// stride is four `vec4`/`uvec4` fields, and a job whose words grew would be read as another
// job's unless the shader's struct grew with it.
static_assert(JOB_STRIDE == 4 * 16, "BakeJob is world_rect, page, indices and policy - four 16-byte fields");
static_assert(MATERIAL_STRIDE == 64, "MaterialParams is color, normal_ao_rough, uv_detile and slope");

inline RID resolve_main_texture(const RID &p_rid, bool p_srgb = false) {
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

inline void append_uniform(TypedArray<Ref<RDUniform>> &r_uniforms,
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

inline void encode_vec4(PackedByteArray &r_data, int64_t p_offset, float p_x, float p_y,
		float p_z, float p_w) {
	r_data.encode_float(p_offset + 0, p_x);
	r_data.encode_float(p_offset + 4, p_y);
	r_data.encode_float(p_offset + 8, p_z);
	r_data.encode_float(p_offset + 12, p_w);
}

// ---- The bake flavors' shared pipeline ------------------------------------------------------------
//
// A ring level, an atlas block and a detail tile present the same work here: a rect they produced, a
// lease saying whether it is still theirs, and a job the shader reads. The job's words, the push
// constant, the descriptor set, the offer budget and the de-duplication were written once per flavor
// and had drifted; they are written once here.

// One job of the bake shader's `BakeJob`, in the shader's own field order: the world rect, the page
// shape, the four indices (source layer, output layer, mode, height layer) and the source policy.
// The byte offsets are the shader's (`shaders/surface_bake.glsl`), and JOB_STRIDE above is what pins
// the total, so a flavor cannot write another flavor's field.
inline void encode_bake_job(PackedByteArray &r_data, const int64_t p_offset, const Vector4 &p_world_rect,
		const Vector4 &p_page, const uint32_t p_source_layer, const uint32_t p_output_layer,
		const uint32_t p_mode, const uint32_t p_height_layer, const Vector4 &p_policy) {
	encode_vec4(r_data, p_offset, p_world_rect.x, p_world_rect.y, p_world_rect.z, p_world_rect.w);
	encode_vec4(r_data, p_offset + 16, p_page.x, p_page.y, p_page.z, p_page.w);
	r_data.encode_u32(p_offset + 32, p_source_layer);
	r_data.encode_u32(p_offset + 36, p_output_layer);
	r_data.encode_u32(p_offset + 40, p_mode);
	r_data.encode_u32(p_offset + 44, p_height_layer);
	encode_vec4(r_data, p_offset + 48, p_policy.x, p_policy.y, p_policy.z, p_policy.w);
}

// One dispatch's push constant (`BakePushConstants` in shaders/surface_bake.glsl), in the shader's
// own three `uvec4`s. `dims` is the physical size, the job count, the material count and - read only
// where the source wraps - "the stored index is the invocation's own rather than `dest.xy`";
// `source` is the wrapping source square (size, phase) and whether its payload is raw; `dest` is the
// output rect this dispatch writes. A stored rect's source is all zeroes, which is what makes the
// taps clamp.
struct BakePushConstant {
	uint32_t dims[4] = { 0u, 1u, 0u, 0u };
	uint32_t source[4] = { 0u, 0u, 0u, 0u };
	uint32_t dest[4] = { 0u, 0u, 0u, 0u };
};

inline PackedByteArray encode_bake_push(const BakePushConstant &p_push) {
	PackedByteArray data;
	data.resize(48);
	for (int word = 0; word < 4; word++) {
		data.encode_u32(word * 4, p_push.dims[word]);
		data.encode_u32(16 + word * 4, p_push.source[word]);
		data.encode_u32(32 + word * 4, p_push.dest[word]);
	}
	return data;
}

// The shared pipeline's own warning. `LOG(WARN, ...)` stamps the enclosing class with `__class__`,
// which a free function has not, so the class is named literally and the DEBUG gate is kept: a
// release build says nothing, exactly as the macro does.
inline void bake_warning(const String &p_label, const char *p_what) {
#ifdef DEBUG_ENABLED
	UtilityFunctions::push_warning("Terrain3DSurfaceBaker:", p_what, " ", p_label);
#else
	(void)p_label;
	(void)p_what;
#endif
}

// Records one dispatch: the job words are uploaded, the push constant set, and the one pipeline and
// set bound inside a compute list and a device label. The flavor supplies all four.
inline bool record_bake_dispatch(RenderingDevice *p_rd, const RID &p_job_buffer, const RID &p_set,
		const RID &p_pipeline, const PackedByteArray &p_job_bytes, const BakePushConstant &p_push,
		const int p_groups_x, const int p_groups_y, const int p_groups_z, const String &p_label) {
	if (p_rd->buffer_update(p_job_buffer, 0, uint32_t(p_job_bytes.size()), p_job_bytes) != OK) {
		bake_warning(p_label, "could not upload the bake jobs for");
		return false;
	}
	const PackedByteArray push = encode_bake_push(p_push);
	SurfaceVTLabel label(p_rd, p_label);
	const int64_t compute_list = p_rd->compute_list_begin();
	if (compute_list < 0) {
		bake_warning(p_label, "could not begin a compute list for");
		return false;
	}
	p_rd->compute_list_bind_compute_pipeline(compute_list, p_pipeline);
	p_rd->compute_list_bind_uniform_set(compute_list, p_set, 0);
	p_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
	p_rd->compute_list_dispatch(compute_list, uint32_t(p_groups_x), uint32_t(p_groups_y), uint32_t(p_groups_z));
	p_rd->compute_list_end();
	return true;
}

// The bake shader's descriptor set (set 0): the two source textures through the nearest sampler, the
// material arrays through the linear one, the material list, the job buffer, and the three output
// arrays. Nine bindings in the shader's own order - every flavor's set is exactly this, so it is
// appended here once and a flavor that added a binding would have to add it to the shader first.
inline void append_bake_uniforms(TypedArray<Ref<RDUniform>> &r_uniforms, const RID &p_sampler_nearest,
		const RID &p_sampler_linear, const RID &p_source0, const RID &p_source1, const RID &p_albedo,
		const RID &p_normal, const RID &p_material_buffer, const RID &p_job_buffer,
		const RID (&p_outputs)[3]) {
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
			p_sampler_nearest, p_source0);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
			p_sampler_nearest, p_source1);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
			p_sampler_linear, p_albedo);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3,
			p_sampler_linear, p_normal);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 4, p_material_buffer);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 5, p_job_buffer);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 6, p_outputs[0]);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 7, p_outputs[1]);
	append_uniform(r_uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 8, p_outputs[2]);
}

// Releases a bake's descriptor set if the device still owns it, and forgets it: the device drops a set
// when a resource it names is freed, so asking first keeps that from reading as an invalid ID.
inline void free_bake_set(RenderingDevice *p_rd, RID &r_set) {
	if (r_set.is_valid() && p_rd != nullptr && p_rd->uniform_set_is_valid(r_set)) {
		p_rd->free_rid(r_set);
	}
	r_set = RID();
}

// The identity of one offer, whichever storage produced it: the storage's unit, the lease it carried,
// and the rect. The conservative union of the keys the flavors used - a lease alone is not enough (an
// atlas reuses a slot) and neither is a rect (a ring turns its levels) - so work already on its way is
// recognized and no offered rect is dropped as a duplicate of a different one.
struct BakeOfferKey {
	int unit = -1;
	uint64_t lease = 0;
	int x0 = 0;
	int y0 = 0;
	int x1 = 0;
	int y1 = 0;

	bool same(const BakeOfferKey &p_other) const {
		return unit == p_other.unit && lease == p_other.lease && x0 == p_other.x0 && y0 == p_other.y0 &&
				x1 == p_other.x1 && y1 == p_other.y1;
	}
};

inline BakeOfferKey bake_offer_key(const TerrainClipmap::BakeRect &p_rect) {
	return { p_rect.unit, p_rect.lease, p_rect.x0, p_rect.y0, p_rect.x1, p_rect.y1 };
}

// The offer/collect loop every bake flavor runs: take what the storage has produced, drop the rects
// already on their way to a dispatch, and hand the batch to the next dispatch as the *queued* one.
// `p_offer(index, key, texels)` fills one pending rect's identity and its size in channel texels;
// `p_key(job)` reads the same identity back off a job; `p_job(index)` builds the flavor's own job. The
// caller holds the lock and has already reported the last dispatch's landings.
//
// The budget is the production budget's own unit and a *soft* bound: at least one rect is collected -
// a whole-level fill is larger than a tick's budget, and a budget that never admitted it would leave
// the level unbaked forever - and after that first rect it is a real bound. The clamped subtraction is
// the detail half's rule and the conservative one; the append to `queued` is that half's measured fix
// for a batch a render callback had not drained yet.
template <typename Job, typename OfferFn, typename KeyFn, typename JobFn>
int offer_bake_jobs(std::vector<Job> &r_collected, std::vector<Job> &r_queued, const int p_budget_texels,
		const int p_offer_count, OfferFn p_offer, KeyFn p_key, JobFn p_job) {
	std::vector<Job> fresh;
	std::vector<Job> previous = std::move(r_collected);
	r_collected.clear();
	int budget = MAX(0, p_budget_texels);
	for (int index = 0; index < p_offer_count; index++) {
		BakeOfferKey key;
		int64_t texels = 0;
		if (!p_offer(index, key, texels)) {
			continue;
		}
		bool already = false;
		for (const Job &job : previous) {
			already = already || p_key(job).same(key);
		}
		for (const Job &job : fresh) {
			already = already || p_key(job).same(key);
		}
		if (already) {
			continue;
		}
		if (!fresh.empty() && texels > int64_t(budget)) {
			break;
		}
		budget = int(MAX(int64_t(0), int64_t(budget) - texels));
		fresh.push_back(p_job(index));
	}
	for (const Job &job : previous) {
		r_queued.push_back(job);
	}
	r_collected = std::move(fresh);
	return int(r_collected.size());
}


// Frames a replaced page-array bundle is kept after the material acknowledged its successor.
// The renderer builds the draws of a frame before the material's new pair has necessarily
// reached them, so releasing on the acknowledgment itself - or on the very next frame - is
// reported once per draw as a missing material uniform set. Three frames matches the depth
// the device keeps in flight; the cost is a transient extra bundle during a format change.
inline constexpr uint64_t RETIRE_FRAME_MARGIN = 3;

} // namespace terrain_surface_baker

#endif // TERRAIN3D_SURFACE_BAKER_INTERNAL_H
