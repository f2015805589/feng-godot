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

	struct ResourceBundle {
		RID output_albedo_rd;
		RID output_normal_rd;
		RID output_params_rd;
		RID output_albedo_rs;
		RID output_normal_rs;
		RID output_params_rs;
		// Compressed copies of the three channels, sampled by the material. The staging
		// arrays above stay RGBA16F and writable by imageStore; a compressed format
		// cannot be a storage image, so an encode step has to copy between them.
		RID sampled_albedo_rd;
		RID sampled_normal_rd;
		RID sampled_params_rd;
		RID sampled_albedo_rs;
		RID sampled_normal_rs;
		RID sampled_params_rs;
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
	std::vector<uint8_t> _ready;
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
	int _atlas_compression = 0;
	// Written by the resolver on the main thread and read by the resource builder on the
	// render thread, so both halves of the resolved state are atomic.
	std::atomic<int> _atlas_compression_effective{ 0 };
	std::atomic<int> _atlas_compression_applied{ 0 };
	std::atomic<RenderingDevice::DataFormat> _atlas_rd_format{ RenderingDevice::DATA_FORMAT_MAX };
	godot::String _atlas_compression_reason;
	void _resolve_atlas_compression();
	// Staging and sampled channel accessors, so a channel is addressed by index.
	RID _staging_rd(int p_channel) const;
	RID _sampled_rd(int p_channel) const;
	RID _sampled_rs(int p_channel) const;
	// Pages whose staging content changed and whose compressed copy is stale.
	std::vector<uint8_t> _encode_pending;
	bool _encode_warned = false;
	// Encoded layers waiting for a recording point. A readback callback runs inside the
	// frame stall, which is after the frame's draw graph was ended and immediately before
	// the next one is begun, so a texture_update() issued from there is recorded into the
	// finished graph and discarded when the new one starts: the compressed arrays stayed
	// empty while every upload reported success. The callback therefore only compresses and
	// queues, and the render callback - which runs inside the recording - performs the
	// uploads.
	struct EncodedLayer {
		int channel = 0;
		int slot = 0;
		uint64_t generation = 0;
		godot::PackedByteArray data;
	};
	std::vector<EncodedLayer> _encoded_layers;
	// Counters for the compressed-page pipeline, reported by get_stats() so a page that
	// is ready in the staging arrays but never reaches the sampled ones is visible
	// instead of only showing up as blank material in the viewport.
	uint64_t _encode_requests = 0;
	uint64_t _encode_readbacks = 0;
	uint64_t _encode_updates = 0;
	uint64_t _encode_failures = 0;
	void _request_encodes();
	void _flush_encodes(uint64_t p_generation);
	void _on_encode_readback(const PackedByteArray &p_data, int p_slot, int p_channel);
	bool _encode_image(int p_channel, int p_slot, const Ref<godot::Image> &p_image);
	bool _upload_encoded_layer(int p_channel, int p_slot, const godot::PackedByteArray &p_data);
	uint64_t _dispatch_count = 0;
	uint64_t _baked_pages = 0;
	uint64_t _cached_uploads = 0;
	uint64_t _migrated_pages = 0;
	uint64_t _invalidated_pages = 0;
	uint64_t _source_uploads = 0;

	static void _free_deferred(const RID &p_output_albedo_rd, const RID &p_output_normal_rd,
			const RID &p_output_params_rd, const RID &p_output_albedo_rs, const RID &p_output_normal_rs,
			const RID &p_output_params_rs, const RID &p_source_id_rd, const RID &p_source_height_rd,
			const RID &p_material_buffer, const RID &p_job_buffer, const RID &p_dummy_albedo_rd,
			const RID &p_dummy_normal_rd, const RID &p_uniform_set, const RID &p_pipeline,
			const RID &p_shader, const RID &p_sampler_nearest, const RID &p_sampler_linear, const RID &p_cell_shader, const RID &p_cell_pipeline,
			const RID &p_sampled_albedo_rd, const RID &p_sampled_normal_rd, const RID &p_sampled_params_rd,
			const RID &p_sampled_albedo_rs, const RID &p_sampled_normal_rs, const RID &p_sampled_params_rs);
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
	// Atlas compression for the three material page arrays. They must all share one
	// format, and every one of them carries an alpha value the shader reads (material
	// height, roughness, and the params validity bit), so only codecs that keep alpha
	// are usable. The requested mode is resolved once against this build's compressors
	// and this device's sampling support; `get_atlas_compression_info()` reports what
	// was actually applied and why a request was refused.
	void set_atlas_compression(int p_mode);
	Dictionary get_atlas_compression_info() const;
	void request_capacity(int p_count);
	// True while a larger capacity has been requested but the arrays are still the old size.
	// A caller that would produce pages into the old size can wait a frame or two instead:
	// growth replaces the arrays and releases the pages produced against the old count.
	bool has_pending_capacity() const;
	// Pages baked per frame. The caller's budget, capped lower while the atlas is
	// compressed because every page then costs a readback and a codec pass.
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
	void queue_page(int p_slot, const Ref<godot::Image> &p_idweights, const Ref<godot::Image> &p_height,
			const godot::Rect2 &p_world_rect, float p_slope_factor = 1.0f, Vector3 p_source_grid = Vector3());
	void queue_cached_page(int p_slot, const godot::Dictionary &p_channels);
	// Cell pieces either name a resident cell (layer + level, copied from the GPU cell
	// store) or carry cropped images to upload first.
	void queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect);
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
	// All three sampled arrays of the current bundle at once, with the generation they
	// belong to. Bind the material from this, never from the three getters above.
	godot::Dictionary get_published_arrays() const;
	bool is_page_ready(int p_slot) const;
	Dictionary export_page(int p_slot) const;
	// Compress and decode one image through the same codec the atlas uses, and report the
	// error it introduced. Deterministic and independent of the page pipeline, so a test
	// can verify the codec path even where page production has nothing to bake from.
	Dictionary probe_atlas_compression(const Ref<godot::Image> &p_image) const;
	Ref<godot::Image> get_page_preview(int p_slot) const;
	Dictionary get_stats() const;
	void clear();
};

#endif // TERRAIN3D_SURFACE_BAKER_CLASS_H
