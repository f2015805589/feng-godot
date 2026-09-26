// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DAssets, part 2 of 3: the texture array.

// One of three files that define the asset library. This one turns the texture list into the two
// channel arrays the shader samples. `_update_texture_files()` builds the albedo and normal
// layers, reusing `_texture_layer_cache` for any layer whose identity has not changed - size,
// compression, mipmaps, layer kind, working format and a SHA-256 of the source bytes - and
// `_update_texture_settings()` packs the per-layer parameters, always 32 of them, because the
// shader's uniform array is fixed at 32 slots and a short array would leave the tail stale.
//
// The codec table at the top is this file's vocabulary: the array compression setting, the working
// format each codec needs, its HDR flag and the ASTC block size all come from one row, and the
// `static_assert` keeps the row count equal to `ARRAY_COMPRESSION_MAX`.
//
// The other two: `terrain_3d_assets.cpp` (the resource object and the shared list engine) and
// `terrain_3d_assets_meshes.cpp` (the mesh list and its thumbnails).

#include "terrain_3d_assets.h"

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/hashing_context.hpp>

#include <utility>

///////////////////////////
// Private Functions
///////////////////////////

namespace {
struct ArrayCodec {
	const char *name;
	Image::CompressMode mode;
	Image::UsedChannels channels;
	bool hdr;
	Image::ASTCFormat block;
};
const ArrayCodec ARRAY_CODECS[] = {
	{"Uncompressed", Image::COMPRESS_MAX, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4},
	{"BC7", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4},
	{"BC1 RGB", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4},
	{"BC3 RGBA", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4},
	{"BC4 R", Image::COMPRESS_S3TC, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4},
	{"BC5 RG", Image::COMPRESS_S3TC, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4},
	{"BC6H HDR RGB", Image::COMPRESS_BPTC, Image::USED_CHANNELS_RGB, true, Image::ASTC_FORMAT_4x4},
	{"ETC1 RGB", Image::COMPRESS_ETC, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4},
	{"ETC2 RGB", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGB, false, Image::ASTC_FORMAT_4x4},
	{"ETC2 RGBA", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4},
	{"EAC R11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_R, false, Image::ASTC_FORMAT_4x4},
	{"EAC RG11", Image::COMPRESS_ETC2, Image::USED_CHANNELS_RG, false, Image::ASTC_FORMAT_4x4},
	{"ASTC 4x4 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_4x4},
	{"ASTC 8x8 RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, false, Image::ASTC_FORMAT_8x8},
	{"ASTC 4x4 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_4x4},
	{"ASTC 8x8 HDR RGBA", Image::COMPRESS_ASTC, Image::USED_CHANNELS_RGBA, true, Image::ASTC_FORMAT_8x8},
};
static_assert(sizeof(ARRAY_CODECS) / sizeof(ArrayCodec) == Terrain3DAssets::ARRAY_COMPRESSION_MAX);

// True when this build ships the codec's encoder (cvtt for BPTC, squish for
// S3TC, astcenc for ASTC). The engine keeps the encoder function pointers
// private, so availability is probed by compressing a tiny image once per
// update instead of discovering the failure layer by layer.
bool encoder_available(const ArrayCodec &p_codec) {
	Ref<Image> probe = Image::create_empty(4, 4, false, p_codec.hdr ? Image::FORMAT_RGBAF : Image::FORMAT_RGBA8);
	return probe.is_valid() && probe->compress_from_channels(p_codec.mode, p_codec.channels, p_codec.block) == OK;
}
} // namespace

void Terrain3DAssets::_update_texture_files() {
	IS_INIT(VOID);
	LOG(DEBUG, "Received texture_changed signal");
	_terrain->set_warning(WARN_ALL, false);
	if (_texture_list.is_empty()) {
		_generated_albedo_textures.clear();
		_generated_normal_textures.clear();
		_texture_layer_cache.clear();
		_texture_cache_identity.clear();
		_texture_array_info.clear();
		notify_property_list_changed();
		emit_signal("textures_changed");
		return;
	}

	// A Terrain3DAssets resource manages this terrain's two channel arrays.
	// All layers follow explicit authoring settings, independent of imports.
	// When the build lacks the selected codec's encoder (e.g. no cvtt for BC7),
	// fall back to the uncompressed row: the arrays still upload and render
	// instead of the update aborting onto empty or stale arrays.
	TextureArrayCompression effective_compression = _texture_array_compression;
	if (effective_compression != ARRAY_UNCOMPRESSED && !encoder_available(ARRAY_CODECS[effective_compression])) {
		LOG(WARN, "Encoder for ", ARRAY_CODECS[effective_compression].name, " is unavailable in this build; using Uncompressed instead.");
		effective_compression = ARRAY_UNCOMPRESSED;
	}
	const ArrayCodec &codec = ARRAY_CODECS[effective_compression];
	Dictionary next_cache;
	PackedStringArray next_identity;
	auto prepare_layers = [&](bool p_normal, TypedArray<Image> &r_layers) -> bool {
		Image::Format working_format = (effective_compression != ARRAY_UNCOMPRESSED && codec.hdr) ? Image::FORMAT_RGBAF : Image::FORMAT_RGBA8;
		Vector2i size = _texture_array_size > 0 ? V2I(_texture_array_size) : V2I_ZERO;
		for (const Ref<Terrain3DTextureAsset> &asset : _texture_list) {
			Ref<Texture2D> texture;
			if (asset.is_valid()) {
				texture = p_normal ? asset->_normal_texture : asset->_albedo_texture;
			}
			Ref<Image> image;
			if (texture.is_valid()) {
				image = texture->get_image();
				if (image.is_null() || image->is_empty()) {
					LOG(ERROR, "Cannot read texture image; retaining previous arrays.");
					return false;
				}
				Image::Format format = image->get_format();
				if ((format >= Image::FORMAT_RF && format <= Image::FORMAT_RGBE9995) || format == Image::FORMAT_BPTC_RGBF || format == Image::FORMAT_BPTC_RGBFU || format == Image::FORMAT_ASTC_4x4_HDR || format == Image::FORMAT_ASTC_8x8_HDR) {
					if (!codec.hdr) {
						LOG(ERROR, "HDR terrain textures require Uncompressed, BC6H or HDR ASTC. Retaining previous arrays.");
						return false;
					}
					working_format = Image::FORMAT_RGBAF;
				}
				if (size == V2I_ZERO) {
					size = image->get_size();
				}
			}
			r_layers.push_back(image);
		}
		if (size == V2I_ZERO) {
			size = V2I(1024);
		}
		for (int i = 0; i < r_layers.size(); i++) {
			Ref<Image> source = r_layers[i];
			String key = String::num_int64(size.x) + ":" + String::num_int64(size.y) + ":" + String::num_int64(effective_compression) + ":" + String::num_int64(_texture_array_mipmaps) + ":" + String::num_int64(p_normal) + ":" + String::num_int64(working_format);
			if (source.is_valid()) {
				Ref<HashingContext> hash;
				hash.instantiate();
				hash->start(HashingContext::HASH_SHA256);
				hash->update(source->get_data());
				key += ":" + String::num_int64(source->get_width()) + ":" + String::num_int64(source->get_height()) + ":" + String::num_int64(source->get_format()) + ":" + hash->finish().hex_encode();
			} else {
				key += ":placeholder";
			}
			next_identity.push_back(key);
			if (_texture_layer_cache.has(key)) {
				r_layers[i] = _texture_layer_cache[key];
				next_cache[key] = r_layers[i];
				continue;
			}
			Ref<Image> image;
			if (source.is_valid()) {
				image = source->duplicate();
				if (image->is_compressed() && image->decompress() != OK) {
					LOG(ERROR, "Cannot decompress layer ", i, "; retaining previous arrays.");
					return false;
				}
				image->clear_mipmaps();
				// RGBA retains albedo height and normal roughness in alpha.
				image->convert(working_format);
				if (image->get_size() != size) {
					image->resize(size.x, size.y, Image::INTERPOLATE_LANCZOS);
				}
			} else {
				image = Util::get_filled_image(size, p_normal ? COLOR_NORMAL : COLOR_CHECKED, false, working_format);
			}
			if (_texture_array_mipmaps && image->generate_mipmaps(p_normal) != OK) {
				LOG(ERROR, "Cannot generate texture mipmaps; retaining previous arrays.");
				return false;
			}
			if (effective_compression != ARRAY_UNCOMPRESSED) {
				// Explicit channels keep every array layer in the same format even
				// when one source happens to have opaque alpha or fewer used channels.
				if (image->compress_from_channels(codec.mode, codec.channels, codec.block) != OK || !image->is_compressed()) {
					LOG(ERROR, "Encoder unavailable for ", codec.name, "; retaining previous arrays.");
					return false;
				}
			}
			r_layers[i] = image;
			next_cache[key] = image;
		}
		// Validate cache hits too (BC6H chooses signed or unsigned per layer).
		Ref<Image> first = r_layers[0];
		for (int i = 1; i < r_layers.size(); i++) {
			Ref<Image> image = r_layers[i];
			if (image->get_format() != first->get_format() || image->get_size() != first->get_size() || image->has_mipmaps() != first->has_mipmaps()) {
				LOG(ERROR, "Array layers require matching formats and dimensions. For BC6H, do not mix signed and unsigned HDR layers. Retaining previous arrays.");
				return false;
			}
		}
		return true;
	};

	TypedArray<Image> albedo_layers;
	TypedArray<Image> normal_layers;
	if (!prepare_layers(false, albedo_layers) || !prepare_layers(true, normal_layers)) {
		return;
	}
	// Decode unsupported formats before upload so array previews remain readable.
	const char *feature = "";
	switch (codec.mode) {
		case Image::COMPRESS_S3TC: feature = (codec.channels == Image::USED_CHANNELS_R || codec.channels == Image::USED_CHANNELS_RG) ? "rgtc" : "s3tc"; break;
		case Image::COMPRESS_BPTC: feature = "bptc"; break;
		case Image::COMPRESS_ETC:
		case Image::COMPRESS_ETC2: feature = "etc2"; break;
		case Image::COMPRESS_ASTC: feature = codec.hdr ? "astc_hdr" : "astc"; break;
		default: break;
	}
	const bool fallback = effective_compression != ARRAY_UNCOMPRESSED && !RenderingServer::get_singleton()->has_os_feature(feature);
	TypedArray<Image> albedo_upload = albedo_layers;
	TypedArray<Image> normal_upload = normal_layers;
	if (fallback) {
		albedo_upload = albedo_layers.duplicate();
		normal_upload = normal_layers.duplicate();
		for (TypedArray<Image> *layers : { &albedo_upload, &normal_upload }) {
			for (int i = 0; i < layers->size(); i++) {
				Ref<Image> encoded = (*layers)[i];
				Ref<Image> decoded = encoded->duplicate();
				if (decoded->decompress() != OK) {
					LOG(ERROR, "Cannot decode unsupported GPU format; retaining previous arrays.");
					return;
				}
				decoded->convert(codec.hdr ? Image::FORMAT_RGBAH : Image::FORMAT_RGBA8);
				(*layers)[i] = decoded;
			}
		}
	}
	GeneratedTexture albedo;
	GeneratedTexture normal;
	if (!albedo.create(albedo_upload).is_valid() || !normal.create(normal_upload).is_valid()) {
		albedo.clear();
		normal.clear();
		LOG(ERROR, "Cannot create terrain texture arrays; keeping previous arrays.");
		return;
	}
	// Commit both arrays together, then notify materials before freeing the old
	// RIDs. A failed layer update must not destroy an already rendering terrain.
	_texture_layer_cache = next_cache;
	// Preserve source content identity after runtime releases editor texture assets.
	_texture_cache_identity = next_identity;
	Ref<Image> albedo_first = albedo_layers[0];
	Ref<Image> normal_first = normal_layers[0];
	_texture_array_info["layers"] = albedo_layers.size();
	_texture_array_info["albedo_size"] = albedo_first->get_size();
	_texture_array_info["normal_size"] = normal_first->get_size();
	_texture_array_info["format"] = effective_compression == ARRAY_UNCOMPRESSED ? (albedo_first->get_format() == Image::FORMAT_RGBAF ? "RGBAF" : "RGBA8") : codec.name;
	_texture_array_info["albedo_image_format"] = albedo_first->get_format();
	_texture_array_info["normal_image_format"] = normal_first->get_format();
	_texture_array_info["channel_warning"] = codec.channels == Image::USED_CHANNELS_RGBA ? "" : "This format drops channels, including packed height/roughness in alpha. RGBA formats preserve the complete terrain material.";
	_texture_array_info["mipmaps"] = albedo_first->has_mipmaps();
	_texture_array_info["encoded_bytes"] = (albedo_first->get_data().size() + normal_first->get_data().size()) * albedo_layers.size();
	Ref<Image> albedo_gpu = albedo_upload[0];
	Ref<Image> normal_gpu = normal_upload[0];
	_texture_array_info["gpu_bytes"] = (albedo_gpu->get_data().size() + normal_gpu->get_data().size()) * albedo_upload.size();
	_texture_array_info["gpu_fallback"] = fallback;
	_texture_array_info["encoder_missing"] = effective_compression != _texture_array_compression;
	_texture_array_info["albedo_upload_format"] = albedo_gpu->get_format();
	_texture_array_info["normal_upload_format"] = normal_gpu->get_format();
	_texture_array_info["gpu_note"] = fallback ? "GPU does not support this codec; decoded upload uses uncompressed memory." : "Native GPU format";
	notify_property_list_changed();
	std::swap(_generated_albedo_textures, albedo);
	std::swap(_generated_normal_textures, normal);
	emit_signal("textures_changed");
	albedo.clear();
	normal.clear();
}

void Terrain3DAssets::_update_texture_settings() {
	LOG(DEBUG, "Received setting_changed signal");
	if (!_texture_list.is_empty()) {
		LOG(INFO, "Updating texture asset settings arrays");
		_texture_colors.clear();
		_texture_normal_depths.clear();
		_texture_ao_strengths.clear();
		_texture_ao_light_affects.clear();
		_texture_roughness_mods.clear();
		_texture_uv_scales.clear();
		_texture_detiles.clear();
		_texture_displacements.clear();
		_texture_slope_params.clear();

		for (const Ref<Terrain3DTextureAsset> &ta : _texture_list) {
			if (ta.is_null()) {
				continue;
			}
			if (ta->is_highlighted()) {
				_texture_colors.push_back(ta->get_highlight_color());
			} else {
				_texture_colors.push_back(ta->get_albedo_color());
			}
			_texture_normal_depths.push_back(ta->get_normal_depth());
			_texture_ao_strengths.push_back(ta->get_ao_strength());
			_texture_ao_light_affects.push_back(ta->get_ao_light_affect());
			_texture_roughness_mods.push_back(ta->get_roughness());
			_texture_uv_scales.push_back(ta->get_uv_scale());
			_texture_detiles.push_back(Vector2(ta->get_detiling_rotation(), ta->get_detiling_shift()));
			_texture_displacements.push_back(Vector2(ta->get_displacement_offset(), ta->get_displacement_scale()));
			_texture_slope_params.push_back(Vector3(ta->get_slope_blend_sharpness(), ta->get_slope_based_damp(), ta->get_slope_based_normal_damp()));
		}
		// The shader declares `uniform vec3 _texture_slope_params_array[32]` and
		// the R16 surface map can decode any MaterialId in 0..31, so all 32 slots
		// must be written. A short array leaves the tail of the uniform buffer
		// undefined (or stale from a previous, longer list). Unused slots get
		// Slope default: blendSharpness 1000
		// (-> 1.0 after the 0.001 shader scale) and both damps 0.
		while (_texture_slope_params.size() < MAX_TEXTURES) {
			_texture_slope_params.push_back(Vector3(1000.0f, 0.0f, 0.0f));
		}
	}
	LOG(DEBUG, "Emitting textures_changed");
	emit_signal("textures_changed");
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DAssets::set_texture_array_size(int p_size) {
	if (p_size != 0 && (p_size < 4 || p_size > 8192 || (p_size & (p_size - 1)) != 0)) {
		LOG(ERROR, "Array size must be Auto (0) or a power of two between 4 and 8192.");
		return;
	}
	if (_texture_array_size == p_size) {
		return;
	}
	_texture_array_size = p_size;
	_update_texture_files();
	emit_changed();
}

void Terrain3DAssets::set_texture_array_mipmaps(bool p_enabled) {
	if (_texture_array_mipmaps == p_enabled) {
		return;
	}
	_texture_array_mipmaps = p_enabled;
	_update_texture_files();
	emit_changed();
}

void Terrain3DAssets::set_texture_array_compression(TextureArrayCompression p_compression) {
	if (p_compression < ARRAY_UNCOMPRESSED || p_compression >= ARRAY_COMPRESSION_MAX || _texture_array_compression == p_compression) {
		return;
	}
	_texture_array_compression = p_compression;
	_update_texture_files();
	emit_changed();
}

// Called when creating a new asset
void Terrain3DAssets::set_texture_asset(const int p_id, const Ref<Terrain3DTextureAsset> &p_texture) {
	if (p_id < 0 || p_id >= MAX_TEXTURES) {
		LOG(ERROR, "Invalid texture id: ", p_id, " range is 0-", MAX_TEXTURES - 1);
		return;
	}
	if (p_id < _texture_list.size() && _texture_list[p_id] == p_texture) {
		return;
	}
	LOG(INFO, "Setting texture id: ", p_id);
	_set_asset(TYPE_TEXTURE, p_id, p_texture);
	update_texture_list();
}

// Called when loading a list of assets from an assets resource file on disk
void Terrain3DAssets::set_texture_list(const TypedArray<Terrain3DTextureAsset> &p_texture_list) {
	LOG(INFO, "Setting texture list with ", p_texture_list.size(), " entries");
	if (!differs(_texture_list, p_texture_list)) {
		return;
	}
	// Inspector edits replace the list. Build from a snapshot before clearing
	// occupied slots, otherwise a replacement is ignored as a duplicate ID.
	TypedArray<Terrain3DTextureAsset> source = p_texture_list.duplicate();
	for (const Ref<Terrain3DTextureAsset> &asset : _texture_list) {
		if (asset.is_null()) { continue; }
		if (asset->is_connected("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids))) {
			asset->disconnect("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids));
		}
		if (asset->is_connected("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files))) {
			asset->disconnect("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files));
		}
		if (asset->is_connected("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings))) {
			asset->disconnect("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings));
		}
	}
	for (int i = 0; i < source.size(); i++) {
		if (source[i].get_type() == Variant::NIL || Ref<Terrain3DTextureAsset>(source[i]).is_null()) {
			Ref<Terrain3DTextureAsset> placeholder;
			placeholder.instantiate();
			placeholder->_id = i;
			source[i] = placeholder;
		}
	}
	_texture_list.clear();
	_set_asset_list(TYPE_TEXTURE, source);
	update_texture_list();
}

void Terrain3DAssets::clear_textures(const bool p_update) {
	LOG(INFO, "Clearing texture list");
	_texture_list.clear();
	if (p_update) {
		update_texture_list();
	}
}

void Terrain3DAssets::update_texture_list() {
	LOG(INFO, "Reconnecting texture signals");
	for (const Ref<Terrain3DTextureAsset> &ta : _texture_list) {
		if (ta.is_null()) {
			LOG(ERROR, "Null TextureAsset found at index: ", _texture_list.find(ta));
			continue;
		}
		if (!ta->is_connected("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files))) {
			LOG(DEBUG, "Connecting file_changed signal");
			ta->connect("file_changed", callable_mp(this, &Terrain3DAssets::_update_texture_files));
		}
		if (!ta->is_connected("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings))) {
			LOG(DEBUG, "Connecting setting_changed signal");
			ta->connect("setting_changed", callable_mp(this, &Terrain3DAssets::_update_texture_settings));
		}
	}
	_update_texture_files();
	_update_texture_settings();
}
