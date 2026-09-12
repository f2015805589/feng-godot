// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/color_rect.hpp>
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>

#include "constants.h"
#include "target_node_3d.h"
#include "terrain_3d_assets.h"
#include "terrain_3d_collision.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_material.h"
#include "terrain_3d_mesher.h"
#include "terrain_3d_streamer.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_feedback.h"

class Terrain3D : public Node3D {
	GDCLASS(Terrain3D, Node3D);
	CLASS_NAME();

public: // Constants
	enum DebugLevel {
		MESG = -2, // Always print except in release builds
		WARN = -1, // Always print except in release builds
		ERROR = 0, // Always print except in release builds
		INFO = 1, // Print every function call and important entries
		DEBUG = 2, // Print details within functions
		EXTREME = 3, // Continuous operations like snapping
	};

	enum RegionSize {
		SIZE_64 = 64,
		SIZE_128 = 128,
		SIZE_256 = 256,
		SIZE_512 = 512,
		SIZE_1024 = 1024,
		SIZE_2048 = 2048,
	};

private:
	String _version = "1.1.0-dev";
	String _data_directory;
	bool _is_inside_world = false;
	bool _initialized = false;
	uint8_t _warnings = 0u;

	// Object references
	Terrain3DData *_data = nullptr;
	Ref<Terrain3DAssets> _assets;
	Terrain3DCollision *_collision = nullptr;
	Terrain3DInstancer *_instancer = nullptr;
	Terrain3DEditor *_editor = nullptr;
	Object *_editor_plugin = nullptr;
	Terrain3DStreamer *_streamer = nullptr;
	bool _streaming_enabled = false;

	// One surface service owns the settings and GPU material cache. AVT and SVT
	// below are addressing/producer views over its shared physical residency pool.
	int _vt_page_size = 256;
	int _vt_page_border = 4;
	int _vt_page_count = 256;
	int _vt_pages_per_update = 4;
	bool _vt_adaptive_enabled = true;
	bool _vt_debug_direct_material = false;
	bool _vt_shared_ready = false;
	bool _vt_materials_dirty = true;
	bool _vt_callback_registered = false;
	Ref<RefCounted> _vt_baker;
	Dictionary _vt_page_records;
	Dictionary _vt_registered_sectors;
	PackedFloat32Array _surface_vt_block_sizes;
	RID _vt_bound_albedo;
	uint64_t _vt_source_revision = 1;
	Dictionary _vt_svt_tiles;
	bool _svt_auto_bake = true;
	Dictionary _vt_svt_dirty_regions;
	uint64_t _vt_svt_edit_time = 0;
	bool _vt_svt_bake_incremental = false;
	uint64_t _vt_svt_bake_generation = 0;
	Array _vt_svt_bake_queue;
	Dictionary _vt_svt_bake_waiting;
	int _vt_svt_bake_total = 0;
	int _vt_svt_bake_done = 0;
	uint32_t _vt_material_signature = 0;
	bool _vt_svt_catalog_loaded = false;
	bool _vt_offline_producing = false;
	int _vt_svt_bake_failed = 0;
	String _vt_svt_bake_error;

	// Surface virtual texture: the near field's surface pages, produced from the
	// region surface maps. Off by default; the array path stays authoritative until
	// the source data carries more detail than the array can afford to keep resident.
	Terrain3DVirtualTexture *_surface_vt = nullptr;
	bool _surface_vt_enabled = false;
	// The near field's working set is roughly 50 pages at density 4 (a 512 m radius
	// with the distance rule), so 64 left no headroom for the LRU.
	int _surface_vt_page_count = 128;
	int _surface_vt_page_size = 256;
	int _surface_vt_page_border = 4;
	int _surface_vt_pages_per_axis = 4;
	real_t _surface_vt_distance = 512.f;
	Vector2i _surface_vt_region_grid = Vector2i(2, 2);
	int _surface_vt_selection_mode = 0;
	mutable bool _vt_view_focus_valid = false;
	mutable Vector2i _vt_view_focus;
	Vector2i _surface_vt_region_offset;
	real_t _surface_vt_forward_regions = 0.f;
	bool _surface_vt_force_mip = false;
	int _surface_vt_mip = 0;
	// Layer slot -> virtual page block origin, or (-1, -1). Indexed by the same slot
	// the chunk directory returns, so the shader needs no separate sector lookup.
	PackedVector2Array _surface_vt_blocks;
	bool _surface_vt_blocks_dirty = false;
	// GPU page demand. When enabled it replaces the distance rule: the compute pass
	// knows the field of view, the resolution and the view direction, and it culls.
	Terrain3DVTFeedback *_surface_vt_feedback = nullptr;
	bool _surface_vt_feedback_enabled = false;
	int _surface_vt_feedback_interval = 4;
	int _surface_vt_feedback_tick = 0;
	int _surface_vt_feedback_grid_chunks = 8;
	// A page whose screen extent falls below this is not requested at all: it would
	// be a sub-pixel speck in the atlas.
	real_t _surface_vt_feedback_min_extent = 8.f;
	Vector2i _surface_vt_feedback_origin;

	// Far field (sparse virtual texture). A world-space page grid at a coarser texel
	// density, so the surface channel does not have to keep every region's payload
	// resident: a page spans several regions and its mip chain is world-space, which is
	// what the region-aligned near field above cannot express. Off by default; the
	// region texture array still serves whenever no page covers a texel.
	Terrain3DVirtualTexture *_surface_svt = nullptr;
	bool _surface_svt_enabled = false;
	// One mip 0 page covers this many metres.
	real_t _surface_svt_page_world = 512.f;
	int _surface_svt_page_size = 256;
	int _surface_svt_page_border = 4;
	int _surface_svt_page_count = 256;
	// -1 means auto: the coarsest level the world grid can publish.
	int _surface_svt_max_mip = -1;
	// How far from the clipmap target the far field is kept resident, in metres.
	real_t _surface_svt_distance = 6144.f;
	// Coarsest levels of the world grid that are always resident. This root pyramid is
	// what lets the shader resolve any world position without the region texture array,
	// so it is the far field's fallback rather than a separate fallback page.
	int _surface_svt_root_mips = 2;
	Vector3i _surface_svt_scan_key = Vector3i(INT32_MAX, INT32_MAX, INT32_MAX);
	int64_t _surface_svt_root_cursor = 0;
	int64_t _surface_svt_detail_cursor = 0;
	// Whether the surface channel is uploaded to the region texture array. Off means
	// the virtual textures serve every surface read, which is what removes the
	// density-squared array cost; the array stays allocated but blank.
	bool _surface_array_enabled = true;

	// Regions
	RegionSize _region_size = SIZE_512;
	// Stored surface resolution, in texels per region texel. 1 keeps the region
	// surface map at region_size squared; 4 gives each region a payload four times
	// finer on each axis. Terrain-wide: the region texture array's layers all share
	// one size, and the array stays at region_size regardless (the virtual texture
	// serves the extra detail).
	int _surface_density = 1;
	bool _save_16_bit = false;
	real_t _label_distance = 0.f;
	int _label_size = 48;

	// Tracked Targets
	TargetNode3D _clipmap_target;
	TargetNode3D _collision_target;
	TargetNode3D _light_target;
	TargetNode3D _camera; // Fallback target for clipmap and collision

	// Terrain Mesh
	Terrain3DMesher *_terrain_mesher = nullptr;
	Ref<Terrain3DMaterial> _material;
	int _mesh_lods = 7;
	int _tessellation_level = 0;
	int _mesh_size = 48;
	real_t _vertex_spacing = 1.0f;
	real_t _cull_margin = 0.0f;
	RenderingServer::ShadowCastingSetting _cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_ON;
	GeometryInstance3D::GIMode _gi_mode = GeometryInstance3D::GI_MODE_STATIC;
	uint32_t _render_layers = 1u | (1u << 31u); // Bit 1 and 32 for the cursor

	// Displacement Buffer
	SubViewport *_d_buffer_vp = nullptr;
	ColorRect *_d_buffer_rect = nullptr;
	Vector2 _last_buffer_position = V2_MAX;

	// Ocean Mesh
	Terrain3DMesher *_ocean_mesher = nullptr;
	bool _ocean_enabled = false;
	int _ocean_mesh_lods = 7;
	int _ocean_tessellation_level = 0;
	int _ocean_mesh_size = 32;
	real_t _ocean_vertex_spacing = 4.0f;
	real_t _ocean_cull_margin = 20.0f;
	RenderingServer::ShadowCastingSetting _ocean_cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_OFF;
	GeometryInstance3D::GIMode _ocean_gi_mode = GeometryInstance3D::GI_MODE_DISABLED;
	uint32_t _ocean_render_layers = 1u;
	Ref<Material> _ocean_material;

	// Rendering
	bool _free_editor_textures = true;
	// Mouse cursor
	SubViewport *_mouse_vp = nullptr;
	Camera3D *_mouse_cam = nullptr;
	MeshInstance3D *_mouse_quad = nullptr;
	uint32_t _mouse_layer = 32u;
	// Parent containers for child nodes
	Node3D *_label_parent;

	void _initialize();
	void __physics_process(const double p_delta);
	void _grab_camera();

	void _destroy_collision(const bool p_final = false);

	void _setup_terrain_mesher();
	void _update_mesher_aabbs() { _terrain_mesher ? _terrain_mesher->update_aabbs() : void(); }
	void _destroy_terrain_mesher(const bool p_final = false);
	void _setup_ocean_mesher();
	void _update_ocean_aabbs() { _ocean_mesher ? _ocean_mesher->update_aabbs() : void(); }
	void _destroy_ocean_mesher(const bool p_final = false);
	void _destroy_streamer();

	void _setup_surface_vt();
	void _update_vt_service();
	void _destroy_vt_service();
	void _configure_vt_service();
	void _queue_vt_material_page(int p_slot, const Ref<Image> &p_payload, const Rect2 &p_rect,
			bool p_svt, int p_mip, const Vector2i &p_address);
	static void _bind_vt_methods();
	void _process_svt_bake(int p_page_budget = -1);
	int _update_visible_svt(int p_max_pages);
	String _svt_page_path(const Vector2i &p_address, int p_mip) const;
	void _invalidate_vt_region(const Vector2i &p_region);
	void _process_svt_auto_bake();
	int _queue_svt_bake(const Dictionary &p_dirty_regions);
	void _invalidate_vt_slot(int p_slot);
	void _reset_vt_configuration();
	void _cancel_svt_bake(const String &p_reason);
	void _destroy_surface_vt();
	// One demand pass: registers sectors for the regions near the target, picks a mip
	// per page (GPU feedback when enabled, otherwise the distance rule), produces the
	// pages that are missing and commits.
	int update_surface_vt(int p_max_pages = 0);
	// Refreshes the feedback pass and returns true when a usable result is available.
	bool _update_surface_vt_feedback(const Vector3 &p_target);
	// Local mip for one page of a sector, or -1 when the demand says "no page".
	int _surface_vt_mip_for_page(const Vector2i &p_region_loc, const int p_page_x0,
			const int p_page_y0, const real_t p_distance, const real_t p_page_world_size,
			const int p_max_local_mip);

	void _setup_surface_svt();
	void _destroy_surface_svt();
	// One far-field demand pass: walks the world page grid within the reach of the
	// clipmap target, picks a mip per page from its distance, and produces the pages
	// that are missing.
	int update_surface_svt(int p_max_pages = 0);
	int _surface_svt_mip_for_page(const real_t p_distance) const;

	void _setup_displacement_buffer();
	void _update_displacement_buffer();
	void _destroy_displacement_buffer();

	void _build_containers();
	void _destroy_containers();
	void _destroy_labels();

	void _setup_mouse_picking();
	void _destroy_mouse_picking();
	void _destroy_instancer();

	void _generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
			const Terrain3DData::HeightFilter p_filter, const bool require_nav, const AABB &p_global_aabb) const;
	void _generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
			const Terrain3DData::HeightFilter p_filter, const bool require_nav, const int32_t x, const int32_t z) const;

public:
	void set_vt_page_size(int p_size);
	int get_vt_page_size() const { return _vt_page_size; }
	void set_vt_page_border(int p_border);
	int get_vt_page_border() const { return _vt_page_border; }
	void set_vt_page_count(int p_count);
	int get_vt_page_count() const { return _vt_page_count; }
	void set_vt_pages_per_update(int p_pages);
	int get_vt_pages_per_update() const { return _vt_pages_per_update; }
	void set_vt_adaptive_enabled(bool p_enabled);
	bool is_vt_adaptive_enabled() const { return _vt_adaptive_enabled; }
	void set_vt_debug_direct_material(bool p_enabled);
	bool is_vt_debug_direct_material() const { return _vt_debug_direct_material; }
	Dictionary get_vt_settings() const;
	Array get_vt_pages() const;
	Dictionary get_vt_material_textures() const;
	Ref<Image> get_vt_page_preview(int p_slot);
	void invalidate_vt_materials();
	int bake_svt();
	void set_svt_auto_bake(bool p_enabled);
	bool is_svt_auto_bake() const { return _svt_auto_bake; }
	Array get_svt_baked_pages();
	PackedFloat32Array get_surface_vt_block_sizes() const { return _surface_vt_block_sizes; }
	static DebugLevel debug_level; // Initialized in terrain_3d.cpp

	Terrain3D();
	~Terrain3D() {}
	bool is_inside_world() const { return _is_inside_world; }

	// Terrain
	String get_version() const { return _version; }
	void set_debug_level(const DebugLevel p_level);
	DebugLevel get_debug_level() const { return debug_level; }
	void set_data_directory(String p_dir);
	String get_data_directory() const { return _data ? _data_directory : ""; }

	// Object references
	Terrain3DData *get_data() const { return _data; }
	void set_assets(const Ref<Terrain3DAssets> &p_assets);
	Ref<Terrain3DAssets> get_assets() const { return _assets; }
	Terrain3DCollision *get_collision() const { return _collision; }
	Terrain3DInstancer *get_instancer() const { return _instancer; }
	void set_editor(Terrain3DEditor *p_editor);
	Terrain3DEditor *get_editor() const { return _editor; }
	void set_plugin(Object *p_plugin);
	Object *get_plugin() const { return _editor_plugin; }

	// Region Streaming
	Terrain3DStreamer *get_streamer() const { return _streamer; }
	void set_streaming_enabled(const bool p_enabled);
	bool is_streaming_enabled() const { return _streaming_enabled; }

	Terrain3DVirtualTexture *get_surface_vt() const { return _surface_vt; }
	void set_surface_vt_enabled(const bool p_enabled);
	bool is_surface_vt_enabled() const { return _surface_vt_enabled; }
	void set_surface_vt_page_count(const int p_count);
	int get_surface_vt_page_count() const { return _surface_vt_page_count; }
	void set_surface_vt_page_size(const int p_size);
	int get_surface_vt_page_size() const { return _surface_vt_page_size; }
	void set_surface_vt_page_border(const int p_border);
	int get_surface_vt_page_border() const { return _surface_vt_page_border; }
	void set_surface_vt_pages_per_axis(const int p_pages);
	int get_surface_vt_pages_per_axis() const { return _surface_vt_pages_per_axis; }
	void set_surface_vt_distance(const real_t p_distance);
	real_t get_surface_vt_distance() const { return _surface_vt_distance; }
	void set_surface_vt_region_grid(const Vector2i &p_grid) { _surface_vt_region_grid = Vector2i(CLAMP(p_grid.x, 1, 64), CLAMP(p_grid.y, 1, 64)); }
	Vector2i get_surface_vt_region_grid() const { return _surface_vt_region_grid; }
	void set_surface_vt_selection_mode(int p_mode) { _surface_vt_selection_mode = CLAMP(p_mode, 0, 1); _vt_view_focus_valid = false; }
	int get_surface_vt_selection_mode() const { return _surface_vt_selection_mode; }
	void set_surface_vt_region_offset(const Vector2i &p_offset) { _surface_vt_region_offset = p_offset; }
	Vector2i get_surface_vt_region_offset() const { return _surface_vt_region_offset; }
	void set_surface_vt_forward_regions(real_t p_forward) { _surface_vt_forward_regions = CLAMP(p_forward, -64.f, 64.f); }
	real_t get_surface_vt_forward_regions() const { return _surface_vt_forward_regions; }
	Rect2i get_surface_vt_region_rect() const;
	// Forces every sector to one mip, so a test can ask for a specific level instead
	// of whatever the distance rule picks.
	void set_surface_vt_force_mip(const bool p_enabled, const int p_mip = 0);
	bool is_surface_vt_force_mip() const { return _surface_vt_force_mip; }
	int get_surface_vt_mip() const { return _surface_vt_mip; }
	void set_surface_vt_feedback_enabled(const bool p_enabled);
	bool is_surface_vt_feedback_enabled() const { return _surface_vt_feedback_enabled; }
	void set_surface_vt_feedback_interval(const int p_updates);
	int get_surface_vt_feedback_interval() const { return _surface_vt_feedback_interval; }
	void set_surface_vt_feedback_grid_chunks(const int p_chunks);
	int get_surface_vt_feedback_grid_chunks() const { return _surface_vt_feedback_grid_chunks; }
	void set_surface_vt_feedback_min_extent(const real_t p_extent);
	real_t get_surface_vt_feedback_min_extent() const { return _surface_vt_feedback_min_extent; }
	Terrain3DVTFeedback *get_surface_vt_feedback() const { return _surface_vt_feedback; }
	PackedVector2Array get_surface_vt_blocks() const { return _surface_vt_blocks; }
	bool is_surface_vt_blocks_dirty() const { return _surface_vt_blocks_dirty; }
	void clear_surface_vt_blocks_dirty() { _surface_vt_blocks_dirty = false; }

	// Far field
	Terrain3DVirtualTexture *get_surface_svt() const { return _surface_svt; }
	void set_surface_svt_enabled(const bool p_enabled);
	bool is_surface_svt_enabled() const { return _surface_svt_enabled; }
	void set_surface_svt_page_world(const real_t p_size);
	real_t get_surface_svt_page_world() const { return _surface_svt_page_world; }
	void set_surface_svt_page_size(const int p_size);
	int get_surface_svt_page_size() const { return _surface_svt_page_size; }
	void set_surface_svt_page_border(const int p_border);
	int get_surface_svt_page_border() const { return _surface_svt_page_border; }
	void set_surface_svt_page_count(const int p_count);
	int get_surface_svt_page_count() const { return _surface_svt_page_count; }
	void set_surface_svt_max_mip(const int p_mip);
	int get_surface_svt_max_mip() const { return _surface_svt_max_mip; }
	void set_surface_svt_distance(const real_t p_distance);
	real_t get_surface_svt_distance() const { return _surface_svt_distance; }
	void set_surface_svt_root_mips(const int p_mips);
	int get_surface_svt_root_mips() const { return _surface_svt_root_mips; }
	void set_surface_array_enabled(const bool p_enabled);
	bool is_surface_array_enabled() const { return _surface_array_enabled; }
	// Whether the array still has to carry the surface channel. It must, whenever no
	// virtual texture tier is enabled: with both off the array is the only source, and a
	// blank array would render every texel as material 0.
	bool is_surface_array_upload_needed() const {
		return _surface_array_enabled || (!_surface_vt_enabled && !_surface_svt_enabled);
	}
	// Drops the pages that carry a region's surface, so an edit is re-produced instead
	// of being served stale from either virtual texture.
	void invalidate_surface_pages(const Vector2i &p_region_loc);

	// Regions
	void set_region_size(const RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	void change_region_size(const RegionSize p_size) { _data ? _data->change_region_size(p_size) : void(); }
	void set_surface_density(const int p_density);
	int get_surface_density() const { return _surface_density; }
	void change_surface_density(const int p_density);
	void set_save_16_bit(const bool p_enabled);
	bool get_save_16_bit() const { return _save_16_bit; }
	void set_label_distance(const real_t p_distance);
	real_t get_label_distance() const { return _label_distance; }
	void set_label_size(const int p_size);
	int get_label_size() const { return _label_size; }
	void update_region_labels();

	// Target Tracking
	void set_camera(Camera3D *p_camera);
	Camera3D *get_camera() const { return cast_to<Camera3D>(_camera.ptr()); }
	void set_clipmap_target(Node3D *p_node);
	Node3D *get_clipmap_target() const { return _clipmap_target.ptr(); }
	Vector3 get_clipmap_target_position() const;
	void set_collision_target(Node3D *p_node);
	Node3D *get_collision_target() const { return _collision_target.ptr(); }
	Vector3 get_collision_target_position() const;
	void set_light_target(Node3D *p_node);
	Node3D *get_light_target() const { return _light_target.ptr(); }
	void snap();

	// Collision Aliases
	void set_collision_mode(const CollisionMode p_mode) { _collision ? _collision->set_mode(p_mode) : void(); }
	CollisionMode get_collision_mode() const { return _collision ? _collision->get_mode() : CollisionMode::DYNAMIC_GAME; }
	void set_collision_shape_size(const uint16_t p_size) { _collision ? _collision->set_shape_size(p_size) : void(); }
	uint16_t get_collision_shape_size() const { return _collision ? _collision->get_shape_size() : 16; }
	void set_collision_radius(const uint16_t p_radius) { _collision ? _collision->set_radius(p_radius) : void(); }
	uint16_t get_collision_radius() const { return _collision ? _collision->get_radius() : 64; }
	void set_collision_layer(const uint32_t p_layers) { _collision ? _collision->set_layer(p_layers) : void(); }
	uint32_t get_collision_layer() const { return _collision ? _collision->get_layer() : 1; }
	void set_collision_mask(const uint32_t p_mask) { _collision ? _collision->set_mask(p_mask) : void(); }
	uint32_t get_collision_mask() const { return _collision ? _collision->get_mask() : 1; }
	void set_collision_priority(const real_t p_priority) { _collision ? _collision->set_priority(p_priority) : void(); }
	real_t get_collision_priority() const { return _collision ? _collision->get_priority() : 1.f; }
	void set_physics_material(const Ref<PhysicsMaterial> &p_mat) { _collision ? _collision->set_physics_material(p_mat) : void(); }
	Ref<PhysicsMaterial> get_physics_material() const { return _collision ? _collision->get_physics_material() : Ref<PhysicsMaterial>(); }

	// Terrain Mesh
	Terrain3DMesher *get_mesher() const { return _terrain_mesher; }
	void set_material(const Ref<Terrain3DMaterial> &p_material);
	Ref<Terrain3DMaterial> get_material() const { return _material; }
	void set_mesh_lods(const int p_count);
	int get_mesh_lods() const { return _mesh_lods; }
	void set_tessellation_level(const int p_level);
	int get_tessellation_level() const { return _tessellation_level; }
	void set_mesh_size(const int p_size);
	int get_mesh_size() const { return _mesh_size; }
	void set_vertex_spacing(const real_t p_spacing);
	real_t get_vertex_spacing() const { return _vertex_spacing; }
	void set_cull_margin(const real_t p_margin);
	real_t get_cull_margin() const { return _cull_margin; }
	void set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows);
	RenderingServer::ShadowCastingSetting get_cast_shadows() const { return _cast_shadows; }
	void set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode);
	GeometryInstance3D::GIMode get_gi_mode() const { return _gi_mode; }
	void set_render_layers(const uint32_t p_layers);
	uint32_t get_render_layers() const { return _render_layers; }

	// Material Displacement Aliases
	void set_displacement_scale(const real_t p_displacement_scale) { _material.is_valid() ? _material->set_displacement_scale(p_displacement_scale) : void(); }
	real_t get_displacement_scale() const { return _material.is_valid() ? _material->get_displacement_scale() : 1.f; }
	void set_displacement_sharpness(const real_t p_displacement_sharpness) { _material.is_valid() ? _material->set_displacement_sharpness(p_displacement_sharpness) : void(); }
	real_t get_displacement_sharpness() const { return _material.is_valid() ? _material->get_displacement_sharpness() : 0.25f; }
	void set_buffer_shader_override_enabled(const bool p_enabled) { _material.is_valid() ? _material->set_buffer_shader_override_enabled(p_enabled) : void(); }
	bool is_buffer_shader_override_enabled() const { return _material.is_valid() ? _material->is_buffer_shader_override_enabled() : false; }
	void set_buffer_shader_override(const Ref<Shader> &p_shader) { return _material.is_valid() ? _material->set_buffer_shader_override(p_shader) : void(); }
	Ref<Shader> get_buffer_shader_override() const { return _material.is_valid() ? _material->get_buffer_shader_override() : Ref<Shader>(); }

	// Ocean Mesh
	Terrain3DMesher *get_ocean_mesher() const { return _ocean_mesher; }
	void set_ocean_enabled(const bool p_enabled);
	bool is_ocean_enabled() const { return _ocean_enabled; }
	void set_ocean_mesh_lods(const int p_count);
	int get_ocean_mesh_lods() const { return _ocean_mesh_lods; }
	void set_ocean_tessellation_level(const int p_level);
	int get_ocean_tessellation_level() const { return _ocean_tessellation_level; }
	void set_ocean_mesh_size(const int p_size);
	int get_ocean_mesh_size() const { return _ocean_mesh_size; }
	void set_ocean_vertex_spacing(const real_t p_spacing);
	real_t get_ocean_vertex_spacing() const { return _ocean_vertex_spacing; }
	void set_ocean_cull_margin(const real_t p_margin);
	real_t get_ocean_cull_margin() const { return _ocean_cull_margin; }
	void set_ocean_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows);
	RenderingServer::ShadowCastingSetting get_ocean_cast_shadows() const { return _ocean_cast_shadows; }
	void set_ocean_gi_mode(const GeometryInstance3D::GIMode p_gi_mode);
	GeometryInstance3D::GIMode get_ocean_gi_mode() const { return _ocean_gi_mode; }
	void set_ocean_render_layers(const uint32_t p_layers);
	uint32_t get_ocean_render_layers() const { return _ocean_render_layers; }
	void set_ocean_material(const Ref<Material> &p_material);
	Ref<Material> get_ocean_material() const { return _ocean_material; }

	// Rendering
	void set_mouse_layer(const uint32_t p_layer);
	uint32_t get_mouse_layer() const { return _mouse_layer; }
	void set_free_editor_textures(const bool p_free_textures) { _free_editor_textures = p_free_textures; }
	bool get_free_editor_textures() const { return _free_editor_textures; }
	void set_instancer_mode(const InstancerMode p_mode) { _instancer ? _instancer->set_mode(p_mode) : void(); }
	InstancerMode get_instancer_mode() const { return _instancer ? _instancer->get_mode() : InstancerMode::NORMAL; }

	// Utility
	Vector3 get_intersection(const Vector3 &p_src_pos, const Vector3 &p_direction, const bool p_gpu_mode = false);
	Dictionary get_raycast_result(const Vector3 &p_src_pos, const Vector3 &p_direction, const uint32_t p_col_mask = 0xFFFFFFFF, const bool p_exclude_self = false) const;
	Ref<Mesh> bake_mesh(const int p_lod, const Terrain3DData::HeightFilter p_filter = Terrain3DData::HEIGHT_FILTER_NEAREST) const;
	PackedVector3Array generate_nav_mesh_source_geometry(const AABB &p_global_aabb, const bool p_require_nav = true) const;

	// Warnings
	void set_warning(const uint8_t p_warning, const bool p_enabled);
	uint8_t get_warnings() const { return _warnings; }
	PackedStringArray _get_configuration_warnings() const override;

	// Overlay Aliases
	void set_show_region_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_region_grid(p_enabled) : void(); }
	bool get_show_region_grid() const { return _material.is_valid() ? _material->get_show_region_grid() : false; }
	void set_show_instancer_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_instancer_grid(p_enabled) : void(); }
	bool get_show_instancer_grid() const { return _material.is_valid() ? _material->get_show_instancer_grid() : false; }
	void set_show_vertex_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_vertex_grid(p_enabled) : void(); }
	bool get_show_vertex_grid() const { return _material.is_valid() ? _material->get_show_vertex_grid() : false; }
	void set_show_contours(const bool p_enabled) { _material.is_valid() ? _material->set_show_contours(p_enabled) : void(); }
	bool get_show_contours() const { return _material.is_valid() ? _material->get_show_contours() : false; }
	void set_show_slope(const bool p_enabled) { _material.is_valid() ? _material->set_show_slope(p_enabled) : void(); }
	bool get_show_slope() const { return _material.is_valid() ? _material->get_show_slope() : false; }
	void set_show_navigation(const bool p_enabled) { _material.is_valid() ? _material->set_show_navigation(p_enabled) : void(); }
	bool get_show_navigation() const { return _material.is_valid() ? _material->get_show_navigation() : false; }

	// Debug View Aliases
	void set_show_checkered(const bool p_enabled) { _material.is_valid() ? _material->set_show_checkered(p_enabled) : void(); }
	bool get_show_checkered() const { return _material.is_valid() ? _material->get_show_checkered() : false; }
	void set_show_grey(const bool p_enabled) { _material.is_valid() ? _material->set_show_grey(p_enabled) : void(); }
	bool get_show_grey() const { return _material.is_valid() ? _material->get_show_grey() : false; }
	void set_show_heightmap(const bool p_enabled) { _material.is_valid() ? _material->set_show_heightmap(p_enabled) : void(); }
	bool get_show_heightmap() const { return _material.is_valid() ? _material->get_show_heightmap() : false; }
	void set_show_jaggedness(const bool p_enabled) { _material.is_valid() ? _material->set_show_jaggedness(p_enabled) : void(); }
	bool get_show_jaggedness() const { return _material.is_valid() ? _material->get_show_jaggedness() : false; }
	void set_show_autoshader(const bool p_enabled) { _material.is_valid() ? _material->set_show_autoshader(p_enabled) : void(); }
	bool get_show_autoshader() const { return _material.is_valid() ? _material->get_show_autoshader() : false; }
	void set_show_control_texture(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_texture(p_enabled) : void(); }
	bool get_show_control_texture() const { return _material.is_valid() ? _material->get_show_control_texture() : false; }
	void set_show_control_blend(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_blend(p_enabled) : void(); }
	bool get_show_control_blend() const { return _material.is_valid() ? _material->get_show_control_blend() : false; }
	void set_show_control_angle(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_angle(p_enabled) : void(); }
	bool get_show_control_angle() const { return _material.is_valid() ? _material->get_show_control_angle() : false; }
	void set_show_control_scale(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_scale(p_enabled) : void(); }
	bool get_show_control_scale() const { return _material.is_valid() ? _material->get_show_control_scale() : false; }
	void set_show_colormap(const bool p_enabled) { _material.is_valid() ? _material->set_show_colormap(p_enabled) : void(); }
	bool get_show_colormap() const { return _material.is_valid() ? _material->get_show_colormap() : false; }
	void set_show_roughmap(const bool p_enabled) { _material.is_valid() ? _material->set_show_roughmap(p_enabled) : void(); }
	bool get_show_roughmap() const { return _material.is_valid() ? _material->get_show_roughmap() : false; }
	void set_show_displacement_buffer(const bool p_enabled) { _material.is_valid() ? _material->set_show_displacement_buffer(p_enabled) : void(); }
	bool get_show_displacement_buffer() const { return _material.is_valid() ? _material->get_show_displacement_buffer() : false; }

	// PBR View Aliases
	void set_show_texture_albedo(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_albedo(p_enabled) : void(); }
	bool get_show_texture_albedo() const { return _material.is_valid() ? _material->get_show_texture_albedo() : false; }
	void set_show_texture_height(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_height(p_enabled) : void(); }
	bool get_show_texture_height() const { return _material.is_valid() ? _material->get_show_texture_height() : false; }
	void set_show_texture_normal(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_normal(p_enabled) : void(); }
	bool get_show_texture_normal() const { return _material.is_valid() ? _material->get_show_texture_normal() : false; }
	void set_show_texture_rough(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_rough(p_enabled) : void(); }
	bool get_show_texture_rough() const { return _material.is_valid() ? _material->get_show_texture_rough() : false; }
	void set_show_texture_ao(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_ao(p_enabled) : void(); }
	bool get_show_texture_ao() const { return _material.is_valid() ? _material->get_show_texture_ao() : false; }

protected:
	void _notification(const int p_what);
	void _validate_property(PropertyInfo &p_property) const;
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3D::RegionSize);
VARIANT_ENUM_CAST(Terrain3D::DebugLevel);

constexpr Terrain3D::DebugLevel MESG = Terrain3D::DebugLevel::MESG;
constexpr Terrain3D::DebugLevel WARN = Terrain3D::DebugLevel::WARN;
constexpr Terrain3D::DebugLevel ERROR = Terrain3D::DebugLevel::ERROR;
constexpr Terrain3D::DebugLevel INFO = Terrain3D::DebugLevel::INFO;
constexpr Terrain3D::DebugLevel DEBUG = Terrain3D::DebugLevel::DEBUG;
constexpr Terrain3D::DebugLevel EXTREME = Terrain3D::DebugLevel::EXTREME;

#endif // TERRAIN3D_CLASS_H
