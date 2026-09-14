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
	// Atlas compression for the three material page arrays, as a
	// Terrain3DAssets::TextureArrayCompression value. Resolved and validated by the
	// surface baker, which reports what was applied and why a request was refused.
	int vt_atlas_compression = 0;
	bool surface_vt_coarse_mip_fallback = false;
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
	// cover the visible world, as (mip 0 page x, mip 0 page y, level). Rebuilt every
	// demand pass, because a root that leaves the visible set must lose its pin.
	std::vector<Vector3i> svt_root_pages;
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
};

#endif // TERRAIN3D_VT_STATE_H
