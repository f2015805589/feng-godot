// Copyright 漏 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#include <array>
#include <functional>
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
#include "terrain_3d_debug.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_material.h"
#include "terrain_3d_mesher.h"
#include "terrain_3d_streamer.h"
#include "terrain_3d_svt.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_feedback.h"
#include "terrain_vt.h"
#include "terrain_3d_vt_visibility.h"
#include "terrain_3d_vt_state.h"
#include "terrain_3d_clipmap_layer.h"
#include "terrain_3d_page_pipeline.h"

class Terrain3D : public Node3D {
	GDCLASS(Terrain3D, Node3D);
	CLASS_NAME();

public: // Constants
	// The levels and their names are `Terrain3DDebug::Level`, declared in terrain_3d_debug.h so
	// that `logger.h` can reach them without this class. The property, the setter and the value
	// itself are still this class's: `debug_level` below is a `Terrain3D` static member.
	using DebugLevel = Terrain3DDebug::Level;

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
	// The near field's per-pass page allowance, always inside the live page-budget tier. The tick
	// hands the pass this many pages and the producer's frame budget and the source queue window are
	// set from the same number, so the split has one home. See the definition.
	int _avt_tick_allowance() const;
	// The near field's per-pass ceiling before the even split: the live tier, clamped by
	// `vt_pages_per_update` when that budget was set below the shipped rate. One spelling, because
	// the allowance and the pass's own clamp both size against it. See the definition.
	int _avt_live_batch() const;
	// The near field's page budget for this tick: consumes the motion sample the lead was built from
	// and picks the tier (stable / escalated) with its hold and decay. The only writer of the tier,
	// called once per tick right after `_vt_update_motion_lead()`.
	void _vt_update_avt_page_budget();
	// Hands the producer the peak the configured tiers can reach, which is what its encode ring is
	// sized for when its bundle is built.
	void _publish_avt_page_budget();
	// Stages of one _produce_sector_avt_pages() pass, in call order. See the pass
	// struct in terrain_3d_avt.h for what each stage owns.
	void _avt_classify_plan(Terrain3DAVTProducePass &r_pass);
	void _avt_retain_visible(const Terrain3DAVTProducePass &p_pass);
	Terrain3DPagePipeline::Request _avt_page_request(const Terrain3DAVTPageRequest &p_page) const;
	bool _avt_produce_page(Terrain3DAVTProducePass &r_pass, const Terrain3DAVTPageRequest &p_page);
	// `p_refill_above` > 0 skips the call when the source queue already holds that many claimable
	// requests; the second call of a tick passes it. `p_refill` names which of the two the
	// statistics describe. See the definition.
	void _avt_prime_sources(const Terrain3DAVTProducePass &p_pass, const int p_refill_above = 0, const bool p_refill = false);
	void _avt_produce_visible(Terrain3DAVTProducePass &r_pass, int p_max_pages);
	void _avt_finish_produce(Terrain3DAVTProducePass &r_pass);
	Terrain3DAVTPlanKey _avt_plan_state(bool p_bounds_ready) const;
	int _avt_install_or_reuse_plan(uint64_t p_started, int p_max_pages, bool p_same_plan);
	// Republishes the standing plan's page set to the near field's indirection as its "planned"
	// levels, which is what the shader's strict resolve (feedback off) coarsens against. Called
	// wherever `_vt.avt_plan.pages` changes shape, never per tick: the write is a diff over two
	// page sets, not a pass over the address space.
	void _avt_publish_plan_coverage();
	Terrain3DAVTSectorScan _avt_scan_sectors(const TerrainVT::VisibleView &p_view, const Vector3 &p_camera_position,
			bool p_bounds_ready, const Vector2 &p_focus, float p_reach) const;
	Terrain3DAVTHierarchy _avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan);
	void _avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, float p_reach);
	void _avt_submit_plan(Terrain3DAVTHierarchy &r_hierarchy, const Terrain3DAVTPlanKey &p_plan_key,
			const TerrainVT::VisibleView &p_view, bool p_bounds_ready,
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
	void _destroy_ocean_mesher(const bool p_final = false);
	void _destroy_streamer();

	void _setup_surface_vt();
	// The assembly rule: brings the live service objects in line with the delivery matrix, and
	// rebuilds the material when the set moved. Called by every write to a cell and by
	// `_initialize()`, so a service's lifetime has one owner instead of a setup call site each.
	void _resolve_vt_delivery(const bool p_changed);
	// Builds the clipmap layer of one channel group if it does not exist and (re)applies the layer
	// settings to it - including which implementation answers them. The one owner of the layer's
	// lifetime, called from the assembly rule and by `debug_update_vt_clipmap()`; a group whose
	// channel this build has no source for stays unbuilt, says so, and is reported by the return value
	// rather than by a layer nobody can produce.
	bool _setup_vt_clipmap(const TerrainVT::ChannelGroup p_group);
	// The shape and implementation the layer is configured from, in the shared vocabulary. One place
	// builds it, so the settings, the assembly rule and the debug entry cannot disagree about what a
	// group's layer is.
	Terrain3DClipmapLayer::Settings _clipmap_settings() const;
	// The channels this build's ring can carry. One decision read twice - by `has_clipmap_source()`
	// above and by the factory below - so the matrix's acceptance and the ring's construction cannot
	// disagree, and adding a channel is one case here plus its source class. `None` is the answer for
	// a group whose payload another path produces (the material group's baked arrays, today).
	enum class ClipmapChannel {
		None,
		// The height channel: `R32F`, one height-map texel a ring texel.
		Height,
		// The material group: the packed `R16` surface payload, one payload texel a ring texel. The
		// group's *baked* arrays are the baker's, so the ring carries the payload they are baked from
		// and the fragment evaluates from it inside the band the ring serves.
		Material,
	};
	ClipmapChannel _clipmap_channel(const TerrainVT::ChannelGroup p_group) const;
	// The whole of what a channel group costs the assembly rule: one arm, naming the source that
	// carries it, and nothing when this build has none. The ring's addressing, budget, strips,
	// invalidation, reporting and the tick are channel-agnostic, so a new channel group is a
	// `Terrain3DClipmapSource` subclass and a case above. Null while the instance has no data, which
	// is a state the assembly rule retries rather than a capability the matrix reads.
	std::unique_ptr<Terrain3DClipmapSource> _make_clipmap_source(const TerrainVT::ChannelGroup p_group) const;
	// Gives the near field's coarse owner back to the shared pool. The two moments it stops being
	// sampled are a deselection and a destruction, and both go through here so neither forgets.
	void _release_avt_coarse_protections();
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
	// The far field's demand pass stages. See the definitions.
	std::vector<Terrain3DSVTPage> _svt_walk_visible_pages(const std::vector<Terrain3DSVTRegion> &p_regions,
			const TerrainVT::VisibleView &p_view, const std::function<bool(const Rect2 &)> &p_avt_interior,
			const Rect2 &p_domain, float p_page_world, int p_plan_limit, int &r_visited);
	void _process_svt_bake(int p_page_budget = -1);
	int _update_visible_svt(int p_max_pages);
	// Pins the far field's root pyramid over `p_domain` and reports the four stages it spent its
	// time in: building the root list, releasing the previous plan's pins, requesting and pinning
	// the new roots (and queueing the ones with no content), and recording what the pinned set
	// covers. `r_produced` is the pass's production count, which the root walk adds its queued
	// pages to; `r_cached` reports whether the previous plan was still valid, which is the case
	// that makes a settled far field free. `p_pass_budget` is how many pages the pass this belongs
	// to may produce: the pyramid is queued under that same bound, so rebuilding it ramps over the
	// passes the page budget allows instead of queueing the whole set in one tick - pinning is free
	// and unconditional, so the plan still settles on the first pass. Split out of
	// `_update_visible_svt()` so that pass reads as the stages it runs - see the definition for
	// what the pyramid is for.
	std::array<double, 4> _svt_plan_roots(const Rect2 &p_domain, int p_maximum_mip, int p_coverage_limit,
			int p_physical_page_count, int p_pass_budget, const std::vector<Terrain3DSVTPage> &p_visible,
			int &r_produced, bool &r_cached);
	// The two fallback policies as strategies, and the one place that chooses between them. See the
	// definitions for what each guarantees and H2 of `docs/vt_reference_avt_alignment.md` for the
	// measurement that decides which is default.
	std::vector<Vector3i> _svt_global_root_pyramid(int p_indirection_size, int p_protected_limit,
			int p_root_top, int p_root_first);
	std::vector<Vector3i> _svt_per_unit_coarsest(const std::vector<Terrain3DSVTPage> &p_visible,
			int p_coarsest_mip, int p_protected_limit);
	std::vector<Vector3i> _svt_fallback_pages(int p_policy, int p_maximum_mip, int p_indirection_size,
			int p_protected_limit, int p_root_top, int p_root_first,
			const std::vector<Terrain3DSVTPage> &p_visible);
	// Whether a published page still has no content: true when the producer does
	// not hold it ready and no production for it is in flight. Demand re-produces such a page
	// instead of treating its indirection entry as a hit. Both views and the service ask this,
	// so it is declared here and defined with the page plumbing it reads.
	bool _vt_page_production_stale(int p_slot);
	// The same question with the producer's answer already known (-1 asks it here), so a
	// verification pass over a whole resident set takes one lock instead of one per page.
	bool _vt_page_production_stale(int p_slot, int p_ready);
	// One page record as the script-facing dictionary `get_vt_pages()` returns. The production path
	// stores records as plain values (`Terrain3DVTState::PageRecord`), so the dictionary a
	// diagnostic reads is built here, on demand, instead of once per produced page.
	Dictionary _vt_page_record_dictionary(const Terrain3DVTState::PageRecord &p_record) const;
	// `get_vt_settings()` is one flat dictionary assembled by owner: each view and the fade write
	// the keys their own fields back, from the file that owns those fields, and
	// `_report_vt_service()` adds the service's half.
	void _report_vt_service(Dictionary &r_result) const;
	void _report_avt(Dictionary &r_result) const;
	void _report_svt(Dictionary &r_result) const;
	void _report_vt_fade(Dictionary &r_result) const;
	// The persisted far-field cell file for one address. A cell file carries its whole mip
	// chain, so there is no per-mip path: mip 0 names the cell. This took a mip parameter it
	// hard-coded to 0, which is a trap for the next caller rather than information.
	String _svt_page_path(const Vector2i &p_address) const;
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
	double _monitor_vt_cpu_seconds() const { return _vt.vt_cpu_ms / 1000.0; }
	double _monitor_vt_peak_seconds() const { return _vt.vt_cpu_peak_ms / 1000.0; }
	double _monitor_avt_cpu_seconds() const { return _vt.vt_avt_ms / 1000.0; }
	double _monitor_svt_cpu_seconds() const { return _vt.vt_svt_ms / 1000.0; }
	// The geometry backend's pass, which the rendering server drives rather than the tick,
	// so it is read from the mesher instead of from the VT state.
	double _monitor_cdlod_cpu_seconds() const;
	int64_t _monitor_material_bytes() const;
	int64_t _monitor_pages_ready() const;
	int64_t _monitor_pages_pending() const;
	// Pages the image being rendered samples with no content. With the motion lead on
	// this is the reading that says whether the view is streaming in.
	int64_t _monitor_pages_late() const { return _vt.avt_cost.late_pages; }
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
	void set_vt_auto_capacity(bool p_enabled) { _vt.vt_auto_capacity = p_enabled; invalidate_avt_plan_key(_vt.avt_plan.key); }
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
	float get_avt_density_scale() const { return _vt.avt_density_scale; }
	// The sample level at which the fallback table takes over: a sample at or above it reads the
	// fallback table directly, one below it is an upgrade and goes through the sector directory for
	// second-level addressing. One home for the number, because the shader's read order and the
	// plan's own classification both derive from it. Distinct from `avt_max_adaptive_level`, which
	// is the fallback grid's own mip boundary rather than a sample level.
	float get_avt_adaptive_threshold_level() const;
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
	// The render-side counterpart of the above: drop one resident page's *content*, so the
	// shader stops resolving it and draws the level behind it, and the demand pass then
	// produces it again. `debug_lose_vt_page_readiness()` only clears the CPU-side readiness,
	// which the demand pass acts on but the shader never sees; this is what a test needs to
	// watch a page actually arrive.
	bool debug_invalidate_vt_page(int p_slot);
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

	// ---- Delivery assembly ---------------------------------------------------------------------
	// Which method carries which channel group in which distance band, and the three service
	// questions the rest of the node asks of it. `TerrainVT::DeliveryMatrix` in
	// terrain_3d_vt_delivery.h holds the four values; the accessors here are what the bindings,
	// the dock, the setters and the passes use, and `set_vt_delivery()` is the one place a
	// change reaches the assembly - it creates the service a newly selected method needs and
	// destroys the one the last cell that used it has left. See docs/vt_delivery_assembly.md.
	void set_vt_delivery(const int p_tier, const int p_group, const int p_delivery);
	int get_vt_delivery(const int p_tier, const int p_group) const;
	void set_vt_delivery_near_material(const int p_delivery);
	int get_vt_delivery_near_material() const { return get_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Material)); }
	void set_vt_delivery_near_height(const int p_delivery);
	int get_vt_delivery_near_height() const { return get_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Height)); }
	void set_vt_delivery_far_material(const int p_delivery);
	int get_vt_delivery_far_material() const { return get_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Material)); }
	void set_vt_delivery_far_height(const int p_delivery);
	int get_vt_delivery_far_height() const { return get_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Height)); }
	// Whether any cell selected the method's service. A service object is created iff its question
	// is true and destroyed when the last cell that selected it changes away, so this - not a
	// group's own delivery - is what a pass, a pool reservation and the tick test.
	bool has_avt_delivery() const { return _vt.delivery.uses(TerrainVT::Delivery::AVT); }
	bool has_svt_delivery() const { return _vt.delivery.uses(TerrainVT::Delivery::SVT); }
	// Whether any cell selected the clipmap. This is the matrix's answer; `has_vt_clipmap_layer()` is
	// the question about the object, and the two differ for a layer `debug_update_vt_clipmap()` built
	// to measure the mechanism with no cell naming the method.
	bool has_clipmap_delivery() const { return _vt.delivery.uses(TerrainVT::Delivery::Clipmap); }
	// The same question by property value, which is the form a debug view asks it in: a
	// method no cell selects has no layout to draw, so its view hides itself instead of polling a
	// scan of an empty service. An out-of-range value is false rather than a clamp, mirroring
	// `TerrainVT::is_valid_delivery()`.
	bool is_vt_delivery_used(const int p_method) const {
		return TerrainVT::is_valid_delivery(p_method) && _vt.delivery.uses(TerrainVT::Delivery(p_method));
	}
	// Whether this build can *deliver* a method for a channel group, which is what the matrix's
	// acceptance is decided from: a cell may only name a method that reaches a fragment here. A
	// method this build has no arm for is refused rather than accepted and rendered from somewhere
	// else, because "selected, but nothing samples it" is a configuration nobody can tell from a
	// broken one. The matrix is deliberately asymmetric: the material group's methods are AVT, SVT
	// and (M4) Clipmap, while the height group's choices are `Direct` and the clipmap ring alone -
	// AVT and SVT page the material group and are not height's methods at all. The tier does not
	// enter, because the two bands select reach rather than capability. `Direct` is always
	// deliverable, being the fallback and the one method that is always correct. See
	// docs/vt_delivery_assembly.md, "What a cell may name".
	bool is_vt_delivery_supported(const int p_group, const int p_method) const;
	// Whether a channel group has a clipmap source in this build - which is the same question as
	// "may a cell of this group name `Clipmap`", because the matrix's acceptance is read from here
	// rather than from a table of its own. `_clipmap_channel()` is the registry, so "which source" and
	// "is there one" cannot disagree: the day a group has a source its cells become writable
	// everywhere at once (the dock's rows, both previews, the report and the setter), and until then
	// the refusal names the group. It is a question about the *build* and not about an instance, so a
	// cell is accepted - and a scene's stored cell kept - before a data resource exists.
	bool has_clipmap_source(const int p_group) const;
	// Whether a group is delivered by the clipmap in either band, which is exactly the condition the
	// generated shader carries that group's arm under: a group that is `Direct` in both bands
	// compiles no clipmap code, binds no clipmap uniform and tests no branch, so a method nobody
	// selected costs the Direct path nothing. Which *implementation*'s tables the arm binds is the
	// layer's own answer (`vt_clipmap_implementation`), not a second gate.
	bool clipmap_arm_used(const TerrainVT::ChannelGroup p_group) const {
		return _vt.delivery.group_uses(p_group, TerrainVT::Delivery::Clipmap);
	}
	// Why the pair above is refused, in the sentence the setter logs, a panel shows and a test pins.
	// Empty for a pair that is supported.
	String get_vt_delivery_unsupported_reason(const int p_group, const int p_method) const;
	// Whether the layer assembles any service at all. False is the all-direct configuration - the
	// one that must own no view, no array family, no VT uniform, no VT shader arm and no tick.
	bool has_vt_delivery() const { return _vt.delivery.any_service(); }
	// Whether a channel group is delivered by a service in either band. This is the *family*
	// question: the material arrays are not published for a tier whose only user is the height
	// group, and the region arrays stay authoritative for a group no service carries.
	bool group_has_vt_delivery(const TerrainVT::ChannelGroup p_group) const {
		return _vt.delivery.group_uses(p_group, TerrainVT::Delivery::AVT) ||
				_vt.delivery.group_uses(p_group, TerrainVT::Delivery::Clipmap) ||
				_vt.delivery.group_uses(p_group, TerrainVT::Delivery::SVT);
	}

	// ---- Clipmap: the layer's settings and its readings -----------------------------------------
	// One layer per channel group, built by the assembly rule the first time a cell selects Clipmap
	// and kept afterwards, exactly like the two views. Unit l covers `base_world * 2^l` metres in
	// `size` texels, so its texel is `base_world * 2^l / size` metres wide - the shared ladder both
	// implementations address by.
	void set_vt_clipmap_size(const int p_size);
	int get_vt_clipmap_size() const { return _vt.clipmap_size; }
	void set_vt_clipmap_levels(const int p_levels);
	int get_vt_clipmap_levels() const { return _vt.clipmap_units; }
	void set_vt_clipmap_base_world(const real_t p_metres);
	real_t get_vt_clipmap_base_world() const { return _vt.clipmap_base_world; }
	// **The implementation selector**, and the whole of what used to be a second delivery: `LOD` is
	// the toroidal level ring, `Atlas` the block atlas. A write here re-resolves the assembly, so the
	// switch takes effect on the next resolve and the next tick - the storage is replaced, not added.
	void set_vt_clipmap_implementation(const int p_implementation);
	int get_vt_clipmap_implementation() const { return int(_vt.clipmap_implementation); }
	// What one layer may produce in one tick, in channel texels. The clipmap does not touch the shared
	// page pool, so this is spent beside `vt_pages_per_update` rather than out of it.
	void set_vt_clipmap_budget_texels(const int p_texels);
	int get_vt_clipmap_budget_texels() const { return _vt.clipmap_budget_texels; }
	// The Atlas implementation's own settings. They are *layer* settings - the LOD implementation
	// simply does not use them - so they are named after the layer rather than after a mode:
	// `global_texels` is the one-time minimal-resolution block outside the atlas grid, and
	// `blocks_per_frame` its per-frame production bound, one being "a frame loads one block". How many
	// rings the grid holds is the layer's own `vt_clipmap_levels`.
	void set_vt_clipmap_global_texels(const int p_texels);
	int get_vt_clipmap_global_texels() const { return _vt.clipmap_atlas_global_texels; }
	void set_vt_clipmap_blocks_per_frame(const int p_blocks);
	int get_vt_clipmap_blocks_per_frame() const { return _vt.clipmap_atlas_blocks_per_frame; }
	// The layer's stored value at a world position, through the layer's own addressing - the same unit
	// rule, snapping and offset the shader arm samples with, whichever implementation is selected.
	// Read by the deterministic tests and the dock, which otherwise have no way to compare what the
	// layer holds against the height map it was produced from. NAN when the group has no layer.
	real_t sample_vt_clipmap(const int p_group, const Vector2 &p_world_xz, const int p_channel = 0) const;
	// The density the layer serves at a world point, in texels a metre: the shared ladder's reciprocal,
	// asked of the *layer* rather than of either storage, so the "density - distance" curve is one
	// reading for both implementations. Zero outside the layer's coverage.
	real_t sample_vt_clipmap_density(const int p_group, const Vector2 &p_world_xz) const;
	// Everything the material's arm is bound from, in one dictionary, so the shader's copy of the
	// layer's addressing and the CPU's are the *same* numbers rather than two implementations that
	// agree until one changes. The selected implementation fills it and `arm["implementation"]` names
	// which, so the binding above it is one path. Empty when the group has no configured layer.
	Dictionary get_vt_clipmap_arm(const int p_group) const;
	// An edit changed the source under a world AABB: the layer re-produces the texels that cover it
	// and stops serving the units that touch it until they have. Called from the one place every edit
	// reports itself to (`Terrain3DData::add_edited_area()`), and public because a script that writes
	// heights through the data API without going through the editor can call it. Returns how many rect
	// jobs were queued; zero when no layer exists or the unit is already being produced.
	int invalidate_vt_clipmap_area(const AABB &p_area);
	// Whether any clipmap layer object exists, which is the layer's own "is this used" question and
	// the gate its debug view and native preview are read with: a layer exists because a cell selected
	// the method (once a build can deliver it) or because `debug_update_vt_clipmap()` built one to
	// measure the mechanism, and it is kept afterwards. False is the state with no layer at all: no
	// units, no texture, no jobs and no budget.
	bool has_vt_clipmap_layer() const;
	// The mechanism's own entry, beside `sample_vt_clipmap()`: build the layer for `p_group` from the
	// clipmap settings if it does not exist - with whichever implementation is selected - run the phase
	// the tick runs for it (the same `update()`, the same focus and the same `vt_clipmap_budget_texels`)
	// and return the channel texels produced, or -1 when no layer can be built for that group. This is
	// the door a reading takes the mechanism through *without* a delivery claim: the addressing, the
	// units and the budget are measurable with every cell `Direct`, which is how `native/tests/vt_clipmap`
	// isolates the mechanism from the arm. It publishes `clipmap_produced_texels` and `vt_clipmap_ms`
	// exactly as the tick's phase does.
	int debug_update_vt_clipmap(const int p_group);
	// The layer's read-only debug payload, in the **one schema** the facade assembles: the shared
	// per-unit entries, the shape, the density/reach curve and the implementation's private payload
	// (`impl`) - so the debug view draws the selected implementation's picture and both of them can be
	// plotted against the same density axis. Empty when no layer exists - the scan is refused rather
	// than drawn empty, the way `get_avt_layout_preview()` refuses - and the two counters in
	// `get_vt_settings()` record the difference between an ask and the work.
	Dictionary get_clipmap_layout_preview() const;
	// Whether any layer's addressing changed since the shader was last bound with it - its shape, any
	// unit's snapped origin or offset, or which units are current - and the rebind that follows. The
	// layer's own stamp is the answer, so a tick that produced nothing rebinds nothing: the
	// alternative, rebinding every tick, would republish the whole VT uniform set (and the region
	// tables with it) for a layer that had not moved. The rebind is the clipmap's own uniforms and not
	// `Terrain3DMaterial::update()`, for the same reason.
	void _update_vt_clipmap_arm();
	bool _vt_clipmap_state_changed();

	// ---- The material group's detail layer ------------------------------------------------------
	// The sparse, demand-resident fine layer that reaches the 1024 texels/m target the coarse ring
	// cannot. It is a *layer on top of* the ring rather than a replacement: the ring keeps its
	// complete coverage and its fallback, and this object only exists while the material group is
	// delivered by `Clipmap` and its switch is on. See
	// `Terrain3DMaterialClipmapDetail` (terrain_3d_material_clipmap_detail.h) for the mechanism.
	void set_vt_detail_enabled(const bool p_enabled);
	bool is_vt_detail_enabled() const { return _vt.detail_enabled; }
	void set_vt_detail_density(const real_t p_texels_per_meter);
	real_t get_vt_detail_density() const { return _vt.detail_density; }
	void set_vt_detail_min_density(const real_t p_texels_per_meter);
	real_t get_vt_detail_min_density() const { return _vt.detail_min_density; }
	void set_vt_detail_tile_size(const int p_texels);
	int get_vt_detail_tile_size() const { return _vt.detail_tile_size; }
	void set_vt_detail_directory_size(const int p_texels);
	int get_vt_detail_directory_size() const { return _vt.detail_directory_size; }
	void set_vt_detail_budget_bytes(const int p_bytes);
	int get_vt_detail_budget_bytes() const { return _vt.detail_budget_bytes; }
	void set_vt_detail_demand_radius(const real_t p_metres);
	real_t get_vt_detail_demand_radius() const { return _vt.detail_demand_radius; }
	void set_vt_detail_texels_per_pixel(const real_t p_texels);
	real_t get_vt_detail_texels_per_pixel() const { return _vt.detail_texels_per_pixel; }
	// Whether a detail object exists. It is built by the assembly rule when the material group
	// selects Clipmap and freed with the node; a deselection stops its tick rather than freeing its
	// content, the rule the rings and the views follow.
	bool has_vt_detail_layer() const { return _vt.material_detail != nullptr; }
	// Everything the detail arm is bound from, or an empty dictionary when the layer is off. Built by
	// the manager, so the shader's directory, window origin and tile span are the CPU's own numbers.
	Dictionary get_vt_detail_arm() const;
	// Whether the detail layer's arm addressing moved since the shader was bound with it: a directory
	// publish, a window move, or a tile becoming readable. One comparison a tick, like the ring's.
	void _update_vt_detail_arm();
	bool _vt_detail_state_changed();
	// The detail layer's own report, for `get_vt_settings()` and the tests: the request (density,
	// budget, radius), the *delivered* state (resident, valid, pending, starved), the byte accounting
	// and the source pipeline's counters. Kept beside the layer rather than in the service report so
	// the two halves of "asked for" and "delivered" are one dictionary.
	Dictionary get_vt_detail_settings() const;
	// The finest level with a readable tile at a world point, and its density in texels per metre
	// (0 / -1 when none). The CPU mirror of the fragment's lookup, so the stage's density acceptance
	// can be asserted without reading a picture.
	int sample_vt_detail_level(const Vector2 &p_world_xz) const;
	real_t sample_vt_detail(const Vector2 &p_world_xz) const;
	// The detail layer's demand pass, run from the clipmap phase's own tick hook. It derives the
	// frame's wanted tiles, hands out slots, primes and polls the source pipeline, and offers landed
	// tiles to the baker. A no-op - no focus read, no scan - while the layer does not exist.
	void _update_vt_material_detail();
	// An edit changed the source under a world AABB: the tiles that cover it stop being readable and
	// are re-produced. Returns how many tiles were invalidated.
	int invalidate_vt_detail_area(const AABB &p_area);
	// Builds the detail layer when the material group selects Clipmap and the switch is on, and
	// clears it when either stops being true. The one owner of the layer's lifetime, called from the
	// assembly rule and from the settings' setters.
	bool _setup_vt_material_detail();

	void set_surface_vt_enabled(const bool p_enabled);
	// A view of the near field's material cell: the AVT carries the diffuse+normal group. It is not
	// a second source of truth - writing it writes that cell - and it is exactly what the material's
	// `_surface_vt_enabled` uniform means, which is why the setter is kept rather than retired.
	bool is_surface_vt_enabled() const { return _vt.delivery.get(TerrainVT::Tier::Near, TerrainVT::ChannelGroup::Material) == TerrainVT::Delivery::AVT; }
	void set_surface_vt_page_count(const int p_count);
	int get_surface_vt_page_count() const { return _vt.surface_vt_page_count; }
	void set_surface_vt_page_size(const int p_size);
	int get_surface_vt_page_size() const { return _vt.surface_vt_page_size; }
	void set_surface_vt_page_border(const int p_border);
	int get_surface_vt_page_border() const { return _vt.surface_vt_page_border; }
	// The near field's requested anisotropy: 0 follows the viewport's filtering level, any other
	// value is the request itself. `get_avt_anisotropy()` is what the shader and the CPU footprint
	// both use - this request clamped by what the page gutter can sample.
	void set_surface_vt_anisotropy(const int p_anisotropy);
	int get_surface_vt_anisotropy() const { return _vt.surface_vt_anisotropy; }
	void set_surface_vt_pages_per_axis(const int p_pages);
	int get_surface_vt_pages_per_axis() const { return _vt.surface_vt_pages_per_axis; }
	void set_surface_vt_texels_per_meter(real_t p_value);
	real_t get_surface_vt_texels_per_meter() const { return _vt.surface_vt_texels_per_meter; }
	void set_surface_svt_texels_per_meter(real_t p_value);
	real_t get_surface_svt_texels_per_meter() const { return _vt.vt_page_size / _vt.surface_svt_page_world; }
	void set_surface_vt_mip_distances(const PackedFloat32Array &p_distances);
	PackedFloat32Array get_surface_vt_mip_distances() const { return _vt.surface_vt_mip_distances; }
	int get_surface_vt_mip_for_distance(real_t p_distance) const;
	int get_avt_base_block_size() const;
	// Sector resolution tier count (default three); local page tables keep complete mip chains.
	int get_avt_mip_levels() const { return _vt.surface_vt_mip_levels; }
	void set_surface_vt_mip_levels(int p_levels);
	int get_avt_mip_level_cap() const;
	// The near field's page budget, in two settings. `default` (16) is the stable rate and the
	// shipped behaviour; `max` is the "over page" the plugin escalates to *by itself* while the
	// camera is moving fast, while the view it is filling is still unserved, or on a discontinuity -
	// a snap turn, a teleport, a displacement cut. The two read as
	// `default <= max <= AVT_PAGE_BATCH_CEILING`. Both are properties, neither reconfigures
	// anything, and a change applies on the next tick. No game code is needed to drive them;
	// `get_vt_settings()` reports the live tier as `avt_batch_max` / `avt_batch_tier` beside the
	// observed `avt_batch_peak`. See `Terrain3DAVTPageBudget`.
	void set_surface_vt_page_batch_default(int p_pages);
	int get_surface_vt_page_batch_default() const { return _vt.avt_page_budget.default_pages; }
	void set_surface_vt_page_batch_max(int p_pages);
	int get_surface_vt_page_batch_max() const { return _vt.avt_page_budget.max_pages; }
	int get_avt_local_block_size() const { return get_avt_base_block_size(); }
	float get_avt_local_section_world() const { return 64.f; }
	// The near field's anisotropy: `..._sampler()` is the tap count the viewport's filtering level
	// gives the material samplers (the terrain cannot raise it), `..._request()` is the setting (or
	// the sampler's level when the setting is zero), and `get_avt_anisotropy()` is the request
	// clamped by both that tap count and the page gutter - the two hard bounds, because a filtering
	// footprint can neither take taps the viewport does not give it nor reach past the border texels
	// a page carries. One home for a rule that used to be spelled at both call sites: the material
	// binds the third and the sector AVT footprint uses it for CPU demand.
	float get_avt_anisotropy_sampler(const Camera3D *p_camera) const;
	float get_avt_anisotropy_request(const Camera3D *p_camera) const;
	float get_avt_anisotropy(const Camera3D *p_camera) const;
	void set_surface_vt_resolution(int p_resolution);
	int get_surface_vt_resolution() const { return _vt.vt_page_size * _vt.surface_vt_pages_per_axis; }
	void set_surface_vt_distance(const real_t p_distance);
	real_t get_surface_vt_distance() const { return _vt.surface_vt_distance; }
	void set_surface_vt_region_grid(const Vector2i &p_grid) { _vt.surface_vt_region_grid = Vector2i(CLAMP(p_grid.x, 1, 64), CLAMP(p_grid.y, 1, 64)); }
	Vector2i get_surface_vt_region_grid() const { return _vt.surface_vt_region_grid; }
	void set_surface_vt_selection_mode(int p_mode);
	int get_surface_vt_selection_mode() const { return _vt.surface_vt_selection_mode; }
	bool is_sector_avt() const { return _vt.surface_vt_selection_mode == 2 && !_vt.vt_debug_direct_material; }
	// Motion look-ahead: smooths the camera's velocity and its turn rate, and returns the transform
	// both demand passes plan for - where the camera will be and where it will be looking, because a
	// turn brings new world into the frustum the way a step does. See
	// Terrain3DVTState::vt_motion_lead_ms and the note on the turn half of the state.
	void _vt_update_motion_lead();
	Transform3D _vt_lead_camera_transform(const Transform3D &p_camera_transform) const;
	Transform3D _vt_plan_key_transform(const Transform3D &p_camera_transform) const;
	RID get_avt_sector_directory() const { return _vt.avt_sector_directory.is_valid() ? _vt.avt_sector_directory->get_rid() : RID(); }
	int get_avt_directory_mask() const { return _vt.avt_directory_mask; }
	Dictionary get_avt_layout_preview(Camera3D *p_camera) const;
	const Terrain3DAVTCoarseImage &get_avt_coarse_image() const { return _vt.avt_coarse; }
	// Page-arrival fade: the per-slot ramp a page comes in over, so a page arriving is a
	// sharpen instead of a rectangular step in the image. The texture is one texel per
	// physical slot, which is what lets the shader index it by the slot the indirection
	// lookup already decoded. The pass that fills it, and the arrival decision it makes, are
	// in terrain_3d_vt_fade.cpp.
	RID get_vt_page_fade_rid() const { return _vt.fade.texture.is_valid() ? _vt.fade.texture->get_rid() : RID(); }
	int get_vt_page_fade_frames() const { return _vt.vt_page_fade_frames; }
	void set_vt_page_fade_frames(int p_frames);
	// Records that a slot's content is missing or still being produced, so the tick it stops
	// waiting - which `_update_vt_page_fade()` decides against the producer - is the tick its fade
	// is *armed*. The ramp does not start there: the pass releases armed slots a few per tick, so
	// that a burst of arrivals sharpens as a wash. Set where content is removed or queued, never by
	// a demand pass.
	void _vt_mark_page_waiting(int p_slot);
	// Turns those records and the producer's readiness into the per-slot ramp the shader reads,
	// on every tick whether or not a demand pass ran. See terrain_3d_vt_fade.cpp.
	void _update_vt_page_fade();
	void _reset_vt_page_fade();
	// Wakes both source pipelines' workers for the work the pass that just ended submitted.
	void _flush_source_wakes();
	// As above, but a no-op while the physics tick is running: the tick releases them itself, after
	// its phases have been measured.
	void _flush_source_wakes_unless_ticking();
	void set_surface_vt_region_offset(const Vector2i &p_offset) { _vt.surface_vt_region_offset = p_offset; }
	Vector2i get_surface_vt_region_offset() const { return _vt.surface_vt_region_offset; }
	void set_surface_vt_forward_regions(real_t p_forward) { _vt.surface_vt_forward_regions = CLAMP(p_forward, -64.f, 64.f); }
	real_t get_surface_vt_forward_regions() const { return _vt.surface_vt_forward_regions; }
	Rect2i get_surface_vt_region_rect() const;
	// Screen texels per pixel of world surface, i.e. how much finer than the pixel footprint the
	// demand asks the near field to be. It scales the density the scan turns into a wanted page
	// size, so raising it buys sharpness at the cost of pages.
	void set_surface_vt_texels_per_pixel(real_t p_value) { _vt.surface_vt_texels_per_pixel = MAX(0.25f, p_value); }
	real_t get_surface_vt_texels_per_pixel() const { return _vt.surface_vt_texels_per_pixel; }
	// Forces every sector to one mip, so a test can ask for a specific level instead
	// of whatever the distance rule picks.
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
	void set_surface_vt_normal_compression(int p_mode);
	int get_surface_vt_normal_compression() const;
	void set_surface_svt_normal_compression(int p_mode);
	int get_surface_svt_normal_compression() const;
	// The near field's setting, under the name it had while compression was one switch.
	void set_vt_atlas_compression(const int p_compression);
	int get_vt_atlas_compression() const;
	Dictionary probe_vt_atlas_compression(const Ref<Image> &p_image) const;
	int get_surface_vt_mip() const { return _vt.surface_vt_mip; }
	void set_surface_vt_feedback_enabled(const bool p_enabled);
	bool is_surface_vt_feedback_enabled() const { return _vt.surface_vt_feedback_enabled; }
	// The demand-source seam: whether the projection pass may run at all, and which source answers
	// this frame. Two questions, one owner - see `TerrainVTPageDemandSource` in terrain_3d_vt_state.h
	// for why a single flag could not express both.
	bool _vt_projection_demand_enabled() const { return _vt.surface_vt_feedback_enabled; }
	TerrainVTPageDemandSource _vt_demand_source() const;
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
	// A view of the far field's material cell, the far-tier counterpart of
	// `is_surface_vt_enabled()`.
	bool is_surface_svt_enabled() const { return _vt.delivery.get(TerrainVT::Tier::Far, TerrainVT::ChannelGroup::Material) == TerrainVT::Delivery::SVT; }
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
	void set_surface_svt_fallback_policy(const int p_policy);
	int get_surface_svt_fallback_policy() const { return _vt.surface_svt_fallback_policy; }
	void set_surface_svt_mip_distances(const PackedFloat32Array &p_distances);
	PackedFloat32Array get_surface_svt_mip_distances() const { return _vt.surface_svt_mip_distances; }
	int get_surface_svt_mip_distance_count() const { return int(_vt.surface_svt_mip_distances.size()); }
	// The far field's level rule, built from the live settings, and the published cap it resolves
	// against when a caller does not name one. `TerrainVT::MipRule` in terrain_vt.h is the rule
	// itself; these two are the only parts of it that need the node. See the definitions.
	TerrainVT::MipRule _svt_mip_rule() const;
	int _svt_mip_rule_cap(int p_max_mip) const;
	// Largest distance the table (or the automatic rule) still serves with a page.
	real_t get_surface_svt_mip_reach() const;
	void set_surface_array_enabled(const bool p_enabled);
	bool is_surface_array_enabled() const { return _vt.surface_array_enabled; }
	// Whether the array still has to carry the surface channel. It must, whenever no
	// service delivers the diffuse/normal group: with the group direct the array is its only
	// source, and a blank array would render every texel as material 0.
	bool is_surface_array_upload_needed() const {
		return is_vt_editor_preview_active() || _vt.surface_array_enabled ||
				!group_has_vt_delivery(TerrainVT::ChannelGroup::Material) ||
				// A material group the ring carries still has fragments its baked layers cannot
				// answer - outside the band, and every rect the CPU side is producing or the bake
				// has not covered - and those fall back to the payload evaluation, whose control
				// texel is the region array. Stopping the array upload for a group only the paged
				// tiers carry would be correct; doing it for the ring would render material 0 for
				// every fallback fragment.
				clipmap_arm_used(TerrainVT::ChannelGroup::Material);
	}
	// Whether the generated shader carries a virtual-texture arm at all. A group that a service
	// does not carry is sampled from the region arrays, and that arm contributes no code, no
	// uniform and no sampler - so this is the single input to the material's variant choice and it
	// must name every group that has an arm. It is the union over the groups, so an all-`Direct`
	// matrix stays the no-VT build and a configuration with one arm still compiles the arm it asked
	// for.
	bool needs_vt_shader_arms() const {
		for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
			if (group_has_vt_delivery(TerrainVT::ChannelGroup(group))) {
				return true;
			}
		}
		return false;
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

#endif // TERRAIN3D_CLASS_H
