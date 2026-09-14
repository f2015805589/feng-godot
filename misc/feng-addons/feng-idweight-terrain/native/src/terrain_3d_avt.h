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

#include <atomic>
#include <cstdint>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

// One page the planner wants resident: the virtual block that owns it, the mip
// inside that block, the page coordinate and the world rectangle it covers.
struct Terrain3DAVTPageRequest {
	Vector2i owner;
	int mip = 0;
	int x = 0;
	int y = 0;
	Rect2 rect;
	// Plan epoch this request was last visible in. A grazing page can disappear
	// for one plan and reappear immediately; the epoch lets the next plan keep
	// recently requested work instead of cancelling and re-preparing it.
	uint64_t last_visible_plan = 0;
};

// A camera/configuration key and the page set planned for it. The planner runs
// on a worker thread, so only `ready` is synchronized; the payload is written
// before it is published and read after it is observed.
struct Terrain3DAVTRefinement {
	std::atomic<bool> ready{ false };
	PackedByteArray key;
	std::vector<Terrain3DAVTPageRequest> pages, warm;
	float finest = 0.f;
	int denied = 0, roots = 0;
	uint64_t submitted_us = 0, elapsed_us = 0;
};

// A virtual block that stays allocated across plans, with the hierarchy level
// that gives it its world span.
struct Terrain3DAVTCachedAddress {
	Vector2i location;
	Vector2i owner;
	int level = 0;
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
};

// What one scan of the resident regions produced: the demand cells and the
// world sector bounds they cover.
struct Terrain3DAVTSectorScan {
	std::vector<Terrain3DAVTSector> visible;
	int world_x0 = 0, world_y0 = 0, world_x1 = 0, world_y1 = 0;
	bool has_world = false;
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
};

// One fill pass over a published plan. The pass is filled in observable stages -
// classify the plan, retain, prime sources, fill visible, fill idle prefetch,
// commit - so the caller can read each stage instead of tracking locals across
// 120 lines. `protected` pins every slot the pass touched until the commit, so
// the pool cannot evict a page that has just been written.
struct Terrain3DAVTProducePass {
	std::vector<const Terrain3DAVTPageRequest *> missing; // Planned pages with no physical slot yet.
	std::vector<int> protected_slots;
	uint64_t allocation_us = 0, payload_us = 0, queue_us = 0;
	int produced = 0, prefetched = 0;
	bool prefetch_pending = false;
};

#endif // TERRAIN3D_AVT_TYPES_H
