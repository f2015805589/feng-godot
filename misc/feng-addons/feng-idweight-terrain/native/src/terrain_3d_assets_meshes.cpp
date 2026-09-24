// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DAssets, part 3 of 3: the mesh list and the thumbnail renderer behind it.

// One of three files that define the asset library. `update_mesh_list()` reconnects every mesh
// asset's `instancer_setting_changed` notification and emits `meshes_changed`; `set_mesh_asset()`
// is the write path and clears the instancer's instances for a slot being emptied;
// `load_pending_meshes()` commits the scene files the instancer deferred.
//
// The thumbnails are a small offline renderer: one scenario, viewport, orthographic camera and two
// directional lights in `_setup_thumbnail_creation()`, reused by every capture in
// `create_mesh_thumbnails()` - which is what the validity guards in both functions are for.
//
// The other two: `terrain_3d_assets.cpp` (the resource object and the shared list engine) and
// `terrain_3d_assets_textures.cpp` (the texture array).

#include "terrain_3d_assets.h"

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

///////////////////////////
// Private Functions
///////////////////////////

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
