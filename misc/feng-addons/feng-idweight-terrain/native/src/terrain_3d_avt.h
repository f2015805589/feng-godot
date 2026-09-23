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
// That walk is the reference implementation's recursive mip lookup - a mip-0 entry that is missing
// is answered by the mip-1 entry, and so on to the sector's coarsest page and then to the
// independent dense fallback grid above it - so it is the whole of what a cold page resolves
// through. `vt_fallback.gd` pins the consequence: a selected AVT miss never crosses into the far
// field's independent hierarchy.

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

// The near field's page budget, in two settings and one owner (`Terrain3DAVTPageBudget` below).
//
// The reference implementation this pipeline follows bakes at most sixteen physical pages a frame
// (`RenderingPagePerFrame` in HDRPVirtualTexture's `Constant.cs`) and reaches a converged picture by
// *mechanism* rather than by rate: a virtual image atlas that keeps every sector's entry addressable
// whether or not the view looks at it, an indirection remap that leaves no mip empty across a
// resize, a recursive mip lookup in the sampler, a feedback set that names the pages the view
// samples, and an LRU that holds what the last view used. A pass of this pipeline is one batch, and
// it may never hand more pages to the pool allocator than the live tier allows, whatever view it is
// filling. `avt_batch_pages` and `avt_batch_peak` report what it actually handed over, and the
// acceptance probe reads them to prove the bound holds.
//
// The shipped rate is still the reference's own sixteen, and that is the *stable* tier: a camera
// that is not doing anything violent runs exactly the rate `cb8e06cf80` ran. What is new is that the
// rate is a function of how violently the view changed rather than a constant, because the mechanism
// decides what a converged picture *is*, not how many frames it takes to reach it - and the frames
// are what a snap turn is judged on. The two settings are:
//
//   * `default_pages` (`surface_vt_page_batch_default`): the stable tier, 16. This is the whole of
//     the shipped behaviour and every existing acceptance reading.
//   * `max_pages` (`surface_vt_page_batch_max`): the tier the plugin raises the batch to *by itself*
//     while the camera is moving fast, while the view it is filling is still unserved, or on the
//     tick the motion sampler sees a discontinuity. This is the "over page" the request named - the
//     most a large movement may add - and it is deliberately not a third setting: an `over` quota
//     and a `max` would be two spellings of one number, so the headroom has one knob and one
//     relationship to keep.
//
// The two read as `default <= max <= ceiling`. A configuration with `max == default` has one tier:
// the governor is then inert and the rate is the constant it always was, which is how the shipped
// 16-page behaviour runs through this same code in the acceptance comparison.
//
// The tier is resolved once per tick by `avt_page_budget_update()`, in the file that owns the near
// field's configuration, and read by everything that spends or bounds the rate:
// `_avt_tick_allowance()` (the pass, the producer's frame budget, the source queue window), the
// production pass's own clamp, and the producer's encode ring depth. A setting change therefore
// reconfigures nothing and applies on the next tick, and no game code drives any of it.
// The default `max`: 64, the value the request named. Measured on the snap probe it converges in 7
// displayed frames on the first 180 degree turn where the shipped 16 page batch takes 24 (`auto32`
// 10, `auto64` 7, `auto128` 4), and what it costs is the encode ring's allocation - 128 positions
// instead of the 43 the shipped 16 needs, i.e. 259 MiB of staging against 87 MiB, still inside the
// slot-count invariant the ring answers to (`allocated * 2 <= physical_cache_bytes_uncompressed`).
// A project that would rather have the frames than the memory sets it to 128, which converges in
// 3-5 frames on the same turn at 256 positions and 518 MiB of staging.
constexpr int AVT_PAGE_BATCH_DEFAULT = 16;
constexpr int AVT_PAGE_BATCH_MAX_DEFAULT = 64;

// The most either may be set to, so "raise it while moving" cannot be turned into a stall or an
// out-of-memory by a typo. It is not an arbitrary guard: it is the widest window the rest of the
// path is sized for, so a larger batch could not be served in one pass anyway. `ReadyKeys` and
// `Terrain3DPagePipeline::MAX_QUEUE_CAPACITY` hold 256 keys, and the producer's encode ring is
// capped at `Terrain3DSurfaceBaker::ENCODE_PAGES_MAX` = 256 positions. 256 pages a frame is already
// sixteen times the shipped rate, which is where a value stops being tuning and becomes churn.
constexpr int AVT_PAGE_BATCH_CEILING = 256;

// What the governor reads to decide the tier: the two quantities the motion look-ahead already
// estimates and clamps - the smoothed linear speed in metres per second and the smoothed turn rate
// in degrees per second - so the budget follows the same signal the plan does and the two cannot
// disagree about whether the camera is moving fast. A brisk run or a deliberate turn asks for the
// escalated tier: 24 m/s is 86 km/h and 45 deg/s is a quarter turn a second, both past what a
// walking camera does and below what a vehicle or a flick does.
//
// The two *events* ask for the same tier without any threshold at all, because they mean the same
// thing - a view with no resident pages behind it. A discontinuity is the >25 degree step and the
// working-set cut the motion sampler already detects; `avt_view_unserved` is the same condition seen
// from the production side, a plan that mostly names ground nothing has produced.
constexpr float AVT_BATCH_ESCALATE_SPEED_M_S = 24.f;
constexpr float AVT_BATCH_ESCALATE_TURN_DEG_S = 45.f;

// The hysteresis, and it is the whole reason a jitter does not move the budget: a tier is *held* for
// this long after the condition that asked for it stopped, and only then does it step down, one
// tier per decay interval. So a threshold crossed for a frame or two costs nothing, a snap turn
// keeps the raised rate for the ~15 ticks a 60 Hz frame spends in the hold - which is the ticks the
// view is actually filling - and a settled camera is back at the stable rate about 350 ms after the
// motion ended. The hold is longer than the decay on purpose: the fall is a ramp, not a step.
constexpr uint64_t AVT_BATCH_HOLD_US = 250000;
constexpr uint64_t AVT_BATCH_DECAY_US = 100000;

// The two page-budget tiers, in order. The numeric order is the order the governor compares them in,
// so `wanted > tier` is "escalate" and `wanted < tier` is "decay".
enum class Terrain3DAVTBatchTier {
	Stable = 0,
	Escalated = 1,
};

// The one owner of the near field's page budget: the two settings, the tier they currently resolve
// to, and the hysteresis that moves it. Everything else reads `live_pages()`.
//
// Settings and policy live together because they answer one question - how many pages may this pass
// hand over - and the two must not be able to disagree: `pages_for_tier()` is the only spelling of
// the relationship, so a setter that raises `default` past `max` cannot leave a tier that reads as a
// different number than it was clamped to.
struct Terrain3DAVTPageBudget {
	int default_pages = AVT_PAGE_BATCH_DEFAULT;
	int max_pages = AVT_PAGE_BATCH_MAX_DEFAULT;
	// The most pages the configuration can ever ask for: the escalated tier. This is what the
	// producer's encode ring is sized for at bundle build, because the ring is allocated once and
	// re-admitted per tick - sizing it for the tier of the moment would make the escalation a rate
	// its own staging never had.
	int peak_pages() const {
		return std::min(pages_for_tier(Terrain3DAVTBatchTier::Escalated), AVT_PAGE_BATCH_CEILING);
	}
	int pages_for_tier(Terrain3DAVTBatchTier p_tier) const;
	// The tier in force, which is what every reader of the rate is handed.
	int live_pages() const { return pages_for_tier(tier); }

	// The tier and the hysteresis that produced it.
	Terrain3DAVTBatchTier tier = Terrain3DAVTBatchTier::Stable;
	uint64_t hold_us = 0;
	uint64_t calm_us = 0;
	uint64_t stamp_us = 0;
	// Diagnostics for the acceptance probe's timeline: how many ticks the session spent at each
	// tier, how many times the governor escalated, and the last motion the decision was made from.
	uint64_t ticks = 0;
	uint64_t escalated_ticks = 0;
	uint64_t escalations = 0;
	uint64_t cuts = 0;
	float last_speed = 0.f;
	float last_turn_deg_s = 0.f;
	bool last_discontinuity = false;
	bool last_unserved = false;
};

// `pages_for_tier()` is the tier-resolving half of the owner - the relationship between the two
// settings, spelled once, in the file that owns the near field's configuration. A configuration with
// no headroom (`max <= default`) collapses both tiers onto the default, which is how "auto escalation
// off" is expressed and how the acceptance comparison runs the shipped 16-page behaviour through the
// same governor.

// One tick of the governor: what the motion asks for, against the tier already held, with the hold
// and decay above. `p_delta_us` is the tick's own interval, clamped by the caller.
void avt_page_budget_update(Terrain3DAVTPageBudget &r_budget, bool p_discontinuity, bool p_unserved,
		float p_speed, float p_turn_deg_s, uint64_t p_delta_us);
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
	std::vector<Terrain3DAVTPageRequest> pages;
	float finest = 0.f;
	int denied = 0, roots = 0;
	// Pages the current image samples. Production diagnostics count a
	// missing page among these as a page the view is shading without content.
	int sampled = 0;
	// The residency the plan was budgeted against. The retention window is appended to the
	// completed plan, so the installer needs the budget to keep the total inside it.
	int budget = 0;
	// How many of the previous plan's pages the installer may append after the walk: the
	// retention window. See `AVT_RETAIN_PAGES_MAX`.
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
// classify the plan, retain, prime sources, fill visible, commit - so the caller
// can read each stage instead of tracking locals across 120 lines. `protected`
// pins every slot the pass touched until the commit, so the pool cannot evict a
// page that has just been written.
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
	int produced = 0;
	// Wall time inside `_avt_produce_page()` and how many pages it published. `upload_us` covers
	// the whole stage - the readiness snapshot and the walk included - so the pair is what says
	// whether a moving view's publish cost is per page or per pass. It is a sum over the pass and
	// never reset, and `_produce_sector_avt_pages()` differences two readings into a mean.
	uint64_t page_us = 0;
	int pages = 0;
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
