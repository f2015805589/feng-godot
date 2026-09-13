// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_BAKER_CLASS_H
#define TERRAIN3D_SURFACE_BAKER_CLASS_H

#include "constants.h"

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
	ResourceBundle _resources, _retired_resources;
	bool _retire_ready = false;

	uint64_t _render_frame = UINT64_MAX;
	int _frame_page_updates = 0;
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
			const RID &p_shader, const RID &p_sampler_nearest, const RID &p_sampler_linear, const RID &p_cell_shader, const RID &p_cell_pipeline);
	static void _free_bundle(RenderingDevice *p_rd, const ResourceBundle &p_resources);
	static RID _create_texture(RenderingDevice *p_rd, RenderingDevice::DataFormat p_format,
			int p_size, int p_layers, uint64_t p_usage, const PackedByteArray &p_first_layer = PackedByteArray());
	static RID _create_sampler(RenderingDevice *p_rd, RenderingDevice::SamplerFilter p_filter,
			RenderingDevice::SamplerRepeatMode p_repeat, float p_max_lod);

	void _take_resources(ResourceBundle &r_resources);
	bool _ensure_resources(uint64_t p_generation, int p_page_count,
			int p_stored_size, const RID &p_albedo_array_rs, const RID &p_normal_array_rs,
			const PackedByteArray &p_material_bytes);
	bool _rebuild_uniform_set(ResourceBundle &r_resources, const RID &p_albedo_array_rs,
			const RID &p_normal_array_rs);
	bool _compile_pipeline(ResourceBundle &r_resources);
	bool _upload_materials(const PackedByteArray &p_material_bytes);
	bool _upload_source_page(const PendingJob &p_job, int p_layer);
	bool _upload_cached_page(const PendingJob &p_job);
	bool _copy_cell_page(const PendingJob &p_job);
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
	void request_capacity(int p_count);
	int get_capacity() const;
	bool has_render_work() const;
	void acknowledge_output(const RID &p_albedo);
	void set_materials(const RID &p_albedo_array_rid, const RID &p_normal_array_rid,
			const PackedColorArray &p_colors, const PackedFloat32Array &p_normal_depths,
			const PackedFloat32Array &p_ao_strengths, const PackedFloat32Array &p_ao_affects,
			const PackedFloat32Array &p_roughness_mods, const PackedFloat32Array &p_uv_scales,
			const PackedVector2Array &p_detiles, const PackedVector3Array &p_slope_params);
	void queue_page(int p_slot, const Ref<godot::Image> &p_idweights, const Ref<godot::Image> &p_height,
			const godot::Rect2 &p_world_rect, float p_slope_factor = 1.0f, Vector3 p_source_grid = Vector3());
	void queue_cached_page(int p_slot, const godot::Dictionary &p_channels);
	void queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect);
	void invalidate_slot(int p_slot);

	// Called by the parent through RenderingServer::call_on_render_thread().  The
	// keep-alive is intentionally unused; binding a Ref<RefCounted> to the Callable
	// keeps this object alive until the callback has returned.
	void render_pending(const Ref<godot::RefCounted> &p_keep_alive = Ref<godot::RefCounted>());

	RID get_albedo_rid() const;
	RID get_normal_rid() const;
	RID get_params_rid() const;
	bool is_page_ready(int p_slot) const;
	Dictionary export_page(int p_slot) const;
	Ref<godot::Image> get_page_preview(int p_slot) const;
	Dictionary get_stats() const;
	void clear();
};

#endif // TERRAIN3D_SURFACE_BAKER_CLASS_H
