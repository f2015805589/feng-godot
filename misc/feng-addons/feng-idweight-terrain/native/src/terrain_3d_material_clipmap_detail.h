// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MATERIAL_CLIPMAP_DETAIL_H
#define TERRAIN3D_MATERIAL_CLIPMAP_DETAIL_H

// The material group's *detail* layer: a sparse, demand-resident ring of small fine tiles that sits
// between the camera and the coarse clipmap ring, and the only thing in the delivery matrix that can
// reach the 1024 texels/m the near field is measured at.
//
// **Why it is not a denser ring.** The coarse ring is one dense level per octave: making its finest
// level 1024 texels/m with a 256-texel axis would cover 0.25 m, and a point 1.6 m ahead would fall to
// level 3 or 4 - the same 64-128 texels/m it has today - while a single dense 4096-texel level over
// the whole near field costs hundreds of MiB. The density has to be spent where a fragment actually
// reads it, and that is a sparse set of tiles with a bounded pool, not a denser square.
//
// **What lives here, and what does not.** This class owns residency only: integer world tile keys
// (`level + snapped tile X/Y`, so a world 10 km out addresses exactly like the origin), a fixed slot
// table, a per-level directory the shader indexes (`key -> slot`, published only once a tile's bake
// has landed *and* its generation still matches), the demand rule, the LRU, the byte budget and the
// counters. It owns the GPU storage too - the two source arrays a pipeline result is uploaded into
// and the three baked arrays a producer writes - because the shader and the producer have to sample
// the same textures. It does **not** own the bake: `Terrain3DSurfaceBaker::queue_detail_tiles()`
// takes the offers this class produces and dispatches them, exactly the way it bakes a ring rect.
//
// **The fallback chain it enables.** Shader-side: a valid detail tile -> the coarse ring's baked
// layers -> the coarse ring's payload through `evaluate_idweight_material()` -> the region texture
// array. A tile that is not resident, or resident but not yet baked, or baked against a generation
// that has since been invalidated, is *absent* from the directory, so a fragment never reads stale
// texels - the directory bit is the whole of the reader's gate, and the same bit is what makes a
// moved camera safe: a slot is only published when the bake that filled it acknowledges the
// generation the slot was handed out under.
//
// **Source preparation reuses the page pipeline.** A tile is one `Terrain3DPagePipeline::Request`
// whose rect is the tile's *interior* rect and whose size is the tile's interior texel count. When
// the output texel is finer than the source step - which is the whole case this layer exists for -
// the pipeline answers with the id/weight and height images on the *source* corner grid, and returns
// that grid in `Result::grid`. The bake job then carries the output texel size and the source grid
// separately (`policy.w` against `page.xy` in the bake shader), so a 1024 texels/m output is filtered
// from real source corners instead of reading the same low-density texel a thousand times.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_page_pipeline.h"

class Terrain3DMaterialClipmapDetail {
	// The class is not a Godot object, so it names itself for the log macro the way the ring does.
	CLASS_NAME_STATIC("Terrain3DMaterialClipmapDetail");

public:
	// Detail levels a manager can carry, and therefore the fixed length of the shader's per-level
	// arrays. Level `l` is `density / 2^l` texels per metre: level 0 is the measured 1024, and the
	// coarser levels are the fringe the finer level's bytes should not be spent on.
	static constexpr int MAX_LEVELS = 4;
	// Slots one manager may hold. A slot is three RGBA16F baked layers plus its two source layers at
	// `stored_size^2`, which is ~1.7 MiB at the default shape, so this ceiling is a guard against a
	// budget setting that would make the arrays absurd rather than a target.
	static constexpr int MAX_SLOTS = 4096;
	// A slot table below this is not a cache: the pool has to be able to hold at least a ring of
	// tiles around the focus or every move would evict what the next frame needs.
	static constexpr int MIN_SLOTS = 8;
	// Rects published per level in the arm dictionary, for the debug view only.
	static constexpr int64_t MIN_BUDGET_BYTES = 16ll << 20;

	// The shape and the policy. Every field is clamped by `configure()`, so a script cannot express a
	// manager whose allocation disagrees with its own addressing.
	struct Config {
		// Interior texels an axis, and the gutter each side. The gutter is what lets the 8x
		// anisotropy the near field requests filter across a tile edge without reading a neighbour
		// tile's texel as if it were its own; it is the same 5 the ring and the pages carry.
		int tile_size = 256;
		int border = 5;
		// Texels per metre at level 0. This is the value the whole layer exists to deliver.
		real_t density = 1024.f;
		int levels = 3;
		// Directory texels an axis per level. The window a level covers is
		// `directory_size * tile_world(l)` metres, so this is the near field's reach as a tile count:
		// 128 tiles of 0.25 m is 32 m at level 0, and 128 m at level 2.
		int directory_size = 128;
		// Bytes of GPU storage the whole layer may hold. `slot_capacity()` turns it into slots.
		int64_t budget_bytes = 256ll << 20;
		// A hard ceiling on the derived slot count, applied after the budget.
		int max_slots = 512;
		// How far from the focus any detail tile is demanded, in metres. Beyond it the coarse ring
		// serves: the layer is a near-field sharpener, not a second world.
		real_t demand_radius = 12.f;
		// The camera's half-angle the demand walk keeps, in radians. A tile behind the camera is not
		// visible, so demanding it would spend a slot on ground no fragment reads.
		real_t forward_half_angle = 1.31f;
		// Screen-space target, in output texels a screen pixel. This is the "screen footprint" the
		// level rule is built from: a level is demanded while its density still puts at least this
		// many texels on a pixel at that distance. Four keeps the 1.6 m probe at level 0 (1024) on
		// a 1080p viewport at the reference's 8-degree pitch.
		real_t texels_per_pixel = 4.f;
		// Source threads its own pipeline may run. 0 selects the machine default; the manager is
		// only created when the layer is selected, so this is a cost a configuration that never
		// selects Clipmap material does not pay.
		int source_workers = 0;
	};

	// One frame's demand view: where the fragment-side camera is and what the screen footprint rule
	// needs from it. Deliberately plain numbers rather than a `Camera3D *`, so the rule is testable
	// with no scene and the manager has no renderer dependency.
	struct DemandView {
		Vector2 focus;
		Vector2 forward = Vector2(0.f, -1.f);
		// Camera height above the ground and the vertical field of view, both in metres/radians.
		real_t height = 1.7f;
		real_t fov_y = 1.1868f;
		int viewport_height = 1080;
		// Overrides `Config::texels_per_pixel` when positive, so a test can ask for one level.
		real_t texels_per_pixel = 0.f;
	};

	// One tile's residency, keyed by `level + (x, y)` in tile units. A tile's world origin is
	// `window_origin(level) + (x, y) * tile_world(level)`, and both the key and the slot are
	// integer: nothing about the addressing degrades at 10 km.
	struct Tile {
		int64_t key = 0;
		int level = -1;
		int x = 0;
		int y = 0;
		int slot = -1;
		// Bumped when the slot is handed to a new key and when the tile's content is invalidated.
		// A bake that lands with a different generation is dropped rather than published: the slot
		// may already describe a different tile, and the directory bit has to describe *content*.
		uint64_t generation = 0;
		uint64_t last_used = 0;
		// The slot has been handed out and the source is being prepared or baked. Not readable.
		bool pending = false;
		// The pipeline produced this tile's source and it has been uploaded into the slot's source
		// layers. The bake can be offered.
		bool source_ready = false;
		// An offer for this tile is with the producer, and `offer_tick` is when it was made. The
		// flag keeps the same tile from being offered twice while a dispatch is in flight; the tick
		// is what retries an offer a producer that cannot dispatch never acknowledges.
		bool bake_in_flight = false;
		uint64_t offer_tick = 0;
		// Tick the slot was handed out. The eviction rule uses it to tell a wanted tile that is
		// merely mid-production from one whose production has been stuck long enough to be worth
		// reclaiming - `last_used` cannot answer that, because a wanted tile is touched every frame.
		uint64_t pending_tick = 0;
		// The *source* corner grid the pipeline produced for this tile: `(origin.x, origin.y, step)`,
		// which is the spacing the bake filters from and is deliberately not the output texel size.
		// Kept per tile because the offer is built from the residency table a tick after the source
		// landed, and the two must describe the same upload.
		Vector3 source_grid;
		// The bake that filled this slot acknowledged the current generation. The slot's entry is
		// published in the directory exactly while this is true.
		bool valid = false;
	};

	// What the producer needs to bake one tile: the slot it writes, the generation the bake must
	// still match to count, the tile's interior world rect, and the source's own corner grid.
	struct BakeOffer {
		int slot = -1;
		int level = 0;
		uint64_t generation = 0;
		// The interior rect the tile's output texels cover. `world_rect.size / tile_size` is the
		// output texel size; `source_grid.z` is the *source* step, which is a different number.
		Rect2 world_rect;
		// `(origin.x, origin.y, step)` of the id/weight and height source the pipeline produced.
		Vector3 source_grid;
		real_t texel_world = 0.f;
		int border = 0;
		int stored_size = 0;
	};

	explicit Terrain3DMaterialClipmapDetail() = default;
	// The GPU arrays are RAII through `GeneratedTexture` and the baked RIDs below, so a manager that
	// is never configured costs nothing and one that is freed releases everything it holds.
	~Terrain3DMaterialClipmapDetail();

	// Applies the shape. A change to anything the addressing or the allocation depends on - the tile
	// shape, the density, the level count, the directory size or the budget - invalidates every
	// resident tile and rebuilds the arrays, because a different slot table is a different
	// allocation. A change to the demand *policy* alone (radius, cone, pixels per texel) is picked
	// up by the next tick and touches nothing. A no-op when nothing moved.
	void configure(const Config &p_config);
	// Releases every GPU and CPU resource. The manager can be configured again afterwards.
	void clear();

	bool is_configured() const { return _config.levels > 0 && _stored_size > 0 && _slot_count > 0; }
	// Whether the budget could afford a usable slot table. False is reported, not hidden: the
	// caller keeps the coarse ring and logs why this layer does not exist.
	bool is_enabled() const { return _enabled; }
	const Config &get_config() const { return _config; }

	// ---- The demand tick --------------------------------------------------------------------------
	// One update: derive this frame's wanted tile set from `p_view`, hand the missing ones slots
	// (evicting under the budget), submit their source requests, poll the pipeline and upload what
	// landed, and publish the directory. Returns how many tiles were newly requested.
	//
	// `p_snapshot` is the shared source snapshot the page pipeline was built from. The caller owns
	// it because it is a property of the terrain's regions, not of this layer.
	int update(const DemandView &p_view, const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot,
			const int p_source_budget);

	// ---- The producer's side ---------------------------------------------------------------------
	// Offers the tiles whose source has landed and whose bake no producer has taken yet. The caller
	// copies them and reports each one back through `acknowledge_bake()` when its dispatch lands.
	int get_pending_bake_count() const { return int(_offers.size()); }
	const BakeOffer &get_pending_bake(const int p_index) const { return _offers[size_t(p_index)]; }
	// Takes one offer out of the queue once a producer has copied it. The producer takes only what
	// its budget admitted, so this is per offer rather than a clear: clearing the whole queue would
	// drop the offers the budget deferred, and their tiles are already marked in flight - they would
	// not be offered again until their own timeout, which is exactly the stall this avoids.
	bool take_pending_bake(const int p_slot, const uint64_t p_generation);
	// A dispatch for `p_slot` landed. The tile becomes resident - and therefore readable - only when
	// the generation still matches the one the offer carried: a camera move or an edit between the
	// offer and the landing has already invalidated the content, and publishing it would map a
	// fragment to texels the producer wrote for a different world position.
	bool acknowledge_bake(const int p_slot, const uint64_t p_generation);

	// ---- Invalidation ----------------------------------------------------------------------------
	// The source changed under a world rect: every tile the rect touches stops being valid and is
	// queued for re-production. Returns how many tiles were invalidated.
	int invalidate_rect(const Rect2 &p_world);

	// ---- The sampled storage ---------------------------------------------------------------------
	// The two source arrays a pipeline result is uploaded into, and the three baked arrays a producer
	// writes. All five are `slots` layers of the stored size, layer `slot` a tile's.
	RID get_payload_texture_rid() const { return _payload.get_rid(); }
	RID get_height_texture_rid() const { return _height.get_rid(); }
	RID get_baked_texture_rid(const int p_channel) const;
	RID get_baked_device_rid(const int p_channel) const;
	// The directory one level publishes: one texel a tile, holding `slot + 1`, 0 for "no readable
	// tile". The shader's whole residency gate is this fetch plus its window origin.
	RID get_directory_rid(const int p_level) const;

	// ---- The shader's copy of the addressing -----------------------------------------------------
	// One dictionary the material binds, built here so the shader's window origin, tile span and
	// directory cannot drift from the CPU's. Empty when the layer is not configured.
	Dictionary get_arm() const;
	// A counter that moves whenever something the shader reads changed: the shape, a directory, or
	// any tile's validity. The caller rebinds on the comparison instead of every tick.
	uint64_t get_state_stamp() const { return _state_stamp; }
	// The finest level with a *readable* tile at a world point, or -1. It is the CPU's mirror of the
	// fragment's own lookup - the same window origin, tile index and directory bit - so a test can
	// assert what a fragment would be served without reading a picture, and it is what the stage's
	// density acceptance is measured with. `density_at()` is its density in texels per metre, 0 when
	// no level has a readable tile there.
	int level_at(const Vector2 &p_world) const;
	real_t density_at(const Vector2 &p_world) const;
	// The focus the last demand walk was built from. Kept because the walk is the only place the
	// layer learns where the view is, and the report has to state the density the directory actually
	// answers *there* rather than the density that was requested.
	Vector2 get_last_focus() const { return _last_focus; }

	// ---- Readings ---------------------------------------------------------------------------------
	int get_slot_count() const { return _slot_count; }
	int get_used_slots() const { return int(_resident.size()); }
	int get_valid_count() const;
	int get_pending_count() const;
	int get_level_count() const { return _config.levels; }
	int get_tile_size() const { return _config.tile_size; }
	int get_border() const { return _config.border; }
	int get_stored_size() const { return _stored_size; }
	int get_directory_size() const { return _config.directory_size; }
	real_t get_density() const { return _config.density; }
	// Level `l`'s density in texels per metre, its tile span in metres, and the world origin the
	// level's directory is currently snapped to.
	real_t get_level_texels_per_meter(const int p_level) const;
	real_t get_level_tile_world(const int p_level) const;
	Vector2 get_window_origin(const int p_level) const;
	int64_t get_budget_bytes() const { return _config.budget_bytes; }
	int64_t get_used_bytes() const;
	int64_t get_directory_bytes() const;
	int64_t bytes_per_slot() const;
	// How many slots the budget and the ceiling allow, without configuring anything.
	int slot_capacity_for(const Config &p_config) const;
	// How many screen texels per world metre a fragment at `p_distance` needs to put
	// `texels_per_pixel` on a pixel, and which detail level that selects on this view. Public so a
	// test can assert the rule rather than the picture.
	real_t required_texels_per_meter(const DemandView &p_view, const real_t p_distance) const;
	int level_for_distance(const DemandView &p_view, const real_t p_distance) const;
	// Cumulative counters: tiles that were demanded with a readable slot (hits) and without one
	// (misses), slots evicted to make room, source results that landed, bakes offered and
	// acknowledged, and invalidations.
	uint64_t get_hit_count() const { return _hits; }
	uint64_t get_miss_count() const { return _misses; }
	uint64_t get_evictions() const { return _evictions; }
	uint64_t get_source_uploads() const { return _source_uploads; }
	uint64_t get_bake_offers() const { return _bake_offers; }
	uint64_t get_bake_acks() const { return _bake_acks; }
	uint64_t get_bake_rejects() const { return _bake_rejects; }
	uint64_t get_invalidation_calls() const { return _invalidation_calls; }
	uint64_t get_invalidated_tiles() const { return _invalidated_tiles; }
	uint64_t get_directory_publishes() const { return _directory_publishes; }
	// Tiles the demand walk wanted and could not hold because every slot was taken by a tile the
	// same walk also wanted. This is the "budget insufficient" reading the plan asks for: the coarse
	// ring serves those fragments and the number says how many.
	int get_starved_tiles() const { return _starved; }
	String get_budget_report() const;

	// The tile key of a snapped world tile, and its inverse, public for the tests and the report.
	static int64_t tile_key(const int p_level, const int p_x, const int p_y);
	static int key_level(const int64_t p_key);
	static int key_x(const int64_t p_key);
	static int key_y(const int64_t p_key);

private:
	// ---- Addressing ------------------------------------------------------------------------------
	// The tile index a world position falls in, for a level whose window origin is already snapped.
	// Integer floor of a real division: the origin and the span are both exact multiples of the
	// texel size by construction, so the only rounding is the one floor() does.
	Vector2i _tile_of_world(const int p_level, const Vector2 &p_world) const;
	// The interior world rect of a tile: the rect its output texels cover, which is what the bake
	// job's `world_rect` and the pipeline `Request::rect` both are.
	Rect2 _tile_world_rect(const int p_level, const int p_x, const int p_y) const;
	// Snap a level's window to its own tile grid around the focus, so a stationary camera does not
	// move the window and the same world tile keeps the same index.
	Vector2 _snap_window(const int p_level, const Vector2 &p_focus) const;

	// ---- Slots -----------------------------------------------------------------------------------
	int _acquire_slot(const int64_t p_key, const Vector2 &p_focus);
	void _release_slot(const int p_slot);
	// The least valuable resident tile, or -1 when nothing may be evicted. The policy is what keeps
	// the cache stable under over-subscription: a tile this frame's walk *wants and holds readable*
	// is never evicted, so a working set larger than the slot table starves its tail once and keeps
	// the tiles it did get instead of churning them every frame. Only a tile the walk no longer wants
	// (rank 0) and a wanted tile whose production has been stuck past
	// `DETAIL_PENDING_EVICT_TICKS` (rank 1) are candidates, and rank 0 goes first. Among equals the
	// oldest `last_used` goes, then the one furthest from the focus.
	int _eviction_candidate(const Vector2 &p_focus) const;
	void _ensure_storage();
	void _ensure_baked();
	void _free_baked();
	// Rebuild one level's directory image from the resident set and hand it to the GPU. Only
	// `valid` tiles are published, which is what makes a stale slot unreadable rather than merely
	// unadvertised.
	void _publish_directory(const int p_level);
	void _mark_directory_dirty() {
		for (int level = 0; level < MAX_LEVELS; level++) {
			_directory_dirty[level] = true;
		}
		_state_stamp++;
	}

	Config _config;
	bool _enabled = false;
	int _stored_size = 0;
	int _slot_count = 0;
	// Focus of the last demand walk, reported beside the density the directory answers there.
	Vector2 _last_focus;
	// Slot index -> tile, the authoritative residency table. A free slot's entry has `slot == -1`.
	std::vector<Tile> _slots;
	// Free slot indices, so a demand walk does not scan the table for a hole per allocation.
	std::vector<int> _free_slots;
	// Resident tile key -> slot. `_slots[_resident[key]]` is the same tile; this is the lookup the
	// demand walk and the producer's acknowledgment both need.
	std::unordered_map<int64_t, int> _resident;
	// The keys this frame's walk asked for, mapped to the tile's *rank* in that walk (1 is the nearest
	// tile). Eviction reads membership to tell "resident and wanted" from "resident and stale"; the
	// offer queue reads the rank to spend a scarce bake budget on the tile the view needs first.
	std::unordered_map<int64_t, uint32_t> _wanted;
	uint64_t _tick = 0;
	uint64_t _state_stamp = 1;

	// The source pipeline: its own, because the near field's is retained against a plan that does
	// not name these keys, and a shared queue would evict one against the other every tick.
	std::unique_ptr<Terrain3DPagePipeline> _pipeline;
	// Tiles whose source landed and whose bake no producer has taken. Held here rather than offered
	// straight out, because the producer is offered once a tick and the offer has to survive the
	// frame the source was uploaded in - the ring's one-tick separation, for the same reason: the
	// upload is a RenderingServer command and the dispatch is a device one.
	std::vector<BakeOffer> _offers;

	// The GPU storage. The two source arrays are RenderingServer-owned so a result can be uploaded
	// with `texture_2d_update`; the three baked arrays are device-owned so the bake can write them
	// through storage images. `_baked_rd` and `_baked_rs` are created and freed together.
	GeneratedTexture _payload;
	GeneratedTexture _height;
	std::vector<RID> _baked_rd;
	std::vector<RID> _baked_rs;
	// Latched when the device was reached and the baked arrays could not be allocated. Retrying a
	// budget-sized allocation every tick would spend a frame's worth of GPU work on a failure and
	// log once per frame; the layer stays configured but unreadable (every tile stays pending and
	// the shader falls back to the ring), and a reconfigure or a `clear()` is what retries it.
	bool _baked_unavailable = false;
	GeneratedTexture _directory[MAX_LEVELS];
	bool _directory_dirty[MAX_LEVELS] = { true, true, true, true };
	// The window origin each level's directory was last published against, so the shader's window
	// and the CPU's cannot disagree by a frame.
	Vector2 _window_origin[MAX_LEVELS];

	// Counters.
	uint64_t _hits = 0;
	uint64_t _misses = 0;
	uint64_t _evictions = 0;
	uint64_t _source_uploads = 0;
	uint64_t _bake_offers = 0;
	uint64_t _bake_acks = 0;
	uint64_t _bake_rejects = 0;
	uint64_t _invalidation_calls = 0;
	uint64_t _invalidated_tiles = 0;
	uint64_t _directory_publishes = 0;
	int _starved = 0;
	// Bumped whenever a slot is handed to a new key or a tile's content is invalidated: a bake offer
	// carries the value it was made under, and a bake that lands against a different one is dropped
	// rather than published. Monotonic for the session, so a slot that is reused cannot inherit an
	// older tile's generation.
	uint64_t _generation_serial = 1;
};

#endif // TERRAIN3D_MATERIAL_CLIPMAP_DETAIL_H
