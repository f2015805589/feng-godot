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
		// The *baked* channels: this many arrays of `baked_format`, one layer per level, that a
		// compute producer writes through storage images and a reader samples whole. They exist
		// because a value with several components - baked material is albedo and height, an
		// octahedral normal and roughness, and the parameters - is not expressible as `channels`
		// values in `format`, and because the producer is a pass, not a row filler: it reads the
		// level's own texels and writes the level's own layer, so nothing travels through the CPU.
		// The ring owns the storage rather than the producer because the shape is the ring's - one
		// layer per level, at the ring's size, following its centres and its rings - and the producer
		// is handed the levels. Zero means a ring whose content is only what its source fills.
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
		// Whether every texel of this level matches `center` and `ring` right now. False covers all
		// three reasons a level is not current - never filled, a strip queued, an edited rect queued -
		// because a reader's answer to all three is the same: read the source instead.
		bool valid = false;
		// Whether the level's *baked* layers have been written for the content the level holds. A
		// separate flag because the two producers are separate passes over the same rect: the source
		// fills the strips from the CPU, the bake follows them on the device, and a reader that samples
		// the baked layers needs both - the rect the CPU side now holds and the layers the device side
		// wrote for it. It is derived from the ring's *bake rect queue* (`_refresh_baked()`): a level
		// with a produced rect no bake has covered is not baked, and one whose queue is empty has had
		// every rect of its content written. Cleared beside `valid` wherever the content starts moving,
		// because a level the CPU side is replacing is not a level the device side describes either.
		bool baked = false;
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

	// Sizes the ring from `p_config`: `size` texels an axis over `levels` levels, the finest covering
	// `base_world` metres, carrying `channels` values a texel in `format`. Reconfigures in place:
	// content cannot survive a different shape, so every level is invalidated and rebuilt from the
	// next update. A no-op when nothing changed.
	void configure(const Config &p_config);
	void clear();

	bool is_configured() const { return _config.size > 0 && !_levels.empty(); }
	const Config &get_config() const { return _config; }
	int get_size() const { return _config.size; }
	int get_level_count() const { return int(_levels.size()); }
	int get_channel_count() const { return _config.channels; }
	Image::Format get_format() const { return _config.format; }
	String get_source_name() const;
	// The shape the *source* declares, which is what `configure()` is called with: the mechanism's
	// owner asks the ring rather than knowing a channel, so the channel's shape travels with the
	// channel. The fallbacks are a one-value RF texel, i.e. what a ring with no source would be.
	int get_source_channel_count() const { return _source != nullptr ? _source->get_channel_count() : 1; }
	Image::Format get_source_format() const { return _source != nullptr ? _source->get_format() : Image::FORMAT_RF; }
	// The same for the baked channels: what the *source* says a producer bakes out of its texels. Read
	// by the owner when it configures the ring, so the declaration travels with the channel the way the
	// shape above does - `get_baked_channel_count()` is what this ring was configured with, which is 0
	// until the owner has asked this question once.
	int get_source_baked_channel_count() const {
		return _source != nullptr ? _source->get_baked_channel_count() : 0;
	}
	Image::Format get_source_baked_format() const {
		return _source != nullptr ? _source->get_baked_format() : Image::FORMAT_RGBAH;
	}

	// ---- The baked channels: what a compute producer fills --------------------------------------
	// The ring carries the storage and the shader's copy of it; the pass that fills it belongs to
	// whoever can bake, and it is handed the ring rather than the other way round. Nothing here
	// dispatches, and a ring with no baked channels answers with invalid RIDs rather than refusing.
	//
	// **The producer's work is the ring's own rects, one rect at a time.** A level is produced as
	// rects (a fill, a strip, an invalidated area), and the same rect is what a bake has to cover:
	// baking the level whole for every strip would throw away the strip model the whole mechanism is
	// built around. `_bake_rects` is therefore the queue: every rect this ring has produced and no bake
	// has covered yet, in the level's *stored* frame - the frame the payload layer is in, and the one
	// that keeps naming the same world position as the level turns - merged per level as it is produced.
	// A producer copies what it will dispatch and reports each rect back when its bake lands; the ring
	// keeps a rect whose lease moved, so "the level is baked" is a statement about what the device wrote
	// rather than about what was asked for.
	struct BakeRect {
		int level = 0;
		int x0 = 0;
		int y0 = 0;
		int x1 = 0;
		int y1 = 0;
		// The rect's own content, as a lease: the ring's shape and the level's content serial at the
		// moment this rect was last queued or merged. It is what makes a bake acceptable *per rect*
		// rather than per level - a rect that was not produced into again holds exactly the texels the
		// bake read, however many times the level moved around it - and it is refreshed when a rect
		// grows over new content, which is what makes the dispatch that covered the old rect stale.
		uint64_t lease = 0;
	};
	int get_baked_channel_count() const { return _config.baked_channels; }
	Image::Format get_baked_format() const { return _config.baked_format; }
	// One device texture per baked channel, `levels` layers, layer `l` the level `l`'s. The layer is
	// indexed exactly the way the level's payload layer is - by the *stored* texel, the one
	// `physical_of_logical()` names - so a reader samples a level's baked layer with the same addressing
	// it samples the payload with, and a producer writes a rect of stored texels. That frame is the one
	// that keeps naming the same world position as the level turns; see `_queue_bake_rect()` and
	// `shaders/surface_bake.glsl`.
	RID get_baked_device_rid(const int p_channel) const;
	// The same texture as a shader samples it, i.e. the `RenderingServer` wrapper of the above. What
	// the material's arm binds; a producer would bind the device RID instead.
	RID get_baked_texture_rid(const int p_channel) const;
	// Whether every rect this level has produced has been baked - which is what the arm gates on, and
	// what the *report* publishes per level. A level with nothing queued and nothing ever baked is not
	// baked: the layers it would serve hold nothing.
	bool is_level_baked(const int p_level) const { return _levels[size_t(p_level)].baked; }
	// How many disjoint rects of one level a reader can be told about. A level under a moving focus
	// queues one strip per movement, and the arm's gate is per rect, so the table has to cover what a
	// tick's own production can leave outstanding; beyond it the ring answers with the level's whole
	// square, which can only make a reader fall back more.
	static constexpr int MAX_OUTSTANDING_RECTS = 4;
	// The rects of *stored* texels a reader must not serve from this ring's baked layers right now, for
	// one level: the rects no bake has covered yet and the rects the CPU side is still producing. The
	// second kind is why this is a reading rather than a mirror of `_bake_rects`: between a job being
	// queued and the bake that follows it, the level's stored texels are being replaced and the layers
	// describe world positions the level no longer covers. Returns how many entries were written, up to
	// `p_max`; more than that is answered with one rect covering the level, because a reader that falls
	// back too much is correct while one that serves a texel the device has not written is not.
	int get_outstanding_rects(const int p_level, BakeRect *r_rects, const int p_max) const;
	// The rects this ring has produced and a producer has not yet covered, oldest first. The producer
	// copies what it will dispatch - with each rect's own lease, because that is what the bake reads -
	// and reports each rect back when its dispatch lands.
	int get_pending_bake_rect_count() const { return int(_bake_rects.size()); }
	const BakeRect &get_pending_bake_rect(const int p_index) const { return _bake_rects[size_t(p_index)]; }
	// A dispatch for `p_rect` landed. The ring says whether it still describes the level - the shape
	// and the level's content both have to match the lease the producer took - and forgets the rect
	// when it does. Returns whether the bake counted, so the producer's accounting is the ring's
	// answer too.
	bool acknowledge_bake_rect(const int p_level, const int p_x0, const int p_y0, const int p_x1,
			const int p_y1, const uint64_t p_lease);
	// Every level's baked layers are stale, which is what a change to the material the bake evaluates
	// against is: the payload is untouched, so the levels stay current - only the layers produced from
	// it are. Each level is queued whole. See `Terrain3DSurfaceBaker::set_materials()`.
	void mark_baked_stale();
	// A producer that is about to dispatch a rect takes the rect's lease - which the queue stored when it
	// queued it - and reports it back with the rect, and the ring accepts the bake only if the rect still
	// carries that lease: the shape, because a reconfigured ring has different layers (and clears its
	// queue), and the rect's content, because a rect that grew over new texels holds texels the bake
	// never read. A bake is dispatched on one thread and lands while another ticks, so the ring - not the
	// producer - is what says whether what the bake wrote still describes the rect. A lease that is not
	// current is dropped: the rect stays queued and is dispatched again.
	uint64_t take_bake_lease(const int p_level) const;
	// How many channel texels a producer has baked into this ring's layers and how many dispatches it
	// took, in the same currency the production budget is charged in (section 6.2), so a panel or a
	// test reads the bake's cost beside the fill's.
	uint64_t get_baked_texels() const { return _baked_texels; }
	uint64_t get_bake_dispatches() const { return _bake_dispatches; }
	// How many dispatches the ring *refused*: a rect whose level's content moved before the bake landed.
	// It is the number that says whether a focus which keeps moving is being baked at all - a rect the
	// ring refuses stays queued and is dispatched again, so a ring whose lease is too coarse accumulates
	// refusals and never reports a baked level.
	uint64_t get_bake_rejects() const { return _bake_rejects; }
	// The world rect one level's whole stored square covers, which is the rect a producer dispatches
	// over: `size` texels of `texel_world`, its first texel *centre* half a texel inside the origin.
	// The same rect the source fills from, so a producer that reads a level's texels reads exactly
	// the world the level it writes describes.
	Rect2 get_level_world_bounds(const int p_level) const;
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
	// Re-derives one level's `baked` from its queue. Every mutation of the queue goes through here, so
	// "is this level baked" is the queue's answer; a level whose content starts being replaced is
	// cleared directly beside `valid` as well, because that is the same statement - the layers no
	// longer describe what the level is being filled with - and the queue has not heard about it yet.
	void _refresh_baked(const int p_level);

	Config _config;
	std::unique_ptr<Terrain3DClipmapSource> _source;
	std::vector<Level> _levels;
	std::vector<Job> _jobs;
	// One row of source values, reused so a production does not allocate.
	std::vector<float> _row_values;
	GeneratedTexture _texture;
	// The baked channels, one device texture and one `RenderingServer` wrapper each, in channel
	// order. Both are created and freed together, and both are invalid on a ring with none.
	std::vector<RID> _baked_rd;
	std::vector<RID> _baked_rs;
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
	// Bumped only by a reconfigure or a clear: the shape a bake lease is taken against.
	uint64_t _shape_serial = 1;
	// One counter per level, bumped whenever the level stops being current, which is what makes a
	// lease taken before the bump stale. See `BakeRect::lease`.
	std::vector<uint64_t> _content_serial;
	// The rects of logical texels produced and not yet baked, oldest first, merged per level as they
	// are produced. One queue for the whole ring rather than one per level, because a producer drains
	// it in the order the ring produced, and the level is a field of the entry.
	std::vector<BakeRect> _bake_rects;
	// What a producer has written, in channel texels and dispatches. The same unit the production
	// budget is charged in, so the two halves of a ring's cost are one column in a report.
	uint64_t _baked_texels = 0;
	uint64_t _bake_dispatches = 0;
	// Dispatches this ring refused because the level's content moved first. See `get_bake_rejects()`.
	uint64_t _bake_rejects = 0;
};

#endif // TERRAIN3D_CLIPMAP_H
