// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_H
#define TERRAIN3D_CLIPMAP_H

// The clipmap delivery: a toroidal ring of power-of-two levels in one `Texture2DArray`, addressed by
// arithmetic rather than by an indirection page table.
//
// It is the fourth method of the delivery matrix (`terrain_3d_vt_delivery.h`) and the simplest of
// them by construction: no indirection texture, no allocator, no page table, no LRU. Level `l`
// covers `base_world * 2^l` metres in `size` texels, so its texel is `base_world * 2^l / size`
// metres wide, and a world position is answered by the finest level whose coverage contains it.
//
// **The ring is channel-agnostic, and that is the point.** This class is the *mechanism*: the
// levels, the addressing, the strips, the budget and the upload. What a texel holds is a
// `Terrain3DClipmapSource` (`terrain_3d_clipmap_source.h`) - the height source, the material
// source, and whatever comes next - so a second channel group selecting Clipmap is a new source
// object, not a second copy of this file, and the ring's own addressing tests run with no terrain
// and no channel at all.
//
// **The ring, and why content never moves.** A level's centre is snapped to its own texel size, so
// a stationary camera writes nothing and a moving one writes only the strips that its own coverage
// lost and gained. The stored texels do not move: the level carries a `ring` offset and the mapping
// is `physical = (logical + ring) mod size`, so a centre that moved `d` texels only turns the ring
// by `d` while a *logical* index keeps naming the same world position. Deriving a world position
// from the *physical* index without undoing the ring is the classic failure of this design, which is
// why `logical_of_physical()` is the only way a reader gets from a stored texel to a world position
// and why the deterministic tests drive every axis and both signs of wrap through it.
//
// **The budget.** A strip is at most `2 * size * |d|` texels, but a level that moved past its own
// coverage - or that has never been produced - is a full `size * size`, so production is queued as
// rect jobs and drained under a per-call budget. A level is `valid` only while every job that names
// it has drained; a level that is not valid still holds the level it replaces, which is what a
// caller that has not been switched to the ring yet reads anyway. The budget is counted in
// *channel texels* - one logical texel of one channel - so a multi-channel source pays for what it
// produces rather than for the texel it lands in.
//
// **`valid` is a rendering input, not a diagnostic.** A reader that samples the ring - the shader
// arm - serves a level only while it is `valid` and falls back to the source it can still trust
// otherwise, so a level that is mid-fill, mid-strip or mid-invalidation never reaches a fragment.
// That is what makes `invalidate_rect()` safe to be cheap: an edit turns the levels that cover it
// not-current, the fallback answers for the few ticks the re-production takes, and the ring takes
// over again when the rect has drained.
//
// **Uploading.** `RenderingServer::texture_2d_update()` replaces a whole layer of a layered texture,
// so a drained level is published as one layer update per channel and the byte count is reported
// (`get_upload_bytes()`): the CPU side is incremental and the transfer is not, and the number is
// published so the second half is a measurement rather than an assumption. See
// docs/vt_delivery_assembly.md section 6.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <memory>
#include <vector>

#include "generated_texture.h"
#include "terrain_3d_clipmap_source.h"

class Terrain3DClipmap {
	// The ring is not a Godot class, so it has to name itself for the log macro the way
	// `GeneratedTexture` does.
	CLASS_NAME_STATIC("Terrain3DClipmap");

public:
	// The most levels a ring can hold, and therefore the fixed size of the shader's per-level arrays
	// and of the dictionaries that bind them. One number for the clamp, the publish and the
	// declaration, so a ring that grew past the shader's arrays is not expressible.
	static constexpr int MAX_LEVELS = 16;
	// The shape of the ring. `size`, `levels` and `channels` are clamped by `configure()`.
	// `channels` is how many values a texel holds, one texture array layer each (slice
	// `level * channels + channel`); `format` is one *value's* format - `FORMAT_RF` (float32) or
	// `FORMAT_R8` (normalised) - because a layer holds exactly one value per texel. A channel that
	// needs several components is a different publish path, not a different ring.
	struct Config {
		int size = 256;
		int levels = 8;
		real_t base_world = 256.f;
		int channels = 1;
		Image::Format format = Image::FORMAT_RF;
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
		// Whether every texel of this level matches `center` and `ring` right now. False covers all
		// three reasons a level is not current - never filled, a strip queued, an edited rect queued -
		// because a reader's answer to all three is the same: read the source instead.
		bool valid = false;
	};

	// A rect of *logical* texels to produce, half-open on both axes. A rect is always a rect: a
	// column strip is `[size - d, size) x [0, size)` and every one of its rows is produced, which is
	// why where production stopped is separate state rather than a second shape. `cursor_*` names
	// the next value to produce - row, channel and column inside the rect - so a job the budget cut
	// short resumes at exactly the value after the last one it wrote, and a job that has not started
	// has its cursor at the rect's origin (what the constructor sets).
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
	// Frees the layered texture's RID; `GeneratedTexture` has no destructor of its own.
	~Terrain3DClipmap();

	// Sizes the ring for `p_size` texels an axis over `p_levels` levels, the finest covering
	// `p_base_world` metres. Reconfigures in place: content cannot survive a different shape, so
	// every level is invalidated and rebuilt from the next update. A no-op when nothing changed.
	void configure(const Config &p_config);
	void clear();

	bool is_configured() const { return _config.size > 0 && !_levels.empty(); }
	const Config &get_config() const { return _config; }
	int get_size() const { return _config.size; }
	int get_level_count() const { return int(_levels.size()); }
	int get_channel_count() const { return _config.channels; }
	Image::Format get_format() const { return _config.format; }
	String get_source_name() const;
	int get_level_valid_count() const;
	real_t get_base_world() const { return _config.base_world; }
	real_t get_texel_world(const int p_level) const;
	// Whether the coarsest level's own texel range contains a point. Inside it the ring answers;
	// outside it a reader must go elsewhere, because the level rule clamps to the coarsest level and
	// its edge texel names a different world position. The shader arm's gate is exactly this test;
	// `sample()` below deliberately does not apply it, so a reading can still ask what the ring holds.
	bool covers(const Vector2 &p_world) const;

	// One update: re-derive the jobs a new focus implies, drain them under the budget, publish the
	// levels that drained. Returns the number of channel texels produced by this call.
	int update(const Vector2 &p_focus, const int p_budget_texels);

	// The source changed under a world rect: mark every level the rect touches not-current and queue
	// the texels that cover it for re-production. Returns how many rect jobs were queued, and costs
	// the ring nothing when a level is already being produced whole (the values it has not written
	// yet are read from the source as it stands, edit included). Content outside the rect is
	// untouched, which is the difference between this and a whole-ring refresh: a brush stroke pays
	// for the texels it covers rather than for every level.
	int invalidate_rect(const Rect2 &p_world);

	// ---- Addressing: the mirror of the shader's arm -------------------------------------------
	// The finest level whose coverage contains `p_world`, clamped to the coarsest.
	int level_for_world(const Vector2 &p_world) const;
	// The stored value at a world position through the clipmap's own addressing: the level
	// `level_for_world()` selects, the texel its centre and ring put under that position. NAN when
	// the ring is not configured.
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const;
	// The world position the *centre* of a logical texel of a level stands for.
	Vector2 world_of_logical(const int p_level, const Vector2i &p_logical) const;

	Vector2i physical_of_logical(const int p_level, const Vector2i &p_logical) const;
	Vector2i logical_of_physical(const int p_level, const Vector2i &p_physical) const;

	// ---- Readings ------------------------------------------------------------------------------
	// A counter that moves whenever something a *reader's addressing* depends on changed: the shape,
	// any level's snapped centre and toroidal offset, and any level's validity. The shader arm binds
	// that state, so this is what lets the node rebind it once per change instead of once per tick -
	// a ring that produced nothing reports the same stamp and costs one integer comparison. See
	// `Terrain3D::_update_vt_clipmap_arm()`.
	uint64_t get_state_stamp() const { return _state_stamp; }
	RID get_texture_rid() const { return _texture.get_rid(); }	// `levels * channels`.
	int get_texture_layer_count() const { return _texture.get_layer_count(); }
	const Level &get_level(const int p_level) const { return _levels[p_level]; }
	Vector2 get_center(const int p_level) const { return _levels[p_level].center; }
	Vector2i get_ring(const int p_level) const { return _levels[p_level].ring; }
	uint64_t get_produced_texels() const { return _produced_texels; }
	uint64_t get_full_level_productions() const { return _full_productions; }
	uint64_t get_upload_bytes() const { return _upload_bytes; }
	uint64_t get_update_calls() const { return _update_calls; }
	uint64_t get_idle_updates() const { return _idle_updates; }
	// How many invalidations were asked for and how many texels they queued, so "an edit re-produces
	// the rect it covers rather than the ring" is a reading and not a claim about the code.
	uint64_t get_invalidation_calls() const { return _invalidation_calls; }
	uint64_t get_invalidated_texels() const { return _invalidated_texels; }
	int get_pending_jobs() const { return int(_jobs.size()); }
	// Per-level readings for the dock and the tests: one dictionary per level, in level order.
	Array get_level_reports() const;
	// The debug view's data, and deliberately a second method rather than a key of the one above:
	// this one also states the rects each level still has queued, in world space, so only a caller
	// that draws them pays for building them. One entry per level, in level order, with the same
	// shape/address keys as `get_level_reports()` plus `pending` and `pending_rects`.
	Array get_layout_reports() const;

private:
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
	// Copies every channel of one level into its layer of the ring texture and counts the bytes.
	void _publish_level(const int p_level);
	void _ensure_texture();

	Config _config;
	std::unique_ptr<Terrain3DClipmapSource> _source;
	std::vector<Level> _levels;
	std::vector<Job> _jobs;
	// One row of source values, reused so a production does not allocate.
	std::vector<float> _row_values;
	GeneratedTexture _texture;
	// The blank layer `ensure_layers()` is called with; one layer image per publish is allocated from
	// the bytes instead, because a queued `texture_2d_update()` holds the image it was given.
	Ref<Image> _layer_image;
	Vector2 _last_focus;
	bool _has_focus = false;
	uint64_t _produced_texels = 0;
	uint64_t _full_productions = 0;
	uint64_t _upload_bytes = 0;
	uint64_t _update_calls = 0;
	uint64_t _idle_updates = 0;
	uint64_t _invalidation_calls = 0;
	uint64_t _invalidated_texels = 0;
	// Bumped by every change the shader's copy of the ring has to follow. See `get_state_stamp()`.
	uint64_t _state_stamp = 1;
};

#endif // TERRAIN3D_CLIPMAP_H
