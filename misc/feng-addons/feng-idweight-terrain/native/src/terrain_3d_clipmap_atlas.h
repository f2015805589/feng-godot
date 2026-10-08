// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_ATLAS_H
#define TERRAIN3D_CLIPMAP_ATLAS_H

// Block-atlas clipmap storage with a 3x3 grid per octave ring. Each block holds
// block_size texels across base_world * 2^ring metres. The finest covering
// ring serves the point; centre cells cover slivers caused by independent snapping.
//
// Movement relabels resident blocks and queues entering edges. Toroidal offsets
// preserve each block's content between block crossings. Optional per-ring spare
// slots allow replacements to finish before previous storage is recycled.
// Production is bounded by blocks_per_frame: coarse-first fill, fine-first scroll.
//
// The grid is world-XZ aligned. A coarse global block provides outer coverage.
// Workers pack block rectangles; the render thread publishes device copies.

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

// Atlas storage implementation selected by Terrain3DClipmapLayer.
class Terrain3DClipmapAtlas : public Terrain3DClipmapImpl {
	CLASS_NAME_STATIC("Terrain3DClipmapAtlas");

public:
	// Shared capacities for configuration, material bindings and shader tables.
	static constexpr int MAX_RINGS = TerrainClipmap::ATLAS_MAX_RINGS;
	static constexpr int MAX_CELLS = TerrainClipmap::ATLAS_MAX_CELLS;
	static constexpr int MAX_SLOTS = TerrainClipmap::ATLAS_MAX_SLOTS;
	static constexpr int MAX_CHANNELS = 16;
	// Packing schemes compared by bounding area and efficiency.
	enum Packer {
		// Every block of every ring in one descending-size shelf sequence: the smallest bounding
		// box, and the one that mixes the rings' blocks inside a row.
		PACK_SHELF = 0,
		// One horizontal band a ring, placed in ring order: a ring's blocks never share a row with
		// another ring's, which costs area and buys a layout a debug view can label.
		PACK_RING_BANDS = 1,
		// Recursive power-of-two quadrants; default layout.
		PACK_QUADTREE = 2,
		PACK_COUNT = 3,
	};

	struct Config {
		// Block resolution is constant across rings; world coverage doubles per ring.
		int block_size = 0;
		// How many units the atlas holds. Clamped to `[1, MAX_RINGS]`, and the layer's own
		// `vt_clipmap_levels` is what a user sets: unit `r` reaches `1.5 * base_world * 2^r` metres.
		int rings = 0;
		// Finest block width in metres; each ring covers a 3x3 grid of blocks.
		real_t base_world = 0.f;
		// Values a texel holds, one atlas texture layer each - the same shape the ring declares.
		int channels = 1;
		Image::Format format = Image::FORMAT_RF;
		// The global block: `global_texels` an axis over `global_world` metres, produced once. Zero
		// `global_world` derives it from the grid's own reach.
		int global_texels = 0;
		real_t global_world = 0.f;
		// One replacement slot per ring.
		bool spares = false;
		// Maximum completed blocks per update.
		int blocks_per_frame = 0;
		// Chosen layout; all schemes remain available for area comparisons.
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
		uint64_t serial = 0;
		bool resident = false;
		bool spare = false;
		bool global = false;
		// Baked arrays match this slot's content; reset when a slot is reused.
		bool baked = false;
	};

	// A cell in a moving 3x3 grid. Relabelling changes its slot index, not stored content.
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
		// Replacement slot, or -1. Keep current false until the replacement lands.
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

		Job() = default;
		Job(const int p_slot, const int p_ring, const int64_t p_block_x, const int64_t p_block_y) :
				slot(p_slot), ring(p_ring), block_x(p_block_x), block_y(p_block_y) {}
	};

	// The planner worker prepares tightly packed block bytes; the facade publishes them only after it
	// consumes that worker result on the render thread.
	struct PendingUpload {
		int staging = -1;
		Rect2i rect;
		int texels = 0;
		int channel = 0;
		std::vector<uint8_t> bytes;
	};

	// Shared bake entry: unit is the atlas slot and lease is its content serial.
	using BakeRect = TerrainClipmap::BakeRect;

	// Measured bounds and packing efficiency for one scheme.
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
	// Shared clipmap identity and octave density ladder.
	TerrainClipmap::Implementation get_implementation() const override {
		return TerrainClipmap::Implementation::Atlas;
	}
	TerrainClipmap::Ladder get_ladder() const override {
		return _ladder;
	}
	int get_unit_count() const override { return _config.rings; }
	// World width of the ring's 3x3 square: 3 * base_world * 2^unit.
	real_t get_unit_world_size(const int p_unit) const override {
		return real_t(UNIT_SIDE) * _block_world_of_ring(CLAMP(p_unit, 0, MAX_RINGS - 1));
	}
	int get_unit_for_world(const Vector2 &p_world) const override;
	real_t get_texel_world_at(const Vector2 &p_world) const override;
	int get_size() const override { return _config.block_size; }
	int get_channel_count() const override { return _config.channels; }
	Image::Format get_format() const override { return _config.format; }
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot) override {
		if (_source != nullptr) { _source->set_source_snapshot(p_snapshot); }
	}
	// Number of cells in the requested ring.
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
	// Centre of the grid's central block, snapped to whole blocks; shared with shader addressing.
	Vector2 get_ring_start(const int p_ring) const { return _ring_start(p_ring, _last_focus); }
	int get_cell_index(const int p_ring, const int p_gx, const int p_gy) const;
	int get_cell_slot(const int p_cell) const { return _cells[size_t(p_cell)].slot; }
	bool is_cell_current(const int p_cell) const { return _cells[size_t(p_cell)].current; }
	Vector2i get_cell_offset(const int p_cell) const { return _cells[size_t(p_cell)].offset; }
	// Cell covering a world point in this ring, or -1 outside its 3x3 grid.
	int cell_for_ring(const int p_ring, const Vector2 &p_world) const;
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const override;
	// The global block's own readings: the minimal-resolution resource outside the grid.
	int get_global_texels() const { return _config.global_texels; }

	// Baked RGBAH arrays share the source atlas rectangles. Producers use device RIDs;
	// materials use renderer wrappers. Unbaked channels allocate no arrays.
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
	// Produced blocks awaiting baking. Slot serials reject completion after content reuse.
	int get_pending_bake_count() const override { return int(_bake_rects.size()); }
	const BakeRect &get_pending_bake(const int p_index) const override { return _bake_rects[size_t(p_index)]; }
	bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) override;
	// Queue derived material arrays again while retaining source content.
	void mark_baked_stale() override;
	// The block's world square origin: the world XZ of the corner *before* the first texel's centre,
	// so content index `i` names `get_slot_block_origin() + (i + 0.5) * get_slot_texel_world()`.
	// This is the number the producer's job carries as its policy origin.
	Vector2 get_slot_block_origin(const int p_slot) const;
	real_t get_slot_texel_world(const int p_slot) const;

	// One update: re-derive the grid the focus implies, relabel the cells, queue the blocks that
	// entered, drain up to `blocks_per_frame` of them. Returns the channel texels produced.
	int update(const Vector2 &p_focus, const int p_budget_texels = 0) override;
	// True while the atlas needs production or its ring origin/phase differs from this focus.
	bool needs_update_at(const Vector2 &p_focus) const override;
	// Atlas payload packing can run on the planner worker; publish its device copies on the render thread.
	void publish_pending_uploads() override;
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
	// Completed-block timeline: frame, slot, ring, texels and bytes.
	Array get_load_timeline() const;
	// Scheme bounds, efficiencies, selection and per-ring block counts.
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
	// Queue waiting cells as slots become free across successive updates.
	void _reconcile_cells();
	// The slot that already holds the coordinate, or -1.
	int _find_slot(const int p_ring, const int64_t p_block_x, const int64_t p_block_y) const;
	int _take_free_slot(const int p_ring);
	int _slot_owner(const int p_slot, const bool p_include_pending) const;
	void _queue_block(const int p_cell, const int p_slot);
	void _produce_job(const Job &p_job);
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
	TerrainClipmap::Ladder _ladder;
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
	// Block-sized staging textures, one per channel.
	std::vector<RID> _staging_rd;
	std::vector<PendingUpload> _pending_uploads;
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
