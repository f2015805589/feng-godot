// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_BAKER_CLASS_H
#define TERRAIN3D_SURFACE_BAKER_CLASS_H

#include "constants.h"
#include "terrain_3d_clipmap.h"
#include "terrain_3d_vt_cells.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <cstdint>
#include <atomic>
#include <map>
#include <mutex>
#include <vector>

// The material group's sparse fine layer. Declared rather than included: the baker only holds a
// pointer to it and calls into it from the one translation unit that bakes its tiles, so the layer's
// own header (and the page pipeline it carries) does not become a dependency of every file that
// includes the baker.
class Terrain3DMaterialClipmapDetail;

/**
 * What a material page array can be stored in. This is deliberately a shorter list than the
 * shared texture-array vocabulary the asset inspector offers, and the two must not be
 * confused: an array of authored textures is compressed once on the CPU by the engine's own
 * encoders, while a page is produced and stored on the GPU every time an edit invalidates it.
 *
 * The albedo and parameter arrays use the RGBA codecs produced by the GPU block encoder. The
 * normal array is independent: its signed world normal is octahedrally packed into BC5 RG (or
 * the BC3N A/G compatibility layout), while roughness lives in the parameter array. This keeps
 * a normal's negative components out of a colour codec and leaves the persistent staging/SVT
 * representation canonical.
 *
 * Uncompressed is not a codec: the tier samples the staging arrays directly, exactly as it
 * would with no page compression at all.
 */
enum SurfacePageCompression {
	SURFACE_PAGE_UNCOMPRESSED = 0,
	SURFACE_PAGE_BC7,
	SURFACE_PAGE_BC3,
	SURFACE_PAGE_COUNT,
};
VARIANT_ENUM_CAST(SurfacePageCompression);

/** Storage requested for the signed world-normal page. -1 follows the diffuse request. */
enum SurfaceNormalCompression {
	SURFACE_NORMAL_AUTO = -1,
	SURFACE_NORMAL_UNCOMPRESSED = 0,
	SURFACE_NORMAL_BC5 = 1,
	SURFACE_NORMAL_BC3N = 2,
	SURFACE_NORMAL_BC7 = 3,
	SURFACE_NORMAL_COUNT = 4,
};
VARIANT_ENUM_CAST(SurfaceNormalCompression);

/**
 * Asynchronous material-page producer for the surface virtual texture.
 *
 * The object owns the compute resources and three main-rendering-device texture
 * arrays.  CPU callers only enqueue immutable page references under a mutex.  The
 * parent terrain registers render_pending() as a render-thread callback; that
 * callback snapshots the queue, uploads source pages and records a compute dispatch
 * without submitting or synchronously reading the GPU.
 *
 * The output arrays are deliberately separate from the IDWeight source atlas:
 * albedo_height.rgb/a stores the evaluated albedo and material height alpha,
 * normal_roughness.rgb/a stores a world normal and roughness, and
 * params.rgba stores normal depth, AO, AO affect and a validity bit.  Macro colour,
 * wetness, specular and lighting remain in the consumer material shader.
 */
class Terrain3DSurfaceBaker : public godot::RefCounted {
	GDCLASS(Terrain3DSurfaceBaker, godot::RefCounted);
	CLASS_NAME();

public:
	// The two tiers that produce pages into the one shared physical pool. They differ in
	// how their content is stored, not in where it lives: AVT pages are rebaked from live
	// region sources whenever an edit invalidates them, SVT pages are assembled once from a
	// baked cell and then never rewritten, so the two are allowed different codecs and
	// different sampling arrays over the same slot numbering.
	enum Tier {
		TIER_AVT = 0,
		TIER_SVT = 1,
		TIER_COUNT = 2,
	};

private:
	enum PendingKind {
		PENDING_BAKE = 0,
		PENDING_INVALIDATE = 1,
		PENDING_CACHED = 2,
		PENDING_CELL = 3,
	};

	struct PendingJob {
		int slot = -1;
		Array cells;
		PendingKind kind = PENDING_INVALIDATE;
		// Which tier's storage the page is produced into. The pool is shared, so a slot can
		// change tier when it is freed and handed to the other view; the tier travels with
		// the job that fills it.
		int tier = TIER_AVT;
		// Scratch layer this job's half-float content is written to. It equals the slot under
		// the page-sized staging arrays, and a ring page under the scratch regime.
		int staging_layer = -1;
		Ref<godot::Image> idweights;
		Ref<godot::Image> height;
		Ref<godot::Image> albedo_height;
		Ref<godot::Image> normal_roughness;
		Ref<godot::Image> params;
		godot::Rect2 world_rect;
		float slope_factor = 1.0f;
		Vector3 source_grid;
		uint64_t generation = 0;
		uint64_t sequence = 0;
	};

	// One tier's sampling arrays: each channel is optional. A raw channel samples the canonical
	// staging array while a compressed channel samples its matching target here.
	struct SampledSet {
		RID albedo_rd;
		RID normal_rd;
		RID params_rd;
		RID albedo_rs;
		RID normal_rs;
		RID params_rs;
		bool empty() const {
			return !albedo_rd.is_valid() && !normal_rd.is_valid() && !params_rd.is_valid() &&
					!albedo_rs.is_valid() && !normal_rs.is_valid() && !params_rs.is_valid();
		}
	};

	struct ResourceBundle {
		RID output_albedo_rd;
		RID output_normal_rd;
		RID output_params_rd;
		RID output_albedo_rs;
		RID output_normal_rs;
		RID output_params_rs;
		// Compressed copies of the three channels, one set per tier, sampled by the material
		// in place of the staging arrays. The staging arrays stay RGBA16F and writable by
		// imageStore; a compressed format cannot be a storage image, so the block encoder
		// copies between them.
		SampledSet sampled[TIER_COUNT];
		// The GPU block encoder: one compute pipeline that reads a staging layer through a
		// sampler and writes that layer's compressed blocks into one region of a storage
		// buffer. A block-compressed texture cannot be a storage image and no texture copy
		// converts formats, so the words travel back as a buffer readback - a few tens of
		// kilobytes per layer instead of the whole half-float page.
		RID encode_shader;
		RID encode_pipeline;
		RID encode_buffer;
		// One uniform set per channel: the staging array of that channel plus the output
		// buffer. Rebuilt with the bundle because it names the staging textures.
		RID encode_uniform[3];
		RID source_id_rd;
		RID source_height_rd;
		RID material_buffer;
		RID job_buffer;
		RID dummy_albedo_rd;
		RID dummy_normal_rd;
		RID uniform_set;
		RID cell_shader;
		RID cell_pipeline;
		RID pipeline;
		RID shader;
		RID sampler_nearest;
		RID sampler_linear;
	};

	mutable std::mutex _mutex;
	int _page_size = 0;
	int _border = 0;
	int _page_count = 0;
	int _requested_capacity = 0;
	int _resource_page_count = 0;
	int _stored_size = 0;
	// True when no paged tier is selected and the bundle exists for the ring's bake alone: the
	// shader, the material list, the job buffer and the samplers are built, and none of the
	// page-sized storage is. Written by `configure()` on the main thread and read by the render
	// callback and the bundle builder, so it is atomic like the tier state beside it.
	std::atomic<bool> _ring_only{ false };
	uint64_t _generation = 1;
	uint64_t _material_version = 1;
	uint64_t _next_sequence = 1;
	uint64_t _resource_generation = 0;
	bool _configured = false;
	bool _invalidate_all = false;
	bool _materials_dirty = true;
	// Set when a rebuild could not bind the snapshot's arrays, cleared by the next
	// set_materials(). Read by the main thread to decide whether to publish again.
	bool _materials_stale = false;
	RID _material_albedo_rs;
	RID _material_normal_rs;
	PackedByteArray _material_bytes;
	int _material_count = 0;
	std::map<int, PendingJob> _pending;
	// The producer handoff's cost, split into the wait for the queue's mutex and the work done
	// under it. See `get_queue_lock_stats()`.
	std::atomic<uint64_t> _queue_wait_us{ 0 }, _queue_hold_us{ 0 };
	std::atomic<uint64_t> _queue_calls{ 0 };

	// One *rect of a level* waiting for its bake, which is the ring's own unit of production: a fill, a
	// strip, an invalidated area. Everything the dispatch needs is copied in: the callback runs on
	// another thread than the one that owns the ring, so it holds no pointer into it, and the lease the
	// offer took is what the ring later uses to say whether what the bake wrote still describes the
	// level. The rect is in *stored* texels - the frame the ring's own payload and baked layers are in,
	// and the one that keeps naming the same world position as the level turns - and `level_origin` is
	// the level's world origin, which with the level's texel size and ring offset is the whole of what
	// the shader needs to turn a stored texel back into the world position it stands for.
	struct RingJob {
		int level = 0;
		uint64_t lease = 0;
		int x0 = 0;
		int y0 = 0;
		int x1 = 0;
		int y1 = 0;
		Vector2 level_origin;
		real_t texel = 1.f;
		Vector2i ring;
		int payload_layer = 0;
		int height_layer = 0;
		// The material list the rect was offered under. The bake reads whatever list the buffer
		// holds when it is dispatched, so a rect collected before a material replacement must not
		// be dispatched after it: the layers it would write describe the old materials, and the
		// ring would then be told they are current. A mismatch drops the job instead.
		uint64_t material_version = 0;
	};

	// The ring bake's state: the ring the set was built for (identity only - a ring is baked by the
	// baker it is offered to, and the lease, not the pointer, is what survives the dispatch), the
	// descriptor set that binds the ring's own atlas to the bake shader's two inputs and the ring's
	// three arrays to its outputs, and the three rect sets that make the one-tick separation:
	// `collected` is what the tick can bake now, `queued` is what the next render callback dispatches,
	// and `landed` is what a dispatch wrote and the next offer reports back to the ring. One ring at a
	// time, because the channel that declares baked layers is the material group's: a second one would
	// need a second entry and a second descriptor set, which is the shape a second baked channel would
	// take.
	struct RingBake {
		const Terrain3DClipmap *ring = nullptr;
		RID uniform_set;
		RID atlas_rd;
		// The bundle's job buffer the set was built against. It is part of the set's identity because
		// the set names that buffer: a bundle a generation later has its own, its predecessor is
		// retired and freed, and a dispatch from a set that outlived its buffer would either read a
		// job nobody wrote or bind a buffer the device has already released.
		RID job_buffer;
		int size = 0;
		std::vector<RingJob> collected;
		std::vector<RingJob> queued;
		std::vector<RingJob> landed;
		uint64_t dispatches = 0;
	};
	RingBake _ring_bake;
	// ---- The detail layer's bake -----------------------------------------------------------------
	// The material group's sparse fine layer (`Terrain3DMaterialClipmapDetail`) is baked by the same
	// shader as a page and the same shader as a ring rect: one *tile* is one page-shaped job, its
	// source the two layers the manager uploaded a pipeline result into, its output the manager's own
	// three arrays at the tile's slot. It is a separate path from the ring's rather than a third kind
	// of `RingJob` because the two differ in every part of their geometry: a ring rect names a
	// wrapping level in stored texels, a detail tile is an affine page rect with a gutter. What they
	// share is the job format, the material list and the one-tick separation, which is why one shader
	// and one job buffer serve both.
	struct DetailJob {
		int slot = -1;
		int level = 0;
		uint64_t generation = 0;
		Rect2 world_rect;
		// `(origin.x, origin.y, step)` of the source the pipeline produced - the *source* corner
		// grid, which is a different spacing from the tile's output texel.
		Vector3 source_grid;
		real_t texel = 1.f;
		int border = 0;
		int stored_size = 0;
	};
	struct DetailBake {
		Terrain3DMaterialClipmapDetail *detail = nullptr;
		RID uniform_set;
		RID payload_rd;
		RID height_rd;
		// Part of the set's identity for the same reason the ring's is: the set names this buffer,
		// and a bundle a generation later retires and frees its predecessor.
		RID job_buffer;
		int stored_size = 0;
		int slots = 0;
		std::vector<DetailJob> collected;
		std::vector<DetailJob> queued;
		std::vector<DetailJob> landed;
		uint64_t dispatches = 0;
		// Offers that reached this producer and could not be taken because its set was not ready:
		// the layer re-offers after its own timeout, so a nonzero count is a delay, and a count that
		// keeps growing is a set that never builds.
		uint64_t set_failures = 0;
		uint64_t offers_taken = 0;
	};
	DetailBake _detail_bake;
	// Builds the detail bake's descriptor set when there is none or when the layer it describes is
	// not this one, and frees the previous set. False when the layer cannot be baked at all - no
	// device, no bundle to take the material list and job buffer from, or an unfinished allocation.
	bool _ensure_detail_bake(Terrain3DMaterialClipmapDetail *p_detail);
	// Frees the descriptor set and forgets the identity it was built for, but *keeps* the three job
	// lists: a bundle rebuild replaces the job buffer the set names without invalidating the work the
	// layer already produced, and dropping that work would silently lose both a queued dispatch and a
	// landing that still owes the layer an acknowledgment.
	void _free_detail_set();
	// The whole bake: the set and the jobs. Called when the layer's shape changes and at teardown,
	// where the jobs describe a slot table that no longer exists.
	void _free_detail_bake();
	// The render callback's half: one dispatch for the queued tiles, recording what landed for the
	// next offer to acknowledge. Returns how many jobs were dispatched.
	int _dispatch_detail_bake();
	// Builds the ring bake's descriptor set when there is none or when the ring it describes is not
	// this one, and frees the previous set. False when the ring cannot be baked at all - no device, no
	// bundle to take the material list and job buffer from, or a channel count the bake shader does not
	// write - in which case the ring keeps serving nothing but its own texels.
	bool _ensure_ring_bake(Terrain3DClipmap *p_ring);
	void _free_ring_bake();
	// The render callback's half. Dispatches the queued levels into the ring's own layers and records
	// what landed; the next offer marks them. Returns how many jobs were dispatched.
	int _dispatch_ring_bake();
	// The albedo and normal arrays the bake samples, resolved to the device's own textures, with the
	// bundle's dummy arrays as the fallback for a snapshot the device no longer owns. Shared with the
	// page bake's descriptor set, so "which array does the bake read" has one answer.
	void _resolve_material_rd(const ResourceBundle &p_resources, RID &r_albedo_rd, RID &r_normal_rd,
			const RID &p_albedo_array_rs, const RID &p_normal_array_rs) const;
	// Consumer-visible readiness. With compression this becomes true only after all three
	// sampled layers were uploaded, not merely after the writable staging page finished.
	std::vector<uint8_t> _ready;
	std::vector<uint8_t> _sampled_channel_mask;
	// Frame each page's content was produced in, and how long the compressed ones then waited
	// for their encoded layers. This is the number that says whether an encode is stored in the
	// frame it was produced in or a few frames later, so it stays a permanent statistic.
	std::vector<uint64_t> _produced_frame;
	uint64_t _ready_latency_sum = 0;
	uint64_t _ready_latency_max = 0;
	uint64_t _ready_latency_samples = 0;
	std::vector<uint64_t> _slot_sequence;

	// These fields are touched by the render callback only, except for the output RS
	// RIDs which are copied under _mutex by the getters and clear().
	RenderingDevice *_rd = nullptr;
	ResourceBundle _resources;
	// Resident far-field cell sources, assigned by the main thread and read while a queued
	// cell copy runs on the render thread.
	Ref<Terrain3DCellStore> _cell_store;
	// Replaced bundles, each with the generation it belonged to. A bundle is freed only
	// once the material has acknowledged a newer published output: the virtual texture
	// pass runs before the draws of the frame that rebuilds the arrays, so the draws of
	// that same frame still sample the previous pair. Freeing on replacement instead
	// leaves one frame per rebuild drawing with freed texture RIDs, which the renderer
	// reports as a missing uniform set.
	std::vector<std::pair<uint64_t, ResourceBundle>> _retired;
	// Generation of the bundle the material was last bound to. 0 means none yet.
	uint64_t _acknowledged_generation = 0;
	// Frame the acknowledgment above arrived on. The material's new RIDs are published to
	// the renderer on the main thread and reach the drawn material a frame or more later, so
	// the release waits RETIRE_FRAME_MARGIN frames after this before it honours the
	// acknowledgment. Freeing sooner can still catch a draw prepared with the old pair, which
	// the renderer reports as a missing material uniform set.
	uint64_t _acknowledged_frame = 0;
	bool _retire_ready = false;

	uint64_t _render_frame = UINT64_MAX;
	int _frame_page_updates = 0;
	std::atomic<int> _page_budget{ 16 };
	// Per-tier storage format. Written by the resolver on the main thread and read by the
	// resource builder on the render thread, so both halves of a resolved tier state are
	// atomic. Each tier resolves independently: a request refused for one tier leaves the
	// other tier's format alone.
	struct TierState {
		int requested = 0;
		std::atomic<int> effective{ 0 };
		std::atomic<int> applied{ 0 };
		int normal_requested = SURFACE_NORMAL_AUTO;
		std::atomic<int> normal_effective{ SURFACE_NORMAL_UNCOMPRESSED };
		std::atomic<int> normal_applied{ SURFACE_NORMAL_UNCOMPRESSED };
		// The codec's linear renderer format. The normal and parameter pages hold linear
		// data - a direction, a ratio, a height - so they are stored in it.
		std::atomic<RenderingDevice::DataFormat> format{ RenderingDevice::DATA_FORMAT_MAX };
		// The codec's sRGB renderer format, used by the albedo page alone, which is a colour:
		// the encoder writes the sRGB encoding of the linear staging value and the hardware
		// decodes it back on sampling, so the codec's quantisation is spent in the space it
		// was designed for instead of on linear values whose darks fall below its first step.
		std::atomic<RenderingDevice::DataFormat> format_srgb{ RenderingDevice::DATA_FORMAT_MAX };
		// Linear channel formats are derived by the shared codec mapping. The public tier
		// setting unifies them; backend compatibility overrides may still select them separately.
		std::atomic<RenderingDevice::DataFormat> normal_format{ RenderingDevice::DATA_FORMAT_MAX };
		std::atomic<RenderingDevice::DataFormat> params_format{ RenderingDevice::DATA_FORMAT_MAX };
		std::atomic<bool> params_encoded{ false };
		godot::String reason;
		godot::String normal_reason;
	};
	TierState _tiers[TIER_COUNT];
	void _resolve_tier_compression(int p_tier);
	void _resolve_tier_normal_compression(int p_tier);
	// Which tier last produced each slot's content, so the encoder knows where to store it
	// and the material binding knows which array set serves it.
	std::vector<uint8_t> _slot_tier;
	// Staging and sampled channel accessors, so a channel is addressed by index.
	static RID _staging_rd_of(const ResourceBundle &p_resources, int p_channel);
	RID _staging_rd(int p_channel) const;
	RID _sampled_rd(int p_tier, int p_channel) const;
	RID _sampled_rs(int p_tier, int p_channel) const;
	// Bit 0/1/2 are albedo, normal and params. The resolved mask is used while a bundle is
	// being allocated; the applied mask is what the current bundle actually owns.
	uint8_t _tier_channel_mask(int p_tier, bool p_applied) const;
	int _tier_channel_codec(int p_tier, int p_channel, bool p_applied) const;
	bool _tier_channel_uses_sampled(int p_tier, int p_channel) const;
	bool _tier_uses_sampled(int p_tier) const;
	bool _any_tier_uses_sampled(bool p_applied) const;
	// The scratch regime: every tier is stored compressed, so nothing samples the RGBA16F
	// staging arrays and they do not have to be page sized at all. Production then writes
	// into one scratch layer per page - the same ring page the block encoder reads from and
	// whose readbacks hold it - and the half-float pool collapses from `page_count` layers to
	// ENCODE_PAGES. A tier left uncompressed samples the staging array by slot, which is what
	// keeps the arrays page sized in that case.
	bool _staging_is_scratch() const;
	// Scratch layer each slot's current content was produced into, meaningful only while
	// _staging_is_scratch().
	std::vector<uint8_t> _slot_scratch;
	// Layers the staging and source arrays carry: the ring under the scratch regime, one per
	// physical slot otherwise.
	int _staging_layers = 0;
	// Pages whose staging content changed and whose compressed copy is stale.
	std::vector<uint8_t> _encode_pending;
	bool _encode_warned = false;
	// Pages the encoder may have in flight at once. Each in-flight page owns one output
	// region per channel, and a page's regions are only handed out again once every readback
	// of that page has been delivered, so a readback can never observe a later page's blocks.
	// This bounds the encoder at a few hundred kilobytes instead of one region per physical
	// slot, which is what keeps compression a storage decision rather than another page-sized
	// allocation per slot.
	//
	// The admitted depth is not a constant. A page holds its regions until its readbacks
	// arrive, and the render graph delivers them about two frames after the recording that
	// asked for them, so the ring has to hold the caller's whole page budget times that
	// latency. Measured with the previous fixed depth of eight and a sixteen page budget, a
	// compressed tier became ready at four pages per frame - eight pages every two frames -
	// however much the demand asked for, because the ring, not the budget, decided the rate.
	//
	// Above `ENCODE_PAGES_MAX / ENCODE_READBACK_FRAMES` pages a frame the ring, not the
	// budget, is the rate again, so this is the number a caller raising the budget has to
	// raise too. It is deliberately not the byte ceiling: pages a tier does not compress cost
	// three encoded regions and no staging layer, so a page-sized run can afford far more
	// positions than the scratch regime can, and the byte ceiling below is what bounds that
	// case.
	static constexpr int ENCODE_PAGES_MIN = 8;
	static constexpr int ENCODE_PAGES_MAX = 256;
	static constexpr int ENCODE_READBACK_FRAMES = 2;
	// The same ring is the staging pool under the scratch regime, so its depth is bounded by
	// bytes rather than by pages: this is the ceiling a derived depth may cost.
	//
	// It is a *staging* bound, not a rate. The rate is `surface_vt_page_batch_max` and the producer's
	// frame budget, which is what the tick hands the near field; the ring only has to be deep
	// enough to hold the pages the batch and the far field put in flight for the two frames the
	// readback takes, and `_derive_encode_ring_pages()` sizes it from exactly that. Deepening it
	// to raise the rate was tried and is a bypass of the batch bound, not a mechanism: it buys
	// throughput the batch is supposed to bound. Measured cost at the shipped value on the
	// reference project: `_encode_page_bytes()` is ~2.12 MB, so the ~43 positions it resolves to
	// are ~91 MB of staging and encoder regions.
	static constexpr int64_t ENCODE_RING_BUDGET_BYTES = 96 * 1024 * 1024;
	static constexpr int ENCODE_CHANNELS = 3;
	// `_slot_scratch` entry of a slot that has no ring page: either the page is not produced
	// yet, or the arrays are page sized and the slot names its own layer.
	static constexpr uint8_t ENCODE_RING_NONE = 0xff;
	// Bytes one encoded layer occupies at the widest codec, and the same count in words.
	// Both are a function of the stored page size, so they are set with the resources.
	int _encode_region_bytes = 0;
	int _encode_region_words = 0;
	// Ring depth. `allocated` is what the vectors, the staging layers and the encoder's output
	// buffer were sized for, `capacity` is what the ring admits right now. The admitted depth
	// never exceeds the allocated one - those buffers are fixed at bundle build - so the
	// allocation is made for the whole ceiling rather than for the budget of the moment: a
	// budget the caller raises later is then served by that headroom instead of being silently
	// capped at whatever the setting happened to be on the frame the bundle was built. Measured
	// (alignment document section 7.7.12): with an allocation derived from the build-time
	// budget, raising `vt_pages_per_update` from 16 to 64 in a running session changed the
	// tick's split and the plan's tail and nothing about the page rate. The render thread
	// writes both while the caller's `set_page_budget()` reads them, so they are atomic.
	std::atomic<int> _encode_ring_allocated{ ENCODE_PAGES_MIN };
	std::atomic<int> _encode_ring_capacity{ ENCODE_PAGES_MIN };
	// The peak the caller's page-budget settings can reach. It is a *configuration* number, not the
	// rate of the tick: the ring is allocated once, when the bundle is built, and the byte ceiling
	// below is only what it may ever hold on its own. Sizing the allocation from the rate of the
	// moment would make every escalation a rate its own staging never had - the measured failure
	// section 7.7.12 records - so the caller publishes its peak instead and the byte ceiling stays
	// the floor for a caller that never sets one.
	std::atomic<int> _page_budget_ceiling{ ENCODE_PAGES_MIN };
	// Bytes one ring position costs - the encoder's three regions plus the half-float staging
	// layer the same position owns under the scratch regime. Two depths are derived from it,
	// and they are different questions: the ceiling is what the ring may *ever* hold (bytes,
	// the slot count and `ENCODE_PAGES_MAX`), and the admitted depth is what the caller's
	// budget needs of it for the frames a readback takes.
	int64_t _encode_page_bytes() const;
	int _encode_ring_depth_ceiling() const;
	int _derive_encode_ring_pages() const;
	// Re-derives the admitted depth from the current page budget.
	void _refresh_encode_ring_capacity();
	// Bytes the three sampled arrays of one tier cost, or 0 when it has none.
	int64_t _tier_sampled_bytes(int p_tier) const;
	// Channel readbacks still outstanding for each in-flight page in the ring; 0 is free.
	// Guarded by _encode_mutex with _encoded_layers: the completion callback runs in the
	// frame stall, not in the render callback.
	std::vector<uint8_t> _encode_ring_held;
	// Encoded layers waiting for a recording point. A readback callback runs inside the
	// frame stall, which is after the frame's draw graph was ended and immediately before
	// the next one is begun, so a texture_update() issued from there is recorded into the
	// finished graph and discarded when the new one starts: the compressed arrays stayed
	// empty while every upload reported success. The callback therefore only queues, and the
	// render callback - which runs inside the recording - performs the uploads.
	struct EncodedLayer {
		int channel = 0;
		int slot = 0;
		int tier = TIER_AVT;
		uint64_t generation = 0;
		uint64_t sequence = 0;
		godot::PackedByteArray data;
	};
	// Async readback completion may not share the render callback's execution context.
	// Protect the completion queue, the ring and their generation/slot tokens explicitly.
	std::mutex _encode_mutex;
	std::vector<EncodedLayer> _encoded_layers;
	// Counters for the compressed-page pipeline, reported by get_stats() so a page that
	// is ready in the staging arrays but never reaches the sampled ones is visible
	// instead of only showing up as blank material in the viewport.
	uint64_t _encode_requests = 0;
	uint64_t _encode_readbacks = 0;
	uint64_t _encode_updates = 0;
	uint64_t _encode_failures = 0;
	// Records the block-encoder dispatches for every pending page that has a free output
	// region, and requests one buffer readback per channel.
	void _request_encodes();
	void _flush_encodes(uint64_t p_generation);
	// Frees the resource bundles the material has stopped sampling, from the frame after it
	// acknowledged the pair it is drawn with. Called from `render_pending()`, on the render thread,
	// before the frame's own resources are ensured. See the definition for why the acknowledgment is
	// only honoured from the following frame.
	void _retire_acknowledged_bundles();
	// One frame's job list, drained from the pending queue. With `p_invalidate_all` the list is one
	// job per slot - the queued job where there is one, an invalidation where there is not - and
	// otherwise it is exactly what was queued.
	std::vector<PendingJob> _build_frame_jobs(const std::map<int, PendingJob> &p_pending,
			bool p_invalidate_all, uint64_t p_generation, int p_page_count) const;
	// One frame's page production and dispatch. Returns false when the job recording failed, in
	// which case the frame did nothing and the caller must return. See the definition.
	bool _dispatch_frame_jobs(std::vector<PendingJob> &p_jobs, uint64_t p_generation,
			uint64_t p_material_version, int p_page_count, int p_page_size, int p_border,
			int p_stored_size, int p_material_count, bool p_invalidate_all,
			Terrain3DCellStore *p_cell_store);
	// Decrements the outstanding readback count of one ring page. Called from the completion
	// callback, which takes the encode mutex alone; the caller checks the page's generation
	// and sequence against the world state in its own scope.
	// Sets one ring page's outstanding readback count, and releases one on completion.
	void _hold_encode_page(int p_page, int p_outstanding);
	void _release_encode_page(int p_page);
	// Takes a free ring page for a page about to be produced, or -1 when all of them are held.
	// Under the scratch regime this also reserves the scratch layer the production writes to,
	// because a produced page's half-float content only exists until its blocks arrive.
	int _take_staging_layer(int p_slot);
	void _on_encode_readback(const PackedByteArray &p_data, int p_slot, int p_channel, int p_tier,
			int p_page, uint64_t p_generation, uint64_t p_sequence);
	void _mark_encode_failed(int p_slot, uint64_t p_generation, uint64_t p_sequence);
	bool _upload_encoded_layer(int p_tier, int p_channel, int p_slot, uint64_t p_generation,
			uint64_t p_sequence, const godot::PackedByteArray &p_data);
	void _mark_sampled_channel_ready(int p_tier, int p_slot, int p_channel, uint64_t p_generation,
			uint64_t p_sequence);
	uint64_t _dispatch_count = 0;
	uint64_t _baked_pages = 0;
	uint64_t _cached_uploads = 0;
	uint64_t _migrated_pages = 0;
	uint64_t _invalidated_pages = 0;
	uint64_t _source_uploads = 0;

	// A replaced bundle is released on the render thread. Its RIDs are collected into two
	// lists instead of being threaded through a bound-argument list, so a new resource does
	// not have to be added in three places: the RS wrappers first, then the device
	// resources, with descriptor and pipeline objects ahead of what they reference.
	static void _collect_bundle_rids(const ResourceBundle &p_resources, godot::Array &r_rs_rids,
			godot::Array &r_rd_rids);
	static void _free_rids(RenderingDevice *p_rd, const godot::Array &p_rs_rids,
			const godot::Array &p_rd_rids);
	static void _free_deferred(const godot::Array &p_rs_rids, const godot::Array &p_rd_rids);
	static void _free_bundle(RenderingDevice *p_rd, const ResourceBundle &p_resources);
	static RID _create_texture(RenderingDevice *p_rd, RenderingDevice::DataFormat p_format,
			int p_size, int p_layers, uint64_t p_usage, const PackedByteArray &p_first_layer = PackedByteArray());
	static RID _create_sampler(RenderingDevice *p_rd, RenderingDevice::SamplerFilter p_filter,
			RenderingDevice::SamplerRepeatMode p_repeat, float p_max_lod);

	// Moves the current bundle out and returns the generation it belonged to, so the
	// caller can retire it against the material's acknowledgment.
	uint64_t _take_resources(ResourceBundle &r_resources);
	// Takes the main device the first time a bundle is needed. False when there is no device.
	bool _acquire_device();
	// The producer's core: the dummy sampling arrays, the samplers, the material table, the job
	// buffer and the bake pipeline. Built for every bundle, including a ring-only one, because a
	// ring's bake needs exactly these and nothing a page owns.
	bool _create_bake_core_resources(ResourceBundle &r_next, const PackedByteArray &p_material_bytes,
			int p_page_count);
	// The page half: the per-tier compressed sets, the half-float staging pool the page-sized source
	// and output arrays, and the choice between page-sized and ring-deep staging. Built only while a
	// paged tier is selected; a ring-only bundle never allocates any of it.
	bool _create_page_resources(ResourceBundle &r_next, int p_stored_size, int p_page_count);
	// Carries a grown pool's finished pages into the bundle replacing it, and queues the old bundle for
	// retirement. Returns false - with `p_next` freed - when a copy fails.
	bool _adopt_grown_pages(const ResourceBundle &p_old, ResourceBundle &p_next, int p_old_count,
			const std::vector<uint8_t> &p_ready, uint64_t p_old_generation, int p_stored_size);
	// Adopts a finished bundle as the one this baker produces into, resizing everything indexed by the
	// page count together.
	void _adopt_bundle(ResourceBundle &p_next, uint64_t p_generation, int p_page_count);
	bool _ensure_resources(uint64_t p_generation, int p_page_count,
			int p_stored_size, const RID &p_albedo_array_rs, const RID &p_normal_array_rs,
			const PackedByteArray &p_material_bytes);
	bool _rebuild_uniform_set(ResourceBundle &r_resources, const RID &p_albedo_array_rs,
			const RID &p_normal_array_rs);
	bool _compile_pipeline(ResourceBundle &r_resources);
	bool _compile_encode_pipeline(ResourceBundle &r_resources);
	bool _upload_materials(const PackedByteArray &p_material_bytes);
	bool _upload_source_page(const PendingJob &p_job, int p_layer);
	bool _upload_cached_page(const PendingJob &p_job);
	bool _copy_cell_page(const PendingJob &p_job, Terrain3DCellStore *p_store);
	PackedByteArray _image_bytes(const Ref<godot::Image> &p_image, godot::Image::Format p_expected_format,
			int p_bytes_per_pixel) const;
	bool _record_jobs(std::vector<PendingJob> &p_jobs, uint64_t p_generation, int p_page_size,
			int p_border, int p_stored_size, int p_material_count);
	void _set_ready(int p_slot, bool p_ready, uint64_t p_generation, uint64_t p_material_version,
			uint64_t p_sequence);

	static void _bind_methods();

public:
	Terrain3DSurfaceBaker() = default;
	~Terrain3DSurfaceBaker() override;

	void configure(int p_page_size, int p_border, int p_page_count, bool p_ring_only = false);
	// Storage format of the material page arrays, per tier, written in SurfacePageCompression.
	// Each tier's three arrays share one format. Which codecs a page can be stored in at all
	// is decided by that enum; what remains is a device question, so a request is resolved
	// once against this device's sampling and update support, and
	// get_tier_compression_info() reports what was applied and why a request was refused.
	//
	// The tiers are independent because their content is: an AVT page is rewritten whenever
	// an edit invalidates it, while an SVT page is assembled once from a baked cell and then
	// never rewritten. A codec that costs an encode per production is therefore worth its
	// cost for one tier and not necessarily for the other.
	void set_tier_compression(int p_tier, int p_mode);
	void set_tier_normal_compression(int p_tier, int p_mode);
	Dictionary get_tier_compression_info(int p_tier) const;
	void request_capacity(int p_count);
	// True while a larger capacity has been requested but the arrays are still the old size.
	// A caller that would produce pages into the old size can wait a frame or two instead:
	// growth replaces the arrays and releases the pages produced against the old count.
	bool has_pending_capacity() const;
	// Pages produced per frame. The caller's budget, and the only thing that decides the
	// rate: compression re-encodes a page on the GPU after it is produced, so it must not
	// change how many pages a demand pass hands the producer.
	void set_page_budget(int p_pages);
	// The most pages a frame may be asked for, i.e. the peak of the page-budget settings rather than
	// the tier in force this tick. The ring's *allocation* is made for this when the bundle is built
	// (its *admitted* depth still follows `set_page_budget()`), so a configuration whose tiers reach
	// above the shipped 16 has the staging to serve them and a tick that escalates does not have to
	// rebuild anything to be admitted. Leaving it at its default keeps the byte ceiling in charge.
	void set_page_budget_ceiling(int p_pages);
	int get_page_budget_ceiling() const { return _page_budget_ceiling.load(); }
	int get_capacity() const;
	bool has_render_work() const;
	// True when the last material snapshot could not be bound because the arrays it named were
	// already freed by a newer asset edit. The caller has to publish the current pair again:
	// the producer cannot recover on its own, and retrying the dead snapshot is what produced
	// an engine error, and a bake from the fallback array, for every frame after the edit.
	bool materials_stale() const;
	void acknowledge_output(const RID &p_albedo);
	void set_materials(const RID &p_albedo_array_rid, const RID &p_normal_array_rid,
			const PackedColorArray &p_colors, const PackedFloat32Array &p_normal_depths,
			const PackedFloat32Array &p_ao_strengths, const PackedFloat32Array &p_ao_affects,
			const PackedFloat32Array &p_roughness_mods, const PackedFloat32Array &p_uv_scales,
			const PackedVector2Array &p_detiles, const PackedVector3Array &p_slope_params);
	// A page is produced for one tier's storage, and the tier is the caller's to state: the
	// far field bakes from the resident region payloads exactly like the near field, so the
	// content alone does not say whose arrays the slot ends up in. Only the view that owns
	// the slot knows that.
	void queue_page(int p_slot, const Ref<godot::Image> &p_idweights, const Ref<godot::Image> &p_height,
			const godot::Rect2 &p_world_rect, float p_slope_factor = 1.0f, Vector3 p_source_grid = Vector3(),
			int p_tier = TIER_AVT);
	void queue_cached_page(int p_slot, const godot::Dictionary &p_channels, int p_tier = TIER_SVT);
	// Cell pieces either name a resident cell (layer + level, copied from the GPU cell
	// store) or carry cropped images to upload first.
	void queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect, int p_tier = TIER_SVT);
	// The resident cell sources the far field copies from. Held by reference so a bake
	// published on the main thread cannot be freed while a copy that names its layer is
	// still queued.
	void set_cell_store(const Ref<Terrain3DCellStore> &p_store);
	void invalidate_slot(int p_slot);

	// ---- The ring's bake -------------------------------------------------------------------------
	// A ring that declares baked channels is baked by the same shader that bakes a page, because a job
	// carries its own geometry and its own input layers: one *rect of a level* is one job, its rect the
	// one the ring produced, and nothing in this path knows what a page or a codec is. The caller offers
	// the ring once a tick with the same budget the ring's own production is charged in - channel
	// texels, a soft floor of one rect per offer - and the rects this call can bake are handed to the
	// render callback, which dispatches them and records that they landed. The *next* call reports each
	// landed rect back to the ring, which is what decides whether the bake still describes the level.
	// The one-tick separation is not an optimisation: a rect's payload reaches the ring through
	// RenderingServer's queue while the bake is a device dispatch, and issuing both for one rect in one
	// tick would let the bake read the payload the rect is replacing. Returns how many rects this call
	// offered, which is not how many are baked - that is `Terrain3DClipmap::is_level_baked()`.
	int queue_clipmap_ring(Terrain3DClipmap *p_ring, const int p_budget_texels);

	// The detail layer's offer, beside the ring's. The caller offers the layer once a tick with the
	// same budget the layer's own production is charged in (channel texels, a soft floor of one tile
	// per offer) and the tiles this call can bake are handed to the render callback, which dispatches
	// them and records that they landed. The *next* call reports each landed tile back to the layer,
	// which decides whether the bake still describes the generation the slot was handed out under.
	// Returns how many tiles this call offered, which is not how many are baked - that is the layer's
	// `valid` count.
	int queue_detail_tiles(Terrain3DMaterialClipmapDetail *p_detail, const int p_budget_texels);
	// The detail bake's own accounting: the dispatches it recorded, and the tiles still queued.
	Dictionary get_detail_bake_stats() const;
	// Drops everything this producer holds for the detail layer: its descriptor set (which names the
	// layer's own textures and this bundle's job buffer) and the three job lists. The layer's lifetime
	// is the node's - `_setup_vt_material_detail()` frees it whenever the material group leaves the
	// ring, exactly as the plan requires a deselection to release the layer's storage - so the
	// producer must be told before that happens. Without this the set would name freed textures and,
	// worse, `_detail_bake.detail` would be a pointer to a manager that no longer exists.
	void drop_detail_bake();

	// Called by the parent through RenderingServer::call_on_render_thread().  The
	// keep-alive is intentionally unused; binding a Ref<RefCounted> to the Callable
	// keeps this object alive until the callback has returned.
	void render_pending(const Ref<godot::RefCounted> &p_keep_alive = Ref<godot::RefCounted>());

	RID get_albedo_rid() const;
	RID get_normal_rid() const;
	RID get_params_rid() const;
	// Generation of the arrays get_published_arrays() would hand out, or 0 while the bundle
	// is being replaced. A caller has to rebind the material whenever this changes: a tier's
	// arrays are rebuilt as a set, and the near field's albedo alone does not identify that
	// set - the far field's arrays can be the only ones that changed.
	uint64_t get_published_generation() const;
	// All three sampled arrays of the current bundle at once, with the generation they
	// belong to. Bind the material from this, never from the three getters above.
	godot::Dictionary get_published_arrays() const;
	bool is_page_ready(int p_slot) const;
	// Where a `queue_page()` call's wall time went: waiting for the queue's mutex and the work
	// done while holding it. A demand pass hands the producer one page at a time, so the two are
	// what separates "the render thread is holding the queue" from "the call's own work is what
	// it costs". Session totals; the reader differences two readings.
	void get_queue_lock_stats(uint64_t &r_wait_us, uint64_t &r_hold_us, uint64_t &r_calls) const;
	// How many of these slots hold no content, read under one lock so a resident set can be
	// verified without a lock per slot.
	int count_unready_pages(const std::vector<int> &p_slots) const;
	// One readiness flag per slot, in the order given, under the same single lock.
	void query_page_readiness(const std::vector<int> &p_slots, std::vector<uint8_t> &r_ready) const;
	// Diagnostic and test hook: drops one page's readiness and nothing else. The slot keeps
	// its sequence, its tier and whatever its published indirection entry names, which is
	// exactly the state a failed encode or a production dropped by a bundle rebuild leaves
	// behind, so a test can check that a demand pass notices and produces the page again.
	void debug_clear_readiness(int p_slot);
	Dictionary export_page(int p_slot) const;
	// Compress and decode one image through the codec a tier resolved to, and report the
	// error it introduced. Deterministic and independent of the page pipeline, so a test can
	// verify the codec's error bound even where page production has nothing to bake from.
	// `Terrain3D::probe_vt_atlas_compression()` is the script-facing entry point.
	Dictionary probe_tier_compression(int p_tier, const Ref<godot::Image> &p_image) const;
	Ref<godot::Image> get_page_preview(int p_slot) const;
	Dictionary get_stats() const;
	// Single readings for a monitor that polls every frame: the bytes the page arrays cost,
	// and the slots a sampler can use against the jobs still waiting for one. Same numbers as
	// the matching `get_stats()` keys, without building the dictionary.
	int64_t get_material_bytes() const;
	int get_ready_page_count() const;
	int get_pending_page_count() const;
	void clear();
};

#endif // TERRAIN3D_SURFACE_BAKER_CLASS_H
