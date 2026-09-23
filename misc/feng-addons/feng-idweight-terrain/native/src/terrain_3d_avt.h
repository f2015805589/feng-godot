// AVT runtime data types.
//
// These are plain records shared by the terrain node, the demand planner in
// terrain_3d_sector_avt.cpp and the shared physical residency in
// terrain_3d_virtual_texture.h. They live here, rather than nested inside
// Terrain3D, so a planner step can be a free function with a readable signature
// instead of a lambda closing over a 500 line function's locals.
//
// No algorithm belongs in this file.

#ifndef TERRAIN3D_AVT_TYPES_H
#define TERRAIN3D_AVT_TYPES_H

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_set>
#include <vector>

#include "terrain_vt_request_priority.h"

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

// What the near field's feedback switch may answer a page it cannot serve from. The switch itself
// is `surface_vt_feedback` (the shader's `_avt_feedback`): it decides whether a miss recovers at a
// resident coarser level of the near field's own hierarchy instead of rendering the diagnostic.
// This is the *source* that recovery may read.
//
//   COARSE - the near field's own hierarchy only: the sector's local mip chain and, above it, the
//            independent dense fallback grid. This is the shipped contract, and the one
//            `vt_fallback.gd` pins: a selected AVT miss never crosses into the far field.
//   SVT    - the far field's own sparse virtual texture, a second page path with its own atlas,
//            its own indirection and its own residency.
//
// Only a *cold* page uses the second source - the pages of a cut's view that the burst has not
// produced yet - so the switch's steady meaning is unchanged whichever source it names. See
// `_avt_cold_svt_source` in the shader and `Terrain3D::set_avt_feedback_source()`.
constexpr int AVT_FEEDBACK_SOURCE_COARSE = 0;
constexpr int AVT_FEEDBACK_SOURCE_SVT = 1;

// What a page plan is a function of: the predicted camera transform, the projection, the viewport// and the settings that size the plan. A fixed-size value rather than a byte array, because it is
// built, copied and compared on every tick of a moving view and an allocation per tick was the
// largest single thing that build cost. `_avt_plan_state()` fills it in the order the component
// diagnostic numbers (9 basis, 3 origin, 16 projection, 4 viewport, then the scalars).
constexpr std::size_t TERRAIN_AVT_PLAN_BASIS_OFFSET = 0;
constexpr std::size_t TERRAIN_AVT_PLAN_ORIGIN_OFFSET = 9;
constexpr std::size_t TERRAIN_AVT_PLAN_PROJECTION_OFFSET = 12;
constexpr std::size_t TERRAIN_AVT_PLAN_VIEWPORT_OFFSET = 28;
constexpr std::size_t TERRAIN_AVT_PLAN_SCALARS_OFFSET = 32;
constexpr std::size_t TERRAIN_AVT_PLAN_KEY_SIZE = 64;
using Terrain3DAVTPlanKey = std::array<double, TERRAIN_AVT_PLAN_KEY_SIZE>;

static_assert(TERRAIN_AVT_PLAN_ORIGIN_OFFSET == TERRAIN_AVT_PLAN_BASIS_OFFSET + 9);
static_assert(TERRAIN_AVT_PLAN_PROJECTION_OFFSET == TERRAIN_AVT_PLAN_ORIGIN_OFFSET + 3);
static_assert(TERRAIN_AVT_PLAN_VIEWPORT_OFFSET == TERRAIN_AVT_PLAN_PROJECTION_OFFSET + 16);
static_assert(TERRAIN_AVT_PLAN_SCALARS_OFFSET == TERRAIN_AVT_PLAN_VIEWPORT_OFFSET + 4);
static_assert(TERRAIN_AVT_PLAN_SCALARS_OFFSET < TERRAIN_AVT_PLAN_KEY_SIZE);

inline Vector3 avt_plan_key_forward(const Terrain3DAVTPlanKey &p_key) {
	return Vector3(
			-float(p_key[TERRAIN_AVT_PLAN_BASIS_OFFSET + 2]),
			-float(p_key[TERRAIN_AVT_PLAN_BASIS_OFFSET + 5]),
			-float(p_key[TERRAIN_AVT_PLAN_BASIS_OFFSET + 8]));
}

inline Vector2 avt_plan_key_origin_xz(const Terrain3DAVTPlanKey &p_key) {
	return Vector2(
			float(p_key[TERRAIN_AVT_PLAN_ORIGIN_OFFSET]),
			float(p_key[TERRAIN_AVT_PLAN_ORIGIN_OFFSET + 2]));
}

// A key that matches nothing, for a view that has no plan key yet or whose key was invalidated.
// NaN is its own inequality, which is the semantics wanted: an invalidated key never compares
// equal to the key that replaces it, so the next tick plans. `is_valid_avt_plan_key()` is its
// reader; the value form exists so a member can be initialized with it, and the in-place form is
// what a settings change uses.
inline Terrain3DAVTPlanKey invalid_avt_plan_key() {
	Terrain3DAVTPlanKey key;
	key.fill(std::numeric_limits<double>::quiet_NaN());
	return key;
}
inline void invalidate_avt_plan_key(Terrain3DAVTPlanKey &r_key) {
	r_key = invalid_avt_plan_key();
}
inline bool is_valid_avt_plan_key(const Terrain3DAVTPlanKey &p_key) {
	return !std::isnan(p_key[0]);
}

// The world size of one demand cell. The scan that fills cells, the planner that walks them and the
// shader's sector arithmetic all have to agree on this number, and they are in three files, so it
// lives beside the record it describes instead of in one of its readers.
constexpr float AVT_SECTOR_WORLD = 64.f;

// How far demand leads the footprint that asks for it. It is a factor on a density, not a distance:
// 1.25 asks for the level a quarter finer than the one the footprint selects, which is what makes an
// asynchronous production land before a normal mip transition needs it. The scan applies it when it
// picks a cell's wanted size and the planner applies it when it picks a page's density, so it is
// shared for the same reason the cell size is.
constexpr float AVT_DEMAND_DENSITY_MARGIN = 1.25f;

// A view whose sampled plan has almost no content is *cold*: a snap turn, a teleport, a cut, the
// first frames of a session. The shader draws such a view through the independent dense fallback,
// which is one texel per metre - a flat smear at a 1080p pixel footprint - and the steady allowance
// fills the plan over tens of ticks (measured: `vt_project_lifetime_probe.py --motion snap` at
// 1920x1080 needs ~97 ticks to clear 90% of the textured ground against 752 sampled pages at eight
// pages a tick). A cold view is therefore served by a bounded burst instead: while it is armed the
// near field takes `avt_burst_allowance()` pages a tick and the producer's frame budget is raised to
// match, so the plan that the image is actually shading is filled in the few ticks the user allows
// rather than over a second. The burst is bounded in ticks and in pages, and it is the same work at
// a higher rate - no page is asked for that the steady plan did not name already.
//
// The threshold is a fraction of the *sampled* plan, not of the pool: a moving view that is merely
// streaming keeps most of its sampled set resident, so it never arms the burst, while a cut leaves
// almost none of it.
constexpr float AVT_COLD_BURST_MISSING_FRACTION = 0.25f;
// How many ticks a cold view is served at the burst rate. Four is the window the reference project
// asks for; six leaves the ramp a tail to finish on.
constexpr int AVT_COLD_BURST_TICKS = 6;
// How many pages one cold episode may produce at the burst rate, as a multiple of the plan it is
// filling, so a plan the pool cannot serve - a deliberately oversubscribed one, a pressure fixture -
// cannot hold the burst open forever. It is not a second expiry timer: the burst ends on the pass
// that finds the view served, and this only bounds how long "unserved" is allowed to mean "still
// worth a burst". Expressed in pages rather than ticks because the rate is per *tick* and the window
// being judged is in displayed frames: measured on the reference project, seven physics ticks run
// per displayed frame during a cut, so a tick budget meant to cover the window expired inside three
// frames and the burst's own rate stopped applying exactly when the remaining pages needed it.
constexpr int AVT_COLD_BURST_PAGE_BUDGET_MULTIPLE = 2;
// The burst rate as a multiple of the configured page budget, and its ceiling. The ceiling is what
// bounds the transient on the main thread: one page costs a source poll, a pool write and a bake
// dispatch, and the measured main-thread cost of a pass is ~0.05 ms a page. The multiple is the
// rate, and the rate is what the encoder ring is sized from (`_derive_encode_ring_pages()` is the
// budget times the readback latency), so it is also the number that decides how many pages a frame
// can finish.
//
// The end of the chain is the ring's own ceiling, `_page_count / 2`, so the budget that reaches it
// is `_page_count / 4` - 256 pages a tick for the reference project's 1024 slot pool, which is 256
// finished pages a frame. That is the number this multiple is set from, and it is a reading rather
// than a preference: the transition's own criterion is nearly converged ground, the reference
// project's first 180-degree cut plan is 752 pages, and at 256 a frame the plan is resident inside
// the window it is judged on. Six (96 a frame) left the ground flat for twenty frames, eight (128)
// for seven, twelve (192) for six; each step was measured, and the last two were still bounded by
// pages the shader could not resolve rather than by the rate they arrived at.
constexpr int AVT_COLD_BURST_FACTOR = 16;
constexpr int AVT_COLD_BURST_PAGES_MAX = 384;
// The arrival blend a cold view's burst switches off, in ticks. A page that has arrived but is still
// ramping is drawn as the level it replaced, and on a cold view *every* page of the view arrives in
// the same few frames: the blend that hides one page's step behind its resident ancestor is then
// applied to the whole footprint at once, so the ground stays at `1 - fade` of the level it left
// until the ramp of the last page has run. Measured on the reference project's first 180-degree cut:
// with the shipped twelve tick ramp the picture was still at 0.39 of the settled gradient energy
// four frames after every page of its 752 page plan was resident, and reached the transition's own
// threshold only at frame seven; with the blend off it was at 1.41 of settled the frame after the
// cut and at the threshold by frame one. Zero is therefore the cold value: the pages of a view
// nothing had produced for are drawn as themselves the moment they land, which costs the one thing
// the blend exists for - a step where an arrived page meets one still missing - and buys the whole
// of the window the transition is judged on. The trade is a *transient* one and it is bounded by the
// episode: `vt_page_fade_frames` is untouched, a settled or ordinary moving view ramps at its full
// length, and the ramp state is left finished so the blend does not reappear mid-arrival when the
// episode ends. See `_update_vt_page_fade()` and `_update_sector_avt()`.
constexpr int AVT_COLD_BURST_FADE_FRAMES = 0;
// What the near field's production pass may ever be handed in one tick. The steady path never asks
// for more than `vt_pages_per_update`; this is the ceiling the burst is admitted under, and it is
// the same number the source queue window is raised to while the burst runs.
constexpr int AVT_PAGE_BUDGET_CEILING = 384;
// How many of the previous view's pages the plan's retention window may hold. The window is what
// makes a level the view has just left a level it can come back to: a page it holds stays named by
// the plan, stays demanded in the pool and keeps its address, so returning to its level is a
// resolve that finds a resident ancestor instead of a source read, a bake and an arrival ramp. It
// is spent rather than free - every page it holds is a page the current walk cannot add - and the
// walk's tail is the *finest* page of each chain, so the window is exactly as many pages as it
// costs to keep: measured on the reference project, reserving 64 of a 768 page budget cost 48
// pages of the finest content and moved the gradient reading at a given residency by ~0.15 of
// settled, while 16 costs nothing measurable. Which pages it holds is the other half of the
// decision and is not a budget question at all: `_avt_install_or_reuse_plan()` orders the
// candidates finest first, because the coarse end of a chain is what the always-resident fallback
// ladder already answers for and the fine end is what costs a rebuild.
constexpr int AVT_RETAIN_PAGES_MAX = 16;

// The near field's share of a cold view's burst, and 0 when no burst is running. The burst never
// reduces the steady allowance and it is off in the diagnostic direct-material mode, where the
// budget is deliberately pinned to four pages.
inline int avt_cold_burst_allowance(const int p_page_budget, const int p_steady_allowance, const int p_ticks_left) {
	if (p_ticks_left <= 0) {
		return 0;
	}
	return CLAMP(p_page_budget * AVT_COLD_BURST_FACTOR, p_steady_allowance, AVT_COLD_BURST_PAGES_MAX);
}

// A position that crosses this fraction of the near field no longer belongs to the old
// retention window. Both motion sampling and plan refresh use this one contract.
constexpr float AVT_MOTION_SPATIAL_DISCONTINUITY_REACH_FRACTION = 0.125f;
constexpr float AVT_MOTION_SPATIAL_DISCONTINUITY_MIN_METRES = 8.f;

inline float avt_motion_spatial_discontinuity_distance(const float p_reach) {
	const float near_reach = std::max(64.f, p_reach);
	return std::max(AVT_MOTION_SPATIAL_DISCONTINUITY_MIN_METRES,
			near_reach * AVT_MOTION_SPATIAL_DISCONTINUITY_REACH_FRACTION);
}

// One page the planner wants resident: the virtual block that owns it, the mip
// inside that block, the page coordinate and the world rectangle it covers.
struct Terrain3DAVTPageRequest {
	Vector2i owner;
	int mip = 0;
	int x = 0;
	int y = 0;
	Rect2 rect;
	// The worker and producer consume one shared order: roots, current visible
	// bands, then optional apron/retained work.
	TerrainVT::PageRequestPriority priority;
	// Plan epoch this request was last visible in. A grazing page can disappear
	// for one plan and reappear immediately; the epoch lets the next plan keep
	// recently requested work instead of cancelling and re-preparing it.
	uint64_t last_visible_plan = 0;
};

// upgrades use independent high-resolution local blocks; the dense chain starts at mip 1.
inline Vector2i avt_coarse_owner() { return Vector2i(INT32_MIN, INT32_MIN); }
struct Terrain3DAVTCoarseImage {
	Vector2 origin;
	Vector2 center;
	float page_world = 1.f; // World span of a mip 1 page.
	int size = 0; // mip 1 grid width, power of two.
	int levels = 0; // Dense table mip limit plus one; mip 0 in this reserved block is unused.
	Vector2i block; // Base (mip 0) coordinate in the shared page table.
	std::vector<Terrain3DAVTPageRequest> pages;
};

// A camera/configuration key and the page set planned for it. The planner runs
// on a worker thread, so only `ready` is synchronized; the payload is written
// before it is published and read after it is observed.
struct Terrain3DAVTRefinement {
	std::atomic<bool> ready{ false };
	Terrain3DAVTPlanKey key = {};
	std::vector<Terrain3DAVTPageRequest> pages, warm;
	float finest = 0.f;
	int denied = 0, roots = 0;
	// Integer quality coarsening selected by the worker when the visible hierarchy
	// cannot fit the current near-field budget. The material applies the same bias to
	// its derivative footprint, so a page kept by this plan is the page the shader
	// selects while the pool is under pressure.
	int mip_bias = 0;
	// Leading entries of `pages` that the current image actually samples, as opposed
	// to the speculative apron appended after them. Production diagnostics count a
	// missing page among these as a page the view is shading without content.
	int sampled = 0;
	// The residency the plan was budgeted against. The retention window is appended to the
	// completed plan, so the installer needs the budget to keep the total inside it.
	int budget = 0;
	// The plan's rate term, as derived and as spent. `tail_cap` is the whole term - the pages the
	// installed plan may hold beyond the ones the image samples - and `retain_cap` is what is left
	// of it for the retention window the installer appends after the refinement walk has taken its
	// apron. Both are bounded by what one refresh window can produce
	// (`_avt_tick_allowance() * avt_plan_refresh_frames`), not by what the pool can hold. See
	// `PlanInput::tail_cap` and `docs/vt_reference_avt_alignment.md` section 7.7.
	int tail_cap = 0;
	int retain_cap = 0;
	// The plan's composition by level, over the pages above: `level_mips` is a histogram of the
	// local mip of every 64 m sector page the plan holds (index 0 = the finest a block can address,
	// the last index = the block's whole span), and `world_pages` counts the pages belonging to a
	// world node above the sectors. The fine entries are what a fragment samples and the coarse
	// ones are the fallback ladder above them, so the two are the residency a shorter chain could
	// give back - the question "does the fallback ladder cost slots" answered with the plan itself.
	PackedInt32Array level_mips;
	int world_pages = 0;
	// Pages the plan holds for cells the view did not sample. These are what keep a cell beside the
	// frustum's edge from being drawn as one whole-cell page: before refinement followed the
	// distance's demand rather than the view's answer for the cell, this was nothing but whole-cell
	// roots, and a cell at the edge was a 0.25-1 m per texel patch next to a millimetre neighbour.
	int invisible_cell_pages = 0;
	uint64_t submitted_us = 0, elapsed_us = 0;
};

// A virtual block that stays allocated across plans, with the hierarchy level
// that gives it its world span.
struct Terrain3DAVTCachedAddress {
	Vector2i location;
	Vector2i owner;
	int level = 0;
	int resolution_level = 0;
	float logical_pages = 1.f;
};

// One demand cell: a 64 m world sector, or one node of the hierarchy above it.
struct Terrain3DAVTSector {
	Vector2i location;
	Vector2i owner;
	int level = 0;
	int wanted = 1;
	int size = 1;
	// Whether the cell is on screen this plan. Off-screen cells still get
	// addresses and warm pages, but never compete with visible demand.
	bool produce = true;
	float distance = 0.f;
	Vector2 heights;
	int resolution_level = 0;
	float logical_pages = 1.f;
};

// What one scan of the resident regions produced: the demand cells and the
// world sector bounds they cover.
struct Terrain3DAVTSectorScan {
	std::vector<Terrain3DAVTSector> visible;
	int world_x0 = 0, world_y0 = 0, world_x1 = 0, world_y1 = 0;
	bool has_world = false;
	Terrain3DAVTCoarseImage coarse;
	int budget = 0;
};

// The sorted working set a plan is built from, plus the coarse root level and
// the physical page budget it has to fit.
struct Terrain3DAVTHierarchy {
	std::vector<Terrain3DAVTSector> working; // Coarse roots first, then the 64 m cells.
	std::vector<Terrain3DAVTSector> leaves; // The 64 m cells only, near to far.
	std::unordered_set<uint64_t> owners; // Owner keys that produce this plan.
	int root_level = 1;
	int coarse_roots = 0; // Distinct coarse root cells.
	int budget = 0; // Physical pages the near field may use.
	bool directory_dirty = false;
	// How many sectors had their virtual block size raised by the sync that consumed this working
	// set. `_avt_sync_address_directory()` only ever grows one (`previous_size < sector.size`) or
	// registers it for the first time, so this counts the one event that re-addresses a whole
	// sector's pages at once. P0e's `plan_rescaled` is 0-75 addresses a generation; the pair says
	// whether that is this growth or the refinement walk reaching a new mip by itself.
	int size_grows = 0;
};

// One fill pass over a published plan. The pass is filled in observable stages -
// classify the plan, retain, prime sources, fill visible, fill idle prefetch,
// commit - so the caller can read each stage instead of tracking locals across
// 120 lines. `protected` pins every slot the pass touched until the commit, so
// the pool cannot evict a page that has just been written.
struct Terrain3DAVTProducePass {
	std::vector<const Terrain3DAVTPageRequest *> missing; // Planned pages with no physical slot yet.
	std::vector<int> protected_slots;
	// Index of the first entry of `missing` this pass has not attempted. The source queue is
	// primed from here, so the refill after a production submits the pages *behind* the ones
	// just produced instead of re-submitting those.
	size_t missing_next = 0;
	uint64_t allocation_us = 0, payload_us = 0, queue_us = 0;
	// `allocation_us` split into the two things it covers, because they have different
	// fixes: asking the pool for a slot (the allocator's own cost) and clearing the slot's
	// content before the new page is written (the producer's).
	uint64_t request_us = 0, invalidate_us = 0;
	int produced = 0, prefetched = 0;
	bool prefetch_pending = false;
	// Diagnostics over the sampled prefix of the plan: pages the current image
	// samples, how many of them have no content yet, and how many are already being
	// produced. A visible miss is what the shader draws as the missing-page material.
	int sampled_plan = 0, sampled_missing = 0, sampled_pending = 0;
	// Sampled pages that have been demanded for at least one motion lead without
	// content, and the age of the oldest one. With a lead the plan is predictive, so
	// only these are what the image being rendered actually shows as a miss.
	int sampled_late = 0;
	int late_worst_us = 0;
	// Why a planned page was not produced this pass: its source job was not ready yet
	// (the workers are behind) or the pool handed out no slot (residency is saturated).
	int source_wait = 0, slot_wait = 0;
	// The fallback tier's own residency, measured against its plan. This tier is the one the
	// addressing rules make a guarantee rather than demand: a fragment no upgrade covers resolves
	// through it, so a cell of it that is not resident is a fragment with no owner. The pair is the
	// reading that decides whether the guarantee needs a reservation - `plan` is what the plan holds
	// and `ready` is how much of it has content, so a settled view whose `ready` is short of `plan`
	// is the tier being starved, and an `evict` count that moves with it says by whom.
	int fallback_plan = 0, fallback_ready = 0;
	// Upgrade pages the plan holds whose own level is at or above the level the fallback takes over
	// at: pages no fragment asks the upgrade path for. The plan and the shader's read order derive
	// from one number by rule R3, so this is the reading that says they agree.
	int upgrade_above_level = 0;
};

#endif // TERRAIN3D_AVT_TYPES_H
