// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_BAKER_INTERNAL_H
#define TERRAIN3D_SURFACE_BAKER_INTERNAL_H

#include "constants.h"
#include "terrain_3d_surface_baker.h"

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

#include <cstdint>

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


inline constexpr int MATERIAL_COUNT = 32;
inline constexpr int MATERIAL_STRIDE = 64;
inline constexpr int JOB_STRIDE = 64;

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


// Frames a replaced page-array bundle is kept after the material acknowledged its successor.
// The renderer builds the draws of a frame before the material's new pair has necessarily
// reached them, so releasing on the acknowledgment itself - or on the very next frame - is
// reported once per draw as a missing material uniform set. Three frames matches the depth
// the device keeps in flight; the cost is a transient extra bundle during a format change.
inline constexpr uint64_t RETIRE_FRAME_MARGIN = 3;

} // namespace terrain_surface_baker

#endif // TERRAIN3D_SURFACE_BAKER_INTERNAL_H
