// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_ASSETS_CLASS_H
#define TERRAIN3D_ASSETS_CLASS_H

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_mesh_asset.h"
#include "terrain_3d_texture_asset.h"

class Terrain3D;
class Terrain3DInstancer;

class Terrain3DAssets : public Resource {
	GDCLASS(Terrain3DAssets, Resource);
	CLASS_NAME();

public: // Constants
	enum AssetType {
		TYPE_TEXTURE,
		TYPE_MESH,
	};

	static inline const int MAX_TEXTURES = 32;
	static inline const int MAX_MESHES = 256;

	enum TextureArrayCompression {
		ARRAY_UNCOMPRESSED,
		ARRAY_BC7,
	};

private:
	int _texture_array_size = 0;
	bool _texture_array_mipmaps = true;
	TextureArrayCompression _texture_array_compression = ARRAY_BC7;
	Dictionary _texture_array_info;
	Dictionary _texture_layer_cache;
	Terrain3D *_terrain = nullptr;

	TypedArray<Terrain3DTextureAsset> _texture_list;
	TypedArray<Terrain3DMeshAsset> _mesh_list;

	GeneratedTexture _generated_albedo_textures;
	GeneratedTexture _generated_normal_textures;
	PackedColorArray _texture_colors;
	PackedFloat32Array _texture_normal_depths;
	PackedFloat32Array _texture_ao_strengths;
	PackedFloat32Array _texture_ao_light_affects;
	PackedFloat32Array _texture_roughness_mods;
	PackedFloat32Array _texture_uv_scales;
	PackedVector2Array _texture_detiles;
	PackedVector2Array _texture_displacements;
	// Hydra slope params per material: x=blend_sharpness, y=slope_based_damp,
	// z=slope_based_normal_damp (raw 0..1000 authoring space).
	PackedVector3Array _texture_slope_params;

	// Mesh Thumbnail Generation
	RID _scenario;
	RID _viewport;
	RID _viewport_texture;
	RID _camera;
	RID _key_light;
	RID _key_light_instance;
	RID _fill_light;
	RID _fill_light_instance;
	RID _mesh_instance;

	void _swap_ids(const AssetType p_type, const int p_src_id, const int p_dst_id);
	void _set_asset_list(const AssetType p_type, const TypedArray<Terrain3DAssetResource> &p_list);
	void _set_asset(const AssetType p_type, const int p_id, const Ref<Terrain3DAssetResource> &p_asset);

	void _update_texture_files();
	void _update_texture_settings();
	void _update_mesh(const int p_id);
	void _setup_thumbnail_creation();

public:
	Terrain3DAssets() { set_local_to_scene(true); }
	~Terrain3DAssets() { destroy(); }
	void initialize(Terrain3D *p_terrain);
	bool is_initialized() { return _terrain != nullptr; }
	void uninitialize();
	void destroy();

	Terrain3D *get_terrain() const { return _terrain; }
	void set_texture_array_size(int p_size);
	int get_texture_array_size() const { return _texture_array_size; }
	void set_texture_array_mipmaps(bool p_enabled);
	bool get_texture_array_mipmaps() const { return _texture_array_mipmaps; }
	void set_texture_array_compression(TextureArrayCompression p_compression);
	TextureArrayCompression get_texture_array_compression() const { return _texture_array_compression; }
	Dictionary get_texture_array_info() const { return _texture_array_info; }

	void set_texture_asset(const int p_id, const Ref<Terrain3DTextureAsset> &p_texture);
	Ref<Terrain3DTextureAsset> get_texture_asset(const int p_id) const;
	void set_texture_list(const TypedArray<Terrain3DTextureAsset> &p_texture_list);
	TypedArray<Terrain3DTextureAsset> get_texture_list() const { return _texture_list; }
	int get_texture_count() const { return _texture_list.size(); }
	int get_generated_array_size() const { return _generated_albedo_textures.size(); }
	RID get_albedo_array_rid() const { return _generated_albedo_textures.get_rid(); }
	RID get_normal_array_rid() const { return _generated_normal_textures.get_rid(); }
	PackedColorArray get_texture_colors() const { return _texture_colors; }
	PackedFloat32Array get_texture_normal_depths() const { return _texture_normal_depths; }
	PackedFloat32Array get_texture_ao_strengths() const { return _texture_ao_strengths; }
	PackedFloat32Array get_texture_ao_light_affects() const { return _texture_ao_light_affects; }
	PackedFloat32Array get_texture_roughness_mods() const { return _texture_roughness_mods; }
	PackedFloat32Array get_texture_uv_scales() const { return _texture_uv_scales; }
	PackedVector2Array get_texture_detiles() const { return _texture_detiles; }
	PackedVector2Array get_texture_displacements() const { return _texture_displacements; }
	PackedVector3Array get_texture_slope_params() const { return _texture_slope_params; }
	void clear_textures(const bool p_update = false);
	void update_texture_list();

	void set_mesh_asset(const int p_id, const Ref<Terrain3DMeshAsset> &p_mesh_asset);
	Ref<Terrain3DMeshAsset> get_mesh_asset(const int p_id) const;
	void set_mesh_list(const TypedArray<Terrain3DMeshAsset> &p_mesh_list);
	TypedArray<Terrain3DMeshAsset> get_mesh_list() const { return _mesh_list; }
	int get_mesh_count() const { return _mesh_list.size(); }
	void create_mesh_thumbnails(const int p_id = -1, const Vector2i &p_size = V2I(512), const bool p_force = false);
	void update_mesh_list();
	void load_pending_meshes();

	Error save(const String &p_path = "");

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DAssets::AssetType);
VARIANT_ENUM_CAST(Terrain3DAssets::TextureArrayCompression);

inline Ref<Terrain3DTextureAsset> Terrain3DAssets::get_texture_asset(const int p_id) const {
	if (p_id >= 0 && p_id < _texture_list.size()) {
		return _texture_list[p_id];
	}
	return Ref<Terrain3DTextureAsset>();
}

inline Ref<Terrain3DMeshAsset> Terrain3DAssets::get_mesh_asset(const int p_id) const {
	if (p_id >= 0 && p_id < _mesh_list.size()) {
		return _mesh_list[p_id];
	}
	return Ref<Terrain3DMeshAsset>();
}

#endif // TERRAIN3D_ASSETS_CLASS_H
