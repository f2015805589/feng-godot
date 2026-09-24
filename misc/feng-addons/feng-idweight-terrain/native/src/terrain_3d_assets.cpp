// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DAssets, part 1 of 3: the resource object and the list engine both kinds share.

// One of three files that define the asset library. This one owns what is type-agnostic: the
// engine both lists are built with (`_set_asset_list()` refills a list from a resource file and
// reconnects its `id_changed` notifications; `_set_asset()` and `_swap_ids()` then keep a saved
// ID or move the asset to the next free slot), the object's lifecycle, `save()`, and the ClassDB
// bindings. The lifecycle is the fan-out: `initialize()` sets up the thumbnail viewports and then
// asks both halves to build their lists, and `destroy()` releases the shared GPU objects and every
// cache either half filled.
//
// The other two: `terrain_3d_assets_textures.cpp` (the texture array) and
// `terrain_3d_assets_meshes.cpp` (the mesh list and its thumbnails).

#include "terrain_3d_assets.h"

#include "logger.h"
#include "terrain_3d.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

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
