// Copyright 漏 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_STATE_H
#define TERRAIN3D_VT_STATE_H

// Every virtual texture field Terrain3D owns, in one struct.
//
// The node's own state (regions, mesh, ocean, CDLOD, targets) stays in terrain_3d.h;
// this is the shared VT service, the near-field AVT and the far-field SVT together,
// so "what does the VT layer remember" is one greppable unit instead of a hundred
// fields interleaved with the renderer's. No algorithm lives here, and no field reads
// another during construction, so the struct is a plain aggregate.
//
// The fields are grouped in the order a reader meets them, and each group has a banner:
//
//   1. the shared service   - settings, pool identity and producer handles both views read
//   2. the near field (AVT) - its settings, plan, working set, motion lead and arrival fade
//   3. the far field (SVT)  - its settings, root pyramid, cell sources and bake bookkeeping
//   4. cost and diagnostics - per-phase timings, the stage sums, the counter sets
//   5. planner scratch      - capacity owned here so a tick does not reallocate it
//
// The groups follow the work: a field sits with the view that spends it. Four settings are the
// exception and live in the service group because both views read them or the baker resolves them
// once for both tiers - the two compression modes, the source worker count and whether the region
// texture array is uploaded - so a reader looking for a setting should start there.
//
// The fields below that are *one fact* and have to move together. Reading them as independent
// values is how several of them have been broken already:
//
//   * `vt_slot_fade_ticks` and `vt_slot_pending` are the same length by construction: a slot index
//     past them has to grow both, and growing one alone writes past the end of the other. That is
//     not a diagnostic but an out-of-bounds write into the buffer behind it, and it took three
//     suites down with no output before it was found. They are resized together in exactly two
//     places, both in terrain_3d_vt_fade.cpp, which is the only file that touches them.
//   * `vt_page_fade_image` and `vt_page_fade_texture` are rebuilt whenever
//     `vt_slot_fade_ticks.size()` stops matching the pool's page count, and the counters are
//     carried into the fresh texture: a slot keeps its index, so reinitializing them would finish
//     an arrival that is mid-ramp as a step.
//   * the standing plan is `avt_plan_key` (the key it was planned for - deliberately left stale
//     while the refresh interval holds a change), `avt_page_plan` with `avt_sampled_pages`, and
//     `avt_prefetch_plan`. Replacing it must clear `avt_retain_applied` and
//     `avt_retain_with_prefetch`: retention is one set operation over the whole plan, so a stale
//     "already retained" flag leaves the source queue holding work the new plan does not name.
//   * the settled shortcut is `avt_plan_reused` (the caller's verdict that the standing plan is
//     this tick's), `avt_idle_revision` (the pool *residency revision* an idle pass verified, 0
//     when none did), `avt_resident_slots` (the set it verified) and `avt_idle_stats_current` (the
//     dictionary already describes this idle run). The shortcut needs all four: a reused plan, the
//     same residency, a set the producer still holds every page of, and - only for publishing the
//     constants once. Falling through clears the last three, so the set is rebuilt by whichever
//     pass next ends with nothing produced, nothing missing and nothing pending.
//   * the pool is `vt_effective_page_count` (the capacity actually published, which a rebuild
//     starts from rather than from the setting, so a rebuild cannot shrink and then regrow),
//     `vt_pool_generation` (bumped by every rebuild, which is what tells a consumer the residency
//     it was holding is gone) and `vt_capacity_wait_start` (UINT64_MAX when no wait is in flight).
//   * the bound material is `vt_bound_generation` together with `vt_bound_albedo`: both tiers'
//     arrays are replaced as one bundle, so the near field's albedo alone does not identify the set.
//   * a far-field bake is serialized by `vt_svt_explicit_bake` with `vt_svt_bake_total` /
//     `vt_svt_bake_done`: an automatic job must not start while an explicit one is in flight, or
//     the job-scoped counters the dock and the tests read as "this bake completed" are replaced.
//   * the far field's root plan is `svt_root_key` + `svt_root_pages` + `svt_roots_settled` (did the
//     last walk pin everything it planned) + `svt_root_coverage` and `svt_root_level_min/max` (what
//     it covers). A key that still matches while a walk was incomplete is a plan that never pinned,
//     which is the failure the "settled" flag exists to prevent.

#include <map>
#include <memory>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/image.hpp>
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
#include "terrain_vt_arrival_queue.h"
#include "terrain_3d_vt_cells.h"

class Terrain3DVirtualTexture;
class Terrain3DVTFeedback;

// What a physical slot's arrival state is, per slot, in `vt_slot_pending`. Three states rather than
// a bool because the pass holds an arrival back between the tick its content lands and the tick its
// ramp is released, and a slot in between is neither waiting nor settled: it is showing the level
// its page replaces. See that field's note and terrain_3d_vt_fade.cpp.
enum class PageArrival : uint8_t {
	SETTLED = 0,
	WAITING = 1,
	ARMED = 2,
};

struct Terrain3DVTState {
	// ---- 1. the shared service: one surface service owns the settings and the GPU material cache;
	// AVT and SVT below are addressing/producer views over its shared physical residency pool. ----
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
	// Source threads that assemble pages for both views. 0 selects a machine derived default; see
	// Terrain3DPagePipeline. One thread cannot feed a moving view.
	int vt_page_workers = 0;
	bool vt_adaptive_enabled = true;
	// Storage format of the near field's material page arrays, as a
	// SurfacePageCompression value (0 = raw, 1 = BC7, 2 = BC3). Resolved and validated by the
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

	// ---- 2. the near field (AVT): surface pages produced from the region surface maps. On by
	// default since AVT, SVT and CDLOD became the shipped defaults; the array path still serves
	// every texel no page covers. ----
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
	// Stage sums for the same pass, so the mean of a stage can be read beside the live value of
	// the last one. The dictionary only ever holds the pass that just ran, and a pass that
	// installed a plan costs several times one that reused it, so a single reading of it says
	// nothing about where a sweep's average went: `report()` prints the cumulative sums and the
	// pass count, and the mean of a sweep is their difference across it.
	double avt_classify_sum_ms = 0.0;
	double avt_retain_sum_ms = 0.0;
	double avt_prime_sum_ms = 0.0;
	double avt_upload_sum_ms = 0.0;
	double avt_refill_sum_ms = 0.0;
	double avt_finish_sum_ms = 0.0;
	uint64_t avt_pass_count = 0;
	// The same accounting for the tick around the pass, so the difference between the two is what
	// a tick that took the idle shortcut costs - the near field's own report only counts the
	// passes that did work, and a settled turn is mostly not those. `reuse_ticks + chain_ticks` is
	// the number of ticks that reached the production pass, so subtracting `avt_pass_count` leaves
	// the ticks it answered as already settled.
	uint64_t avt_sector_ticks = 0;
	uint64_t avt_reuse_ticks = 0;
	uint64_t avt_chain_ticks = 0;
	// Ticks the production pass was not called at all because the pool was waiting for the
	// producer to publish a larger capacity. They are not idle ticks and they are not a pass, so
	// they need their own count or they read as one of the two.
	uint64_t avt_capacity_skip_ticks = 0;
	double avt_key_sum_ms = 0.0;
	double avt_plan_state_sum_ms = 0.0;
	double avt_install_sum_ms = 0.0;
	double avt_chain_sum_ms = 0.0;
	double avt_produce_sum_ms = 0.0;
	// The whole sector update, from its entry to its return, summed on the same clock the tick
	// uses for the phase it reports. The stage sums above describe what the function did; this is
	// what the phase measured, so a difference between them is time the phase spent outside the
	// function rather than inside it.
	double avt_update_sum_ms = 0.0;
	double avt_wrapper_sum_ms = 0.0;
	// The near field's stage timings as of the pass that produced `vt_avt_peak_ms`, and when that
	// was. The live dictionary is overwritten by every pass, so without this the stages of a peak
	// could not be read at all - and the peak is by definition not the last pass.
	Dictionary avt_peak_stats;
	uint64_t avt_peak_stamp_us = 0;
	uint64_t avt_plan_epoch = 0;
	float avt_plan_logical_ratio = 0.f;
	// How many frames apart the plan is re-derived, and the frame the last chain ran on. The plan
	// is re-derived once per interval rather than once per frame; a key that changed inside the
	// interval is left for the next refresh, and the plan key is then left at the value the
	// installed plan was planned for, so the tick that follows still sees the change.
	uint64_t avt_plan_refresh_frames = 1;
	uint64_t avt_last_chain_frame = UINT64_MAX;
	// Ticks a changed plan key was held back for the refresh interval. Diagnostics: what the
	// interval saved, and what it means for how stale the plan a moving view produces from is.
	uint64_t avt_plan_refresh_skips = 0;
	std::shared_ptr<Terrain3DAVTRefinement> avt_refinement;
	std::vector<Terrain3DAVTPageRequest> avt_page_plan;
	std::vector<Terrain3DAVTPageRequest> avt_prefetch_plan;
	// Length of the sampled prefix of `avt_page_plan`. Everything after it is the
	// speculative apron, which is allowed to lag without the view showing a miss.
	int avt_sampled_pages = 0;
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
	// A camera cut invalidates the old-view retention tail at the next plan install.
	bool avt_discard_retained = false;
	// Lead actually applied to the last submitted plan, for diagnostics and tests.
	Vector2 avt_motion_lead;
	// The turn half of the same look-ahead. A camera that turns sweeps new world into the frustum
	// at every distance at once, so a plan that only moves the eye describes the frustum the camera
	// will *have* while looking where it looks now - which is the one thing a turn makes wrong, and
	// is why a turn streams while a straight run does not. What is predicted is the gaze direction,
	// estimated from consecutive forward vectors: roll spins the frustum about the direction it is
	// already looking along and sweeps no new world into it, so it is deliberately not predicted.
	Vector3 avt_motion_turn;
	Vector3 avt_motion_last_forward;
	// Turn lead actually applied to the last submitted plan: an axis and an angle in radians,
	// which is what `_vt_lead_camera_transform()` rotates the predicted basis by.
	Vector3 avt_motion_turn_lead;
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
	Terrain3DAVTPlanKey avt_plan_key = invalid_avt_plan_key();
	// Sampling density belongs to the installed plan, including its capacity LOD.
	float avt_density_scale = 1.f;
	// Set while the pool's residency revision is the one an idle pass verified. An idle pass
	// keeps its verified resident set instead of re-deriving it, so this is what tells the
	// next tick whether that set can still be trusted.
	uint64_t avt_idle_revision = 0;
	// Whether the last plan was installed from cache. A plain member rather than a lookup in
	// the statistics dictionary, which the settled path reads every tick.
	bool avt_plan_reused = false;
	// True while the statistics dictionary already describes the current idle run. The
	// values an idle pass publishes are constants of the settled state, so a run of idle
	// ticks writes them once - the dictionary is String keyed, and republishing the same
	// numbers is the largest thing left on a settled tick.
	bool avt_idle_stats_current = false;
	// Whether the source queue was already retained against the current plan, and whether
	// that retention included the prefetch plan. Retention is a set operation over the
	// whole plan, so a pass that would repeat the previous wanted set repeats 250 map
	// lookups to reach the state the last pass already reached.
	bool avt_retain_applied = false;
	bool avt_retain_with_prefetch = false;
	// Page-arrival fade, in ticks. A page that has just arrived is blended against the level
	// it replaced, so a page arrival is a ramp rather than a step - which is what a fast turn
	// makes obvious, because the view then refines in the rectangular grid its pages are.
	// 0 disables it and costs nothing: the shader then reads a settled page on every fetch.
	int vt_page_fade_frames = 12;
	// Remaining fade ticks per physical slot; 0 means settled. `vt_slot_pending` is that slot's
	// arrival state: `PageArrival::SETTLED`, `WAITING` for content, or `ARMED` once the content has
	// landed and before its ramp is released. A slot that leaves `WAITING` is one whose content
	// landed. The pass releases all armed slots in the same tick, keeping a completed
	// batch on one fade clock instead of delaying ready neighbouring pages. The first
	// published fade is zero, so it still shows the parent rather than a detail step. The pass
	// decides all of this on every tick from these two vectors, so an arrival is seen whether or not
	// a demand pass ran.
	std::vector<uint8_t> vt_slot_fade_ticks;
	std::vector<PageArrival> vt_slot_pending;
	// The armed slots in the order they landed. The queue owns one node per physical slot, removes
	// a previous node when a slot is re-used, and is therefore bounded by the pool rather than by
	// the number of historical arrivals. A release pops from its head, so there is no consumed
	// prefix or per-tick cursor to retain.
	TerrainVT::PageArrivalQueue vt_page_fade_queue;
	// Set by a waiting mark so a newly unavailable slot publishes fade zero immediately, even if
	// no producer result landed during this tick. Cleared after the dirty texture is uploaded.
	bool vt_page_fade_dirty = false;
	// A slot released this tick holds its replacement level for one published frame before the
	// countdown begins. This scratch vector is the per-slot equivalent of a short-lived release
	// set and is resized with the two fade vectors.
	std::vector<uint8_t> vt_slot_fade_just_started;
	// Scratch for that decision: the slots waiting for content this tick, and the producer's
	// answer for all of them at once.
	std::vector<int> vt_page_fade_waiting;
	std::vector<uint8_t> vt_page_fade_ready;
	Ref<Image> vt_page_fade_image;
	Ref<ImageTexture> vt_page_fade_texture;
	// Ramps the last fade update actually advanced: what a view that is fading reports, and zero
	// from a settled one. An armed slot is deliberately not counted - its countdown has not started -
	// so a view that is only holding the level behind an arrival reads as settled.
	int vt_page_fade_active = 0;
	// Ramps started since startup, and how many slots are waiting for content right now. The
	// active count above only shows a ramp while it runs, so a page that arrived without one
	// cannot be told from a page that never arrived; the start count is that distinction, and
	// the pending count is what a start is decided from.
	uint64_t vt_page_fade_starts = 0;
	int vt_page_fade_pending = 0;
	// Slots whose content landed and whose ramp is still owed, and the most ramps one tick has
	// started. The first is the blur the stagger trades for smoothness; the second is the flicker
	// it removes, which without a number to read is a matter of opinion.
	int vt_page_fade_held = 0;
	int vt_page_fade_starts_peak = 0;
	// The longest ramp still running, so how fast a ramp is spent can be read from one number:
	// the requested length and the number of ticks it was published for are not the same thing
	// while something else advances it.
	int vt_page_fade_ticks_max = 0;
	// The physical slots the standing plan's pages resolved to, rebuilt by every production pass.
	// A tick that finds the plan unchanged and this set still complete on the producer re-marks it
	// as demanded instead of re-deriving it, which is the whole of a settled view's work; a set
	// that has lost content falls through to a full pass, because an evicted slot would otherwise
	// never be noticed. Both ends live in terrain_3d_avt_produce.cpp.
	std::vector<int> avt_resident_slots;
	// Scratch for the near field's classification, kept here so a tick does not allocate: the
	// slot each page of the plan resolved to, and the producer's answer for all of them at once.
	// The producer's readiness is behind a mutex, and the walk used to ask it twice per page -
	// once for the sampled answer and once more inside the staleness check - so a 250 page plan
	// against a mostly missing view took five hundred queue locks to read one array.
	std::vector<int> avt_verify_slots;
	std::vector<uint8_t> avt_verify_ready;
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

	// ---- 3. the far field (SVT): a world-space page grid at a coarser texel density, so the
	// surface channel does not have to keep every region's payload resident. A page spans several
	// regions and its mip chain is world-space, which is what the region-aligned near field above
	// cannot express. On by default; the region texture array still serves whenever no page covers a
	// texel. ----
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
	// Scratch for the demand pass's verification, kept here so a settled tick does not
	// allocate: the slots it has to ask the producer about, and the readiness the producer
	// answers for all of them at once.
	std::vector<int> svt_verify_slots;
	std::vector<uint8_t> svt_verify_ready;
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
	// Breakdown of the far field's worst pass, published as `svt_stats` and attributed to
	// `svt_worst_ms`. The near field has `avt_sector_stats`; without the same for the far
	// field a peak in `svt_cpu_ms` could not be told apart between the visible-footprint
	// walk, the root pyramid plan and the detail set, which are three different fixes. A
	// pass records its stages in locals and only the pass that becomes the new worst writes
	// the dictionary, so the instrumentation is not a per-tick dictionary cost.
	Dictionary svt_stats;
	double svt_worst_ms = 0.0;
	// Frame the worst pass above was taken on, so the breakdown can be read as "this is what
	// the peak cost" rather than as a value of the current tick.
	uint64_t svt_worst_frame = 0;
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
	// ---- 4. cost and diagnostics: what this layer cost and why, for both views. The live phase
	// values describe the tick that just ran and the `*_sum_ms` fields are cumulative since
	// startup, so a mean over a sweep is their difference across it. ----
	// Main-thread cost of one VT section of the physics tick, in milliseconds, and the
	// worst frame since the terrain was created. `svt_cpu_ms` is the far-field demand
	// pass inside that section, so a peak can be attributed to one of the two views.
	double vt_cpu_ms = 0.0;
	double vt_cpu_peak_ms = 0.0;
	double svt_cpu_ms = 0.0;
	// Phase breakdown of the same section: the shared-service check, the near field's demand pass,
	// the far field's demand pass, the page-arrival fade, and the far-field bake. `vt_topup_ms` is
	// kept as a reported phase and is always zero: the near field used to be run a second time in a
	// "top-up" phase with the budget the far field did not spend, and that pass is gone. See
	// Terrain3D::__physics_process() for why it went.
	double vt_service_ms = 0.0;
	double vt_avt_ms = 0.0;
	double vt_svt_ms = 0.0;
	double vt_topup_ms = 0.0;
	double vt_fade_ms = 0.0;
	double vt_bake_ms = 0.0;
	// Worst frame for each demand pass since the terrain was created, so a peak in
	// `vt_cpu_peak_ms` can be attributed to one view without a profiler.
	double vt_avt_peak_ms = 0.0;
	double vt_svt_peak_ms = 0.0;
	// CPU budget for one phase of the VT section, in milliseconds. 0 disables it, which is the
	// default: the phases have no fixed cost left to cap, and a page a phase is not given time
	// to publish is a page the view keeps missing. An explicit update_surface_vt() /
	// update_surface_svt() call is never budgeted - the page count it passes is the caller's
	// own bound.
	//
	// Re-armed at the start of every phase, so the setting bounds what one pass may spend
	// rather than what the whole section may spend, which is the number a profiler attributes
	// a peak to. A deadline shared by the section was consumed by the service check and the
	// far field before the near field ran, so the near field found it already expired on every
	// tick of a moving view, emitted its one-page floor and stopped - the shape that makes a
	// turning view refine in visible blocks. Set it (0.1 is a reasonable cap) when a hard
	// per-phase bound matters more than the pages it costs.
	real_t vt_frame_budget_ms = 0.0f;
	// Absolute deadline of the tick that is running, or 0 when the caller is not the
	// physics tick. Every phase that can stop between two units of work reads it.
	uint64_t vt_tick_deadline_us = 0;
	// Set while the physics tick's VT section is running. The source workers are woken at the end of
	// the tick rather than at the end of each demand pass, because a worker woken inside a phase
	// starts competing for this thread's cores and the phases are measured as wall time on this
	// thread. A caller that drives `update_surface_vt()` directly has no tick to wait for, so the
	// pass flushes its own wakes in that case - see `_flush_source_wakes()`.
	bool vt_tick_active = false;
	// ---- 5. planner scratch: capacity owned by this struct so a plan tick reuses it instead of
	// reallocating. Staged near-field planner scratch: the scan and the hierarchy the chain's
	// phases hand each other. The chain itself runs in one pass; see _update_sector_avt. ----
	Terrain3DAVTSectorScan avt_pending_scan;
	Terrain3DAVTHierarchy avt_pending_hierarchy;
};

#endif // TERRAIN3D_VT_STATE_H
