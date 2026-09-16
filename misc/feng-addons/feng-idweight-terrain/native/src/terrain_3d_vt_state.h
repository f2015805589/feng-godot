// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_STATE_H
#define TERRAIN3D_VT_STATE_H

// Every virtual texture field Terrain3D owns, in one struct.
//
// The node's own state (regions, mesh, ocean, CDLOD, targets) stays in terrain_3d.h;
// this is the shared VT service, the near-field AVT and the far-field SVT together,
// so "what does the VT layer remember" is one greppable unit instead of a hundred
// fields interleaved with the renderer's. No algorithm lives here, and no field reads
// another during construction, so the struct is a plain aggregate.

#include <map>
#include <memory>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "terrain_3d_avt.h"
#include "terrain_3d_page_pipeline.h"
#include "terrain_3d_vt_cells.h"

class Terrain3DVirtualTexture;
class Terrain3DVTFeedback;

struct Terrain3DVTState {
	// One surface service owns the settings and GPU material cache. AVT and SVT
	// below are addressing/producer views over its shared physical residency pool.
	int vt_page_size = 256;
	int vt_page_border = 4;
	int vt_page_count = 256;
	// Physical capacity already published to both views. Auto capacity raises it above the
	// setting, and a later reconfiguration (page size, border, resolution) starts from this
	// value instead of the setting, so a rebuild cannot shrink the pool and then ask the
	// demand pass to grow it straight back, which would release every resident page twice.
	int vt_effective_page_count = 256;
	// Frame the demand pass first skipped production to wait for a requested capacity. The
	// wait is bounded: the pool cannot be resized in place, so growing it releases whatever
	// is resident, and producing pages against the old count only spends the bake budget on
	// content the growth throws away. UINT64_MAX means no wait is in flight.
	uint64_t vt_capacity_wait_start = UINT64_MAX;
	bool vt_auto_capacity = true;
	int vt_pages_per_update = 16;
	bool vt_adaptive_enabled = true;
	// Storage format of the near field's material page arrays, as a
	// Terrain3DAssets::TextureArrayCompression value (1 = BC7). Resolved and validated by the
	// surface baker, which reports what was applied and why a request was refused, and
	// encoded on the GPU by the block encoder, so compressing a page costs this thread
	// nothing. The far field has its own setting below: the two tiers produce the same pool
	// but at very different rates, and a codec worth its encode for a page that is written
	// once is not necessarily worth it for a page every edit rewrites.
	int surface_vt_compression = 0;
	// Storage format of the far field's material page arrays. A far-field page is assembled
	// once from a baked cell and never rewritten, so its compressed copy is final: this is
	// the tier where a codec buys the most memory for the least work.
	int surface_svt_compression = 0;
	// Substitutions for a page that is missing or still in production. Both default on: a
	// miss recovers from a resident coarser level instead of rendering the diagnostic,
	// which is what a shipped view wants while pages are still arriving. Turning one off
	// restores the strict residency contract for that field, where a missing page stays
	// visible as the diagnostic - the only rendering a caller can tell apart from real
	// material.
	bool avt_feedback = true;
	// Far field: allow a miss at the level the distance rule selected to be served by a
	// coarser resident level instead of the diagnostic. Off restores the strict walk.
	bool svt_feedback = true;
	bool vt_debug_direct_material = false;
	bool vt_editor_preview = true;
	Dictionary vt_editor_dirty_regions;
	uint64_t vt_service_frame = UINT64_MAX;
	bool vt_shared_ready = false;
	// Bumped every time the service builds a new page pool. The pool cannot be resized in
	// place, so a rebuild releases every resident page: a change that does not invalidate
	// page content must leave this counter alone, and a test asserts exactly that.
	int vt_pool_generation = 0;
	bool vt_materials_dirty = true;
	bool vt_callback_registered = false;
	// Warn once when the engine build has no virtual texture update callback: without it the
	// material page producer never runs, and every page-dependent test would fail with no
	// explanation.
	bool vt_callback_missing_warned = false;
	Ref<RefCounted> vt_baker;
	std::unique_ptr<Terrain3DPagePipeline> vt_page_pipeline, svt_page_pipeline;
	std::map<int, Terrain3DPagePipeline::Request> svt_pending_pages;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> vt_source_snapshot;
	Dictionary vt_page_records;
	Dictionary vt_registered_sectors;
	PackedFloat32Array surface_vt_block_sizes;
	RID vt_bound_albedo;
	// Generation of the page-array bundle the material is currently bound to. Both tiers'
	// arrays are replaced together, so the near field's albedo alone does not identify the
	// set: a change to the far field's arrays has to rebound the material too.
	uint64_t vt_bound_generation = 0;
	uint64_t vt_source_revision = 1;
	Dictionary vt_svt_tiles;
	Ref<RefCounted> svt_cell_baker;
	// Resident cell sources of the far field. A cell baked in this session (or imported)
	// lives here, and page assembly then copies it on the GPU instead of re-reading a bake
	// file or re-evaluating the material per page. See terrain_3d_vt_cells.h.
	Ref<Terrain3DCellStore> svt_cells;
	// Per-cell probe of the persisted bake, remembered so the render path never stats the
	// same file twice (1 = present, 2 = absent).
	std::unordered_map<int64_t, uint8_t> svt_cell_file_probe;
	// Edit stamp per far-field cell. A resident cell is only reused while its stamp is at
	// least the newest edit that touched it or one of its eight neighbours, because a page
	// border reads them.
	std::unordered_map<int64_t, uint64_t> svt_cell_edit_stamp;
	uint64_t svt_edit_counter = 0;
	Dictionary svt_cell_job;
	uint64_t svt_cells_baked = 0;
	bool svt_auto_bake = true;
	Dictionary vt_svt_dirty_regions;
	uint64_t vt_svt_edit_time = 0;
	bool vt_svt_bake_incremental = false;
	uint64_t vt_svt_bake_generation = 0;
	Array vt_svt_bake_queue;
	Dictionary vt_svt_bake_waiting;
	// An explicit bake_svt() job is queued or still baking its last cell. Automatic jobs wait
	// for it: one that starts a frame earlier replaces the job-scoped progress counters the
	// dock and the tests read as "this bake completed".
	bool vt_svt_explicit_bake = false;
	int vt_svt_bake_total = 0;
	int vt_svt_bake_done = 0;
	uint32_t vt_material_signature = 0;
	bool vt_svt_catalog_loaded = false;
	int vt_svt_bake_failed = 0;
	String vt_svt_bake_error;

	// Surface virtual texture: the near field's surface pages, produced from the
	// region surface maps. On by default since AVT, SVT and CDLOD became the shipped
	// defaults; the array path still serves every texel no page covers.
	Terrain3DVirtualTexture *surface_vt = nullptr;
	bool surface_vt_enabled = true;
	// The near field's working set is roughly 50 pages at density 4 (a 512 m radius
	// with the distance rule), so 64 left no headroom for the LRU.
	int surface_vt_page_count = 128;
	int surface_vt_page_size = 256;
	int surface_vt_page_border = 4;
	int surface_vt_pages_per_axis = 4;
	real_t surface_vt_distance = 512.f;
	Vector2i surface_vt_region_grid = Vector2i(2, 2);
	int surface_vt_selection_mode = 2;
	Ref<ImageTexture> avt_sector_directory;
	PackedByteArray avt_directory_bytes;
	int avt_directory_mask = 0;
	int avt_root_level = 1;
	Dictionary avt_sector_stats;
	uint64_t avt_plan_epoch = 0;
	float avt_plan_logical_ratio = 0.f;
	std::shared_ptr<Terrain3DAVTRefinement> avt_refinement;
	std::vector<Terrain3DAVTPageRequest> avt_page_plan;
	std::vector<Terrain3DAVTPageRequest> avt_prefetch_plan;
	// Length of the sampled prefix of `avt_page_plan`. Everything after it is the
	// speculative apron, which is allowed to lag without the view showing a miss.
	int avt_sampled_pages = 0;
	// Source threads that assemble pages. 0 selects a machine derived default; see
	// Terrain3DPagePipeline. One thread cannot feed a moving view.
	int vt_page_workers = 0;
	// Motion look-ahead: the planner plans for where the camera will be in
	// `vt_motion_lead_ms`, not for where it is. A page takes several frames to
	// assemble and a compressed page several more to encode and read back, so demand
	// issued at the moment a page becomes visible can only ever be late. The velocity
	// is exponentially smoothed and the lead is clamped by the near field's reach, so
	// a stop or a reversal does not leave the plan pointing at a stale position.
	real_t vt_motion_lead_ms = 250.f;
	Vector2 avt_motion_velocity;
	uint64_t avt_motion_stamp_us = 0;
	Vector2 avt_motion_last_focus;
	bool avt_motion_valid = false;
	// Lead actually applied to the last submitted plan, for diagnostics and tests.
	Vector2 avt_motion_lead;
	// How long a page has been demanded without content, keyed by its address. With a
	// lead the plan is predictive, so a page it names is not late yet - only a page that
	// has been demanded for at least one lead and still has no content is what the image
	// being rendered shows as a miss. Entries are dropped as pages become ready, so this
	// only ever holds the pages currently in flight.
	std::unordered_map<uint64_t, uint64_t> avt_demand_age;
	int avt_late_pages = 0;
	int avt_late_worst_us = 0;
	// Pages of the sampled prefix that have no content this pass, and of those, the ones
	// whose production is still inside its window. Kept as state and not only as a stat:
	// the editor has to keep rendering while a page is still owed, and a demand waiting on
	// a source job or a free slot has no render work of its own to report.
	int avt_missing_pages = 0;
	int avt_pending_pages = 0;
	// Plans kept while the lead is applied, so retention does not drop the view being
	// rendered before the plan that replaces it has been produced.
	int avt_retain_epochs = 8;
	// Requests kept from the previous plan because they are still on screen behind the
	// lead. The pool capacity request counts them, so a look-ahead plan cannot grow the
	// pool exactly large enough to evict the view it is leading.
	int avt_retained_pages = 0;
	PackedByteArray avt_plan_key;
	uint64_t avt_idle_revision = 0;
	std::vector<int> avt_resident_slots;
	size_t avt_prefetch_cursor = 0;
	bool avt_prefetch_cycle_pending = false;
	std::vector<Vector2i> avt_registered_owners;
	std::unordered_map<uint64_t, int> avt_allocated_sizes;
	std::unordered_map<uint64_t, Terrain3DAVTCachedAddress> avt_cached_addresses;
	mutable bool vt_view_focus_valid = false;
	mutable Vector2i vt_view_focus;
	Vector2i surface_vt_region_offset;
	real_t surface_vt_forward_regions = 0.f;
	real_t surface_vt_texels_per_pixel = 1.f;
	real_t surface_vt_texels_per_meter = 1024.f;
	PackedFloat32Array surface_vt_mip_distances; // Legacy serialized array.
	bool surface_vt_distance_mips = false;
	Vector3 surface_vt_mip_ranges = Vector3(8, 16, 32);
	bool surface_vt_force_mip = false;
	int surface_vt_mip = 0;
	// Layer slot -> virtual page block origin, or (-1, -1). Indexed by the same slot
	// the chunk directory returns, so the shader needs no separate sector lookup.
	PackedVector2Array surface_vt_blocks;
	bool surface_vt_blocks_dirty = false;
	// GPU page demand. When enabled it replaces the distance rule: the compute pass
	// knows the field of view, the resolution and the view direction, and it culls.
	Terrain3DVTFeedback *surface_vt_feedback = nullptr;
	bool surface_vt_feedback_enabled = false;
	int surface_vt_feedback_interval = 4;
	int surface_vt_feedback_tick = 0;
	int surface_vt_feedback_grid_chunks = 8;
	// A page whose screen extent falls below this is not requested at all: it would
	// be a sub-pixel speck in the atlas.
	real_t surface_vt_feedback_min_extent = 8.f;
	Vector2i surface_vt_feedback_origin;

	// Far field (sparse virtual texture). A world-space page grid at a coarser texel
	// density, so the surface channel does not have to keep every region's payload
	// resident: a page spans several regions and its mip chain is world-space, which is
	// what the region-aligned near field above cannot express. On by default; the
	// region texture array still serves whenever no page covers a texel.
	Terrain3DVirtualTexture *surface_svt = nullptr;
	bool surface_svt_enabled = true;
	// One mip 0 page covers this many metres.
	real_t surface_svt_page_world = 256.f;
	int surface_svt_page_size = 256;
	int surface_svt_page_border = 4;
	int surface_svt_page_count = 256;
	// -1 means auto: the coarsest level the world grid can publish.
	int surface_svt_max_mip = -1;
	// How far from the clipmap target the far field is kept resident, in metres.
	real_t surface_svt_distance = 6144.f;
	// Coarsest levels of the world grid that are always resident. This root pyramid is
	// what lets the shader resolve any world position without the region texture array,
	// so it is the far field's fallback rather than a separate fallback page.
	int surface_svt_root_mips = 2;
	int vt_svt_visible_pages = 0;
	// Far-field roots this pass keeps resident and protected: the coarsest levels that
	// cover the visible far field, as (mip 0 page x, mip 0 page y, level). The set is a
	// function of the covered rect, the level window and the pool, so it is planned once
	// per identity and then reused: the pyramid is baked static content, and re-requesting
	// a page that is already pinned and protected buys nothing.
	std::vector<Vector3i> svt_root_pages;
	// Identity of the plan above (domain, level window, pool, pool generation, source
	// revision), and whether the last walk pinned every root it planned. A matching key on
	// a settled plan lets the demand pass skip the root walk entirely, which is what keeps
	// a baked far field at zero main-thread cost while the view is still.
	uint64_t svt_root_key = 0;
	bool svt_roots_settled = false;
	// Startup gate for the diagnostic shader. The far field uses the live source material
	// until every protected root has sampled content, then switches atomically to strict SVT.
	bool svt_startup_ready = false;
	// Root walks that ran, and passes that reused the plan instead. Diagnostics and tests.
	uint64_t svt_root_passes = 0;
	uint64_t svt_root_skips = 0;
	// World rect the last planned root set covers, and the level window it used. The
	// fallback is only useful where its roots are, so coverage is what a test asserts:
	// a world-sized candidate set truncated by the pin budget used to leave every root in
	// one corner of the map.
	Rect2 svt_root_coverage;
	int svt_root_level_min = -1;
	int svt_root_level_max = -1;
	// Pages re-produced because the table named them but the producer had no content for
	// them. A value that keeps growing in a settled view is a production that never lands.
	uint64_t svt_requeues = 0;
	// The coarseness floor the last over-subscribed pass raised its detail pages to, or
	// 0 when the distance-selected set fit. Diagnostics and tests only.
	int svt_floor_level = 0;
	// Distance -> level table for the far field, in metres. Entry m is the largest
	// camera distance at which world mip m is sampled, so the table states the level
	// bands explicitly instead of deriving them from the page size. Empty keeps the
	// automatic rule (one level per doubling of surface_svt_page_world).
	//
	// Both the page producer and the shader resolve a level through this one table, so
	// a page is always produced at exactly the level the shader samples, and the
	// rendered level is a pure function of distance: it cannot change when the working
	// set, the pool pressure or the visible region set changes underneath it.
	PackedFloat32Array surface_svt_mip_distances;
	Vector3i surface_svt_scan_key = Vector3i(INT32_MAX, INT32_MAX, INT32_MAX);
	int64_t surface_svt_root_cursor = 0;
	int64_t surface_svt_detail_cursor = 0;
	// Whether the surface channel is uploaded to the region texture array. Off means
	// the virtual textures serve every surface read, which is what removes the
	// density-squared array cost; the array stays allocated but blank.
	bool surface_array_enabled = true;
	// Main-thread cost of one VT section of the physics tick, in milliseconds, and the
	// worst frame since the terrain was created. `svt_cpu_ms` is the far-field demand
	// pass inside that section, so a peak can be attributed to one of the two views.
	double vt_cpu_ms = 0.0;
	double vt_cpu_peak_ms = 0.0;
	double svt_cpu_ms = 0.0;
	// Phase breakdown of the same section: the shared-service check, the near-field
	// demand pass, the far-field demand pass, the near-field production top-up, and the
	// far-field bake.
	double vt_service_ms = 0.0;
	double vt_avt_ms = 0.0;
	double vt_svt_ms = 0.0;
	double vt_topup_ms = 0.0;
	double vt_bake_ms = 0.0;
	// Worst frame for each demand pass since the terrain was created, so a peak in
	// `vt_cpu_peak_ms` can be attributed to one view without a profiler.
	double vt_avt_peak_ms = 0.0;
	double vt_svt_peak_ms = 0.0;
	// Automatic-tick CPU budget for the whole VT section, in milliseconds. 0 disables it.
	// An explicit update_surface_vt()/update_surface_svt() call is never budgeted: the page
	// count it passes is the caller's own bound.
	// Default 0: the per-frame deadline is off, so a tick runs to completion. A deadline
	// starves the AVT planner rather than smoothing it - one full plan costs several
	// milliseconds, so a 0.1 ms budget spreads a single plan over dozens of frames, which
	// delays the first pages by seconds and leaves a moving view rendering the
	// missing-page diagnostic the whole time. Raise it to opt into the spread-out tick.
	real_t vt_frame_budget_ms = 0.0f;
	// Absolute deadline of the tick that is running, or 0 when the caller is not the
	// physics tick. Every phase that can stop between two units of work reads it.
	uint64_t vt_tick_deadline_us = 0;
	// Staged near-field planner: which phase of the scan -> plan chain runs next, and the
	// intermediate data the later phases need. One automatic tick runs at most the phases
	// that fit in its budget, so a camera that changes its view every tick cannot put the
	// whole chain into one frame.
	int avt_plan_stage = 0;
	Terrain3DAVTSectorScan avt_pending_scan;
	Terrain3DAVTHierarchy avt_pending_hierarchy;
	// Set while a plan is being assembled for a key the standing plan does not cover.
	bool avt_plan_staging = false;
};

#endif // TERRAIN3D_VT_STATE_H
