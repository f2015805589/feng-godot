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

// What a page plan is a function of: the predicted camera transform, the projection, the viewport
// and the settings that size the plan. A fixed-size value rather than a byte array, because it is
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
