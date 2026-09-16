// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#include <unordered_map>
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
#include "terrain_3d_avt.h"
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
#include "terrain_3d_vt_visibility.h"
#include "terrain_3d_vt_state.h"
#include "terrain_3d_page_pipeline.h"

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

	// Length of the shader's far-field distance table (main.glsl declares
	// `_surface_svt_mip_distance[16]`). Levels above this are unreachable anyway: the
	// indirection's mip chain caps the effective level well below it.
	static constexpr int SVT_MIP_DISTANCE_COUNT = 16;

private:
	String _version = "1.1.0-dev";
	String _data_directory;
	bool _is_inside_world = false;
	bool _initialized = false;
	uint8_t _warnings = 0u;
	// Whether this node's `terrain/...` monitors are published, and the prefix they use.
	// A second terrain in one scene would collide on the plain names, so it publishes under
	// its instance id instead.
	bool _monitors_registered = false;
	String _monitor_prefix = "terrain/";

	// Object references
	Terrain3DData *_data = nullptr;
	Ref<Terrain3DAssets> _assets;
	Terrain3DCollision *_collision = nullptr;
	Terrain3DInstancer *_instancer = nullptr;
	Terrain3DEditor *_editor = nullptr;
	Object *_editor_plugin = nullptr;
	Terrain3DStreamer *_streamer = nullptr;
	bool _streaming_enabled = false;

	// Virtual texture state: the shared service, the near-field AVT and the far-field
	// SVT in one struct, so the node's own fields stay readable. See
	// terrain_3d_vt_state.h for the field groups.
	Terrain3DVTState _vt;


	bool _ensure_vt_capacity(int p_required);
	void _process_async_svt_pages();
	uint32_t _svt_cell_signature(const Vector2i &p_cell) const;
	Dictionary _load_svt_cell(const Vector2i &p_cell);
	int _update_sector_avt(int p_max_pages);
	int _produce_sector_avt_pages(int p_max_pages);
	// Stages of one _produce_sector_avt_pages() pass, in call order. See the pass
	// struct in terrain_3d_avt.h for what each stage owns.
	void _avt_classify_plan(Terrain3DAVTProducePass &r_pass);
	void _avt_retain_visible(const Terrain3DAVTProducePass &p_pass);
	Terrain3DPagePipeline::Request _avt_page_request(const Terrain3DAVTPageRequest &p_page) const;
	bool _avt_produce_page(Terrain3DAVTProducePass &r_pass, const Terrain3DAVTPageRequest &p_page, bool p_prefetch = false);
	void _avt_prime_sources(const Terrain3DAVTProducePass &p_pass);
	void _avt_produce_visible(Terrain3DAVTProducePass &r_pass, int p_max_pages);
	void _avt_produce_prefetch(Terrain3DAVTProducePass &r_pass, int p_max_pages);
	void _avt_finish_produce(Terrain3DAVTProducePass &r_pass);
	PackedByteArray _avt_plan_state(bool p_bounds_ready) const;
	int _avt_install_or_reuse_plan(uint64_t p_started, int p_max_pages, bool p_same_plan);
	Terrain3DAVTSectorScan _avt_scan_sectors(const TerrainVT::VisibleView &p_view, const Vector3 &p_camera_position,
			bool p_bounds_ready, const Vector2 &p_focus, float p_reach) const;
	// World/texel scale of one AVT world level's logical image. A pure function of the live
	// VT configuration, so the plan that stores it and the directory that publishes it read
	// it independently instead of one planner phase reading what another wrote.
	float _avt_logical_ratio() const;
	Terrain3DAVTHierarchy _avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan);
	void _avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, float p_reach);
	void _avt_submit_plan(Terrain3DAVTHierarchy &r_hierarchy, const PackedByteArray &p_plan_key,
			const TerrainVT::VisibleView &p_view, const Vector3 &p_camera_position, bool p_bounds_ready,
			const Vector2 &p_focus, float p_reach);
	bool _avt_publish_directory(const Terrain3DAVTHierarchy &p_hierarchy, bool p_directory_dirty);
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
	bool _cdlod_enabled = true;
	int _cdlod_patch_size = 32;
	real_t _cdlod_lod_scale = 8.f;
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
	void _update_render_geometry();
	void _invalidate_render_geometry();
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
	// Applies one view's configuration apart from its physical pool: page
	// dimensions, format and the mode-specific addressing. Shared by the initial
	// setup and the shared-pool rebuild so neither depends on stored state.
	void _configure_surface_view(Terrain3DVirtualTexture *p_view, bool p_world_space);
	void _update_vt_service();
	// Rebuilds the shared service when a view was cleared out from under it, so a
	// demand pass never runs against a view without a page table.
	void _ensure_vt_views_ready();
	// True once the automatic tick's VT budget is spent. Only an automatic tick sets a
	// deadline, so an explicit demand call always returns false here.
	bool _vt_tick_expired() const;
	// True while any view still owes the render thread a page-table upload. Used by
	// the editor's own redraw request, since render-thread work only progresses
	// while frames are drawn.
	bool _vt_has_pending_upload() const;
	// Whether a view still owes a page: render work queued, demand waiting on a source job
	// or a free slot, or a far-field job outstanding.
	bool _vt_has_streaming_work() const;
	void _destroy_vt_service();
	void _configure_vt_service();
	// Publishes the address directory of a finished hierarchy, and republishes the
	// material only when a uniform it reads changed.
	void _publish_avt_directory(const Terrain3DAVTHierarchy &p_hierarchy);
	void _queue_vt_material_page(int p_slot, const Ref<Image> &p_payload, const Rect2 &p_rect,
			bool p_svt, int p_mip, const Vector2i &p_address,
			const Terrain3DPagePipeline::Result *p_prepared = nullptr);
	static void _bind_vt_methods();
	void _process_svt_bake(int p_page_budget = -1);
	int _update_visible_svt(int p_max_pages);
	// Whether a published far-field page still has no content: true when the producer does
	// not hold it ready and no production for it is in flight. Demand re-produces such a page
	// instead of treating its indirection entry as a hit.
	bool _vt_page_production_stale(int p_slot);
	// The same question with the producer's answer already known (-1 asks it here), so a
	// verification pass over a whole resident set takes one lock instead of one per page.
	bool _vt_page_production_stale(int p_slot, int p_ready);
	String _svt_page_path(const Vector2i &p_address, int p_mip) const;
	void _invalidate_vt_region(const Vector2i &p_region);
	void _process_svt_auto_bake();
	int _queue_svt_bake(const Dictionary &p_dirty_regions);
	void _invalidate_vt_slot(int p_slot);
	// Raw-ID diagnostics read the atlas directly, so a page they allocate has to carry
	// content before it is published: this crops the resident region payloads into one
	// world-aligned page. It is a no-op outside the diagnostic mode.
	bool _write_diagnostic_sparse_page(int p_slot, int p_page_x, int p_page_y, int p_local_mip,
			real_t p_page_world);
	// Creates or resizes the resident far-field cell store to the current far-field density.
	void _configure_svt_cell_store();
	// Cheap staleness key of one resident far-field cell: the material signature, the
	// far-field density and the newest edit that touched the cell or one of its neighbours.
	uint64_t _svt_cell_state_key(const Vector2i &p_cell) const;
	// Resolves the resident cells a far page samples into copy pieces. A cell that is not
	// resident is reported instead, so no page is ever assembled from another cell's layer.
	bool _resolve_svt_cell_pieces(const Rect2 &p_rect, Array &r_pieces, std::vector<Vector2i> &r_missing);
	// Whether any cell a far page touches has a persisted bake the source worker can read.
	bool _svt_cells_have_persisted_bake(const Rect2 &p_rect);
	void _reset_vt_configuration();
	// Applies one tier's storage format to the producer and re-produces the pages it stored.
	void _apply_vt_tier_compression(const int p_tier, const int p_mode);
	// The terrain's own cost, published under a `terrain/` keyword so it can be told apart
	// from the engine's numbers: custom monitors for the editor's monitor graph, and profiler
	// zones and plots for a profiler timeline. Registered on the first tick the VT scheduler
	// actually runs and removed before the node is deleted, because the monitors hold callables
	// onto this object.
	void _register_debug_monitors();
	void _unregister_debug_monitors();
	double _monitor_vt_cpu_ms() const { return _vt.vt_cpu_ms; }
	double _monitor_vt_peak_ms() const { return _vt.vt_cpu_peak_ms; }
	double _monitor_avt_cpu_ms() const { return _vt.vt_avt_ms; }
	double _monitor_svt_cpu_ms() const { return _vt.vt_svt_ms; }
	// The geometry backend's pass, which the rendering server drives rather than the tick,
	// so it is read from the mesher instead of from the VT state.
	double _monitor_cdlod_cpu_ms() const;
	int64_t _monitor_material_bytes() const;
	int64_t _monitor_pages_ready() const;
	int64_t _monitor_pages_pending() const;
	// Pages the image being rendered samples with no content. With the motion lead on
	// this is the reading that says whether the view is streaming in.
	int64_t _monitor_pages_late() const { return _vt.avt_late_pages; }
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
	// Phases of one update_surface_vt() pass, in call order. The pass rebuilds the
	// shader's block tables from the resident set, decides how many pages each
	// sector may use, then fills only the pages this pass allocated.
	void _prepare_vt_block_tables(PackedVector2Array &r_blocks, PackedFloat32Array &r_sizes);
	Dictionary _collect_eligible_vt_regions();
	Dictionary _compute_adaptive_sector_sizes(const Dictionary &p_eligible, int p_max_pages_per_axis);
	void _retire_stale_vt_sectors(const Dictionary &p_eligible);
	bool _prepare_vt_sector(const Vector2i &p_region_loc, int p_pages_per_axis);
	std::vector<Vector3i> _vt_page_requests_for_sector(const Vector2i &p_region_loc, int p_pages_per_axis,
			real_t p_distance, real_t p_page_world_size, int p_max_local_mip);
	int _produce_missing_vt_pages(const Vector2i &p_region_loc, int p_pages_per_axis, real_t p_region_world,
			const std::vector<Vector3i> &p_missing);
	void _publish_vt_block_tables(const PackedVector2Array &p_blocks, const PackedFloat32Array &p_sizes);

	void _setup_surface_svt();
	void _destroy_surface_svt();
	// One far-field demand pass: walks the world page grid within the reach of the
	// clipmap target, picks a mip per page from its distance, and produces the pages
	// that are missing.
	int update_surface_svt(int p_max_pages = 0);
	// The one far-field distance -> level rule, shared by the demand pass, the legacy
	// grid scan and the shader uniform. p_distance is the camera distance in metres to
	// the surface point being sampled or covered. p_max_mip overrides the level the far
	// field currently publishes (the demand pass plans against the indirection's absolute
	// limit); -1 uses the published level.
	int get_surface_svt_mip_for_distance(const real_t p_distance, const int p_max_mip = -1) const;

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
	int get_vt_page_size() const { return _vt.vt_page_size; }
	void set_vt_page_border(int p_border);
	int get_vt_page_border() const { return _vt.vt_page_border; }
	void set_vt_auto_capacity(bool p_enabled) { _vt.vt_auto_capacity = p_enabled; _vt.avt_plan_key.clear(); }
	bool get_vt_auto_capacity() const { return _vt.vt_auto_capacity; }
	void set_vt_page_count(int p_count);
	int get_vt_page_count() const { return _vt.vt_page_count; }
	void set_vt_pages_per_update(int p_pages);
	int get_vt_pages_per_update() const { return _vt.vt_pages_per_update; }
	void set_vt_page_workers(int p_workers);
	int get_vt_page_workers() const { return _vt.vt_page_workers; }
	void set_vt_motion_lead_ms(real_t p_lead);
	real_t get_vt_motion_lead_ms() const { return _vt.vt_motion_lead_ms; }
	void set_avt_feedback(bool p_enabled);
	bool get_avt_feedback() const { return _vt.avt_feedback; }
	void set_svt_feedback(bool p_enabled);
	bool get_svt_feedback() const { return _vt.svt_feedback; }
	bool is_svt_startup_ready() const { return !_vt.svt_feedback || _vt.surface_svt_root_mips <= 0 || _vt.svt_startup_ready; }
	void set_vt_adaptive_enabled(bool p_enabled);
	bool is_vt_adaptive_enabled() const { return _vt.vt_adaptive_enabled; }
	void set_vt_editor_preview(bool p_enabled);
	bool is_vt_editor_preview() const { return _vt.vt_editor_preview; }
	bool is_vt_editor_preview_active() const;
	void set_vt_debug_direct_material(bool p_enabled);
	bool is_vt_debug_direct_material() const { return _vt.vt_debug_direct_material; }
	Dictionary get_vt_settings() const;
	int prepare_vt_capture();
	Array get_vt_pages() const;
	// Diagnostic and test hook: makes one produced page read as not ready, without touching
	// its indirection entry or its demand record. That is what a lost encode leaves behind,
	// and only a demand pass noticing the missing content repairs it. Returns false when the
	// slot is not currently ready, so a caller cannot mistake a no-op for a loss.
	bool debug_lose_vt_page_readiness(int p_slot);
	Dictionary get_vt_material_textures() const;
	Ref<Image> get_vt_page_preview(int p_slot);
	void invalidate_vt_materials();
	int bake_svt();
	void set_svt_auto_bake(bool p_enabled);
	bool is_svt_auto_bake() const { return _vt.svt_auto_bake; }
	Array get_svt_baked_pages();
	PackedFloat32Array get_surface_vt_block_sizes() const { return _vt.surface_vt_block_sizes; }
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

	Terrain3DVirtualTexture *get_surface_vt() const { return _vt.surface_vt; }
	void set_surface_vt_enabled(const bool p_enabled);
	bool is_surface_vt_enabled() const { return _vt.surface_vt_enabled; }
	void set_surface_vt_page_count(const int p_count);
	int get_surface_vt_page_count() const { return _vt.surface_vt_page_count; }
	void set_surface_vt_page_size(const int p_size);
	int get_surface_vt_page_size() const { return _vt.surface_vt_page_size; }
	void set_surface_vt_page_border(const int p_border);
	int get_surface_vt_page_border() const { return _vt.surface_vt_page_border; }
	void set_surface_vt_pages_per_axis(const int p_pages);
	int get_surface_vt_pages_per_axis() const { return _vt.surface_vt_pages_per_axis; }
	void set_surface_vt_texels_per_meter(real_t p_value);
	real_t get_surface_vt_texels_per_meter() const { return _vt.surface_vt_texels_per_meter; }
	void set_surface_svt_texels_per_meter(real_t p_value);
	real_t get_surface_svt_texels_per_meter() const { return _vt.vt_page_size / _vt.surface_svt_page_world; }
	void set_surface_vt_distance_mips(bool p_enabled);
	bool is_surface_vt_distance_mips() const { return _vt.surface_vt_distance_mips; }
	void set_surface_vt_mip_ranges(const Vector3 &p_ranges);
	Vector3 get_surface_vt_mip_ranges() const { return _vt.surface_vt_mip_ranges; }
	float get_surface_vt_distance_lod(float p_distance) const;
	void set_surface_vt_mip0_distance(real_t p_distance) { Vector3 ranges = _vt.surface_vt_mip_ranges; ranges.x = p_distance; set_surface_vt_mip_ranges(ranges); set_surface_vt_distance_mips(true); }
	real_t get_surface_vt_mip0_distance() const { return _vt.surface_vt_mip_ranges.x; }
	void set_surface_vt_mip1_distance(real_t p_distance) { Vector3 ranges = _vt.surface_vt_mip_ranges; ranges.y = p_distance; set_surface_vt_mip_ranges(ranges); set_surface_vt_distance_mips(true); }
	real_t get_surface_vt_mip1_distance() const { return _vt.surface_vt_mip_ranges.y; }
	void set_surface_vt_mip2_distance(real_t p_distance) { Vector3 ranges = _vt.surface_vt_mip_ranges; ranges.z = p_distance; set_surface_vt_mip_ranges(ranges); set_surface_vt_distance_mips(true); }
	real_t get_surface_vt_mip2_distance() const { return _vt.surface_vt_mip_ranges.z; }
	void set_surface_vt_mip_distances(const PackedFloat32Array &p_distances);
	PackedFloat32Array get_surface_vt_mip_distances() const { return _vt.surface_vt_mip_distances; }
	int get_surface_vt_mip_for_distance(real_t p_distance) const;
	int get_avt_base_block_size() const;
	void set_surface_vt_resolution(int p_resolution);
	int get_surface_vt_resolution() const { return _vt.vt_page_size * _vt.surface_vt_pages_per_axis; }
	void set_surface_vt_distance(const real_t p_distance);
	real_t get_surface_vt_distance() const { return _vt.surface_vt_distance; }
	void set_surface_vt_region_grid(const Vector2i &p_grid) { _vt.surface_vt_region_grid = Vector2i(CLAMP(p_grid.x, 1, 64), CLAMP(p_grid.y, 1, 64)); }
	Vector2i get_surface_vt_region_grid() const { return _vt.surface_vt_region_grid; }
	void set_surface_vt_selection_mode(int p_mode);
	int get_surface_vt_selection_mode() const { return _vt.surface_vt_selection_mode; }
	bool is_sector_avt() const { return _vt.surface_vt_selection_mode == 2 && !_vt.vt_debug_direct_material; }
	// Motion look-ahead: smooths the camera's velocity and returns the transform the demand
	// pass plans for. See Terrain3DVTState::vt_motion_lead_ms.
	void _vt_update_motion_lead();
	Transform3D _vt_lead_camera_transform(const Transform3D &p_camera_transform) const;
	Transform3D _vt_plan_key_transform(const Transform3D &p_camera_transform) const;
	RID get_avt_sector_directory() const { return _vt.avt_sector_directory.is_valid() ? _vt.avt_sector_directory->get_rid() : RID(); }
	int get_avt_directory_mask() const { return _vt.avt_directory_mask; }
	int get_avt_root_level() const { return _vt.avt_root_level; }
	void set_surface_vt_region_offset(const Vector2i &p_offset) { _vt.surface_vt_region_offset = p_offset; }
	Vector2i get_surface_vt_region_offset() const { return _vt.surface_vt_region_offset; }
	void set_surface_vt_forward_regions(real_t p_forward) { _vt.surface_vt_forward_regions = CLAMP(p_forward, -64.f, 64.f); }
	real_t get_surface_vt_forward_regions() const { return _vt.surface_vt_forward_regions; }
	Rect2i get_surface_vt_region_rect() const;
	// Forces every sector to one mip, so a test can ask for a specific level instead
	// of whatever the distance rule picks.
	void set_surface_vt_texels_per_pixel(real_t p_value) { _vt.surface_vt_texels_per_pixel = MAX(0.25f, p_value); }
	real_t get_surface_vt_texels_per_pixel() const { return _vt.surface_vt_texels_per_pixel; }
	void set_surface_vt_force_mip(const bool p_enabled, const int p_mip = 0);
	bool is_surface_vt_force_mip() const { return _vt.surface_vt_force_mip; }
	// Storage format of the material page arrays, per tier, one format for each tier's three
	// channels. The baker resolves a request against the GPU block encoder and this device's
	// sampling support; see get_vt_settings() for what was applied and why a request was
	// refused.
	void set_surface_vt_compression(const int p_compression);
	int get_surface_vt_compression() const;
	void set_surface_svt_compression(const int p_compression);
	int get_surface_svt_compression() const;
	// The near field's setting, under the name it had while compression was one switch.
	void set_vt_atlas_compression(const int p_compression);
	int get_vt_atlas_compression() const;
	Dictionary probe_vt_atlas_compression(const Ref<Image> &p_image) const;
	int get_surface_vt_mip() const { return _vt.surface_vt_mip; }
	void set_surface_vt_feedback_enabled(const bool p_enabled);
	bool is_surface_vt_feedback_enabled() const { return _vt.surface_vt_feedback_enabled; }
	void set_surface_vt_feedback_interval(const int p_updates);
	int get_surface_vt_feedback_interval() const { return _vt.surface_vt_feedback_interval; }
	void set_surface_vt_feedback_grid_chunks(const int p_chunks);
	int get_surface_vt_feedback_grid_chunks() const { return _vt.surface_vt_feedback_grid_chunks; }
	void set_surface_vt_feedback_min_extent(const real_t p_extent);
	real_t get_surface_vt_feedback_min_extent() const { return _vt.surface_vt_feedback_min_extent; }
	Terrain3DVTFeedback *get_surface_vt_feedback() const { return _vt.surface_vt_feedback; }
	PackedVector2Array get_surface_vt_blocks() const { return _vt.surface_vt_blocks; }

	// Far field
	Terrain3DVirtualTexture *get_surface_svt() const { return _vt.surface_svt; }
	void set_surface_svt_enabled(const bool p_enabled);
	bool is_surface_svt_enabled() const { return _vt.surface_svt_enabled; }
	void set_surface_svt_page_world(const real_t p_size);
	real_t get_surface_svt_page_world() const { return _vt.surface_svt_page_world; }
	void set_surface_svt_page_size(const int p_size);
	int get_surface_svt_page_size() const { return _vt.surface_svt_page_size; }
	void set_surface_svt_page_border(const int p_border);
	int get_surface_svt_page_border() const { return _vt.surface_svt_page_border; }
	void set_surface_svt_page_count(const int p_count);
	int get_surface_svt_page_count() const { return _vt.surface_svt_page_count; }
	void set_surface_svt_max_mip(const int p_mip);
	int get_surface_svt_max_mip() const { return _vt.surface_svt_max_mip; }
	void set_surface_svt_distance(const real_t p_distance);
	real_t get_surface_svt_distance() const { return _vt.surface_svt_distance; }
	void set_surface_svt_root_mips(const int p_mips);
	int get_surface_svt_root_mips() const { return _vt.surface_svt_root_mips; }
	void set_surface_svt_mip_distances(const PackedFloat32Array &p_distances);
	PackedFloat32Array get_surface_svt_mip_distances() const { return _vt.surface_svt_mip_distances; }
	int get_surface_svt_mip_distance_count() const { return int(_vt.surface_svt_mip_distances.size()); }
	// Largest distance the table (or the automatic rule) still serves with a page.
	real_t get_surface_svt_mip_reach() const;
	void set_surface_array_enabled(const bool p_enabled);
	bool is_surface_array_enabled() const { return _vt.surface_array_enabled; }
	// Whether the array still has to carry the surface channel. It must, whenever no
	// virtual texture tier is enabled: with both off the array is the only source, and a
	// blank array would render every texel as material 0.
	bool is_surface_array_upload_needed() const {
		return is_vt_editor_preview_active() || _vt.surface_array_enabled || (!_vt.surface_vt_enabled && !_vt.surface_svt_enabled);
	}
	// Drops the pages that carry a region's surface, so an edit is re-produced instead
	// of being served stale from either virtual texture. While the editor preview is active
	// an edit is only recorded and the refresh is deferred; p_force skips that, which a
	// change that invalidates every cached page - such as the atlas format - has to do.
	void invalidate_surface_pages(const Vector2i &p_region_loc, bool p_force = false);

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
	void set_cdlod_enabled(bool p_enabled);
	bool is_cdlod_enabled() const { return _cdlod_enabled; }
	void set_cdlod_patch_size(int p_size);
	int get_cdlod_patch_size() const { return _cdlod_patch_size; }
	void set_cdlod_lod_scale(real_t p_scale);
	real_t get_cdlod_lod_scale() const { return _cdlod_lod_scale; }
	Dictionary get_cdlod_stats() const { return _terrain_mesher ? _terrain_mesher->get_cdlod_stats() : Dictionary(); }
	// Main-thread CPU the VT section of one physics tick may spend, in milliseconds.
	void set_vt_frame_budget_ms(real_t p_budget) { _vt.vt_frame_budget_ms = CLAMP(p_budget, 0.f, 16.f); }
	real_t get_vt_frame_budget_ms() const { return _vt.vt_frame_budget_ms; }
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
