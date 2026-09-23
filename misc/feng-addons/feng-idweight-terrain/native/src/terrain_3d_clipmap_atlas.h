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
// **The structure.** Ring `r` is a shell of equal-sized blocks around the rings inside it. Ring 0 is
// the 3x3 square (its centre block plus its 8 shell blocks); ring `r >= 1` is the border of the
// `(2r+3) x (2r+3)` square, i.e. `8 * (r + 1)` blocks. With four rings that is 9 + 16 + 24 + 32 = 81
// blocks, the whole of a 9x9 grid, which is exactly the user's arithmetic (`(2n+1)*4-4 = 8n`, plus
// the first ring's extra centre block). Blocks of every ring cover the *same* world size - that is
// what makes the shells nest exactly: ring `r`'s hole is ring `r-1`'s square, so the union tiles
// with no gap and no overlap. What falls with the ring is the *resolution*: ring `r`'s block is
// `block_size >> r` texels an axis, so its texel is `2^r` wider and the shell is one octave coarser.
// This is the user's layered arrangement ("3x3 at 1024, 5x5 at 512") with the layers packed into one
// texture instead of one array layer each - which is what the rect array buys.
//
// **Rolling.** The 9x9 grid is snapped to the finest ring's texel, so a camera that moves inside a
// block changes only each block's *toroidal offset* (`(logical + offset) mod texels`) and produces
// nothing at all - the stored texels keep naming the same world positions. When the camera crosses a
// block boundary the grid is relabelled: the content of the block that was at grid `(i,j)` is the
// content the block at `(i+1,j)` now needs, so a block's **current-frame atlas index** moves between
// cells rather than its content being re-produced. Only the row and column that entered at the edge
// have no predecessor and are loaded - 17 blocks of 81 for a one-block step, never 81. That is the
// user's "9x9 blocks have their own ordering index, so only the edge data reloads on each scroll".
//
// **Loading without a flash.** A block whose content is being replaced keeps serving what it holds
// until its replacement lands, and is marked not-current so a reader falls back to the ring inside
// it rather than to a stale block. Each ring owns one **spare slot**, so a replacement can be built
// before anything is released, and at most `blocks_per_frame` blocks are produced per update: the
// per-frame timeline is the mechanism's, not a hope. The order is coarsest ring first for a first
// fill (the fallback every finer read depends on exists soonest) and finest first for a scroll (the
// ground under the camera is the first to be right), which is the ring's own dependency rule.
//
// **Everything is derived in the frame's space.** The grid, the block origins, the per-block matrix
// and the offset between them are computed in the space `Config::frame` maps to world, and only the
// final origin is transformed. For the shipped height and material consumers that frame is the world
// XZ plane (identity), because material sampling is a camera/world question and a light-aligned grid
// would make the material move with the sun; the machinery is the shadow clipmap's - a start matrix
// plus a fixed block size is all a block matrix needs - and `set_frame()` is where a light camera's
// matrix would be installed. See `docs/vt_delivery_assembly.md` section 6 and the task summary.
//
// A single **global block** covers everything outside the 9x9 grid at a minimal resolution. It is
// produced once at `configure()` and never again, which is the user's "one global, one-time-loaded,
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
#include "terrain_3d_clipmap_source.h"

class Terrain3DClipmapAtlas {
	CLASS_NAME_STATIC("Terrain3DClipmapAtlas");

public:
	// Four rings is the shipped structure and the user's arithmetic (9 + 16 + 24 + 32 = 81). The
	// ceiling is a statement about the shader's per-cell uniform arrays rather than about the idea:
	// `(2 * MAX_RINGS + 1)^2` cells is what the arrays are sized for.
	static constexpr int MAX_RINGS = 4;
	// The 9x9 grid the four rings tile exactly.
	static constexpr int MAX_CELLS = (2 * MAX_RINGS + 1) * (2 * MAX_RINGS + 1);
	// One slot per cell, one spare a ring, one global block, and room for a layout that leaves a
	// hole. The packing never needs more than this and the shader's rect array is sized from it.
	static constexpr int MAX_SLOTS = MAX_CELLS + MAX_RINGS + 8;
	static constexpr int MAX_CHANNELS = 16;
	// The packing schemes the layout report compares. Every one of them is a *different* answer to
	// "how do these 81 rects occupy the least area", and the report publishes all of them so the
	// choice is a measurement rather than a preference.
	enum Packer {
		// Every block of every ring in one descending-size shelf sequence: the smallest bounding
		// box, and the one that mixes the rings' blocks inside a row.
		PACK_SHELF = 0,
		// One horizontal band a ring, placed in ring order: a ring's blocks never share a row with
		// another ring's, which costs area and buys a layout a debug view can label.
		PACK_RING_BANDS = 1,
		PACK_COUNT = 2,
	};

	struct Config {
		// Ring 0's block resolution in texels an axis. Ring `r` is `block_size >> r`, so the ladder
		// is the user's 1024/512/256/128 scaled to whatever the settings ask for.
		int block_size = 256;
		// How many rings the 9x9-style grid holds. Clamped to `[1, MAX_RINGS]`.
		int rings = 4;
		// The *world* size of a block, the same for every ring. The grid is `(2 * rings + 1)` blocks
		// an axis, so the atlas covers `(2 * rings + 1) * base_world` metres.
		real_t base_world = 256.f;
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
		// The **start matrix**: the light camera a block's own matrix is derived from. It is the one
		// value the matrix array stores; every block's matrix is this matrix carried to the block's
		// own origin by the fixed block size, which is the user's "fixed size/far/near automatic
		// offset, store only one origin" simplification. Identity is the shipped arrangement: the
		// height and material consumers sample in world XZ, so the grid is derived there and only the
		// published matrices are in the light camera. See `get_cell_matrix()`.
		Transform2D frame = Transform2D();
	};

	// One physical rect of the atlas: the entry of the **rect array** the shader indexes. A slot
	// holds *content*, which is one block's worth of one ring at one world block coordinate.
	struct Slot {
		Rect2i rect;
		int ring = -1;
		int texels = 0;
		// The world block coordinate the content was produced for. Two slots with the same
		// coordinate hold the same content, which is what lets a relabelling keep 64 of 81 blocks.
		int64_t block_x = 0;
		int64_t block_y = 0;
		// The ring's texel phase the content was produced at, so a toroidal offset can be derived
		// without re-producing the block.
		int64_t phase = 0;
		uint64_t serial = 0;
		bool resident = false;
		bool spare = false;
		bool global = false;
	};

	// One cell of the grid: a fixed place in the 9x9 arrangement whose world block coordinate moves
	// with the focus. `slot` is the **current-frame atlas index** - what the shader reads - and it
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
	void clear();

	bool is_configured() const { return _config.block_size > 0 && !_cells.empty(); }
	const Config &get_config() const { return _config; }
	int get_rings() const { return _config.rings; }
	// The whole point of the structure, published so a test reads the user's arithmetic rather than
	// a comment: 9, 16, 24, 32 for four rings, and the centre block counted in the first.
	int get_ring_block_count(const int p_ring) const;
	int get_block_count() const;
	int get_cell_count() const { return int(_cells.size()); }
	int get_slot_count() const { return int(_slots.size()); }
	int get_channel_count() const { return _config.channels; }
	Image::Format get_format() const { return _config.format; }
	String get_source_name() const;
	int get_source_channel_count() const { return _source != nullptr ? _source->get_channel_count() : 1; }
	Image::Format get_source_format() const { return _source != nullptr ? _source->get_format() : Image::FORMAT_RF; }

	// ---- The atlas texture ---------------------------------------------------------------------
	// `channels` layers of one `Texture2DArray`, each layer a full 2D atlas for one value of a texel.
	// Two layers are allocated whatever the channel count: the renderer refuses to wrap a one-layer
	// array as a layered texture, and one layer of one value is cheaper than a second publish path.
	RID get_texture_rid() const { return _texture_rid; }
	int get_texture_layer_count() const { return _texture_layers; }
	int get_atlas_width() const { return _layout.width; }
	int get_atlas_height() const { return _layout.height; }
	int64_t get_atlas_texels() const { return int64_t(_layout.width) * int64_t(_layout.height); }
	// One entry of the **rect array** the shader indexes, in atlas pixels. The rect's `size` is the
	// block's texel size, which is the uv scale a reader needs; the position is its uv offset.
	Rect2i get_slot_rect(const int p_slot) const { return _slots[size_t(p_slot)].rect; }
	int get_slot_texels(const int p_slot) const { return _slots[size_t(p_slot)].texels; }
	const Slot &get_slot(const int p_slot) const { return _slots[size_t(p_slot)]; }

	// ---- The grid, the cells and the matrices ---------------------------------------------------
	// The world XZ of a cell's first texel *centre*, which is the origin its block is addressed from.
	// Derived from the ring's own snapped grid origin and the cell's grid coordinate, which is the
	// user's "store one origin, offset by fixed size" simplification rather than 81 stored origins.
	Vector2 get_cell_origin(const int p_cell) const;
	// The **matrix array** entry: the frame's start matrix carried to this cell's own block. A cell
	// under the identity frame is a pure translation, which is the fixed size/far/near case; under a
	// light camera it is the light's matrix with the block's offset folded in.
	Transform2D get_cell_matrix(const int p_cell) const;
	// The frame's own start matrix - the single value a matrix array is derived from.
	Transform2D get_frame_matrix() const { return _config.frame; }
	void set_frame(const Transform2D &p_frame);
	// The ring's snapped grid origin in the frame's space, which is where every cell's block is
	// measured from.
	Vector2 get_grid_origin(const int p_ring) const;
	Vector2 get_focus() const { return _last_focus; }
	// The block coordinate the grid's centre cell holds, `(m, m)`: the integer that tells a
	// relabelling from a phase turn.
	Vector2i get_grid_step() const { return _grid_step; }
	int get_cell_index(const int p_gx, const int p_gy) const;
	int get_cell_slot(const int p_cell) const { return _cells[size_t(p_cell)].slot; }
	int get_cell_pending_slot(const int p_cell) const { return _cells[size_t(p_cell)].pending_slot; }
	bool is_cell_current(const int p_cell) const { return _cells[size_t(p_cell)].current; }
	Vector2i get_cell_offset(const int p_cell) const { return _cells[size_t(p_cell)].offset; }
	// The cell the clipmap's own addressing selects for a world point, or -1 when the point is
	// outside the grid and the global block answers it. The mirror of the shader's arm.
	int cell_for_world(const Vector2 &p_world) const;
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const;
	// The global block's own readings: the minimal-resolution resource outside the grid.
	Rect2i get_global_rect() const { return _global_rect; }
	Vector2 get_global_origin() const { return _global_origin; }
	real_t get_global_world() const { return _global_world; }
	int get_global_texels() const { return _config.global_texels; }

	// One update: re-derive the grid the focus implies, relabel the cells, queue the blocks that
	// entered, drain up to `blocks_per_frame` of them. Returns the channel texels produced.
	int update(const Vector2 &p_focus, const int p_budget_texels = 0);
	// The source changed under a world rect: the blocks the rect touches stop being current and are
	// queued for re-production. A block is the unit, so this is the block-incremental invalidation.
	int invalidate_rect(const Rect2 &p_world);

	// ---- Readings ------------------------------------------------------------------------------
	uint64_t get_state_stamp() const { return _state_stamp; }
	uint64_t get_produced_texels() const { return _produced_texels; }
	uint64_t get_upload_bytes() const { return _upload_bytes; }
	// The number that says whether the atlas's update unit is the block: how many block rects were
	// published, and how many bytes one of them cost. A whole-atlas publish is what this is *not*.
	uint64_t get_block_uploads() const { return _block_uploads; }
	uint64_t get_update_calls() const { return _update_calls; }
	uint64_t get_idle_updates() const { return _idle_updates; }
	// The rolling evidence: how many blocks were loaded because they entered the grid, and how many
	// cells kept their content. A scroll that reloaded the grid would show `retained` at zero.
	uint64_t get_scroll_events() const { return _scroll_events; }
	uint64_t get_edge_blocks_loaded() const { return _edge_blocks_loaded; }
	uint64_t get_interior_blocks_retained() const { return _interior_blocks_retained; }
	uint64_t get_last_scroll_loaded() const { return _last_scroll_loaded; }
	uint64_t get_last_scroll_retained() const { return _last_scroll_retained; }
	int get_pending_jobs() const { return int(_jobs.size()); }
	// The per-frame timeline: one entry per update that produced anything, oldest first, so "one
	// block a frame" is a table and not a claim. Keys: `frame`, `slot`, `ring`, `texels`, `bytes`.
	Array get_load_timeline() const;
	void clear_load_timeline();
	uint64_t get_frame_counter() const { return _frame_counter; }
	// The layout report: every scheme the packer evaluated with its bounding box and efficiency, the
	// chosen one, and the per-ring block counts. The task's "packing report" is this dictionary.
	Dictionary get_layout_report() const;
	// Per-ring readings, in ring order, for the dock and the tests.
	Array get_ring_reports() const;

private:
	// One thing to place: a block of a ring, that ring's spare, or the global block.
	struct PackedItem {
		int size = 0;
		int ring = -1;
		bool spare = false;
		bool global = false;
	};

	// The grid's half extent: `rings`, so the grid is `2 * rings + 1` cells an axis.
	int _grid_side() const { return 2 * _config.rings + 1; }
	// Which ring owns a grid coordinate: the 3x3 square (Chebyshev 0 and 1) is ring 0 and every
	// shell after it is one ring, which is what makes the counts 9, 16, 24, 32.
	static int _ring_of_cell(const int p_gx, const int p_gy);
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
	// the ring, which is why it is a ring reading rather than 81 stored offsets.
	Vector2i _ring_phase(const int p_ring, const Vector2 &p_focus) const;

	void _build_layout();
	// One packing scheme, run over the block sizes. Appends the placed items and their rects in the
	// order they were placed, so slot `i` is rect `i` and the ring identity survives the packing.
	void _pack_scheme(const int p_packer, std::vector<PackedItem> &r_items, std::vector<Rect2i> &r_rects,
			int &r_width, int &r_height) const;
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
	void _free_textures();
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
