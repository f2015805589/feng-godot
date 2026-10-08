// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_H
#define TERRAIN3D_CLIPMAP_H

// Toroidal power-of-two levels in a Texture2DArray, filled by a channel source.
// Level l covers base_world * 2^l metres in size texels. Sampling chooses the
// finest covering level; the shared ladder defines density.
//
// Centres snap to texels. Physical = (logical + ring) mod size preserves stored
// content while moving coverage queues only entering strips. Production is
// budgeted in channel texels; readers fall back while a level is incomplete.
//
// Uploads and bakes use produced rectangles in physical storage coordinates.
// Workers pack bytes; publish_pending_uploads performs device copies on the
// render thread. Bake leases reject results for replaced content.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <map>
#include <memory>
#include <vector>

#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_clipmap_impl.h"
#include "terrain_3d_clipmap_source.h"

// LOD storage implementation selected by Terrain3DClipmapLayer.
class Terrain3DClipmap : public Terrain3DClipmapImpl {
	// The ring is not a Godot class, so it has to name itself for the log macro the way the baked
	// channel storage does.
	CLASS_NAME_STATIC("Terrain3DClipmap");

public:
	// Shared limit for configuration and shader arrays.
	static constexpr int MAX_LEVELS = TerrainClipmap::MAX_LEVELS;
	// One texture-array layer per channel per level: level * channels + channel.
	struct Config {
		// Filled from the facade's shared Shape. Zero means a caller did not resolve a shape.
		int size = 0;
		int levels = 0;
		real_t base_world = 0.f;
		int channels = 1;
		Image::Format format = Image::FORMAT_RF;
		// Optional GPU-produced arrays, one layer per level and one array per channel.
		int baked_channels = 0;
		Image::Format baked_format = Image::FORMAT_RGBAH;
	};

	// One level's storage and its addressing. `texels` is the authority: the GPU layers are a copy
	// of it, published when the level's jobs have drained. Channelled texels are interleaved.
	struct Level {
		real_t world_size = 0.f;
		real_t texel_world = 1.f;
		// The snapped centre the stored content is aligned to.
		Vector2 center;
		// The toroidal offset, in texels, always reduced into [0, size).
		Vector2i ring;
		std::vector<float> texels;
		// All source texels match the current centre and ring.
		bool valid = false;
		// All produced rectangles have been baked for the current content.
		// Cleared with valid when production begins; refreshed from the bake queue.
		bool baked = false;
	};

	// Half-open logical rectangle with a row/channel/column cursor for budgeted resume.
	struct Job {
		int level = 0;
		int x0 = 0;
		int y0 = 0;
		int x1 = 0;
		int y1 = 0;
		int cursor_y = 0;
		int cursor_channel = 0;
		int cursor_x = 0;

		Job() = default;
		Job(const int p_level, const int p_x0, const int p_y0, const int p_x1, const int p_y1) :
				level(p_level), x0(p_x0), y0(p_y0), x1(p_x1), y1(p_y1),
				cursor_y(p_y0), cursor_channel(0), cursor_x(p_x0) {}
	};

	// The ring is built around one source. It is owned here, and it is the only thing that differs
	// between the channels this class can carry.
	explicit Terrain3DClipmap(std::unique_ptr<Terrain3DClipmapSource> p_source);
	// Frees the device texture, its renderer wrapper and the staging pool; none of them has a
	// destructor of its own.
	~Terrain3DClipmap();

	// Reconfigure changed shapes in place, invalidating old content; unchanged shapes are a no-op.
	void configure(const Config &p_config);
	void clear() override;

	bool is_configured() const override { return _config.size > 0 && !_levels.empty(); }
	int get_size() const override { return _config.size; }
	int get_level_count() const { return int(_levels.size()); }
	int get_unit_count() const override { return int(_levels.size()); }
	int get_channel_count() const override { return _config.channels; }
	Image::Format get_format() const override { return _config.format; }
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot) override {
		if (_source != nullptr) { _source->set_source_snapshot(p_snapshot); }
	}
	// Shared clipmap identity and sampling contract.
	TerrainClipmap::Implementation get_implementation() const override {
		return TerrainClipmap::Implementation::LOD;
	}
	TerrainClipmap::Ladder get_ladder() const override {
		return _ladder;
	}
	real_t get_unit_world_size(const int p_unit) const override {
		const int unit = CLAMP(p_unit, 0, MAX(0, int(_levels.size()) - 1));
		return _levels.empty() ? 0.f : _levels[size_t(unit)].world_size;
	}
	// The unit that serves a world position, and the texel size a fragment would be served there. The
	// shader's own arm is exactly this rule (`clipmap_level_for_world()`), which is why the two are
	// stated as one.
	int get_unit_for_world(const Vector2 &p_world) const override {
		return covers(p_world) ? level_for_world(p_world) : -1;
	}
	real_t get_texel_world_at(const Vector2 &p_world) const override {
		const int unit = get_unit_for_world(p_world);
		return unit < 0 ? 0.f : get_texel_world(unit);
	}
	bool covers(const Vector2 &p_world) const;
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const override;
	String get_source_name() const override;

	// Produced rectangles awaiting GPU baking, oldest first. Coordinates are physical
	// storage texels; unit names the level and lease identifies its content revision.
	using BakeRect = TerrainClipmap::BakeRect;
	// The producer copies each queued rectangle and acknowledges it after dispatch.
	int get_pending_bake_count() const override { return int(_bake_rects.size()); }
	const BakeRect &get_pending_bake(const int p_index) const override { return _bake_rects[size_t(p_index)]; }
	int get_baked_channel_count() const override { return _config.baked_channels; }
	Image::Format get_baked_format() const override { return _config.baked_format; }
	// One device array per baked channel, indexed by the same physical texels as the source.
	RID get_baked_device_rid(const int p_channel) const override;
	// The same texture as a shader samples it, i.e. the `RenderingServer` wrapper of the above. What
	// the material's arm binds; a producer would bind the device RID instead.
	RID get_baked_texture_rid(const int p_channel) const override;
	// Outstanding-rectangle table limit; overflow conservatively covers the full level.
	static constexpr int MAX_OUTSTANDING_RECTS = TerrainClipmap::MAX_OUTSTANDING_RECTS;
	// Physical rectangles still being produced or awaiting baking. If they exceed
	// p_max, return one full-level rectangle so readers conservatively fall back.
	int get_outstanding_rects(const int p_level, BakeRect *r_rects, const int p_max) const;
	// Acknowledge a dispatched rectangle only while its content lease still matches.
	bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) override;
	// Queue every baked level again after material changes; source texels stay valid.
	void mark_baked_stale() override;
	// Lease combines shape and per-level content revisions. Stale completions leave work queued.
	uint64_t take_bake_lease(const int p_level) const;
	// World bounds of the level; the first texel centre lies half a texel inside.
	Rect2 get_level_world_bounds(const int p_level) const;
	real_t get_texel_world(const int p_level) const;
	// The gate above is declared beside the shared contract (`covers()`), because it *is* part of it:
	// "does this layer reach that world position" is a question every implementation answers.

	// One update: re-derive the jobs a new focus implies, drain them under the budget, and queue the
	// upload and the bake of every rect that drained. Returns the number of channel texels produced
	// by this call. The device half of the upload is `publish_pending_uploads()`.
	int update(const Vector2 &p_focus, const int p_budget_texels) override;
	// Lands the uploads `update()` packed: one `texture_update()` + `texture_copy()` per stored
	// piece, on the thread the facade calls this from. Drops the queue when the device texture does
	// not exist to receive it.
	void publish_pending_uploads() override;
	// True when the ring has pending production, an invalid level, or a snapped centre that differs
	// from this focus. The owner uses this to avoid dispatching an idle worker task between texel moves.
	bool needs_update_at(const Vector2 &p_focus) const override;

	// Invalidate intersecting texels and queue their reproduction; existing full fills cover edits.
	int invalidate_rect(const Rect2 &p_world) override;

	// ---- Addressing: the mirror of the shader's arm -------------------------------------------
	// The finest level whose coverage contains `p_world`, clamped to the coarsest.
	int level_for_world(const Vector2 &p_world) const;

	Vector2i physical_of_logical(const int p_level, const Vector2i &p_logical) const;
	// Addressing stamp changes with shape, centre, ring or validity.
	uint64_t get_state_stamp() const override { return _state_stamp; }
	RID get_texture_rid() const override { return _texture_rid; }	// renderer wrapper of `_texture_rd`.
	int get_texture_layer_count() const override { return _texture_layers; }
	Vector2i get_ring(const int p_level) const { return _levels[p_level].ring; }
	uint64_t get_produced_texels() const override { return _produced_texels; }
	uint64_t get_upload_bytes() const override { return _upload_bytes; }
	uint64_t get_update_calls() const override { return _update_calls; }
	uint64_t get_idle_updates() const override { return _idle_updates; }
	int get_pending_jobs() const override { return int(_jobs.size()); }
	// Per-level readings for the dock and the tests: one dictionary per level, in level order.
	Array get_level_reports() const;
	// ---- The shared contract's debug half --------------------------------------------------------
	// One level's entry in the *shared* schema (`TerrainClipmap::UnitReport`), which is what the
	// facade assembles and a debug view or a test reads whichever implementation is selected.
	void get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const override;
	// What only the ring can say: the per-level centre, toroidal ring, world size and the stored-space
	// rects a producer must not serve. Nested by the facade, so the shared schema above is untouched.
	Dictionary get_impl_payload() const override;
	// This ring's own arm: the per-level centres/rings/validity, the outstanding-rect table and the
	// level rule. The material binds it, and the numbers here are the ones the shader's arm computes
	// with - one publish, so the two cannot drift.
	Dictionary get_arm() const override;
	Dictionary get_address_arm() const override;
	void get_address_uniforms(PackedVector4Array &r_addresses, PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const override;
	void get_outstanding_uniforms(PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const override;

private:
	// Per-call timings and work counts for the LOD implementation. Durations are accumulated in
	// nanoseconds so the per-row source/scatter split keeps useful precision; the debug payload exposes
	// them as microseconds. These are reset at the start of every update().
	struct UpdateDiagnostics {
		uint64_t update_ns = 0;
		uint64_t rebuild_schedule_ns = 0;
		uint64_t source_fill_ns = 0;
		uint64_t ring_scatter_ns = 0;
		uint64_t pack_ns = 0;
		uint64_t publish_ns = 0;
		uint64_t produced_texels = 0;
		uint64_t packed_texels = 0;
		uint64_t published_bytes = 0;
		int jobs_before = 0;
		int jobs_scheduled = 0;
		int jobs_completed = 0;
		int jobs_after = 0;
		int source_row_calls = 0;
		int levels_configured = 0;
		int levels_completed = 0;
		int published_uploads = 0;
	};

	// Reduces a signed texel index into [0, size). The two wraps - the map's and the source's - are
	// the trap the addressing tests exist for, so both go through here.
	int _wrap(const int p_value) const;
	// Whether a level's own texel range contains a world point - the half-open range the level
	// actually stores, which is what `level_for_world()` searches and what `covers()` reports.
	bool _contains_level(const int p_level, const Vector2 &p_world) const;
	void _rebuild_jobs(const Vector2 &p_focus);
	// Produces as much of one rect as the budget allows; leaves `p_job` naming what is left and
	// returns false when the budget ran out with the rect unfinished.
	bool _produce_rect(Job &p_job, int &r_budget);
	// Asks the source for one row segment of one channel and scatters it to its ring position.
	void _fill_row(const Job &p_job, const int p_channel, const int p_y, const int p_x0, const int p_x1);
	// Split a logical rectangle through the toroidal wrap into at most four physical rectangles.
	int _stored_rects_of_logical(const int p_level, const int p_x0, const int p_y0, const int p_x1,
			const int p_y1, Rect2i *r_rects) const;
	// Packs the produced rect's channel bytes and queues them for `publish_pending_uploads()` - one
	// upload per stored piece per channel, which is what makes a strip's transfer its own texels.
	void _queue_upload_rect(const int p_level, const int p_x0, const int p_y0, const int p_x1,
			const int p_y1);
	// The ring's device texture and renderer wrapper, allocated once the device is reachable. The
	// texture is the `CAN_COPY_TO` destination the rect upload writes into; the wrapper is the RID the
	// material and the bake producer bind (`resolve_main_texture` unwraps it back).
	void _ensure_texture();
	// Frees the wrapper, the device texture and every staging texture the upload pool holds.
	void _free_textures();
	// One staging texture per rect size published, pooled by dimensions: `texture_update()` demands a
	// whole layer's worth of bytes, so a staging texture's own size is what makes a transfer the rect's.
	RID _staging_for(const int p_width, const int p_height);
	// Allocates the baked channels when the shape calls for them and the device is reachable, and
	// frees the ones that are stale. Called from `configure()` and from `_ensure_texture()`, so a
	// ring configured before a device existed still gets its layers on the first publish.
	void _ensure_baked();
	// Frees both RIDs of every baked channel: the `RenderingServer` wrapper first, then the device
	// texture it wraps.
	void _free_baked();
	// Queues one *produced* rect (a rect of logical texels) for a bake, translated into the level's
	// stored frame and split when it crosses the wrap; a whole level stays one rect. See the definition
	// for why the stored frame is the one a baked layer is indexed in.
	void _queue_bake_rect(const int p_level, const int p_x0, const int p_y0, const int p_x1, const int p_y1);
	// One rect of *stored* texels joins its level's queue, merged with what is already there: a level
	// that turned twice before its first strip was baked is one rect, not two.
	void _queue_stored_bake_rect(const int p_level, const int p_x0, const int p_y0, const int p_x1, const int p_y1);
	// Refresh baked from the queue; starting source production also clears it directly.
	void _refresh_baked(const int p_level);

	Config _config;
	TerrainClipmap::Ladder _ladder;
	std::unique_ptr<Terrain3DClipmapSource> _source;
	std::vector<Level> _levels;
	std::vector<Job> _jobs;
	// One row of source values, reused so a production does not allocate.
	std::vector<float> _row_values;
	// Device array (levels * channels, at least two) and its renderer wrapper.
	// CAN_COPY_TO enables rectangle uploads.
	RID _texture_rd;
	RID _texture_rid;
	int _texture_layers = 0;
	// Staging textures keyed by width << 20 | height, plus packed per-channel uploads.
	std::map<uint64_t, RID> _staging_rd;
	struct PendingUpload {
		int layer = 0;
		Rect2i rect;
		PackedByteArray bytes;
	};
	std::vector<PendingUpload> _pending_uploads;
	// The baked channels, one device texture and one `RenderingServer` wrapper each, in channel
	// order. Both are created and freed together, and both are invalid on a ring with none.
	std::vector<RID> _baked_rd;
	std::vector<RID> _baked_rs;
	bool _has_focus = false;
	uint64_t _produced_texels = 0;
	uint64_t _full_productions = 0;
	uint64_t _upload_bytes = 0;
	UpdateDiagnostics _last_update_diagnostics;
	uint64_t _update_calls = 0;
	uint64_t _idle_updates = 0;
	uint64_t _invalidation_calls = 0;
	uint64_t _invalidated_texels = 0;
	// Bumped by every change the shader's copy of the ring has to follow. See `get_state_stamp()`.
	uint64_t _state_stamp = 1;
	// Bumped only by a reconfigure or a clear: the shape a bake lease is taken against.
	uint64_t _shape_serial = 1;
	// One counter per level, bumped whenever the level stops being current, which is what makes a
	// lease taken before the bump stale. See `BakeRect::lease`.
	std::vector<uint64_t> _content_serial;
	// Produced physical rectangles awaiting baking, oldest first and merged per level.
	std::vector<BakeRect> _bake_rects;
	// What a producer has written, in channel texels and dispatches. The same unit the production
	// budget is charged in, so the two halves of a ring's cost are one column in a report.
	uint64_t _baked_texels = 0;
	uint64_t _bake_dispatches = 0;
	// Dispatches this ring refused because the level's content moved first. See `get_bake_rejects()`.
	uint64_t _bake_rejects = 0;
};

#endif // TERRAIN3D_CLIPMAP_H
