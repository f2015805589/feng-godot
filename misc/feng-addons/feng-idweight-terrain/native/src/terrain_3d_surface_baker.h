// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_BAKER_CLASS_H
#define TERRAIN3D_SURFACE_BAKER_CLASS_H

#include "constants.h"
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

	// One tier's sampling arrays: the copies the material actually samples when that tier
	// is compressed. A tier that resolved to uncompressed samples the staging arrays
	// directly and leaves its set empty.
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
	// Consumer-visible readiness. With compression this becomes true only after all three
	// sampled layers were uploaded, not merely after the writable staging page finished.
	std::vector<uint8_t> _ready;
	std::vector<uint8_t> _sampled_channel_mask;
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
		std::atomic<RenderingDevice::DataFormat> format{ RenderingDevice::DATA_FORMAT_MAX };
		godot::String reason;
	};
	TierState _tiers[TIER_COUNT];
	void _resolve_tier_compression(int p_tier);
	// Which tier last produced each slot's content, so the encoder knows where to store it
	// and the material binding knows which array set serves it.
	std::vector<uint8_t> _slot_tier;
	// Staging and sampled channel accessors, so a channel is addressed by index.
	static RID _staging_rd_of(const ResourceBundle &p_resources, int p_channel);
	RID _staging_rd(int p_channel) const;
	RID _sampled_rd(int p_tier, int p_channel) const;
	RID _sampled_rs(int p_tier, int p_channel) const;
	bool _tier_uses_sampled(int p_tier) const;
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
	// The depth is not a constant. A page holds its regions until its readbacks arrive, and
	// the render graph delivers them about two frames after the recording that asked for
	// them, so the ring has to hold the caller's whole page budget times that latency.
	// Measured with the previous fixed depth of eight and a sixteen page budget, a compressed
	// tier became ready at four pages per frame - eight pages every two frames - however much
	// the demand asked for, because the ring, not the budget, decided the rate.
	static constexpr int ENCODE_PAGES_MIN = 8;
	static constexpr int ENCODE_PAGES_MAX = 64;
	static constexpr int ENCODE_READBACK_FRAMES = 2;
	// The same ring is the staging pool under the scratch regime, so its depth is bounded by
	// bytes rather than by pages: this is the ceiling a derived depth may cost.
	static constexpr int64_t ENCODE_RING_BUDGET_BYTES = 96 * 1024 * 1024;
	static constexpr int ENCODE_CHANNELS = 3;
	// `_slot_scratch` entry of a slot that has no ring page: either the page is not produced
	// yet, or the arrays are page sized and the slot names its own layer.
	static constexpr uint8_t ENCODE_RING_NONE = 0xff;
	// Bytes one encoded layer occupies at the widest codec, and the same count in words.
	// Both are a function of the stored page size, so they are set with the resources.
	int _encode_region_bytes = 0;
	int _encode_region_words = 0;
	// Ring depth. `allocated` is what the vectors and the encoder's output buffer were sized
	// for, `capacity` is what the ring admits right now; the admitted depth never exceeds the
	// allocated one, so a page budget the caller raises later is served by the headroom the
	// allocation already has instead of indexing past it. The render thread writes both while
	// the caller's `set_page_budget()` reads them, so they are atomic.
	std::atomic<int> _encode_ring_allocated{ ENCODE_PAGES_MIN };
	std::atomic<int> _encode_ring_capacity{ ENCODE_PAGES_MIN };
	// Bytes one ring position costs - the encoder's three regions plus the half-float staging
	// layer the same position owns under the scratch regime - and the depth that covers the
	// caller's budget for the frames a readback takes without exceeding the byte ceiling.
	int64_t _encode_page_bytes() const;
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

	void configure(int p_page_size, int p_border, int p_page_count);
	// Storage format of the material page arrays, per tier. Each tier's three arrays share
	// one format, and every one of them carries an alpha value the shader reads (material
	// height, roughness, and the params validity bit), so only codecs that keep alpha are
	// usable. A request is resolved once against the GPU block encoder this build ships and
	// this device's sampling support; get_tier_compression_info() reports what was actually
	// applied and why a request was refused.
	//
	// The tiers are independent because their content is: an AVT page is rewritten whenever
	// an edit invalidates it, while an SVT page is assembled once from a baked cell and then
	// never rewritten. A codec that costs an encode per production is therefore worth its
	// cost for one tier and not necessarily for the other.
	void set_tier_compression(int p_tier, int p_mode);
	Dictionary get_tier_compression_info(int p_tier) const;
	// The AVT tier, which the legacy single setting and the compression tests address.
	void set_atlas_compression(int p_mode) { set_tier_compression(TIER_AVT, p_mode); }
	Dictionary get_atlas_compression_info() const { return get_tier_compression_info(TIER_AVT); }
	void request_capacity(int p_count);
	// True while a larger capacity has been requested but the arrays are still the old size.
	// A caller that would produce pages into the old size can wait a frame or two instead:
	// growth replaces the arrays and releases the pages produced against the old count.
	bool has_pending_capacity() const;
	// Pages produced per frame. The caller's budget, and the only thing that decides the
	// rate: compression re-encodes a page on the GPU after it is produced, so it must not
	// change how many pages a demand pass hands the producer.
	void set_page_budget(int p_pages);
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
	Dictionary export_page(int p_slot) const;
	// Compress and decode one image through the codec a tier resolved to, and report the
	// error it introduced. Deterministic and independent of the page pipeline, so a test can
	// verify the codec's error bound even where page production has nothing to bake from.
	Dictionary probe_atlas_compression(const Ref<godot::Image> &p_image) const { return probe_tier_compression(TIER_AVT, p_image); }
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
