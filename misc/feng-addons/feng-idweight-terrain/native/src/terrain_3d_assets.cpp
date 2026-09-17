// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_assets.h"

#include "logger.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include <utility>

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
} // namespace

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DAssets::_swap_ids(const AssetType p_type, const int p_src_id, const int p_dst_id) {
	LOG(INFO, "Swapping asset ID: ", p_src_id, " and ID: ", p_dst_id);
	Array list;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			break;
		default:
			return;
	}
	if (p_src_id < 0 || p_src_id >= list.size()) {
		LOG(ERROR, "Source ID out of range: ", p_src_id);
		return;
	}
	Ref<Terrain3DAssetResource> res_src = list[p_src_id];
	if (res_src.is_null()) {
		LOG(ERROR, "Source Asset is null at ID: ", p_src_id);
		return;
	}
	// User can type in any value, -1 means swap with first, >size means swap with last
	int dst_id = CLAMP(p_dst_id, 0, list.size() - 1);
	if (dst_id == p_src_id) {
		// They're likely the same due to the clamp, when new ID is <0 or >= array_size)
		res_src->_id = p_src_id;
		return;
	}
	Ref<Terrain3DAssetResource> res_dst = list[dst_id];
	if (res_dst.is_valid()) {
		res_dst->_id = p_src_id;
	}
	res_src->_id = dst_id;
	list[dst_id] = res_src;
	list[p_src_id] = res_dst;

	switch (p_type) {
		case TYPE_TEXTURE:
			update_texture_list();
			break;
		case TYPE_MESH:
			if (_terrain) {
				_terrain->get_instancer()->swap_ids(p_src_id, dst_id);
			} else {
				LOG(ERROR, "Changing IDs before the terrain is initialized. Meshes on the ground may be wrong.");
			}
			update_mesh_list();
			break;
		default:
			return;
	}
}

/**
 * _set_asset_list attempts to keep the asset ID as saved in the resource file.
 * But if an ID is invalid or already taken, the new ID is changed to the next available one
 */
void Terrain3DAssets::_set_asset_list(const AssetType p_type, const TypedArray<Terrain3DAssetResource> &p_list) {
	Array list;
	int max_size;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			max_size = MAX_TEXTURES;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			max_size = MAX_MESHES;
			break;
		default:
			return;
	}
	int array_size = CLAMP(p_list.size(), 0, max_size);
	list.resize(array_size);
	int filled_id = -1;
	// For all provided textures up to MAX SIZE
	for (int i = 0; i < array_size; i++) {
		Ref<Terrain3DAssetResource> res = p_list[i];
		if (res.is_null()) {
			LOG(ERROR, "Asset ID: ", i, " is null");
			continue;
		}
		int id = res->get_id();
		// If saved texture ID is in range and doesn't exist, add it
		if (id >= 0 && id < array_size && !list[id]) {
			list[id] = res;
		} else {
			// Else texture ID is invalid or slot is already taken, insert in first available
			for (int j = filled_id + 1; j < array_size; j++) {
				if (!list[j]) {
					LOG(ERROR, res->get_class(), " ID ", id, " already exists. Setting '",
							res->get_name(), "' to ID ", j,
							". Textures/Meshes on the ground may be wrong. Review Asset list to ensure each have unique IDs.");
					res->set_id(j);
					list[j] = res;
					filled_id = j;
					break;
				}
			}
		}
		if (!res->is_connected("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids))) {
			LOG(DEBUG, "Connecting to id_changed, ID: ", id);
			res->connect("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids));
		}
		res->initialize();
	}
	if (Terrain3D::debug_level >= DEBUG) {
		for (int i = 0; i < list.size(); i++) {
			Ref<Terrain3DAssetResource> res = list[i];
			int id = res.is_valid() ? res->get_id() : -1;
			String name = res.is_valid() ? res->get_name() : "";
			LOG(DEBUG, "Asset ", i, ": ", name, ", ", res, ", stored ID: ", id);
		}
	}
}

void Terrain3DAssets::_set_asset(const AssetType p_type, const int p_id, const Ref<Terrain3DAssetResource> &p_asset) {
	LOG(INFO, "Setting asset type: ", p_type, ", ID: ", p_id, ", asset: ", p_asset);
	Array list;
	int max_size;
	switch (p_type) {
		case TYPE_TEXTURE:
			list = _texture_list;
			max_size = MAX_TEXTURES;
			break;
		case TYPE_MESH:
			list = _mesh_list;
			max_size = MAX_MESHES;
			break;
		default:
			return;
	}

	if (p_id < 0 || p_id >= max_size) {
		LOG(ERROR, "Invalid asset id: ", p_id, " range is 0-", max_size);
		return;
	}
	int id = CLAMP(p_id, 0, list.size());
	// Delete asset if null
	if (p_asset.is_null()) {
		// If final asset, remove it
		if (id == list.size() - 1) {
			LOG(DEBUG, "Deleting asset id: ", id);
			list.pop_back();
		} else {
			// Else just clear it
			Ref<Terrain3DAssetResource> res = list[id];
			res->clear();
			res->_id = id;
		}
	} else {
		// Else Insert/Add Asset at end if a high number
		if (id == list.size()) {
			p_asset->_id = id;
			list.push_back(p_asset);
		} else {
			// Else overwrite an existing slot
			p_asset->_id = id;
			list[id] = p_asset;
		}
		if (!p_asset->is_connected("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids))) {
			LOG(DEBUG, "Connecting to id_changed");
			p_asset->connect("id_changed", callable_mp(this, &Terrain3DAssets::_swap_ids));
		}
		p_asset->initialize();
	}
}

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
	const ArrayCodec &codec = ARRAY_CODECS[_texture_array_compression];
	Dictionary next_cache;
	PackedStringArray next_identity;
	auto prepare_layers = [&](bool p_normal, TypedArray<Image> &r_layers) -> bool {
		Image::Format working_format = (_texture_array_compression != ARRAY_UNCOMPRESSED && codec.hdr) ? Image::FORMAT_RGBAF : Image::FORMAT_RGBA8;
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
			String key = String::num_int64(size.x) + ":" + String::num_int64(size.y) + ":" + String::num_int64(_texture_array_compression) + ":" + String::num_int64(_texture_array_mipmaps) + ":" + String::num_int64(p_normal) + ":" + String::num_int64(working_format);
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
			if (_texture_array_compression != ARRAY_UNCOMPRESSED) {
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
	const bool fallback = _texture_array_compression != ARRAY_UNCOMPRESSED && !RenderingServer::get_singleton()->has_os_feature(feature);
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
	_texture_array_info["format"] = _texture_array_compression == ARRAY_UNCOMPRESSED ? (albedo_first->get_format() == Image::FORMAT_RGBAF ? "RGBAF" : "RGBA8") : codec.name;
	_texture_array_info["albedo_image_format"] = albedo_first->get_format();
	_texture_array_info["normal_image_format"] = normal_first->get_format();
	_texture_array_info["channel_warning"] = codec.channels == Image::USED_CHANNELS_RGBA ? "" : "This format drops channels, including packed height/roughness in alpha. RGBA formats preserve the complete terrain material.";
	_texture_array_info["mipmaps"] = albedo_first->has_mipmaps();
	_texture_array_info["encoded_bytes"] = (albedo_first->get_data().size() + normal_first->get_data().size()) * albedo_layers.size();
	Ref<Image> albedo_gpu = albedo_upload[0];
	Ref<Image> normal_gpu = normal_upload[0];
	_texture_array_info["gpu_bytes"] = (albedo_gpu->get_data().size() + normal_gpu->get_data().size()) * albedo_upload.size();
	_texture_array_info["gpu_fallback"] = fallback;
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

void Terrain3DAssets::_update_mesh(const int p_id) {
	if (p_id < 0 || p_id >= _mesh_list.size()) {
		LOG(ERROR, "Invalid mesh ID: ", p_id);
		return;
	}
	Ref<Terrain3DMeshAsset> ma = _mesh_list[p_id];
	create_mesh_thumbnails(p_id, V2I(512), true);
	IS_INSTANCER_INIT(VOID);
	Terrain3DInstancer *instancer = _terrain->get_instancer();
	instancer->update_mmis(p_id, V2I_MAX, false);
}

void Terrain3DAssets::_setup_thumbnail_creation() {
	IS_INIT(VOID);
	if (_scenario.is_valid()) {
		return;
	}
	LOG(INFO, "Setting up mesh thumbnail creation viewports");
	// Setup Mesh preview environment
	_scenario = RS->scenario_create();

	_viewport = RS->viewport_create();
	RS->viewport_set_update_mode(_viewport, RenderingServer::VIEWPORT_UPDATE_DISABLED);
	RS->viewport_set_scenario(_viewport, _scenario);
	RS->viewport_set_size(_viewport, 128, 128);
	RS->viewport_set_transparent_background(_viewport, true);
	RS->viewport_set_active(_viewport, true);
	_viewport_texture = RS->viewport_get_texture(_viewport);

	_camera = RS->camera_create();
	RS->viewport_attach_camera(_viewport, _camera);
	RS->camera_set_transform(_camera, Transform3D(Basis(), Vector3(0, 0, 3)));
	RS->camera_set_orthogonal(_camera, 1.0, 0.01, 1000.0);

	_key_light = RS->directional_light_create();
	_key_light_instance = RS->instance_create2(_key_light, _scenario);
	RS->instance_set_transform(_key_light_instance, Transform3D().looking_at(V3(-1), V3_UP));

	_fill_light = RS->directional_light_create();
	RS->light_set_color(_fill_light, Color(0.3, 0.3, 0.3));
	_fill_light_instance = RS->instance_create2(_fill_light, _scenario);
	RS->instance_set_transform(_fill_light_instance, Transform3D().looking_at(V3_UP, Vector3(0, 0, 1)));

	_mesh_instance = RS->instance_create();
	RS->instance_set_scenario(_mesh_instance, _scenario);
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DAssets::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing assets");
	if (IS_EDITOR) {
		_setup_thumbnail_creation();
	}

	// Update assets
	update_texture_list();
	update_mesh_list();
}

void Terrain3DAssets::uninitialize() {
	LOG(INFO, "Uninitializing assets");
	_terrain = nullptr;
}

void Terrain3DAssets::destroy() {
	LOG(INFO, "Destroying assets");
	_terrain = nullptr;
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	_texture_list.clear();
	_mesh_list.clear();
	_texture_colors.clear();
	_texture_normal_depths.clear();
	_texture_ao_strengths.clear();
	_texture_ao_light_affects.clear();
	_texture_roughness_mods.clear();
	_texture_uv_scales.clear();
	_texture_detiles.clear();
	_texture_slope_params.clear();

	if (_scenario.is_valid()) {
		RS->free_rid(_mesh_instance);
		RS->free_rid(_fill_light_instance);
		RS->free_rid(_fill_light);
		RS->free_rid(_key_light_instance);
		RS->free_rid(_key_light);
		RS->free_rid(_camera);
		RS->free_rid(_viewport);
		RS->free_rid(_scenario);
		_mesh_instance = RID();
		_fill_light_instance = RID();
		_fill_light = RID();
		_key_light_instance = RID();
		_key_light = RID();
		_camera = RID();
		_viewport = RID();
		_scenario = RID();
	}
}

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

// Called when creating a new asset
void Terrain3DAssets::set_mesh_asset(const int p_id, const Ref<Terrain3DMeshAsset> &p_mesh_asset) {
	if (p_id < 0 || p_id >= MAX_MESHES) {
		LOG(ERROR, "Invalid mesh id: ", p_id, " range is 0-", MAX_MESHES - 1);
		return;
	}
	if (p_id < _mesh_list.size() && _mesh_list[p_id] == p_mesh_asset) {
		return;
	}
	LOG(INFO, "Setting mesh id: ", p_id, ", ", p_mesh_asset);
	if (p_mesh_asset.is_null()) {
		IS_INSTANCER_INIT(VOID);
		_terrain->get_instancer()->clear_by_mesh(p_id);
	}
	_set_asset(TYPE_MESH, p_id, p_mesh_asset);
	update_mesh_list();
}

// Called when loading a list of assets from an assets resource file on disk
void Terrain3DAssets::set_mesh_list(const TypedArray<Terrain3DMeshAsset> &p_mesh_list) {
	LOG(INFO, "Setting mesh list with ", p_mesh_list.size(), " entries");
	if (!differs(_mesh_list, p_mesh_list)) {
		return;
	}
	_set_asset_list(TYPE_MESH, p_mesh_list);
	update_mesh_list();
}

// p_id = -1 for all meshes
// Adapted from godot\editor\plugins\editor_preview_plugins.cpp:EditorMeshPreviewPlugin
void Terrain3DAssets::create_mesh_thumbnails(const int p_id, const Vector2i &p_size, const bool p_force) {
	LOG(INFO, "Creating mesh thumbnails for ID: ", p_id, ", size: ", p_size);
	int max = get_mesh_count();
	if (p_id < -1 || p_id >= max) {
		return;
	}
	if (!_mesh_instance.is_valid()) {
		_setup_thumbnail_creation();
	}
	int start, end;
	if (p_id < 0) {
		start = 0;
		end = max;
	} else {
		start = CLAMP(p_id, 0, max - 1);
		end = CLAMP(p_id + 1, 0, max);
	}
	Vector2i size = CLAMP(p_size, V2I(2), V2I(4096));

	LOG(DEBUG, "Creating thumbnails for ids: ", start, " through ", end - 1);
	for (int i = start; i < end; i++) {
		Ref<Terrain3DMeshAsset> ma = get_mesh_asset(i);
		LOG(EXTREME, i, ": Getting Terrain3DMeshAsset: ", ptr_to_str(*ma));
		if (ma.is_null()) {
			LOG(ERROR, i, ": Terrain3DMeshAsset is null, skipping");
			continue;
		}
		if (!p_force && ma->get_thumbnail().is_valid()) {
			LOG(EXTREME, "Thumbnail already generated, skipping");
			continue;
		}
		// Setup mesh
		Ref<Mesh> mesh = ma->get_mesh(0);
		LOG(EXTREME, i, ": Getting Mesh 0: ", mesh);
		if (mesh.is_null()) {
			LOG(ERROR, i, ": Mesh is null, skipping");
			continue;
		}
		RS->instance_set_base(_mesh_instance, mesh->get_rid());

		// Setup material
		Ref<Material> mat = ma->get_material_override();
		RID rid = mat.is_valid() ? mat->get_rid() : RID();
		RS->instance_geometry_set_material_override(_mesh_instance, rid);
		mat = ma->get_material_overlay();
		rid = mat.is_valid() ? mat->get_rid() : RID();
		RS->instance_geometry_set_material_overlay(_mesh_instance, rid);

		// Setup scene
		AABB aabb = mesh->get_aabb();
		Vector3 ofs = aabb.get_center();
		aabb.position -= ofs;
		Transform3D xform;
		xform.basis = Basis().rotated(V3_UP, -Math_PI * 0.125f);
		xform.basis = Basis().rotated(Vector3(1.f, 0.f, 0.f), Math_PI * 0.125f) * xform.basis;
		AABB rot_aabb = xform.xform(aabb);
		real_t m = MAX(rot_aabb.size.x, rot_aabb.size.y) * 0.5f;
		if (m == 0.f) {
			m = 1.f;
		}
		m = .5f / m;
		xform.basis.scale(V3(m));
		xform.origin = -xform.basis.xform(ofs);
		xform.origin.z -= rot_aabb.size.z * 2.f;
		RS->instance_set_transform(_mesh_instance, xform);

		// Capture image
		RS->viewport_set_size(_viewport, size.x, size.y);
		RS->viewport_set_update_mode(_viewport, RenderingServer::VIEWPORT_UPDATE_ONCE);
		RS->force_draw();

		Ref<Image> img = RS->texture_2d_get(_viewport_texture);
		RS->instance_set_base(_mesh_instance, RID()); // Clear mesh
		if (img.is_valid()) {
			LOG(EXTREME, i, ": Retrieving image: ", img, " size: ", img->get_size(), " format: ", img->get_format());
			ma->set_thumbnail(ImageTexture::create_from_image(img));
		} else {
			LOG(ERROR, "_viewport_texture is null. Couldn't create thumbnail picture");
		}
	}
	return;
}

void Terrain3DAssets::update_mesh_list() {
	IS_INSTANCER_INIT(VOID);
	LOG(INFO, "Updating mesh list");
	if (_mesh_list.size() == 0) {
		LOG(DEBUG, "Mesh list empty, clearing instancer and adding a default mesh");
		_terrain->get_instancer()->destroy();
		Ref<Terrain3DMeshAsset> new_ma;
		new_ma.instantiate();
		set_mesh_asset(0, new_ma);
	}
	LOG(DEBUG, "Reconnecting mesh instance signals");
	for (Ref<Terrain3DMeshAsset> ma : _mesh_list) {
		if (ma.is_null()) {
			LOG(ERROR, "Null Terrain3DMeshAsset found at index ", _mesh_list.find(ma));
			continue;
		}
		if (ma->get_mesh().is_null()) {
			LOG(ERROR, "Terrain3DMeshAsset has null mesh at index ", _mesh_list.find(ma));
			continue;
		}
		if (!ma->is_connected("instancer_setting_changed", callable_mp(this, &Terrain3DAssets::_update_mesh))) {
			LOG(DEBUG, "Connecting instancer_setting_changed signal to _update_mesh");
			ma->connect("instancer_setting_changed", callable_mp(this, &Terrain3DAssets::_update_mesh));
		}
	}
	LOG(DEBUG, "Emitting meshes_changed");
	emit_signal("meshes_changed");
}

void Terrain3DAssets::load_pending_meshes() {
	// Reload meshes for all mesh assets that have changed. Used by the instancer after clearing
	for (const Ref<Terrain3DMeshAsset> &ma : _mesh_list) {
		if (ma.is_valid() && ma->is_scene_file_pending()) {
			ma->commit_meshes();
		}
	}
}

Error Terrain3DAssets::save(const String &p_path) {
	if (p_path.is_empty() && get_path().is_empty()) {
		return ERR_FILE_NOT_FOUND;
	}
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path to ", p_path);
		take_over_path(p_path);
	}
	// Save to external resource file if specified
	Error err = OK;
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save external file: " + path);
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		if (err == OK) {
			LOG(INFO, "File saved successfully: ", path);
		} else {
			LOG(ERROR, "Cannot save file: ", path, ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
		}
	}
	return err;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DAssets::_bind_methods() {
	BIND_ENUM_CONSTANT(ARRAY_UNCOMPRESSED);
	BIND_ENUM_CONSTANT(ARRAY_BC7);
	BIND_ENUM_CONSTANT(ARRAY_BC1);
	BIND_ENUM_CONSTANT(ARRAY_BC3);
	BIND_ENUM_CONSTANT(ARRAY_BC4);
	BIND_ENUM_CONSTANT(ARRAY_BC5);
	BIND_ENUM_CONSTANT(ARRAY_BC6H);
	BIND_ENUM_CONSTANT(ARRAY_ETC1);
	BIND_ENUM_CONSTANT(ARRAY_ETC2_RGB);
	BIND_ENUM_CONSTANT(ARRAY_ETC2_RGBA);
	BIND_ENUM_CONSTANT(ARRAY_EAC_R11);
	BIND_ENUM_CONSTANT(ARRAY_EAC_RG11);
	BIND_ENUM_CONSTANT(ARRAY_ASTC_4X4);
	BIND_ENUM_CONSTANT(ARRAY_ASTC_8X8);
	BIND_ENUM_CONSTANT(ARRAY_ASTC_4X4_HDR);
	BIND_ENUM_CONSTANT(ARRAY_ASTC_8X8_HDR);

	ClassDB::bind_method(D_METHOD("set_texture_array_size", "size"), &Terrain3DAssets::set_texture_array_size);
	ClassDB::bind_method(D_METHOD("get_texture_array_size"), &Terrain3DAssets::get_texture_array_size);
	ClassDB::bind_method(D_METHOD("set_texture_array_mipmaps", "enabled"), &Terrain3DAssets::set_texture_array_mipmaps);
	ClassDB::bind_method(D_METHOD("get_texture_array_mipmaps"), &Terrain3DAssets::get_texture_array_mipmaps);
	ClassDB::bind_method(D_METHOD("set_texture_array_compression", "compression"), &Terrain3DAssets::set_texture_array_compression);
	ClassDB::bind_method(D_METHOD("get_texture_array_compression"), &Terrain3DAssets::get_texture_array_compression);
	ClassDB::bind_method(D_METHOD("get_texture_array_info"), &Terrain3DAssets::get_texture_array_info);
	ADD_GROUP("Texture Array", "texture_array_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "texture_array_size", PROPERTY_HINT_ENUM, "Auto:0,64:64,128:128,256:256,512:512,1024:1024,2048:2048,4096:4096,8192:8192"), "set_texture_array_size", "get_texture_array_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "texture_array_mipmaps"), "set_texture_array_mipmaps", "get_texture_array_mipmaps");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "texture_array_compression", PROPERTY_HINT_ENUM, "Uncompressed,BC7,BC1 RGB,BC3 RGBA,BC4 R,BC5 RG,BC6H HDR RGB,ETC1 RGB,ETC2 RGB,ETC2 RGBA,EAC R11,EAC RG11,ASTC 4x4 RGBA,ASTC 8x8 RGBA,ASTC 4x4 HDR RGBA,ASTC 8x8 HDR RGBA"), "set_texture_array_compression", "get_texture_array_compression");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "texture_array_info", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_texture_array_info");
	ADD_GROUP("", "");
	BIND_ENUM_CONSTANT(TYPE_TEXTURE);
	BIND_ENUM_CONSTANT(TYPE_MESH);
	BIND_CONSTANT(MAX_TEXTURES);
	BIND_CONSTANT(MAX_MESHES);

	ClassDB::bind_method(D_METHOD("set_texture_asset", "id", "texture"), &Terrain3DAssets::set_texture_asset);
	ClassDB::bind_method(D_METHOD("get_texture_asset", "id"), &Terrain3DAssets::get_texture_asset);
	ClassDB::bind_method(D_METHOD("set_texture_list", "texture_list"), &Terrain3DAssets::set_texture_list);
	ClassDB::bind_method(D_METHOD("get_texture_list"), &Terrain3DAssets::get_texture_list);
	ClassDB::bind_method(D_METHOD("get_texture_count"), &Terrain3DAssets::get_texture_count);
	ClassDB::bind_method(D_METHOD("get_albedo_array_rid"), &Terrain3DAssets::get_albedo_array_rid);
	ClassDB::bind_method(D_METHOD("get_normal_array_rid"), &Terrain3DAssets::get_normal_array_rid);
	ClassDB::bind_method(D_METHOD("get_texture_colors"), &Terrain3DAssets::get_texture_colors);
	ClassDB::bind_method(D_METHOD("get_texture_normal_depths"), &Terrain3DAssets::get_texture_normal_depths);
	ClassDB::bind_method(D_METHOD("get_texture_ao_strengths"), &Terrain3DAssets::get_texture_ao_strengths);
	ClassDB::bind_method(D_METHOD("get_texture_ao_light_affects"), &Terrain3DAssets::get_texture_ao_light_affects);
	ClassDB::bind_method(D_METHOD("get_texture_roughness_mods"), &Terrain3DAssets::get_texture_roughness_mods);
	ClassDB::bind_method(D_METHOD("get_texture_uv_scales"), &Terrain3DAssets::get_texture_uv_scales);
	ClassDB::bind_method(D_METHOD("get_texture_detiles"), &Terrain3DAssets::get_texture_detiles);
	ClassDB::bind_method(D_METHOD("get_texture_slope_params"), &Terrain3DAssets::get_texture_slope_params);
	ClassDB::bind_method(D_METHOD("get_texture_displacements"), &Terrain3DAssets::get_texture_displacements);
	ClassDB::bind_method(D_METHOD("clear_textures", "update"), &Terrain3DAssets::clear_textures, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("update_texture_list"), &Terrain3DAssets::update_texture_list);

	ClassDB::bind_method(D_METHOD("set_mesh_asset", "id", "mesh"), &Terrain3DAssets::set_mesh_asset);
	ClassDB::bind_method(D_METHOD("get_mesh_asset", "id"), &Terrain3DAssets::get_mesh_asset);
	ClassDB::bind_method(D_METHOD("set_mesh_list", "mesh_list"), &Terrain3DAssets::set_mesh_list);
	ClassDB::bind_method(D_METHOD("get_mesh_list"), &Terrain3DAssets::get_mesh_list);
	ClassDB::bind_method(D_METHOD("get_mesh_count"), &Terrain3DAssets::get_mesh_count);
	ClassDB::bind_method(D_METHOD("create_mesh_thumbnails", "id", "size", "force"), &Terrain3DAssets::create_mesh_thumbnails, DEFVAL(-1), DEFVAL(V2I(512)), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("update_mesh_list"), &Terrain3DAssets::update_mesh_list);

	ClassDB::bind_method(D_METHOD("save", "path"), &Terrain3DAssets::save, DEFVAL(""));

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "mesh_list", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DMeshAsset", ro_flags), "set_mesh_list", "get_mesh_list");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "texture_list", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DTextureAsset"), "set_texture_list", "get_texture_list");

	ADD_SIGNAL(MethodInfo("meshes_changed"));
	ADD_SIGNAL(MethodInfo("textures_changed"));
}
