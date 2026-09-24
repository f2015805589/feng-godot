// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_ATLAS_H
#define TERRAIN3D_CLIPMAP_ATLAS_H

// The clipmap *atlas*: the same ring-of-scales idea as `terrain_3d_clipmap.h`, organised as a fixed
// number of discrete blocks packed into one texture per channel instead of one toroidal square per
// level in a texture array.
//
// **Why a second organisation at all.** The ring is a good residency cache but a poor *update* unit:
// a level is one `size x size` square, `RenderingServer::texture_2d_update()` replaces a whole layer,
// and a level that moved re-publishes its whole square. Measured on the shipped defaults that is one
// 256 KiB transfer per level per channel per movement, and a first fill of a material ring is eight
// of those plus eight bakes. The user's report - "near material on Clipmap has a very long load
// time" - is that number.
//
// The atlas fixes the *unit*: content is a block, a block is a rect of the atlas, and a rect of a
// device texture can be written without touching the rest of it (`RenderingDevice::texture_copy()`
// from a block-sized staging texture). The upload becomes proportional to what changed rather than
// to the shape it changed inside.
//
// **The structure.** Ring `r` is a 3x3 arrangement of *its own* blocks, centred on the ring's own
// snapped start point, and each of those blocks is `base_world * 2^r` metres of `block_size` texels.
// The centre block of ring `r` is inside ring `r-1`'s square, so the arrangement is a shell with a
// hole: the rings nest, ring `r`'s hole is ring `r-1`'s square, and the finder walks finest first, so
// the union covers the plane with every point served by exactly one unit. It is the user's layered
// arrangement ("3x3 at 1024, then each ring half the density") with the layers packed into one texture
// instead of one array layer each - which is what the rect array buys. Because a block is always
// `block_size` texels, the texel count a ring costs is constant and only the *density* falls with the
// ring (`block_size / (base_world * 2^r)` texels a metre), which is the shared ladder of
// `terrain_3d_clipmap_common.h` - the ring's own block is the LOD implementation's level size.
//
// The **hole is kept, not skipped**: the centre cell of a ring is stored as well, because each ring
// snaps its grid to its *own* texel and the finer ring's square can therefore miss a sliver of the
// coarser ring's centre. Sampling is still unique - the finder takes the finest ring that holds the
// point - so the redundancy is bounded storage, never a point served twice.
//
// **Rolling.** Each ring's 3x3 grid is snapped to its own texel size, so a camera that moves inside a
// block changes only each block's *toroidal offset* (`(logical + offset) mod texels`) and produces
// nothing at all - the stored texels keep naming the same world positions. When the camera crosses a
// block boundary the ring is relabelled: the content of the block that was at grid `(i,j)` is the
// content the block at `(i+1,j)` now needs, so a block's **current-frame atlas index** moves between
// cells rather than its content being re-produced. Only the row and column that entered at the edge
// have no predecessor and are loaded - 5 of 9 for a one-block step, never 9. That is the user's
// "blocks have their own ordering index, so only the edge data reloads on each scroll".
//
// **Loading without a flash.** A block whose content is being replaced keeps serving what it holds
// until its replacement lands, and is marked not-current so a reader falls back to the ring inside
// it rather than to a stale block. Each ring owns one **spare slot**, so a replacement can be built
// before anything is released, and at most `blocks_per_frame` blocks are produced per update: the
// per-frame timeline is the mechanism's, not a hope. The order is coarsest ring first for a first
// fill (the fallback every finer read depends on exists soonest) and finest first for a scroll (the
// ground under the camera is the first to be right), which is the ring's own dependency rule.
//
// **Everything is derived in world XZ.** The grid, the block origins and the offset between them are
// computed on the world plane, because material sampling is a camera/world question and a
// light-aligned grid would make the material move with the sun. See
// `docs/vt_delivery_assembly.md` section 6 and the task summary.
//
// A single **global block** covers everything outside the outermost ring at a minimal resolution. It
// is produced once at `configure()` and never again, which is the user's "one global, one-time-loaded,
// minimal-resolution resource".

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform2d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <memory>
#include <vector>

#include "generated_texture.h"
#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_clipmap_impl.h"
#include "terrain_3d_clipmap_source.h"

// The **Atlas implementation** of the one clipmap layer. The shared contract is
// `terrain_3d_clipmap_impl.h` and the shared vocabulary is `terrain_3d_clipmap_common.h`; what this
// file adds is the block storage, the packing, the rolling relabelling, the block upload and the
// layout. It is selected *inside* the `Clipmap` delivery (`vt_clipmap_implementation`), never as a
// delivery of its own, and nothing above it names it.
class Terrain3DClipmapAtlas : public Terrain3DClipmapImpl {
	CLASS_NAME_STATIC("Terrain3DClipmapAtlas");

public:
	// The units one atlas may hold. Each unit is a 3x3 arrangement of its own blocks and reaches
	// `1.5 * base_world * 2^unit` metres, so the count is the layer's reach in octaves. Twelve is one
	// more than the eleven the shipping 1024 -> 1 ladder needs, so the ladder's outer endpoint is
	// always expressible and the ceiling only bounds the shader's per-cell tables rather than the
	// span. The clamp is reported when it is hit (see `configure()`).
	static constexpr int MAX_RINGS = 12;
	// Nine cells a unit: the centre block and its eight neighbours, which is what nests.
	static constexpr int MAX_CELLS = 9 * MAX_RINGS;
	// One slot per cell, one spare a unit, one global block, and room for a layout that leaves a hole.
	// The packing never needs more than this and the shader's rect array is sized from it.
	static constexpr int MAX_SLOTS = MAX_CELLS + MAX_RINGS + 8;
	static constexpr int MAX_CHANNELS = 16;
	// The packing schemes the layout report compares. Every one of them is a *different* answer to
	// "how do these 9-per-ring rects occupy the least area", and the report publishes all of them so the
	// choice is a measurement rather than a preference.
	enum Packer {
		// Every block of every ring in one descending-size shelf sequence: the smallest bounding
		// box, and the one that mixes the rings' blocks inside a row.
		PACK_SHELF = 0,
		// One horizontal band a ring, placed in ring order: a ring's blocks never share a row with
		// another ring's, which costs area and buys a layout a debug view can label.
		PACK_RING_BANDS = 1,
		// The **quadtree** arrangement: a power-of-two root that is recursively subdivided, and each
		// block placed by depth-first descent into the first node that fits it. Same-sized blocks end
		// up clustered in the same subtree and each ring lands in its own region of the tree, so the
		// picture is nested rather than a shelf: the coarse blocks sit in the large nodes the finer
		// ones were split out of, which is the arrangement the user asked for ("the atlas should look
		// like the quadtree"). It is chosen by default and the shelf and ring-band schemes stay
		// implemented so the comparison the task asks for is the mechanism's own numbers.
		PACK_QUADTREE = 2,
		PACK_COUNT = 3,
	};

	struct Config {
		// Ring 0's block resolution in texels an axis. Every ring's block is this many texels, so the
		// ladder is the shared one (`block_size / (base_world * 2^ring)` texels a metre) and the
		// user's 1024/512/256/128 is exactly this shape's first four rings.
		int block_size = 256;
		// How many units the atlas holds. Clamped to `[1, MAX_RINGS]`, and the layer's own
		// `vt_clipmap_levels` is what a user sets: unit `r` reaches `1.5 * base_world * 2^r` metres.
		int rings = TerrainClipmap::LADDER_UNITS;
		// The *world* size of unit 0's blocks; unit `r`'s blocks are `base_world * 2^r` metres, which
		// is the shared ladder's own unit size, so the atlas serves the LOD ring's density at every
		// distance. The finest unit reaches `1.5 * base_world` metres and each unit after it doubles.
		real_t base_world = 0.25f;
		// Values a texel holds, one atlas texture layer each - the same shape the ring declares.
		int channels = 1;
		Image::Format format = Image::FORMAT_RF;
		// The global block: `global_texels` an axis over `global_world` metres, produced once. Zero
		// `global_world` derives it from the grid's own reach.
		int global_texels = 64;
		real_t global_world = 0.f;
		// One spare slot per ring, which is what lets a replacement be built before its predecessor
		// is released. Off is the "exactly enough, unload then load" arrangement the user rejected.
		bool spares = true;
		// The per-frame production bound. One is the user's "a frame loads one block".
		int blocks_per_frame = 1;
		// The packing scheme the layout uses. The default is the **quadtree**: the user's form
		// requirement is a nested, recursively subdivided arrangement, and the shelf and ring-band
		// schemes stay selectable so the comparison is one build and one report rather than a claim.
		int packer = PACK_QUADTREE;
	};

	// One physical rect of the atlas: the entry of the **rect array** the shader indexes. A slot
	// holds *content*, which is one block's worth of one ring at one world block coordinate.
	struct Slot {
		Rect2i rect;
		int ring = -1;
		int texels = 0;
		// The world block coordinate the content was produced for. Two slots with the same
		// coordinate hold the same content, which is what lets a relabelling keep the interior blocks.
		int64_t block_x = 0;
		int64_t block_y = 0;
		// The ring's texel phase the content was produced at, so a toroidal offset can be derived
		// without re-producing the block.
		int64_t phase = 0;
		uint64_t serial = 0;
		bool resident = false;
		bool spare = false;
		bool global = false;
		// Whether the three *baked* arrays hold this content. The source landing makes a block
		// readable; the producer's dispatch, acknowledged by `acknowledge_bake()`, is what makes
		// it a **material**. A slot reused for another coordinate is not baked until its own bake
		// lands, which is the whole of what keeps a stale rect out of a fragment.
		bool baked = false;
	};

	// One cell of a ring: a fixed place in that ring's own 3x3 arrangement whose world block coordinate
	// moves with the focus. `slot` is the **current-frame atlas index** - what the shader reads - and it
	// changes on a relabelling while the slot's content is untouched.
	struct Cell {
		int ring = 0;
		int gx = 0;
		int gy = 0;
		int chebyshev = 0;
		int slot = -1;
		// The toroidal offset in the ring's own texels.
		Vector2i offset;
		// Whether the slot the cell points at is current for the coordinate the cell wants. False
		// covers "never produced", "being produced now" and "invalidated"; a reader falls back.
		bool current = false;
		// The slot being filled for this cell right now, or -1. The cell keeps pointing at `slot`
		// - and at `current == false`, so a reader falls back rather than reading stale content -
		// until the replacement lands and the two are swapped.
		int pending_slot = -1;
		int64_t want_x = 0;
		int64_t want_y = 0;
		int64_t have_x = 0;
		int64_t have_y = 0;
	};

	// One block of work: the atlas index to fill, and the content it is being filled with.
	struct Job {
		int slot = 0;
		int ring = 0;
		int64_t block_x = 0;
		int64_t block_y = 0;
		int64_t phase = 0;
		int cursor_row = 0;
		int cursor_channel = 0;
		int cursor_x = 0;

		Job() = default;
		Job(const int p_slot, const int p_ring, const int64_t p_block_x, const int64_t p_block_y,
				const int64_t p_phase) :
				slot(p_slot), ring(p_ring), block_x(p_block_x), block_y(p_block_y), phase(p_phase) {}
	};

	// One block the producer has to *bake*: the rect of the baked atlas this block's three material
	// arrays were produced into, and the content it describes. It is the **shared** queue entry
	// (`TerrainClipmap::BakeRect`), with `unit` naming the atlas slot and `lease` the slot serial:
	// a producer's queue is written once against the shared shape, so the atlas and the LOD ring travel
	// through one path rather than two.
	using BakeRect = TerrainClipmap::BakeRect;

	// What one packing scheme produced, published by the layout report so the comparison the task
	// asks for is the mechanism's own numbers rather than a script's.
	struct LayoutScheme {
		const char *name = "";
		int width = 0;
		int height = 0;
		int64_t area = 0;
		double efficiency = 0.0; // packed area / bounding area
		bool chosen = false;
	};

	explicit Terrain3DClipmapAtlas(std::unique_ptr<Terrain3DClipmapSource> p_source);
	~Terrain3DClipmapAtlas();

	void configure(const Config &p_config);
	void clear() override;

	bool is_configured() const override { return _config.block_size > 0 && !_cells.empty(); }
	// ---- The shared contract this implementation answers ----------------------------------------
	// The ladder is the *shared* one: ring `r`'s block is `block_size` texels over `base_world * 2^r`
	// metres, which is `base_world * 2^r / block_size` a texel - the same function the LOD ring's levels
	// answer with. The two organisations therefore serve the same density at the same distance, and the
	// only thing that differs is where those texels are stored.
	TerrainClipmap::Implementation get_implementation() const override {
		return TerrainClipmap::Implementation::Atlas;
	}
	TerrainClipmap::Ladder get_ladder() const override {
		TerrainClipmap::Shape shape;
		shape.size = _config.block_size;
		shape.base_world = _config.base_world;
		return TerrainClipmap::ladder_of(shape);
	}
	int get_unit_count() const override { return _config.rings; }
	// What one unit covers: the side of its own 3x3 square, `UNIT_SIDE * base_world * 2^unit` metres,
	// which is the shared ladder's unit size times the grid the storage lays it out in. The *radius* a
	// caller reads off it is half of this, and the density at that edge is the shared ladder's
	// `block_size / (base_world * 2^unit)` - the same pair the LOD ring answers with its own level
	// square, so the two implementations' coverage plots are one curve.
	real_t get_unit_world_size(const int p_unit) const override {
		return real_t(UNIT_SIDE) * _block_world_of_ring(CLAMP(p_unit, 0, MAX_RINGS - 1));
	}
	int get_unit_for_world(const Vector2 &p_world) const override;
	real_t get_texel_world_at(const Vector2 &p_world) const override;
	int get_size() const override { return _config.block_size; }
	int get_channel_count() const override { return _config.channels; }
	Image::Format get_format() const override { return _config.format; }
	// The whole point of the structure, published so a test reads the user's arithmetic rather than
	// a comment: 9, 16, 24, 32 for four rings, and the centre block counted in the first.
	int get_ring_block_count(const int p_ring) const;
	int get_block_count() const;
	int get_cell_count() const { return int(_cells.size()); }
	int get_slot_count() const { return int(_slots.size()); }
	String get_source_name() const override;

	// ---- The atlas texture ---------------------------------------------------------------------
	// `channels` layers of one `Texture2DArray`, each layer a full 2D atlas for one value of a texel.
	// Two layers are allocated whatever the channel count: the renderer refuses to wrap a one-layer
	// array as a layered texture, and one layer of one value is cheaper than a second publish path.
	RID get_texture_rid() const override { return _texture_rid; }
	int get_texture_layer_count() const override { return _texture_layers; }
	int get_atlas_width() const { return _layout.width; }
	int get_atlas_height() const { return _layout.height; }
	// One entry of the **rect array** the shader indexes, in atlas pixels. The rect's `size` is the
	// block's texel size, which is the uv scale a reader needs; the position is its uv offset.
	Rect2i get_slot_rect(const int p_slot) const { return _slots[size_t(p_slot)].rect; }
	int get_slot_texels(const int p_slot) const { return _slots[size_t(p_slot)].texels; }
	// Which ring a slot's content belongs to. The producer reads it beside the shared bake entry, whose
	// `unit` names the slot rather than the ring.
	int get_slot_ring(const int p_slot) const { return _slots[size_t(p_slot)].ring; }

	// ---- The grid and the cells -----------------------------------------------------------------
	// The ring's **start point**: the centre of the grid's centre block, a whole number of blocks from
	// the origin. This - not the texel-snapped grid origin - is what `cell_for_ring()` and `sample()`
	// measure a block coordinate from, so it is the number the shader's copy of the addressing must
	// publish: the two would disagree by up to half a block at a boundary.
	Vector2 get_ring_start(const int p_ring) const { return _ring_start(p_ring, _last_focus); }
	int get_cell_index(const int p_ring, const int p_gx, const int p_gy) const;
	int get_cell_slot(const int p_cell) const { return _cells[size_t(p_cell)].slot; }
	bool is_cell_current(const int p_cell) const { return _cells[size_t(p_cell)].current; }
	Vector2i get_cell_offset(const int p_cell) const { return _cells[size_t(p_cell)].offset; }
	// The cell of *one* unit that holds a world point, or -1 when that unit's own 3x3 does not. It is
	// the addressing rule in one place, so the finder and `sample()` cannot disagree - and the
	// shader's own finder is this same arithmetic.
	int cell_for_ring(const int p_ring, const Vector2 &p_world) const;
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const override;
	// The global block's own readings: the minimal-resolution resource outside the grid.
	int get_global_texels() const { return _config.global_texels; }

	// ---- The baked arrays ----------------------------------------------------------------------
	// The three arrays a producer writes out of a block's source texels, one rect of one array per
	// block: the same `RGBAH` material the ring's bake produces, addressed by the *same* rect array
	// the source lives in. `get_baked_texture_rid()` is what the material arm binds; the device RIDs
	// are what the producer writes as storage images. A channel with no bake (the height one)
	// allocates none, and the arm binds the dummy array instead.
	int get_baked_channel_count() const override { return _source != nullptr ? _source->get_baked_channel_count() : 0; }
	Image::Format get_baked_format() const override {
		return _source != nullptr ? _source->get_baked_format() : Image::FORMAT_RGBAH;
	}
	RID get_baked_device_rid(const int p_channel) const override;
	RID get_baked_texture_rid(const int p_channel) const override;
	// Whether a block's content has been baked and may be sampled. `is_cell_baked()` is the arm's
	// question - the cell's *current* slot, which is the only one a fragment reads.
	bool is_slot_baked(const int p_slot) const {
		return p_slot >= 0 && p_slot < int(_slots.size()) && _slots[size_t(p_slot)].baked;
	}
	bool is_cell_baked(const int p_cell) const {
		return p_cell >= 0 && p_cell < int(_cells.size()) && _cells[size_t(p_cell)].current &&
				is_slot_baked(_cells[size_t(p_cell)].slot);
	}
	// The bake queue, in the **shared** entry shape: one entry per block whose source has landed and
	// whose baked rect no dispatch has covered yet. `acknowledge_bake()` is the producer's answer,
	// refused when the slot has been reused since the rect was taken (the lease - the slot's serial -
	// no longer matches), which makes a bake that read content the atlas has since replaced a no-op
	// rather than a mislabel.
	int get_pending_bake_count() const override { return int(_bake_rects.size()); }
	const BakeRect &get_pending_bake(const int p_index) const override { return _bake_rects[size_t(p_index)]; }
	bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) override;
	// Every block's baked content is stale, which is what a change to the material list the bake
	// evaluates against is: the source texels are untouched, so every cell stays current - only the
	// layers produced from them are. The ring answers this too, so a material change reaches whichever
	// implementation is selected rather than only the ring.
	void mark_baked_stale() override;
	// The block's world square origin: the world XZ of the corner *before* the first texel's centre,
	// so content index `i` names `get_slot_block_origin() + (i + 0.5) * get_slot_texel_world()`.
	// This is the number the producer's job carries as its policy origin.
	Vector2 get_slot_block_origin(const int p_slot) const;
	real_t get_slot_texel_world(const int p_slot) const;

	// One update: re-derive the grid the focus implies, relabel the cells, queue the blocks that
	// entered, drain up to `blocks_per_frame` of them. Returns the channel texels produced.
	int update(const Vector2 &p_focus, const int p_budget_texels = 0) override;
	// The source changed under a world rect: the blocks the rect touches stop being current and are
	// queued for re-production. A block is the unit, so this is the block-incremental invalidation.
	int invalidate_rect(const Rect2 &p_world) override;

	// ---- Readings ------------------------------------------------------------------------------
	uint64_t get_state_stamp() const override { return _state_stamp; }
	uint64_t get_produced_texels() const override { return _produced_texels; }
	uint64_t get_upload_bytes() const override { return _upload_bytes; }
	uint64_t get_update_calls() const override { return _update_calls; }
	uint64_t get_idle_updates() const override { return _idle_updates; }
	int get_pending_jobs() const override { return int(_jobs.size()); }
	// The per-frame timeline: one entry per update that produced anything, oldest first, so "one
	// block a frame" is a table and not a claim. Keys: `frame`, `slot`, `ring`, `texels`, `bytes`.
	Array get_load_timeline() const;
	// The layout report: every scheme the packer evaluated with its bounding box and efficiency, the
	// chosen one, and the per-ring block counts. The task's "packing report" is this dictionary.
	Dictionary get_layout_report() const;
	// Per-ring readings, in ring order, for the dock and the tests.
	Array get_ring_reports() const;
	// ---- The shared contract's debug and arm halves ----------------------------------------------
	// One ring's entry in the *shared* schema: the shell's texel size, its reach, the density it serves,
	// whether every cell of it is current and baked, and the world reach of the shell. The cells and the
	// rect array - which are this implementation's own frame - travel through `get_impl_payload()`.
	void get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const override;
	Dictionary get_impl_payload() const override;
	Dictionary get_arm() const override;

private:
	// One thing to place: a block of a ring, that ring's spare, or the global block.
	struct PackedItem {
		int size = 0;
		int ring = -1;
		bool spare = false;
		bool global = false;
	};

	// One unit's arrangement is 3x3: a centre and its eight neighbours. It is a *unit* extent rather
	// than a grid's, which is what makes the units nest - unit `r`'s hole is unit `r-1`'s square.
	static constexpr int UNIT_SIDE = 3;
	// The world size of one unit's blocks - the shared ladder's own unit size, `base_world * 2^unit` -
	// and the texel count and texel size that follow from it. Unit `r` stores `block_size` texels of
	// that span, so a unit's cost is constant and its reach doubles per unit.
	real_t _block_world_of_ring(const int p_ring) const;
	int _texels_of_ring(const int p_ring) const;
	real_t _texel_of_ring(const int p_ring) const;
	// The snapped grid origin of a ring: the focus rounded down to that ring's own texel, which is
	// the ring's own answer and exactly what `Terrain3DClipmap` does per level.
	Vector2 _grid_origin_of_ring(const int p_ring, const Vector2 &p_focus) const;
	// The ring's **start point**: the centre of the grid's centre block, a whole number of blocks
	// from the origin. Every cell's block is this point offset by the fixed block size, which is the
	// one value a block's matrix and its rect lookup are both derived from.
	Vector2 _ring_start(const int p_ring, const Vector2 &p_focus) const;
	// The focus's phase inside the ring's block, in the ring's own texels. The same for every cell of
	// the ring, which is why it is a ring reading rather than one offset per block.
	Vector2i _ring_phase(const int p_ring, const Vector2 &p_focus) const;

	void _build_layout();
	// One packing scheme, run over the block sizes. Appends the placed items and their rects in the
	// order they were placed, so slot `i` is rect `i` and the ring identity survives the packing.
	void _pack_scheme(const int p_packer, std::vector<PackedItem> &r_items, std::vector<Rect2i> &r_rects,
			int &r_width, int &r_height) const;
	// The quadtree allocator: descending-size insertion into the smallest free node, splitting along
	// both axes until a quadrant is the item's size. False when `p_width x p_height` cannot hold the
	// content, which is what the root search in `_pack_scheme()` reads.
	bool _pack_quadtree(const std::vector<PackedItem> &p_items, const int p_width, const int p_height,
			std::vector<Rect2i> &r_rects) const;
	void _assign_slots(const std::vector<PackedItem> &p_items, const std::vector<Rect2i> &p_rects);
	void _rebuild_cells();
	// The relabelling of one ring's cells: the block coordinates moved, so a slot that already holds
	// the coordinate is reassigned rather than re-produced.
	void _relabel_ring(const int p_ring, const bool p_first);
	// The progressive recycling: every cell that is neither serving a block nor waiting for one asks
	// for a free slot, and a block is queued into the ones that get one. A relabelling that entered
	// more blocks than there are free slots therefore finishes over several updates instead of
	// stranding the cells it could not place - which is what makes the per-frame bound a *bound* and
	// not a stall.
	void _reconcile_cells();
	// The slot that already holds the coordinate, or -1.
	int _find_slot(const int p_ring, const int64_t p_block_x, const int64_t p_block_y) const;
	int _take_free_slot(const int p_ring);
	int _slot_owner(const int p_slot, const bool p_include_pending) const;
	void _queue_block(const int p_cell, const int p_slot);
	bool _produce_job(Job &p_job);
	void _fill_job_row(const Job &p_job, const int p_channel, const int p_y, const int p_x0, const int p_x1);
	// Copies one produced block's rect into the atlas through the staging texture, which is the
	// block-granular upload the whole organisation exists for.
	void _upload_rect(const int p_staging, const Rect2i &p_rect, const int p_texels, const int p_channel,
			const std::vector<float> &p_values);
	// One block-sized staging texture: its size is what makes a transfer the block's own bytes.
	RID _create_staging(const int p_texels);
	void _publish_global();
	void _ensure_texture();
	void _ensure_staging();
	void _ensure_baked();
	void _free_baked();
	void _free_textures();
	// Queues the block the job just produced for the producer, and clears the slot's baked flag: the
	// rect is what a dispatch will cover, and until it does the material arm must fall back.
	void _queue_bake(const int p_slot);
	uint64_t _serial() { return ++_serial_counter; }

	Config _config;
	std::unique_ptr<Terrain3DClipmapSource> _source;
	std::vector<Cell> _cells;
	std::vector<Slot> _slots;
	std::vector<Job> _jobs;
	// The spare slots, one a ring, kept out of the cell assignment until a replacement needs one.
	std::vector<int> _spare_slots;
	// One value per texel of the largest block, reused so a production does not allocate.
	std::vector<float> _block_values;
	// The source's row scratch, reused by production and by a reading. Mutable because it is a cache
	// rather than state: a reading must not change what the atlas holds.
	mutable std::vector<float> _row_values;
	// The packed bounding box of the chosen scheme.
	LayoutScheme _layout;
	LayoutScheme _schemes[PACK_COUNT];
	std::vector<Rect2i> _packed;
	std::vector<PackedItem> _items;

	RID _texture_rd;
	RID _texture_rid;
	int _texture_layers = 0;
	// The block-sized staging textures the upload copies out of, one a channel. A block-sized
	// transfer is the point; a full-atlas staging image would be the thing this mechanism replaces.
	std::vector<RID> _staging_rd;
	std::vector<RID> _staging_rs;
	// One device texture per baked channel, sized to the whole atlas, plus its RenderingServer
	// wrapper. The producer writes rects of the device texture as storage images and the arm samples
	// the wrapper; the two are created and freed together, exactly like the ring's baked arrays.
	std::vector<RID> _baked_rd;
	std::vector<RID> _baked_rs;
	// The blocks whose source has landed and whose bake no dispatch has covered. One entry per
	// produced block, removed by `acknowledge_bake()`.
	std::vector<BakeRect> _bake_rects;
	Rect2i _global_rect;
	Vector2 _global_origin;
	real_t _global_world = 0.f;
	bool _global_produced = false;

	Vector2 _last_focus;
	bool _has_focus = false;
	Vector2i _grid_step;
	// One entry a ring: its start point (a whole number of blocks from the frame origin), its phase
	// inside the block in its own texels, and the block step the last relabelling was done at.
	std::vector<Vector2> _ring_origin;
	std::vector<Vector2i> _ring_phase_value;
	std::vector<Vector2i> _ring_step;
	uint64_t _state_stamp = 1;
	uint64_t _shape_serial = 1;
	uint64_t _serial_counter = 0;
	uint64_t _produced_texels = 0;
	uint64_t _upload_bytes = 0;
	uint64_t _block_uploads = 0;
	uint64_t _update_calls = 0;
	uint64_t _idle_updates = 0;
	uint64_t _scroll_events = 0;
	uint64_t _edge_blocks_loaded = 0;
	uint64_t _interior_blocks_retained = 0;
	uint64_t _last_scroll_loaded = 0;
	uint64_t _last_scroll_retained = 0;
	uint64_t _frame_counter = 0;
	struct TimelineEntry {
		uint64_t frame = 0;
		int slot = 0;
		int ring = 0;
		int64_t texels = 0;
		int64_t bytes = 0;
	};
	std::vector<TimelineEntry> _timeline;
};

#endif // TERRAIN3D_CLIPMAP_ATLAS_H
