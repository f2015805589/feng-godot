// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_assets.h"

#include "logger.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include <utility>

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
		emit_signal("textures_changed");
		return;
	}

	// GPU array layers must match, but source assets do not have to. Prepare
	// private images so RGB/RGBA, import settings, and empty slots can coexist.
	// Never assign generated placeholders back to assets: their file_changed
	// signal would recursively rebuild and free the arrays being constructed.
	auto prepare_layers = [&](bool p_normal, TypedArray<Image> &r_layers) -> bool {
		Vector2i size = V2I_ZERO;
		Image::Format format = Image::FORMAT_MAX;
		bool mipmaps = false;
		bool normalize = false;
		bool has_empty = false;
		bool hdr = false;
		for (const Ref<Terrain3DTextureAsset> &asset : _texture_list) {
			Ref<Texture2D> texture;
			if (asset.is_valid()) {
				texture = p_normal ? asset->_normal_texture : asset->_albedo_texture;
			}
			Ref<Image> image;
			if (texture.is_valid()) {
				image = texture->get_image();
				if (image.is_null() || image->is_empty()) {
					LOG(ERROR, "Cannot read texture image; keeping previous terrain arrays.");
					return false;
				}
				const Image::Format image_format = image->get_format();
				hdr = hdr || (image_format >= Image::FORMAT_RF && image_format <= Image::FORMAT_RGBE9995) || image_format == Image::FORMAT_BPTC_RGBF || image_format == Image::FORMAT_BPTC_RGBFU;
				if (size == V2I_ZERO) {
					size = image->get_size();
					format = image_format;
					mipmaps = image->has_mipmaps();
				} else {
					normalize = normalize || image->get_size() != size || image_format != format || image->has_mipmaps() != mipmaps;
				}
			} else {
				has_empty = true;
			}
			r_layers.push_back(image);
		}
		if (size == V2I_ZERO) {
			size = V2I(1024);
			format = Image::FORMAT_RGBA8;
			mipmaps = true;
		}
		// Empty layers need writable images too. Keep matching compressed arrays
		// compressed; only mixed/placeholder arrays require decompression.
		normalize = normalize || has_empty;
		if (normalize) {
			format = hdr ? Image::FORMAT_RGBAF : Image::FORMAT_RGBA8;
		}
		for (int i = 0; i < r_layers.size(); i++) {
			Ref<Image> image = r_layers[i];
			if (image.is_null()) {
				image = Util::get_filled_image(size, p_normal ? COLOR_NORMAL : COLOR_CHECKED, mipmaps, format);
			} else if (normalize) {
				image = image->duplicate();
				if (image->is_compressed() && image->decompress() != OK) {
					LOG(ERROR, "Cannot decompress texture layer ", i, "; keeping previous terrain arrays.");
					return false;
				}
				image->clear_mipmaps();
				image->convert(format);
				if (image->get_size() != size) {
					image->resize(size.x, size.y, Image::INTERPOLATE_LANCZOS);
				}
				if (mipmaps && image->generate_mipmaps() != OK) {
					LOG(ERROR, "Cannot generate texture mipmaps; keeping previous terrain arrays.");
					return false;
				}
			}
			r_layers[i] = image;
		}
		return true;
	};

	TypedArray<Image> albedo_layers;
	TypedArray<Image> normal_layers;
	if (!prepare_layers(false, albedo_layers) || !prepare_layers(true, normal_layers)) {
		return;
	}
	GeneratedTexture albedo;
	GeneratedTexture normal;
	if (!albedo.create(albedo_layers).is_valid() || !normal.create(normal_layers).is_valid()) {
		albedo.clear();
		normal.clear();
		LOG(ERROR, "Cannot create terrain texture arrays; keeping previous arrays.");
		return;
	}
	// Commit both arrays together, then notify materials before freeing the old
	// RIDs. A failed layer update must not destroy an already rendering terrain.
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
	_set_asset_list(TYPE_TEXTURE, p_texture_list);
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
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "texture_list", PROPERTY_HINT_ARRAY_TYPE, "Terrain3DTextureAsset", ro_flags), "set_texture_list", "get_texture_list");

	ADD_SIGNAL(MethodInfo("meshes_changed"));
	ADD_SIGNAL(MethodInfo("textures_changed"));
}
