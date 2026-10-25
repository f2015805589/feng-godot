// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_STATE_H
#define TERRAIN3D_VT_STATE_H

// VT runtime state, grouped by shared service, AVT, SVT, diagnostics and planner scratch.
// Node/geometry state belongs to Terrain3D. Each aggregate below owns related state
// and the transitions that preserve its invariant; algorithms live in the corresponding .cpp.
// See docs/vt_architecture_review.md for ownership and frame flow.

#include <algorithm>
#include <map>
#include <memory>
#include <string>
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
#include "terrain_3d_clipmap.h"
#include "terrain_3d_clipmap_atlas.h"
#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_clipmap_layer.h"
#include "terrain_3d_material_clipmap_detail.h"
#include "terrain_3d_page_pipeline.h"
#include "terrain_vt_arrival_queue.h"
#include "terrain_3d_vt_cells.h"
#include "terrain_3d_vt_delivery.h"

class Terrain3DVirtualTexture;
class Terrain3DVTFeedback;

// What a physical slot's arrival state is, per slot, in `Terrain3DVTFade::arrival`. Three states
// rather than a bool because the pass holds an arrival back between the tick its content lands and
// the tick its ramp is released, and a slot in between is neither waiting nor settled: it is
// showing the level its page replaces. See that struct's note and terrain_3d_vt_fade.cpp.
enum class PageArrival : uint8_t {
	SETTLED = 0,
	WAITING = 1,
	ARMED = 2,
};

// The legacy region-addressing demand source. CPU prediction always supplies demand;
// projection refines it while a result exists. The enabled setting and this frame's
// available source are separate decisions.
enum class TerrainVTPageDemandSource {
	// The distance rule the page geometry implies, plus the motion/turn lead.
	CPURule,
	// `Terrain3DVTFeedback`'s projection: the level that puts about one page texel on one pixel, with
	// off-screen and sub-pixel pages culled. It answers between passes too - the standing result is
	// what the interval amortises the readback over.
	Projected,
};

// Arrival ramps, bounded FIFO, shader texture and diagnostics. Per-slot vectors grow
// and reset together; texture rebuilds preserve active ramp counters.
// See terrain_3d_vt_fade.cpp for the update algorithm.
struct Terrain3DVTFade {
	// Remaining fade ticks per physical slot; 0 means settled.
	std::vector<uint8_t> ticks;
	// That slot's arrival state: `PageArrival::SETTLED`, `WAITING` for content, or `ARMED` once
	// the content has landed and before its ramp is released. A slot that leaves `WAITING` is one
	// whose content landed. The first published fade is zero, so an arrival still shows the level
	// it replaces rather than a detail step. The pass decides all of this on every tick from these
	// two vectors, so an arrival is seen whether or not a demand pass ran.
	std::vector<PageArrival> arrival;
	// The armed slots in the order they landed. The queue owns one node per physical slot, removes
	// a previous node when a slot is re-used, and is therefore bounded by the pool rather than by
	// the number of historical arrivals. A release pops from its head, so there is no consumed
	// prefix or per-tick cursor to retain.
	TerrainVT::PageArrivalQueue queue;
	// A slot released this tick holds its replacement level for one published frame before the
	// countdown begins. This scratch vector is the per-slot equivalent of a short-lived release
	// set and is resized with the two vectors above.
	std::vector<uint8_t> just_started;
	// Scratch for that decision: the slots waiting for content this tick, and the producer's
	// answer for all of them at once.
	std::vector<int> waiting;
	std::vector<uint8_t> ready;
	// The ramp texture, one byte per physical slot, and the flag that says it changed. Set by a
	// waiting mark so a newly unavailable slot publishes fade zero immediately, even if no
	// producer result landed during this tick; cleared after the dirty texture is uploaded.
	Ref<Image> image;
	Ref<ImageTexture> texture;
	bool dirty = false;
	// Ramps the last fade update actually advanced: what a view that is fading reports, and zero
	// from a settled one. An armed slot is deliberately not counted - its countdown has not
	// started - so a view that is only holding the level behind an arrival reads as settled.
	int active = 0;
	// Ramps started since startup, and how many slots are waiting for content right now. The
	// active count above only shows a ramp while it runs, so a page that arrived without one
	// cannot be told from a page that never arrived; the start count is that distinction, and
	// the pending count is what a start is decided from.
	uint64_t starts = 0;
	int pending = 0;
	// Slots whose content landed and whose ramp is still owed, and the most ramps one tick has
	// started. The first is the blur the stagger trades for smoothness; the second is the flicker
	// it removes, which without a number to read is a matter of opinion.
	int held = 0;
	int starts_peak = 0;
	// The longest ramp still running, so how fast a ramp is spent can be read from one number:
	// the requested length and the number of ticks it was published for are not the same thing
	// while something else advances it.
	int ticks_max = 0;

	// How many slots this fade is tracking, which is the pool's page count once a pass has run.
	size_t slot_count() const { return arrival.size(); }

	// Record one slot, growing every per-slot vector together. Never a shrink: a resize to the
	// slot below the length the pass published would drop the counters of every slot above it,
	// and with them the ramps that are running - a page arriving mid-blend would finish as a step.
	void ensure_slot(const int p_slot) {
		if (p_slot < 0 || size_t(p_slot) < arrival.size()) {
			return;
		}
		const size_t needed = std::max(size_t(p_slot) + 1, arrival.size());
		arrival.resize(needed, PageArrival::SETTLED);
		ticks.resize(needed, 0);
		just_started.resize(needed, 0);
	}

	// Match the pool's page count. The entries a slot already has are kept: a slot keeps its index
	// across a rebuild, so reinitializing the counters would end a ramp in flight - an arrival
	// that has already begun to blend would finish as a step.
	void resize_slots(const size_t p_slots) {
		arrival.resize(p_slots, PageArrival::SETTLED);
		ticks.resize(p_slots, 0);
		just_started.resize(p_slots, 0);
	}

	// A page pool rebuild invalidates every physical slot index, so the per-slot state and the
	// texture built from it go with it: a slot number reused by the new pool must not inherit an
	// old arrival or an armed FIFO node. The cumulative start counters deliberately survive - the
	// live counters describe the new pool from this point onward, the totals describe the session.
	void reset_for_pool() {
		ticks.clear();
		arrival.clear();
		just_started.clear();
		queue.reset();
		waiting.clear();
		ready.clear();
		image.unref();
		texture.unref();
		dirty = false;
		active = 0;
		pending = 0;
		held = 0;
		ticks_max = 0;
	}
};

// Shared pool capacity, rebuild generation and bounded growth wait.
// Only rebuilds advance generation; capacity publication preserves completed plans.
struct Terrain3DVTPool {
	// How long the demand pass may skip production while the producer rebuilds its arrays for a
	// larger capacity. Long enough for the producer's render pass and the pool's own growth (two or
	// three frames), short enough that a device which cannot grow the arrays loses only a fraction
	// of one page budget.
	static constexpr uint64_t MAX_WAIT_FRAMES = 8;

	// The capacity actually published. Auto capacity raises it above the setting, and a later
	// reconfiguration (page size, border, resolution) starts from this value instead of the
	// setting, so a rebuild cannot shrink the pool and then ask the demand pass to grow it straight
	// back, which would release every resident page twice.
	int capacity = 256;
	// Bumped every time the service builds a new page pool. The pool cannot be resized in place, so
	// a rebuild releases every resident page: this is what tells a consumer the residency it was
	// holding is gone.
	uint64_t generation = 0;
	// Frame the demand pass first skipped production to wait for a requested capacity, or
	// UINT64_MAX when no wait is in flight. The wait is bounded: the pool cannot be resized in
	// place, so growing it releases whatever is resident, and producing pages against the old count
	// only spends the bake budget on content the growth throws away.
	uint64_t wait_start = UINT64_MAX;

	// Publish grown capacity without changing plan generation. Growth evicts physical
	// pages, but retains virtual addresses, source jobs and completed plans. SVT root
	// verification detects released pins and schedules their content again.
	void grow(const int p_capacity) {
		capacity = p_capacity;
		wait_start = UINT64_MAX;
	}
	// An explicit capacity is a request, not a floor: it replaces the auto-grown value and leaves
	// the wait alone, because the caller is changing a setting rather than waiting for a rebuild.
	void request(const int p_capacity) { capacity = p_capacity; }
	// A rebuilt pool. Every consumer's residency is gone from this point on.
	void rebuilt() { generation++; }
	// Whether the demand pass should skip production this tick while a requested growth lands.
	// `p_pending` is the producer's answer that it still has a capacity request in flight; the wait
	// starts on the first frame it is seen and is bounded, so a state that cannot grow the arrays
	// never stops page production.
	bool waiting_for_capacity(const uint64_t p_frame, const bool p_pending) {
		if (!p_pending) {
			wait_start = UINT64_MAX;
			return false;
		}
		if (wait_start == UINT64_MAX) { wait_start = p_frame; }
		if (p_frame < wait_start + MAX_WAIT_FRAMES) { return true; }
		wait_start = UINT64_MAX;
		return false;
	}
};

// The material page arrays the terrain's material is currently bound to: the producer's published
// generation and the albedo array of that bundle. Both tiers' arrays are replaced together, so the
// near field's albedo alone does not identify the set - a change to the far field's arrays has to
// rebound the material too.
struct Terrain3DVTBoundMaterial {
	uint64_t generation = 0;
	RID albedo;

	// Whether the material already samples the bundle the producer is publishing now.
	bool matches(const uint64_t p_generation, const RID &p_albedo) const {
		return generation == p_generation && albedo == p_albedo;
	}
	void adopt(const uint64_t p_generation, const RID &p_albedo) {
		generation = p_generation;
		albedo = p_albedo;
	}
	// Nothing is bound: the next published bundle rebinds unconditionally.
	void clear() { albedo = RID(); }
};

// The far field's pinned root pyramid: the pages the coarsest levels keep resident and protected,
// the identity they were planned for, whether that walk pinned everything it planned, and what the
// set covers. One owner because the key alone is not a cache hit: a key that still matches while
// the last walk was incomplete is a plan that never pinned, which is what the settled flag is for.
struct Terrain3DSVTRootPlan {
	// The roots themselves, as (mip 0 page x, mip 0 page y, level). The set is a function of the
	// covered rect, the level window and the pool, so it is planned once per identity and reused:
	// the pyramid is baked static content, and re-requesting a page that is already pinned and
	// protected buys nothing.
	std::vector<Vector3i> pages;
	// Identity of the plan above (domain, level window, pool, pool generation, source revision).
	uint64_t key = 0;
	// Did the last walk pin every root it planned.
	bool settled = false;
	// World rect the last planned root set covers, and the level window it used. The fallback is
	// only useful where its roots are, so coverage is what a test asserts: a world-sized candidate
	// set truncated by the pin budget used to leave every root in one corner of the map.
	Rect2 coverage;
	int level_min = -1;
	int level_max = -1;

	// Whether the demand pass may skip the walk for this identity. A key that matches on a settled
	// plan may; anything else has to walk again.
	bool matches(const uint64_t p_key) const { return settled && key == p_key; }
};

// The near field's standing plan: the key it was planned for, the page selection, the length of
// its sampled prefix, plus whether the source queue has already been retained against this plan.
// One owner because replacing the plan has to forget that retention: retention is one set operation
// over the whole plan, so a stale "already retained" flag leaves the source queue holding work the
// new plan does not name.
struct Terrain3DAVTPlan {
	// The key of the chain that produced this selection. Deliberately left stale while the refresh
	// interval holds a change: the plan describes the view a lead ahead, and re-deriving it every
	// tick is the cost that interval exists to avoid.
	Terrain3DAVTPlanKey key = invalid_avt_plan_key();
	std::vector<Terrain3DAVTPageRequest> pages;
	// Length of the sampled prefix of `pages`. Everything after it is the retention window this
	// plan's installer appended, which is allowed to lag without the view showing a miss.
	int sampled = 0;
	// Whether the source queue was already retained against this plan. A pass that would repeat the
	// previous wanted set returns early instead of repeating 250 map lookups to reach the state the
	// last pass already reached.
	bool retain_applied = false;

	// The retention no longer describes this selection: a plan was replaced, or the addresses it
	// resolved to were remapped under it. The next retain pass re-applies it.
	void forget_retention() {
		retain_applied = false;
	}
	// Install a completed plan: its selection and its sampled length, and forget the retention,
	// because this is a new wanted set.
	void install(std::vector<Terrain3DAVTPageRequest> &&p_pages, const int p_sampled) {
		pages = std::move(p_pages);
		sampled = p_sampled;
		forget_retention();
	}
	// Whether the queue already holds this exact wanted set.
	bool retained() const { return retain_applied; }
	void mark_retained() { retain_applied = true; }
	// A page-pool rebuild invalidates every address this selection resolved to, so the key and the
	// selection go. The sampled length and the retention flag are left alone: no pass reads them
	// without a resident plan, and the next install overwrites them.
	void forget() {
		invalidate_avt_plan_key(key);
		pages.clear();
	}
};

// The near field's settled shortcut: the driver's verdict that the standing plan is this tick's,
// the pool *residency revision* an idle pass verified, the resident set it verified, and whether
// the idle statistics already describe that run. The shortcut needs all four - a reused plan, the
// same residency, a set the producer still holds every page of, and the constants published once -
// so they are one owner with the three transitions between them.
struct Terrain3DAVTSettled {
	// Whether the last plan was installed from cache. A plain member rather than a lookup in the
	// statistics dictionary, which the settled path reads every tick.
	bool reused = false;
	// Set while the pool's residency revision is the one an idle pass verified, 0 when none did. An
	// idle pass keeps its verified resident set instead of re-deriving it, so this is what tells the
	// next tick whether that set can still be trusted.
	uint64_t revision = 0;
	// The physical slots the standing plan's pages resolved to, rebuilt by every production pass. A
	// tick that finds the plan unchanged and this set still complete on the producer re-marks it as
	// demanded instead of re-deriving it, which is the whole of a settled view's work; a set that has
	// lost content falls through to a full pass, because an evicted slot would otherwise never be
	// noticed.
	std::vector<int> slots;
	// True while the statistics dictionary already describes the current idle run. The values an
	// idle pass publishes are constants of the settled state, so a run of idle ticks writes them
	// once - the dictionary is String keyed, and republishing the same numbers is the largest thing
	// left on a settled tick.
	bool stats_current = false;

	// Whether this pass may take the shortcut at all: the plan is reused and the pool's residency
	// has not moved since the pass that verified the set below.
	bool can_run(const uint64_t p_residency_revision) const {
		return reused && revision == p_residency_revision;
	}
	// The pass verified every slot in `slots` and the pool is still at this revision.
	void verified(const uint64_t p_residency_revision) { revision = p_residency_revision; }
	// The set `slots` was verified against is about to be replaced by a newly submitted plan: the
	// revision goes, so no pass can take the shortcut until it verifies its own set.
	void unverify() { revision = 0; }
	// A pass that is not the settled one runs the real classification. Its verdict goes - so the
	// next pass rebuilds the set - and `stats_current` with it, because the dictionary no longer
	// describes the state the shortcut published.
	void fall_through() {
		stats_current = false;
		revision = 0;
		slots.clear();
	}
};

// Serialized SVT bake state: pending/in-flight cells, protected slots, job counters
// and debounced region edits. Explicit jobs exclude automatic jobs; begin() resets
// job counters without discarding queued edits.
struct Terrain3DSVTBakeJob {
	// Cells still to bake, oldest first, as (cell x, cell y, mip 0).
	Array queue;
	// Published physical slots whose cell is being baked: a slot in here is protected, so the pool
	// cannot evict a page that the bake now running is about to serve.
	Dictionary waiting;
	// The cell being baked right now, and the producer doing it. Empty between cells.
	Dictionary cell_job;
	Ref<RefCounted> cell_baker;

	// An explicit bake_svt() job is queued or still baking its last cell. Automatic jobs wait for
	// it: one that starts a frame earlier replaces the job-scoped progress counters the dock and
	// the tests read as "this bake completed".
	bool explicit_job = false;
	// Whether this job re-bakes only the edited cells (`incremental`) and what it owes: the total it
	// was queued with, how many landed and how many failed. `generation` is what the dock polls to
	// notice that a job completed, and `cells_baked` is the session's cumulative count.
	bool incremental = false;
	uint64_t generation = 0;
	int total = 0;
	int done = 0;
	int failed = 0;
	String error;
	uint64_t cells_baked = 0;

	// Region edits waiting for the auto-bake debounce, and when the last one landed. They belong to
	// the job because they are what queues the next one.
	Dictionary dirty_regions;
	uint64_t edit_time = 0;

	// Whether the job still owes work the demand passes have to leave alone: cells queued, or a
	// protected slot held for a cell that is baking. The near field and the capacity path pause on
	// this, because a pool that grew under a running bake would release the cells it is writing.
	bool busy() const {
		return !queue.is_empty() || !waiting.is_empty();
	}
	// How many items that is: the queued cells plus the slots held for a cell in flight. This is
	// the `bake_pending` reading, and what a cancelled job counts as lost.
	int pending() const {
		return queue.size() + waiting.size();
	}
	// Whether the job has nothing left at all, including the cell in flight. The explicit job is
	// over on this answer.
	bool drained() const {
		return queue.is_empty() && waiting.is_empty() && cell_job.is_empty();
	}
	// Start the job now that `queue` holds the cells it will drain: a new generation for the dock to
	// notice, and the per-job counters from zero.
	void begin(const bool p_incremental) {
		generation++;
		incremental = p_incremental;
		total = queue.size();
		done = 0;
		failed = 0;
		error = String();
	}
	// Pop the head of the queue: the next cell to bake.
	Vector3i take_next() {
		const Vector3i next = queue[0];
		queue.remove_at(0);
		return next;
	}
	// The current cell was produced and published: one more cell of this job, one more of the
	// session.
	void complete_cell() {
		done++;
		cells_baked++;
	}
	// The current cell could not be baked, or the reason a whole job was abandoned.
	void fail(const String &p_reason) {
		failed++;
		error = p_reason;
	}
	// Abandon what this job still owes - a cancelled job counts every cell it had left as failed -
	// and report how many, so the caller only records a reason when there was something to lose.
	int abandon() {
		const int owed = pending();
		failed += owed;
		return owed;
	}
};

struct Terrain3DVTState {
	// ---- 1. the shared service: one surface service owns the settings and the GPU material cache;
	// AVT and SVT below are addressing/producer views over its shared physical residency pool. ----

	// DeliveryMatrix selects services, published arrays and shader arms per channel/tier.
	// Defaults: AVT near material, SVT far material, Direct height in both tiers.
	// See docs/vt_delivery_assembly.md.
	TerrainVT::DeliveryMatrix delivery;
	// Read-only preview telemetry: calls counts requests; computed counts requests
	// that pass the selected-method gate and scan a layout.
	mutable uint64_t avt_preview_calls = 0;
	mutable uint64_t avt_preview_computed = 0;
	mutable uint64_t clipmap_preview_calls = 0;
	mutable uint64_t clipmap_preview_computed = 0;
	// Clipmap: one optional layer per channel group, owning either LOD or Atlas storage.
	// _setup_vt_clipmap() creates only selected groups. Unit l spans base_world * 2^l
	// metres in size texels; budget_texels bounds one layer's per-tick production.
	// Legacy shapes remain storage migration aliases; new scenes use quality profiles.
	TerrainClipmap::Implementation clipmap_implementation = TerrainClipmap::Implementation::LOD;
	int clipmap_quality = 0; // Standard; see `_clipmap_settings()` for the profile table.
	TerrainClipmap::Shape clipmap_legacy_shape;
	// Per-group fields are old serialized overrides. Zero means no legacy override for that dimension;
	// they take precedence over the new profile only while an old scene still carries those values.
	int clipmap_group_size[TerrainVT::GROUP_COUNT] = { 0, 0 };
	int clipmap_group_units[TerrainVT::GROUP_COUNT] = { 0, 0 };
	real_t clipmap_group_base_world[TerrainVT::GROUP_COUNT] = { 0.f, 0.f };
	int clipmap_budget_texels = 65536;
	std::unique_ptr<Terrain3DClipmapLayer> clipmap_layer[TerrainVT::GROUP_COUNT];
	// The state stamp of each layer as the shader was last *bound* with, so a change the shader has to
	// follow is one comparison per layer rather than a rebind per tick. See
	// `Terrain3DClipmapLayer::get_state_stamp()` and `Terrain3D::_update_vt_clipmap_arm()`.
	uint64_t clipmap_state[TerrainVT::GROUP_COUNT] = { 0, 0 };
	// The shader's texture/configuration bindings are separate from the moving address state. A ring
	// may be configured after the shader variant was first bound, so the address-only path must detect
	// a new texture or shape once and publish the sampler plus its dimensions before tracking moves.
	struct ClipmapUniformBinding {
		bool valid = false;
		Terrain3DClipmapLayer::Settings settings;
		RID texture;
		RID baked[3];
	};
	ClipmapUniformBinding clipmap_uniform_binding[TerrainVT::GROUP_COUNT];
	// Channel texels produced by every layer in the tick that just ran.
	int clipmap_produced_texels = 0;
	// Wall time the last completed background LOD ring update spent producing and publishing its level.
	uint64_t clipmap_worker_usec = 0;
	// Optional material detail cache above the Clipmap ladder, enabled by default.
	// Owns separate arrays, directory and source queue only while selected and enabled.
	// Level l uses detail_density / 2^l texels/m down to detail_min_density;
	// detail_budget_bytes determines slot capacity, detail_demand_radius bounds coverage.
	// The ladder supplies the fallback outside resident detail tiles.
	bool detail_enabled = true;
	real_t detail_density = 1024.f;
	// Coarsest detail density. 128 texels/m gives four levels at 1024/512/256/128;
	// the manager fits their coverage into the shared detail slot budget.
	real_t detail_min_density = 128.f;
	int detail_tile_size = 256;
	int detail_directory_size = 128;
	// GPU memory budget for all detail levels. The manager fits density bands to the
	// available slots and reports unmet demand.
	int detail_budget_bytes = 512 * 1024 * 1024;
	real_t detail_demand_radius = 12.f;
	real_t detail_texels_per_pixel = 4.f;
	std::unique_ptr<Terrain3DMaterialClipmapDetail> material_detail;
	// Layout and window stamps last bound to the material. Window moves update only that uniform;
	// shape and directory RID changes rebuild the detail arm. See the manager's paired stamps.
	uint64_t material_detail_state = 0;
	uint64_t material_detail_window_state = 0;
	// Ticks the detail layer's demand pass ran, and the last pass's requested-tile count and cost.
	int detail_requested_tiles = 0;
	int detail_starved_tiles = 0;
	double vt_detail_ms = 0.0;
	uint64_t vt_detail_worker_us = 0;
	int vt_page_size = 256;
	// Page gutter in texels per side. CPU/shader anisotropy is bounded by
	// n <= 2 * border - 1 (kernel half-extent plus bilinear filtering).
	// A five-texel border supports the default 8x; see docs/vt_sampling_review.md.
	int vt_page_border = 5;
	int vt_page_count = 256;
	// The capacity already published, the rebuild generation and the growth handshake, as one
	// owner: a capacity change only reaches the two views through the generation. See
	// `Terrain3DVTPool` above for what each of the three is and which operation changes it.
	Terrain3DVTPool pool;
	bool vt_auto_capacity = true;
	int vt_pages_per_update = 16;
	// Source threads that assemble pages for both views. 0 selects a machine derived default; see
	// Terrain3DPagePipeline. One thread cannot feed a moving view.
	int vt_page_workers = 0;
	bool vt_adaptive_enabled = true;
	// Near-field material compression: 0 raw, 1 BC7, 2 BC3. The surface baker validates
	// and reports the applied format; the GPU encoder produces blocks. SVT selects its
	// own codec independently.
	int surface_vt_compression = 0;
	// Storage format of the far field's material page arrays. A far-field page is assembled
	// once from a baked cell and never rewritten, so its compressed copy is final: this is
	// the tier where a codec buys the most memory for the least work.
	int surface_svt_compression = 0;
	// Allow missing pages to sample a resident coarser level, independently per tier.
	// Disable to expose strict selected-page misses through the diagnostic path.
	bool avt_feedback = true;
	// Far field: allow a miss at the level the distance rule selected to be served by a
	// coarser resident level instead of the diagnostic. Off restores the strict walk.
	bool svt_feedback = true;
	bool vt_debug_direct_material = false;
	bool vt_editor_preview = true;
	Dictionary vt_editor_dirty_regions;
	uint64_t vt_service_frame = UINT64_MAX;
	bool vt_shared_ready = false;
	// True for a bake-only producer without paged arrays. Selecting AVT/SVT upgrades it
	// to a page bundle; a page bundle can also serve Clipmap baking.
	bool vt_ring_only = false;
	bool vt_materials_dirty = true;
	// Whether Clipmap has already requested its initial material-list publication.
	// Repeated publication invalidates all ring bakes, so matrix refreshes reuse it.
	bool vt_materials_published = false;
	bool vt_callback_registered = false;
	// Warn once when the engine build has no virtual texture update callback: without it the
	// material page producer never runs, and every page-dependent test would fail with no
	// explanation.
	bool vt_callback_missing_warned = false;
	Ref<RefCounted> vt_baker;
	std::unique_ptr<Terrain3DPagePipeline> vt_page_pipeline, svt_page_pipeline;
	std::map<int, Terrain3DPagePipeline::Request> svt_pending_pages;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> vt_source_snapshot;
	// Slot-keyed production record. Runtime readers consume typed fields; the editor
	// Dictionary is materialized only on request by _vt_page_record_dictionary().
	struct PageRecord {
		// What the page's production is doing. The script-facing state string is spelled from
		// this, so the two cannot drift.
		enum State {
			PENDING_BAKE = 0,
			PENDING_CELL_COPY = 1,
			MISSING_BAKE = 2,
			PENDING_RESIDENT_FALLBACK = 3,
			MISSING_STALE_CELL_BAKE = 4,
			NO_RESIDENT_PAYLOAD = 5,
		};
		// The state the debug page list publishes. It is spelled here, beside the enum, so the
		// two cannot drift - the strings are the ones the tests and the editor dock read.
		const char *state_name() const;
		int slot = -1;
		// The view that queued it: the near field's pages and the far field's share one record
		// table because they share one pool.
		bool svt = false;
		State state = PENDING_BAKE;
		Rect2 world_rect;
		int mip = 0;
		Vector2i address;
		int64_t revision = 0;
		int64_t queued_frame = 0;
		// Cells a pending cell copy covers, for the debug list.
		int cells = 0;
		// The source the page is being produced from: a page's payload is a few hundred
		// kilobytes and this is a refcount, not a copy.
		Ref<Image> source;
	};
	std::unordered_map<int, PageRecord> vt_page_records;
	Dictionary vt_registered_sectors;
	PackedFloat32Array surface_vt_block_sizes;
	// The page-array bundle the material is bound to, with the invariant that identifies it. See
	// `Terrain3DVTBoundMaterial` above.
	Terrain3DVTBoundMaterial bound;
	uint64_t vt_source_revision = 1;
	Dictionary vt_svt_tiles;
	// The far field's cell bake: what is queued, the slots protected while their cell is in flight,
	// the job-scoped counters and the region edits waiting for the debounce. See
	// `Terrain3DSVTBakeJob` above for why they are one owner.
	Terrain3DSVTBakeJob bake;
	// Resident cell sources of the far field. A cell baked in this session (or imported)
	// lives here, and page assembly then copies it on the GPU instead of re-reading a bake
	// file or re-evaluating the material per page. See terrain_3d_vt_cells.h.
	Ref<Terrain3DCellStore> svt_cells;
	// Per-cell probe of the persisted bake, remembered so the render path never stats the
	// same file twice (1 = present, 2 = absent).
	std::unordered_map<int64_t, uint8_t> svt_cell_file_probe;
	// Persisted-cell probes and pages rejected before probing, accumulated per session.
	uint64_t svt_persist_probe_cells = 0;
	uint64_t svt_persist_probe_skips = 0;
	// Edit stamp per far-field cell. A resident cell is only reused while its stamp is at
	// least the newest edit that touched it or one of its eight neighbours, because a page
	// border reads them.
	std::unordered_map<int64_t, uint64_t> svt_cell_edit_stamp;
	uint64_t svt_edit_counter = 0;
	bool svt_auto_bake = true;
	uint32_t vt_material_signature = 0;
	bool vt_svt_catalog_loaded = false;

	// ---- 2. the near field (AVT): surface pages produced from the region surface maps. On by
	// default since AVT, SVT and CDLOD became the shipped defaults; the array path still serves
	// every texel no page covers. ----
	Terrain3DVirtualTexture *surface_vt = nullptr;
	// The near field's working set is roughly 50 pages at density 4 (a 512 m radius
	// with the distance rule), so 64 left no headroom for the LRU.
	int surface_vt_page_count = 128;
	int surface_vt_page_size = 256;
	// Mirrors `vt_page_border`; the setter syncs all three unless the debug direct-material path
	// keeps them apart.
	int surface_vt_page_border = 5;
	// Requested AVT anisotropy; zero follows the viewport. get_avt_anisotropy() applies
	// the shared CPU/shader bound of 2 * vt_page_border - 1.
	int surface_vt_anisotropy = 8;
	// Sector virtual-image resolution tiers; this does not truncate local page-table mips.
	int surface_vt_mip_levels = 3;
	int surface_vt_pages_per_axis = 4;
	// AVT radius in metres. Planning includes one sector of margin; SVT begins at
	// 0.75 * this radius and overlaps the outer transition band.
	real_t surface_vt_distance = 384.f;
	Vector2i surface_vt_region_grid = Vector2i(2, 2);
	int surface_vt_selection_mode = 2;
	Ref<ImageTexture> avt_sector_directory;
	PackedByteArray avt_directory_bytes;
	int avt_directory_mask = 0;
	int avt_root_level = 1;
	Terrain3DAVTCoarseImage avt_coarse;
	// Typed runtime statistics; to_dictionary() materializes the script-facing report.
	// operator[] returns a one-assignment proxy, preserving named call-site updates.
	struct Stats {
		std::unordered_map<std::string, Variant> values;

		struct Slot {
			Stats *owner = nullptr;
			const char *key = nullptr;
			Slot &operator=(const Variant &p_value) {
				owner->values.insert_or_assign(std::string(key), p_value);
				return *this;
			}
		};
		Slot operator[](const char *p_key) { return Slot{ this, p_key }; }

		void clear() { values.clear(); }

		Dictionary to_dictionary() const {
			Dictionary result;
			for (const auto &entry : values) {
				result[String(entry.first.c_str())] = entry.second;
			}
			return result;
		}
	};
	Stats avt_sector_stats;
	// Live pass statistics. Session sums and peak snapshots belong to avt_cost below.
	uint64_t avt_plan_epoch = 0;
	// How many frames apart the plan is re-derived, and the frame the last chain ran on. The plan
	// is re-derived once per interval rather than once per frame; a key that changed inside the
	// interval is left for the next refresh, and the plan key is then left at the value the
	// installed plan was planned for, so the tick that follows still sees the change.
	uint64_t avt_plan_refresh_frames = 1;
	uint64_t avt_last_chain_frame = UINT64_MAX;
	std::shared_ptr<Terrain3DAVTRefinement> avt_refinement;
	// The standing plan: the key it was planned for, the page selection, its sampled length and the
	// retention flag that says whether the source queue already holds it.
	// See `Terrain3DAVTPlan` above for why replacing the plan has to forget the retention.
	Terrain3DAVTPlan avt_plan;
	// Smoothed camera-velocity prediction over vt_motion_lead_ms, clamped by AVT reach.
	// Stops and reversals update the prediction rather than retaining a stale lead.
	real_t vt_motion_lead_ms = 250.f;
	Vector2 avt_motion_velocity;
	uint64_t avt_motion_stamp_us = 0;
	Vector2 avt_motion_last_focus;
	bool avt_motion_valid = false;
	// A camera cut invalidates the old-view retention tail at the next plan install.
	bool avt_discard_retained = false;
	// Unserved view after a cut, teleport or substantially new plan. Uses the full batch
	// until every sampled page has a slot and content.
	bool avt_view_unserved = false;
	// Page budget settings and hysteresis. _avt_tick_allowance() supplies the same live
	// allowance to production, source queues, frame budgeting and encoding.
	Terrain3DAVTPageBudget avt_page_budget;
	// One-tick discontinuity event from camera turn/displacement, consumed by the budget
	// governor in the same tick.
	bool avt_motion_discontinuity = false;
	// Lead actually applied to the last submitted plan, for diagnostics and tests.
	Vector2 avt_motion_lead;
	// Gaze prediction from consecutive forward vectors. Roll does not change that
	// vector and therefore contributes no predicted turn.
	Vector3 avt_motion_turn;
	Vector3 avt_motion_last_forward;
	// Turn lead actually applied to the last submitted plan: an axis and an angle in radians,
	// which is what `_vt_lead_camera_transform()` rotates the predicted basis by.
	Vector3 avt_motion_turn_lead;
	// Demand age by page address. A page is late after one lead window without content;
	// ready pages leave this map.
	std::unordered_map<uint64_t, uint64_t> avt_demand_age;
	// Reusable retain/prime request vectors built from the missing-page plan.
	std::vector<Terrain3DPagePipeline::Request> avt_retain_requests;
	std::vector<Terrain3DPagePipeline::Request> avt_prime_requests;
	// Sampled pages still missing and those within their production window. Pending
	// source work keeps editor rendering active even without queued GPU work.
	int avt_missing_pages = 0;
	int avt_pending_pages = 0;
	// Plans kept while the lead is applied, so retention does not drop the view being
	// rendered before the plan that replaces it has been produced.
	int avt_retain_epochs = 8;
	// Requests kept from the previous plan because they are still on screen behind the
	// lead. The pool capacity request counts them, so a look-ahead plan cannot grow the
	// pool exactly large enough to evict the view it is leading.
	int avt_retained_pages = 0;
	// Configured sampling texels-per-pixel published with the installed plan.
	// Per-level coarsening lives in indirection plan markers, not a global density bias.
	float avt_density_scale = 1.f;
	// Standing-plan/residency verification and once-per-idle-run statistics.
	// Transitions are owned by Terrain3DAVTSettled.
	Terrain3DAVTSettled avt_settled;
	// Page-arrival fade in ticks; zero disables blending against the replaced level.
	int vt_page_fade_frames = 12;
	// The fade's buffer, FIFO, texture and counters, in one owner: `Terrain3DVTFade` above holds
	// the fields and the only operations that change their length.
	Terrain3DVTFade fade;
	// Reusable slot/readiness batches. One producer query reads readiness for the whole
	// plan instead of taking its queue mutex per page.
	std::vector<int> avt_verify_slots;
	std::vector<uint8_t> avt_verify_ready;
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

	// ---- 3. SVT: world-space far-field page grid and persistent cell sources. ----

	Terrain3DVirtualTexture *surface_svt = nullptr;
	// One mip 0 page covers this many metres.
	real_t surface_svt_page_world = 256.f;
	int surface_svt_page_size = 256;
	// Shared page border mirrored from vt_page_border. SVT uses textureLod;
	// its gutter supports mip transitions. See docs/vt_sampling_review.md.
	int surface_svt_page_border = 5;
	int surface_svt_page_count = 256;
	// -1 means auto: the coarsest level the world grid can publish.
	int surface_svt_max_mip = -1;
	// How far from the clipmap target the far field is kept resident, in metres.
	real_t surface_svt_distance = 6144.f;
	// Coarsest levels of the world grid that are always resident. This root pyramid is
	// what lets the shader resolve any world position without the region texture array,
	// so it is the far field's fallback rather than a separate fallback page.
	int surface_svt_root_mips = 2;
	// SVT fallback policy: 0 pins a root pyramid over the addressable world; 1 pins a
	// coarse cover for visible pages. Both use svt_roots and the same verification path.
	int surface_svt_fallback_policy = 0;
	int vt_svt_visible_pages = 0;
	// Far-field roots this pass keeps resident and protected, the identity they were planned for and
	// what the set covers. See `Terrain3DSVTRootPlan` above for why the key alone is not a hit.
	Terrain3DSVTRootPlan svt_roots;
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
	// Pages re-produced because the table named them but the producer had no content for
	// them. A value that keeps growing in a settled view is a production that never lands.
	uint64_t svt_requeues = 0;
	// World-mip-cap telemetry. Cap changes update uniforms without dirtying regions;
	// vt_svt_coverage asserts svt_cap_dirty_regions remains zero.
	uint64_t svt_cap_changes = 0;
	uint64_t svt_cap_dirty_regions = 0;
	double svt_cap_change_ms = 0.0;
	double svt_cap_change_worst_ms = 0.0;
	int svt_cap_last_from = -1;
	int svt_cap_last_to = -1;
	// The root window's own cap raise (`_svt_plan_roots()`), which rebuilds the material but
	// deliberately does not dirty regions. Counted separately because it is the other writer
	// of the same field.
	uint64_t svt_root_cap_raises = 0;
	// The coarseness floor the last over-subscribed pass raised its detail pages to, or
	// 0 when the distance-selected set fit. Diagnostics and tests only.
	int svt_floor_level = 0;
	// Capacity available to detail pages after pinned roots, used to select the floor.
	int svt_detail_capacity = 0;
	// Stage breakdown of the worst SVT pass. Updated only when svt_worst_ms increases;
	// these values describe that peak, not the latest tick.
	Dictionary svt_stats;
	double svt_worst_ms = 0.0;
	// Frame the worst pass above was taken on, so the breakdown can be read as "this is what
	// the peak cost" rather than as a value of the current tick.
	uint64_t svt_worst_frame = 0;
	// Distance-to-mip table in metres, shared by CPU production and shader sampling.
	// Entry m is the maximum distance for world mip m. Empty uses one level per doubling
	// of surface_svt_page_world; residency pressure does not change these bands.
	PackedFloat32Array surface_svt_mip_distances;
	Vector3i surface_svt_scan_key = Vector3i(INT32_MAX, INT32_MAX, INT32_MAX);
	int64_t surface_svt_root_cursor = 0;
	int64_t surface_svt_detail_cursor = 0;
	// Whether the surface channel is uploaded to the region texture array. Off means
	// the virtual textures serve every surface read, which is what removes the
	// density-squared array cost; the array stays allocated but blank.
	bool surface_array_enabled = true;
	// ---- 4. Diagnostics: latest-tick values, session sums and peak snapshots. ----
	// AVT live pass readings are in avt_sector_stats; cumulative *_sum_ms values and
	// pass_count support interval means without affecting runtime decisions.
	struct Terrain3DAVTCost {
		// Cumulative stage times; divide interval deltas by the pass-count delta for means.
		double classify_sum_ms = 0.0;
		double retain_sum_ms = 0.0;
		double prime_sum_ms = 0.0;
		double upload_sum_ms = 0.0;
		double refill_sum_ms = 0.0;
		double finish_sum_ms = 0.0;
		uint64_t pass_count = 0;
		// Sector tick accounting. reuse_ticks + chain_ticks counts production-pass entries;
		// subtract pass_count to count settled shortcuts.
		uint64_t sector_ticks = 0;
		uint64_t reuse_ticks = 0;
		uint64_t chain_ticks = 0;
		// Ticks the production pass was not called at all because the pool was waiting for the
		// producer to publish a larger capacity. They are not idle ticks and they are not a pass, so
		// they need their own count or they read as one of the two.
		uint64_t capacity_skip_ticks = 0;
		double key_sum_ms = 0.0;
		double plan_state_sum_ms = 0.0;
		double install_sum_ms = 0.0;
		double chain_sum_ms = 0.0;
		double produce_sum_ms = 0.0;
		// Whole sector-update and outer-wrapper time, distinct from internal stage sums.
		double update_sum_ms = 0.0;
		double wrapper_sum_ms = 0.0;
		// The near field's stage timings as of the pass that produced `vt_avt_peak_ms`, and when that
		// was. The live dictionary is overwritten by every pass, so without this the stages of a peak
		// could not be read at all - and the peak is by definition not the last pass.
		Dictionary peak_stats;
		uint64_t peak_stamp_us = 0;
		// Ticks a changed plan key was held back for the refresh interval. Diagnostics: what the
		// interval saved, and what it means for how stale the plan a moving view produces from is.
		uint64_t plan_refresh_skips = 0;
		// The largest batch any production pass of this session handed to the pool. The acceptance probe
		// reads it against the live tier (`avt_batch_max`); it is a MAX and never reset, so one oversized
		// batch shows up whenever it happened.
		int batch_peak = 0;
		int late_pages = 0;
		int late_worst_us = 0;
		// Session totals of the page publish: wall time inside `_avt_produce_page()` and the pages it
		// published. Their ratio is the per-page cost the motion rate multiplies, and it stays as a
		// diagnostic because a view moving continuously is the case that number decides.
		uint64_t page_us_sum = 0;
		uint64_t page_count_sum = 0;
		// The same publish split into the four things it spends the per-page time on, as session sums.
		// The live readings describe the last pass only, and a moving view's cost is a mean over
		// thousands of pages, so the parts have to be summed to be attributable at all.
		double request_sum_ms = 0.0;
		double invalidate_sum_ms = 0.0;
		double payload_sum_ms = 0.0;
		double queue_sum_ms = 0.0;
		// Queue time split between typed page-record publication and the baker handoff.
		double queue_record_sum_ms = 0.0;
		double queue_bake_sum_ms = 0.0;
	};
	Terrain3DAVTCost avt_cost;
	// Main-thread cost of one VT section of the physics tick, in milliseconds, and the
	// worst frame since the terrain was created. `svt_cpu_ms` is the far-field demand
	// pass inside that section, so a peak can be attributed to one of the two views.
	double vt_cpu_ms = 0.0;
	double vt_cpu_peak_ms = 0.0;
	double svt_cpu_ms = 0.0;
	// Per-tick phase timings. vt_topup_ms is the compatibility report key for residual
	// bookkeeping between SVT and bake, not a separate production pass.
	double vt_service_ms = 0.0;
	// The ring phase. It is reported beside the service's phases but it is not one of them: no ring
	// touches the shared pool, so this is the only phase that is pure production.
	double vt_clipmap_ms = 0.0;
	double vt_clipmap_setup_ms = 0.0;
	double vt_clipmap_worker_ms = 0.0;
	double vt_clipmap_loop_ms = 0.0;
	double vt_clipmap_arm_ms = 0.0;
	double vt_clipmap_consume_ms = 0.0;
	double vt_clipmap_bake_ms = 0.0;
	double vt_clipmap_uniform_ms = 0.0;
	double vt_clipmap_schedule_ms = 0.0;
	double vt_clipmap_sync_update_ms = 0.0;
	double vt_clipmap_detail_update_ms = 0.0;
	bool vt_clipmap_detail_deferred = false;
	// Consecutive ticks the detail pump was deferred to the ring's consumption. The deferral's intent
	// is one tick's handoff; without a bound it starves the pump for the whole of a sustained move,
	// which is the 12 m field a fragment reads while the ring's own levels only reach metres.
	int vt_clipmap_detail_deferred_ticks = 0;
	double vt_avt_ms = 0.0;
	double vt_svt_ms = 0.0;
	double vt_topup_ms = 0.0;
	double vt_fade_ms = 0.0;
	double vt_bake_ms = 0.0;
	// Worst frame for each demand pass since the terrain was created, so a peak in
	// `vt_cpu_peak_ms` can be attributed to one view without a profiler.
	double vt_avt_peak_ms = 0.0;
	double vt_svt_peak_ms = 0.0;
	// Soft per-phase CPU budget in milliseconds; zero disables it. Each physics phase
	// re-arms its deadline. Explicit update_surface_vt()/update_surface_svt() calls use
	// the caller's page count and are not time-budgeted.
	real_t vt_frame_budget_ms = 0.0f;
	// Absolute deadline of the tick that is running, or 0 when the caller is not the
	// physics tick. Every phase that can stop between two units of work reads it.
	uint64_t vt_tick_deadline_us = 0;
	// True during the physics VT section: worker wakes flush once at its end.
	// Direct demand calls flush their own wakes via _flush_source_wakes().
	bool vt_tick_active = false;
	// ---- 5. planner scratch: capacity owned by this struct so a plan tick reuses it instead of
	// reallocating. Staged near-field planner scratch: the scan and the hierarchy the chain's
	// phases hand each other. The chain itself runs in one pass; see _update_sector_avt. ----
	Terrain3DAVTSectorScan avt_pending_scan;
	Terrain3DAVTHierarchy avt_pending_hierarchy;
};

#endif // TERRAIN3D_VT_STATE_H
