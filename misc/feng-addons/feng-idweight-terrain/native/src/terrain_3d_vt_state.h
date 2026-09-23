// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_STATE_H
#define TERRAIN3D_VT_STATE_H

// Every virtual texture field Terrain3D owns, in one struct.
//
// The node's own state (regions, mesh, ocean, CDLOD, targets) stays in terrain_3d.h;
// this is the shared VT service, the near-field AVT and the far-field SVT together,
// so "what does the VT layer remember" is one greppable unit instead of a hundred
// fields interleaved with the renderer's. No algorithm lives here: the fields are plain
// aggregates, and the small structs below carry only the operations that keep their own
// invariant.
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
//   * the page-arrival fade is `Terrain3DVTFade` below, because its parts move together: the three
//     per-slot vectors are the same length by construction, and the texture is rebuilt whenever
//     that length stops matching the pool's page count, carrying the counters into it so an
//     arrival that is mid-ramp is not finished as a step. Its methods are the only place a length
//     changes, which is what keeps a new field from being forgotten by a rebuild or a teardown.
//   * the standing plan is `Terrain3DAVTPlan` below: the key, the selection with its sampled
//     length, the prefetch set and the two retention flags. `install()` is the one way a completed
//     plan replaces the standing one, which is what makes forgetting the retention impossible to
//     forget: a stale "already retained" flag leaves the source queue holding work the new plan
//     does not name.
//   * the settled shortcut is `Terrain3DAVTSettled` below: the driver's verdict, the residency
//     revision an idle pass verified, the set it verified and whether the idle statistics already
//     describe that run. `can_run()` is the only place the verdict is read, and `fall_through()` /
//     `unverify()` are the two ways it is dropped - a full pass, and a newly submitted plan.
//   * the pool is `Terrain3DVTPool` below: the published capacity, the rebuild generation and the
//     growth wait are one owner because the capacity only reaches the two views through the
//     generation, and only a rebuild bumps it.
//   * the bound material is `Terrain3DVTBoundMaterial` below: both tiers' arrays are replaced as one
//     bundle, so the near field's albedo alone does not identify the set, and `matches()` is the
//     only place that identity is decided.
//   * the far field's bake is `Terrain3DSVTBakeJob` below: the queue, the slots protected while
//     their cell bakes, the cell in flight and the job-scoped counters are one job, serialized by
//     `explicit_job`. `busy()` is the one predicate the rest of the addon pauses on, and `begin()`
//     is the only place the counters are reset, so an automatic job cannot replace the counters the
//     dock and the tests read as "this bake completed".
//   * the far field's root plan is `Terrain3DSVTRootPlan` below: the key, the pinned pages, the
//     settled flag and the coverage move together, and `matches()` is the only way to ask whether a
//     walk can be skipped - a key that still matches while a walk was incomplete is a plan that
//     never pinned, which is the failure the flag exists to prevent.

#include <algorithm>
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
#include "terrain_3d_clipmap.h"
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

// Which source answers "what level is this page wanted at" for the near field's *region* addressing
// (the legacy path `_surface_vt_mip_for_page()` resolves; the sector path has its own footprint rule).
//
// The two are **layered, not alternatives**: the CPU rule always answers for the demand the lead
// predicts, and the projection pass *refines* that answer while it has a result. Naming them is what
// makes one distinction explicit, because a caller has to get it right and a single boolean cannot
// express it: `_vt_projection_demand_enabled()` is the setting - "may the pass run at all" - and
// `_vt_demand_source()` is this frame - "does it answer now". Both used to be `surface_vt_feedback_enabled`
// read in two files with two different meanings, and one of them also re-tested `has_result()`.
enum class TerrainVTPageDemandSource {
	// The distance rule the page geometry implies, plus the motion/turn lead.
	CPURule,
	// `Terrain3DVTFeedback`'s projection: the level that puts about one page texel on one pixel, with
	// off-screen and sub-pixel pages culled. It answers between passes too - the standing result is
	// what the interval amortises the readback over.
	Projected,
};

// The page-arrival fade's whole state: the per-slot ramps, the FIFO that orders the armed
// arrivals, the one-texel texture the shader reads, and the counters the dock and the tests
// report. One struct rather than fourteen sibling fields, because its parts are one fact each:
// the three per-slot vectors are the same length by construction - a slot index past them has to
// grow all of them, and growing one alone writes past the end of the others, which took three
// suites down with no output before it was found - and the texture is rebuilt whenever that
// length stops matching the pool's page count. The operations that change a length are methods
// here, so a field added below is grown and reset in one place instead of four.
//
// See terrain_3d_vt_fade.cpp for what the pass does with them; this file holds no algorithm.
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

// The shared pool's identity and its growth handshake: the capacity already published to both
// views, the rebuild generation, and the frame a requested growth has been waited on. They are one
// owner because a capacity change only reaches the two views through the generation, and that is
// only bumped when the pool is actually rebuilt - which is why a change that does not invalidate
// page content must leave it alone, as a test asserts.
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

	// The producer's larger arrays arrived and the views were grown: this is the published capacity
	// and the wait is over. **No generation bump, because the generation is what tells a consumer to
	// throw its plan away, and re-planning is the expensive half of the loss.** Growth does release
	// every resident page - the atlas is one Texture2DArray and `ensure_layers()` recreates it blank
	// when its layer count changes, which is why `Terrain3DVTPagePool::grow()` evicts every used slot -
	// but what the consumers keep is their addresses, their source jobs and their completed plans, so
	// they re-produce the same pages instead of re-deriving which pages they want. The far field's own
	// root verification (`_svt_plan_roots()` checks every pinned root is still published and still has
	// content) is what catches the released pins; without it this would have to be bumped, and a bumped
	// generation costs a root pass of about 200 ms (section 7.7.8). Measured in section 7.7.10: in the
	// probe's normal session the view's capacity grows 256 -> 512 while this generation stays put, and
	// `evict_count` jumps by 355 in the interval that contains it.
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
// its sampled prefix and its prefetch set, plus whether the source queue has already been retained
// against this plan. One owner because replacing the plan has to forget that retention: retention
// is one set operation over the whole plan, so a stale "already retained" flag leaves the source
// queue holding work the new plan does not name.
struct Terrain3DAVTPlan {
	// The key of the chain that produced this selection. Deliberately left stale while the refresh
	// interval holds a change: the plan describes the view a lead ahead, and re-deriving it every
	// tick is the cost that interval exists to avoid.
	Terrain3DAVTPlanKey key = invalid_avt_plan_key();
	std::vector<Terrain3DAVTPageRequest> pages;
	// Length of the sampled prefix of `pages`. Everything after it is the speculative apron, which
	// is allowed to lag without the view showing a miss.
	int sampled = 0;
	std::vector<Terrain3DAVTPageRequest> prefetch;
	// Whether the source queue was already retained against this plan, and whether that retention
	// included the prefetch set. A pass that would repeat the previous wanted set returns early
	// instead of repeating 250 map lookups to reach the state the last pass already reached.
	bool retain_applied = false;
	bool retain_with_prefetch = false;

	// The retention no longer describes this selection: a plan was replaced, or the addresses it
	// resolved to were remapped under it. The next retain pass re-applies it.
	void forget_retention() {
		retain_applied = false;
		retain_with_prefetch = false;
	}
	// Install a completed plan: its selection, its sampled length and its prefetch set, and forget
	// the retention, because this is a new wanted set.
	void install(std::vector<Terrain3DAVTPageRequest> &&p_pages, const int p_sampled,
			std::vector<Terrain3DAVTPageRequest> &&p_prefetch) {
		pages = std::move(p_pages);
		sampled = p_sampled;
		prefetch = std::move(p_prefetch);
		forget_retention();
	}
	// Whether the queue already holds this exact wanted set.
	bool retained(const bool p_with_prefetch) const {
		return retain_applied && retain_with_prefetch == p_with_prefetch;
	}
	void mark_retained(const bool p_with_prefetch) {
		retain_applied = true;
		retain_with_prefetch = p_with_prefetch;
	}
	// A page-pool rebuild invalidates every address this selection resolved to, so the key and both
	// selections go. The sampled length and the retention flags are left alone: no pass reads them
	// without a resident plan, and the next install overwrites them.
	void forget() {
		invalidate_avt_plan_key(key);
		pages.clear();
		prefetch.clear();
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

// The far field's cell bake: the cells waiting to be baked, the published slots protected while
// their cell is in flight, the cell being baked right now, the job-scoped counters the dock, the
// inspector and the tests read as "this bake completed", and the region edits waiting for the
// auto-bake debounce. One owner because a bake is serialized - an automatic job must not start
// while an explicit one is in flight, or the counters would be replaced mid-run - and because the
// queue, the protected slots and the cell in flight are three states of one job rather than three
// independent lists.
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

	// Which method carries which channel group, in which distance band. This is the *only* input
	// to what the layer assembles: a view object exists because a cell selected its method, an
	// array family is published because a group samples it, the material's shader carries a method's
	// arm because a cell asked for it, and a pass runs because its service was selected. The default
	// is the shipped architecture written in this vocabulary - near material on AVT, far material on
	// SVT, height direct in both bands - so a scene that never writes a cell loads unchanged.
	// `TerrainVT::DeliveryMatrix` holds the values and the three questions asked of them; see
	// docs/vt_delivery_assembly.md for the channel inventory and the assembly rule.
	TerrainVT::DeliveryMatrix delivery;
	// The two read-only editor previews, counted. `*_calls` is how many times one was asked and
	// `*_computed` how many of those asks did the work; the two differ exactly when no cell selects
	// the method, where the query refuses before its scan. That refusal is the readable half of the
	// assembly rule ("a method no row selects is never built") and counting it is what makes it a
	// measurement instead of a claim. `mutable` because the queries are const and these record what
	// they were asked, not state they set.
	mutable uint64_t avt_preview_calls = 0;
	mutable uint64_t avt_preview_computed = 0;
	mutable uint64_t clipmap_preview_calls = 0;
	mutable uint64_t clipmap_preview_computed = 0;
	// ---- The clipmap delivery's own settings, one ring per channel group ----
	// A group no cell delivers by Clipmap has no ring at all: no levels, no texture, no jobs and no
	// budget. `_setup_vt_clipmap()` is the only place one is built, and the assembly rule calls it,
	// so "no clipmap selected" is zero cost rather than a ring that happens to be idle.
	//
	// `size` is texels an axis on every level, `levels` how many levels the ring holds, and
	// `base_world` the metres the finest level covers: level l covers `base_world * 2^l` metres in
	// `size` texels. `budget_texels` is what one ring may produce in one tick, in channel texels;
	// it is not part of the page budget, because the ring does not touch the shared pool.
	int clipmap_size = 256;
	int clipmap_levels = 8;
	real_t clipmap_base_world = 256.f;
	int clipmap_budget_texels = 65536;
	std::unique_ptr<Terrain3DClipmap> clipmap[TerrainVT::GROUP_COUNT];
	// The state stamp of each ring as the shader was last *bound* with, so a change the shader has to
	// follow is one comparison per ring rather than a rebind per tick. See
	// `Terrain3DClipmap::get_state_stamp()` and `Terrain3D::_update_vt_clipmap_arm()`.
	uint64_t clipmap_state[TerrainVT::GROUP_COUNT] = { 0, 0 };
	// Channel texels produced by all rings in the tick that just ran.
	int clipmap_produced_texels = 0;
	// ---- The material group's detail layer, which is the only path to the 1024 texels/m target ----
	// A sparse, demand-resident layer of fine tiles in front of the camera, above the coarse ring and
	// independent of it: the ring keeps its complete, low-density coverage and its fallback, and the
	// detail layer only exists while the material group is delivered by `Clipmap` *and* this switch
	// is on. It owns its own GPU arrays, directory and source pipeline; nothing is allocated when it
	// is not selected, which is the same rule the rings and the two views follow.
	//
	// `detail_density` is the level-0 density in texels per metre - the measurement the layer exists
	// to make - and level `l` is that over `2^l` down to `detail_min_density`. `detail_budget_bytes`
	// is what the whole layer may hold on the GPU; the slot table is *derived* from it, and a budget
	// that cannot afford one ring of tiles turns the layer off with a log rather than allocating
	// something unusable. `detail_demand_radius` bounds the near field the layer sharpens, in metres;
	// beyond it the ring serves.
	// The layer's own switch. **On by default.** Selecting `Clipmap` for the material group is the
	// whole instruction: at the shipped shape the ring alone is 1 texel/m, so leaving the layer off
	// renders the picture a user who asked for 1024 texels/m reads as blur, with no visible control
	// that says why - the switch is not the answer to "why is my near material mushy". The layer is
	// therefore part of what selecting the method means, and a project that wants the ring's own
	// picture turns it off. With it off nothing is allocated: no textures, no directory and no job
	// queue.
	bool detail_enabled = true;
	real_t detail_density = 1024.f;
	// The coarsest detail level. 128 gives four levels (1024/512/256/128) out of the same slot table
	// the three-level shape used. The coarsest level is the cheap one - a tile is `tile_size / 128`
	// metres wide, four times the area of the finest tile per slot - and the demand fit in the
	// manager uses it to keep the whole `demand_radius` covered by the detail layer instead of letting
	// the fringe fall back to the 1 texel/m ring.
	real_t detail_min_density = 128.f;
	int detail_tile_size = 256;
	int detail_directory_size = 128;
	// What the whole layer may hold on the GPU. The finest tiles are ~2 MiB each, so this is what
	// decides how much of the screen footprint rule the near field can actually be served at; the
	// manager fits its level bands to the table, and reports the starved remainder rather than hiding
	// it. 512 MiB keeps the 1024 level over the ground a 1080p view actually reads at the reference
	// pose and still leaves the coarser levels to cover the rest of `demand_radius`.
	int detail_budget_bytes = 512 * 1024 * 1024;
	real_t detail_demand_radius = 12.f;
	real_t detail_texels_per_pixel = 4.f;
	std::unique_ptr<Terrain3DMaterialClipmapDetail> material_detail;
	// The state stamp of the detail arm as the shader was last bound with, so a directory or a
	// validity change is one comparison a tick rather than a rebind. See
	// `Terrain3DMaterialClipmapDetail::get_state_stamp()` and `Terrain3D::_update_vt_detail_arm()`.
	uint64_t material_detail_state = 0;
	// Ticks the detail layer's demand pass ran, and the last pass's requested-tile count and cost.
	int detail_requested_tiles = 0;
	int detail_starved_tiles = 0;
	double vt_detail_ms = 0.0;
	int vt_page_size = 256;
	// The page gutter, in texels each side. It is a *bound*, not a policy: a page asked for more
	// anisotropy than its border can sample reads its own rim instead of the neighbouring ground,
	// which is why `get_avt_anisotropy()` is the request clamped by this number and the two places
	// that used to spell the rule separately now ask that one function.
	//
	// The arithmetic is the anisotropic kernel's own. With the mip selection holding the minor axis
	// at about one texel, a ratio of n spans about n texels along the major axis, so its half-extent
	// is n / 2 and bilinear filtering adds half a texel: `n <= 2 * border - 1`. Five therefore
	// admits the 8x the near field requests by default (`surface_vt_anisotropy`), at
	// `page_size + 2 * border` = 266 stored texels a side. Nine - the value this replaces - was
	// derived from `border - 0.5` and so bought a bound (17x) three times larger than any request
	// the setting can name, for 7.7% more texels on every page of both views. See
	// docs/vt_sampling_review.md.
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
	// True while the shared service was built for the ring's bake alone: no paged tier is selected,
	// so the producer owns the bake shader, the material list and the job buffer but none of the
	// page arrays. A page selected later moves the service to the page bundle (see
	// `_configure_vt_service()`), and a page bundle serves a ring as well, so that is the only
	// direction a rebuild is needed in.
	bool vt_ring_only = false;
	bool vt_materials_dirty = true;
	// Whether a material list has been asked for on behalf of a *ring* already. `_setup_vt_clipmap()`
	// runs on every write to the matrix, and a ring that declares baked layers needs the list published
	// even when no cell takes a page - but asking again is not free: the service answers a publish by
	// telling every ring its baked layers are stale, which queues a whole level per ring. This is what
	// makes that need a first-time one.
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
	Dictionary vt_page_records;
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
	// Cells `_svt_cells_have_persisted_bake()` has examined over the session, and the pages it
	// refused to examine at all. A page-wide scan is a file stat a cell, so the pair is what says
	// whether a pass spent its time asking the disk about a page the disk could not serve
	// (alignment document section 7.7.13: a rebuilt root pyramid used to scan 16 x 3969 cells).
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
	// The near field's requested anisotropic filtering, as a multiplier: 0 follows the viewport's
	// level, any other value is the request. The gutter is the physical bound - a filtering
	// footprint cannot reach past the border texels a page carries - so the number the shader and
	// the CPU footprint both use is `get_avt_anisotropy()`, which is this request clamped by
	// `2 * vt_page_border - 1`. Eight is the default because it is what the default gutter admits.
	int surface_vt_anisotropy = 8;
	// Sector virtual-image resolution tiers; this does not truncate local page-table mips.
	int surface_vt_mip_levels = 3;
	int surface_vt_pages_per_axis = 4;
	// The near field's reach, in metres around the camera. It is the working set's radius: the plan
	// covers the reach plus a sector of margin, and its size follows the area (measured at one fixed
	// pose: 54 sectors and 15 pages at 512 m, 30 and 9 at 384). It shipped at 512, which is what a
	// 256-slot pool reaches under the reference's per-sector guarantee (section 3 of
	// docs/vt_reference_avt_alignment.md), and 384 is where that reference implementation's own reach
	// sits (camera sector +- 6 sectors). The trade is measured in section 7.7.14: the settled plan
	// falls 44% and the per-move churn does not move at all, while the far field - which excludes
	// only `0.75 * this` - takes the band the near field gives up. So this is not a way to make an
	// update faster; it is a way to spend less residency on the ground furthest from the camera.
	real_t surface_vt_distance = 384.f;
	Vector2i surface_vt_region_grid = Vector2i(2, 2);
	int surface_vt_selection_mode = 2;
	Ref<ImageTexture> avt_sector_directory;
	PackedByteArray avt_directory_bytes;
	int avt_directory_mask = 0;
	int avt_root_level = 1;
	Terrain3DAVTCoarseImage avt_coarse;
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
	// The standing plan: the key it was planned for, the page selection, its sampled length and its
	// prefetch set, with the two retention flags that say whether the source queue already holds it.
	// See `Terrain3DAVTPlan` above for why replacing the plan has to forget the retention.
	Terrain3DAVTPlan avt_plan;
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
	// Ticks left of the cold-view production burst, and the rate it is served at. A plan whose
	// sampled set is mostly missing is a view nothing has produced for yet - a snap turn, a
	// teleport, the first frames of a session - and the shader draws it through the one-texel-per-
	// metre fallback, which is a flat smear at a 1080p footprint. The steady allowance fills such a
	// plan over tens of ticks, so the burst serves it at `avt_burst_allowance()` pages a tick for
	// `AVT_COLD_BURST_TICKS` ticks. `avt_burst_peak` and `avt_burst_pages` are what it did: the
	// largest allowance it asked for, and how many pages it produced across the burst.
	int avt_cold_burst_ticks = 0;
	int avt_burst_peak = 0;
	int64_t avt_burst_pages = 0;
	// The rate the producer's frame budget and the source queue window were last set from, so the
	// tick that arms or ends a burst publishes it once instead of every tick. Zero means nothing has
	// published yet, which is what makes the first tick of a session apply the configured budget.
	int avt_page_budget_applied = 0;
	// Whether the shader was last told the view is cold, i.e. that a fragment served only by the
	// independent fallback tier should take the source evaluator instead. It is the shader's copy of
	// `avt_cold_source_fallback`, published with the burst's rate and reported beside it.
	bool avt_cold_source_published = false;
	// Whether a *cut* put the view in the cold state - the burst's own arm. A camera that merely
	// moves never sets it, which is what keeps the burst and the source fallback off every ordinary
	// streaming path. It is consumed by the production pass that finds the view served again.
	bool avt_burst_from_cut = false;
	// Whether the shader should draw a cold view's under-served fragments from the source evaluator.
	// Armed by the cut that creates the cold view and cleared by the pass that has nothing left to
	// fill, so its window is the *serving* one and not the burst's six ticks: the fragment-level
	// handover is the shader's texel tolerance, and this flag only bounds how long that tolerance may
	// apply. See `_avt_cold_source_fallback` in the shader.
	bool avt_cold_source_fallback = false;
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
	// Sampling density belongs to the installed plan, including its capacity LOD.
	float avt_density_scale = 1.f;
	// The settled shortcut: the caller's verdict that the standing plan is this tick's, the pool
	// residency revision an idle pass verified, the resident set it verified and whether the idle
	// statistics already describe that run. See `Terrain3DAVTSettled` above for why they are one
	// owner and which operation moves each of them.
	Terrain3DAVTSettled avt_settled;
	// Page-arrival fade, in ticks. A page that has just arrived is blended against the level
	// it replaced, so a page arrival is a ramp rather than a step - which is what a fast turn
	// makes obvious, because the view then refines in the rectangular grid its pages are.
	// 0 disables it and costs nothing: the shader then reads a settled page on every fetch.
	int vt_page_fade_frames = 12;
	// The fade's buffer, FIFO, texture and counters, in one owner: `Terrain3DVTFade` above holds
	// the fields and the only operations that change their length.
	Terrain3DVTFade fade;
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
	// One mip 0 page covers this many metres.
	real_t surface_svt_page_world = 256.f;
	int surface_svt_page_size = 256;
	// Mirrors `vt_page_border`, which both views share. The far field samples with a plain
	// `textureLod` (no gradients, no anisotropy), so the gutter it carries is for its own mip
	// transitions rather than for a filtering footprint - see docs/vt_sampling_review.md for the
	// shared bound and what a page's border costs both views.
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
	// Which set answers a far-field fragment whose selected page is not resident (H2 in
	// `docs/vt_reference_avt_alignment.md`). 0 is the root pyramid above: one complete level window over
	// the whole addressable domain, so every world position resolves, at a granularity of kilometres
	// per page. 1 is the reference's per-unit guarantee: the coarsest level that covers each *visible* page,
	// requested unconditionally, so the fallback's granularity is the unit the fragment is looking at
	// and a fallback page that lands or leaves changes its own rectangle rather than a continent.
	//
	// The two are alternatives, not layers: both publish into `svt_roots.pages`, so the pin budget,
	// the plan key and the reuse/verify path are the same for either. Default 0 keeps every recorded
	// measurement valid; the policy is switched on numbers, never on preference.
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
	// P0 instrumentation for the world mip cap, kept because H3 step 1 turned what it measured into
	// an assertion. A cap change *was* treated as a content change - every region marked for re-bake
	// and the material's region arrays rebuilt - and these counters said how often that happened and
	// what it cost. Since H3 step 1 it publishes the cap and refreshes the uniform, so
	// `svt_cap_dirty_regions` is the property `vt_svt_coverage` asserts and is zero because the
	// change marks nothing. Read them from `get_vt_settings()`; see
	// docs/vt_reference_avt_alignment.md sections 4/H3 and 7.
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
	// The capacity that decision was made against: the pool left once the pinned roots have taken
	// theirs. Published beside the floor because the floor is a function of it - a reader cannot
	// tell "no pressure" from "plenty of room" without both, and a test that asks about the floor
	// has to fix this number to be asking a question with an answer.
	int svt_detail_capacity = 0;
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
	// kept as a reported key only: the near field used to be run a second time in a "top-up" phase
	// with the budget the far field did not spend, and that pass is gone, so what the residual now
	// measures is the bookkeeping between the far-field phase and the bake - microseconds, never a
	// phase's own cost. See Terrain3D::__physics_process() for why the pass went.
	double vt_service_ms = 0.0;
	// The ring phase. It is reported beside the service's phases but it is not one of them: no ring
	// touches the shared pool, so this is the only phase that is pure production.
	double vt_clipmap_ms = 0.0;
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
