// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 6 of 6: the frame.
//
// render_pending(), the render-thread callback the parent registers: it snapshots the queue,
// records one frame's jobs, dispatches them, publishes the result and retires the bundles the
// material has stopped sampling. The read-only state the caller and the editor read - the
// published arrays, the exports, get_stats() - and the Godot bindings are here as well, because
// they are what the frame produced.
//
// The other halves: terrain_3d_surface_baker.cpp (the device and its objects),
// terrain_3d_surface_baker_bundle.cpp (the ResourceBundle's lifetime),
// terrain_3d_surface_baker_pipelines.cpp (the two GPU programs),
// terrain_3d_surface_baker_storage.cpp and terrain_3d_surface_baker_queue.cpp.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"
#include "terrain_3d_material_clipmap_detail.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <algorithm>
#include <cmath>
#include <utility>

// The codec vocabulary, the shared constants and the small helpers of the four halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

namespace {

Vector3 surface_decode_normal_oct(const float p_x, const float p_y) {
	float x = p_x * 2.0f - 1.0f;
	float y = p_y * 2.0f - 1.0f;
	float z = 1.0f - std::abs(x) - std::abs(y);
	const float fold = std::clamp(-z, 0.0f, 1.0f);
	x += x >= 0.0f ? -fold : fold;
	y += y >= 0.0f ? -fold : fold;
	const float length = std::sqrt(std::max(x * x + y * y + z * z, 1.0e-12f));
	// The bake's canonical normal is world XYZ, while the octahedral basis is XZY so Y-up
	// terrain does not put its flat normal on the standard Z-up octahedron boundary.
	return Vector3(x / length, z / length, y / length);
}

Ref<Image> surface_decode_normal_page(const Ref<Image> &p_encoded, const Ref<Image> &p_params,
		const int p_encoding, const bool p_params_encoded) {
	if (p_encoded.is_null()) {
		return p_encoded;
	}
	const int width = p_encoded->get_width();
	const int height = p_encoded->get_height();
	Ref<Image> decoded = Image::create_empty(width, height, false, Image::FORMAT_RGBAH);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			const Color encoded = p_encoded->get_pixel(x, y);
			const Color packed_params = p_params.is_valid() ? p_params->get_pixel(x, y) : Color(0, 0, 0, 1);
			const float roughness = p_params_encoded ? std::clamp(packed_params.a * 2.0f - 1.0f, 0.0f, 1.0f) : encoded.a;
			const Vector3 normal = p_encoding == SURFACE_NORMAL_UNCOMPRESSED
					? Vector3(encoded.r, encoded.g, encoded.b)
					: (p_encoding == SURFACE_NORMAL_BC3N
							? surface_decode_normal_oct(encoded.a, encoded.g)
							: surface_decode_normal_oct(encoded.r, encoded.g));
			decoded->set_pixel(x, y, Color(normal.x, normal.y, normal.z, roughness));
		}
	}
	return decoded;
}

Ref<Image> surface_decode_params_page(const Ref<Image> &p_encoded) {
	if (p_encoded.is_null()) {
		return p_encoded;
	}
	const int width = p_encoded->get_width();
	const int height = p_encoded->get_height();
	Ref<Image> decoded = Image::create_empty(width, height, false, Image::FORMAT_RGBAH);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			const Color packed = p_encoded->get_pixel(x, y);
			const bool valid = packed.a >= 0.49f;
			decoded->set_pixel(x, y, Color(packed.r * 2.0f, packed.g, packed.b, valid ? 1.0f : 0.0f));
		}
	}
	return decoded;
}

} // namespace

///////////////////////////
// Render callback
///////////////////////////

bool Terrain3DSurfaceBaker::_record_jobs(std::vector<PendingJob> &p_jobs, uint64_t p_generation,
		int p_page_size, int p_border, int p_stored_size, int p_material_count) {
	if (!_rd || p_jobs.empty() || !_resources.job_buffer.is_valid() || !_resources.uniform_set.is_valid() ||
			!_resources.pipeline.is_valid()) {
		return false;
	}
	PackedByteArray job_bytes;
	SurfaceVTLabel batch_label(_rd, "Surface VT Page Updates - " + String::num_int64(p_jobs.size()) + " pages");
	job_bytes.resize(int64_t(p_jobs.size()) * JOB_STRIDE);
	for (size_t index = 0; index < p_jobs.size(); index++) {
		PendingJob &job = p_jobs[index];
		const int64_t offset = int64_t(index) * JOB_STRIDE;
		const int layer = job.staging_layer >= 0 ? job.staging_layer : job.slot;
		uint32_t mode = 0u;
		if (job.kind == PENDING_BAKE && p_material_count > 0 && _upload_source_page(job, layer)) {
			mode = 1u;
		} else if (job.kind == PENDING_BAKE) {
			job.kind = PENDING_INVALIDATE;
		}
		const float texel_x = p_page_size > 0 ? job.world_rect.size.x / float(p_page_size) : 1.0f;
		const float texel_z = p_page_size > 0 ? job.world_rect.size.y / float(p_page_size) : 1.0f;
		encode_vec4(job_bytes, offset, job.world_rect.position.x, job.world_rect.position.y,
				job.world_rect.size.x, job.world_rect.size.y);
		encode_vec4(job_bytes, offset + 16, texel_x, texel_z, float(p_page_size), float(p_border));
		job_bytes.encode_u32(offset + 32, uint32_t(std::max(0, layer)));
		job_bytes.encode_u32(offset + 36, uint32_t(std::max(0, layer)));
		job_bytes.encode_u32(offset + 40, mode);
		// `indices.w` is the layer the *height* is read from. A page holds its payload and its height
		// at one layer index of two arrays, so here the two are the same number; a ring that keeps
		// both in one array names a different one, which is the only reason the field exists.
		job_bytes.encode_u32(offset + 44, uint32_t(std::max(0, layer)));
		encode_vec4(job_bytes, offset + 48, std::clamp(job.slope_factor, 0.0f, 1.0f), job.source_grid.x, job.source_grid.y, job.source_grid.z);
	}
	if (_rd->buffer_update(_resources.job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
		LOG(WARN, "Could not upload surface bake jobs");
		return false;
	}
	PackedByteArray push;
	push.resize(48);
	push.encode_u32(0, uint32_t(p_stored_size));
	push.encode_u32(4, uint32_t(p_jobs.size()));
	push.encode_u32(8, uint32_t(std::max(0, p_material_count)));
	push.encode_u32(12, uint32_t(p_generation & 0xFFFFFFFFu));
	// `source.x == 0`: a page's source is a stored rect with a gutter, whose taps clamp. The ring's
	// jobs are the only ones that carry a wrapping square, and they are dispatched by
	// `_dispatch_ring_bake()` - this block is the same size for both, so one shader serves the two.
	push.encode_u32(16, 0u);
	push.encode_u32(20, 0u);
	push.encode_u32(24, 0u);
	push.encode_u32(28, 0u);
	// And a page's job covers the layer it fills: origin zero, the stored size either way. A ring's
	// job names one rect of a level here instead, which is the whole difference between the two.
	push.encode_u32(32, 0u);
	push.encode_u32(36, 0u);
	push.encode_u32(40, uint32_t(p_stored_size));
	push.encode_u32(44, uint32_t(p_stored_size));
	SurfaceVTLabel dispatch_label(_rd, "Bake / Invalidate Pages - Dispatch Z = job index");
	const int64_t compute_list = _rd->compute_list_begin();
	if (compute_list < 0) {
		LOG(WARN, "Could not begin surface bake compute list");
		return false;
	}
	_rd->compute_list_bind_compute_pipeline(compute_list, _resources.pipeline);
	_rd->compute_list_bind_uniform_set(compute_list, _resources.uniform_set, 0);
	_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
	_rd->compute_list_dispatch(compute_list,
			uint32_t((p_stored_size + 7) / 8), uint32_t((p_stored_size + 7) / 8),
			uint32_t(p_jobs.size()));
	_rd->compute_list_end();
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_dispatch_count++;
	}
	return true;
}

void Terrain3DSurfaceBaker::_set_ready(int p_slot, bool p_ready, uint64_t p_generation,
		uint64_t p_material_version, uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (p_generation != _generation || p_material_version != _material_version ||
			p_slot < 0 || p_slot >= int(_ready.size()) || p_slot >= int(_slot_sequence.size()) ||
			(p_sequence != 0 && _slot_sequence[size_t(p_slot)] != p_sequence) ||
			(p_sequence == 0 && _slot_sequence[size_t(p_slot)] != 0)) {
		return;
	}
	if (!p_ready) {
		_ready[size_t(p_slot)] = 0;
		if (p_slot < int(_sampled_channel_mask.size())) {
			_sampled_channel_mask[size_t(p_slot)] = 0;
		}
		return;
	}
	// Stamp the frame the content was produced in. A compressed page is only ready once its
	// encoded layers have landed in the sampling arrays, and this is where that wait starts, so
	// measuring from here is what separates an encode stored in the frame it was produced in
	// from one that arrives a few frames later.
	if (p_slot < int(_produced_frame.size())) {
		Engine *engine = Engine::get_singleton();
		_produced_frame[size_t(p_slot)] = engine ? uint64_t(engine->get_process_frames()) : 0;
	}
	// Raw channels are ready as soon as staging was written. Only the compressed channel bits
	// wait for their own block uploads; this is what lets a mixed raw/BC page settle without
	// scheduling a fake encode for a raw channel.
	const int tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
	const uint8_t compressed_mask = _tier_channel_mask(tier, true);
	_sampled_channel_mask[size_t(p_slot)] = uint8_t(0x7u & ~compressed_mask);
	_ready[size_t(p_slot)] = compressed_mask == 0 ? 1 : 0;
}

void Terrain3DSurfaceBaker::_retire_acknowledged_bundles() {
	std::vector<ResourceBundle> retiring;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		// Everything older than the bundle the material currently samples is unreferenced and can
		// go. Nothing is freed while the material has not acknowledged a published pair yet,
		// because these are exactly the arrays its already prepared draws may still bind. The
		// acknowledgment is only honoured from the frame after it arrived: the material's new pair
		// is published on the main thread and reaches the drawn material during that frame's
		// render, in which this pass runs.
		const uint64_t frames_drawn = Engine::get_singleton()->get_frames_drawn();
		const uint64_t acknowledged = frames_drawn > _acknowledged_frame + RETIRE_FRAME_MARGIN ? _acknowledged_generation : 0;
		if (acknowledged != 0) {
			for (size_t index = 0; index < _retired.size();) {
				if (_retired[index].first < acknowledged) {
					retiring.push_back(_retired[index].second);
					_retired.erase(_retired.begin() + index);
					continue;
				}
				++index;
			}
		}
		if (!retiring.empty()) { _retire_ready = false; }
	}
	for (const ResourceBundle &bundle : retiring) { _free_bundle(_rd, bundle); }
}

std::vector<Terrain3DSurfaceBaker::PendingJob> Terrain3DSurfaceBaker::_build_frame_jobs(const std::map<int, PendingJob> &p_pending,
		const bool p_invalidate_all, const uint64_t p_generation, const int p_page_count) const {
	std::vector<PendingJob> jobs;
	jobs.reserve(size_t(p_invalidate_all ? p_page_count : p_pending.size()));
	if (p_invalidate_all) {
		for (int slot = 0; slot < p_page_count; slot++) {
			auto found = p_pending.find(slot);
			if (found != p_pending.end()) {
				jobs.push_back(found->second);
			} else {
				PendingJob invalid;
				invalid.slot = slot;
				invalid.kind = PENDING_INVALIDATE;
				invalid.generation = p_generation;
				jobs.push_back(invalid);
			}
		}
	} else {
		for (const auto &entry : p_pending) {
			jobs.push_back(entry.second);
		}
	}
	return jobs;
}

// One frame's page production and dispatch, from the staging buffers to the compute list: the
// layers a readback callback compressed since the last callback, then per slot the invalidation,
// the budget deferral, the staging layer and the bake or cell copy that fills it, and finally the
// dispatch for the pages that still need shading. Every one of those is local to it; what crosses
// back out is `_frame_page_updates`, the deferred jobs in `_pending`, and - when the job recording
// fails - false, which means the frame did nothing and the caller must return with every job back
// in the queue and the whole atlas marked for invalidation.
bool Terrain3DSurfaceBaker::_dispatch_frame_jobs(std::vector<PendingJob> &p_jobs,
		const uint64_t p_generation, const uint64_t p_material_version, const int p_page_count,
		const int p_page_size, const int p_border, const int p_stored_size, const int p_material_count,
		const bool p_invalidate_all, Terrain3DCellStore *p_cell_store) {
	std::vector<PendingJob> compute_jobs;
	compute_jobs.reserve(p_jobs.size());
	// Invalidation only needs to clear readiness, not shade every cache texel. Under the
	// scratch regime nothing samples the staging arrays at all - the compressed layer of a
	// re-assigned slot keeps the previous page's material for the frame or two until its own
	// encode lands, exactly as it does with page-sized staging - so an invalidation never has
	// to touch a layer, and the layers it could name are not the slot's anyway.
	const bool scratch = _staging_is_scratch();
	const int cleared_layers = scratch ? _staging_layers : p_page_count;
	const bool cleared_all = p_invalidate_all && _rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, 0, uint32_t(cleared_layers)) == OK;
	const uint64_t frame = Engine::get_singleton()->get_frames_drawn();
	if (_render_frame != frame) { _render_frame = frame; _frame_page_updates = 0; }
	// Compressed page production happens here, inside the recording, in two halves: the
	// layers a readback callback compressed since the last callback are uploaded first, so
	// the frames this callback's own production does not cover already sample real data;
	// the readbacks for the pages produced below are then requested from this same
	// recording, which is what makes a page compressed by the frame that produced it.
	_flush_encodes(p_generation);
	for (PendingJob &job : p_jobs) {
		if (job.generation != p_generation || job.slot < 0 || job.slot >= p_page_count) {
			continue;
		}
		if (job.kind == PENDING_INVALIDATE && (cleared_all || scratch ||
				_rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) == OK)) {
			_set_ready(job.slot, false, p_generation, p_material_version, job.sequence);
			{ std::lock_guard<std::mutex> lock(_mutex); ++_invalidated_pages; }
			continue;
		}
		if (job.kind != PENDING_INVALIDATE) {
			if (_frame_page_updates >= _page_budget.load()) {
				{ std::lock_guard<std::mutex> lock(_mutex); _pending.emplace(job.slot, job); }
				// A reused slot must not expose its previous material while deferred.
				PendingJob invalid = job;
				invalid.kind = PENDING_INVALIDATE;
				if (!cleared_all && !scratch &&
						_rd->texture_clear(_resources.output_params_rd, Color(0, 0, 0, 0), 0, 1, job.slot, 1) != OK) {
					compute_jobs.push_back(invalid);
				}
				continue;
			}
			// The layer this page is shaded into: the slot under page-sized staging, a ring
			// page under the scratch regime - and a ring page that is held until this page's
			// block readbacks arrive, because the half-float content only exists that long.
			const int layer = _take_staging_layer(job.slot);
			if (layer < 0) {
				// Every ring page is waiting on readbacks. Defer the page exactly as the
				// budget does, so a later frame produces it with a layer of its own.
				{ std::lock_guard<std::mutex> lock(_mutex); _pending.emplace(job.slot, job); }
				continue;
			}
			job.staging_layer = layer;
			++_frame_page_updates;
		}
		if (job.kind == PENDING_CACHED || job.kind == PENDING_CELL) {
			if (job.kind == PENDING_CELL ? _copy_cell_page(job, p_cell_store) : _upload_cached_page(job)) {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_cached_uploads++;
				}
				// Both far-field paths end with the three channels in the staging arrays -
				// the cached path uploads them, the cell path accumulated them there - so the
				// block encoder is the only thing that turns them into the SVT page. This is
				// where a far-field page is compressed, once per production: an SVT page's
				// content is final, so nothing re-encodes it while the slot keeps its page.
				if (_tier_uses_sampled(job.tier) && job.slot >= 0 && job.slot < int(_encode_pending.size())) {
					_encode_pending[size_t(job.slot)] = 1;
				}
				_set_ready(job.slot, true, p_generation, p_material_version, job.sequence);
			} else {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_invalidated_pages++;
				}
				PendingJob invalid = job;
				invalid.kind = PENDING_INVALIDATE;
				compute_jobs.push_back(invalid);
				_set_ready(job.slot, false, p_generation, p_material_version, job.sequence);
			}
		} else {
			compute_jobs.push_back(job);
		}
	}
	// A pure invalidation has nothing to shade under the scratch regime: its only effect is
	// the readiness clear above, and dispatching it would write zeros into whichever scratch
	// layer the shader named, which may belong to a page whose encode is still in flight.
	if (scratch) {
		compute_jobs.erase(std::remove_if(compute_jobs.begin(), compute_jobs.end(),
								   [](const PendingJob &p_job) { return p_job.kind == PENDING_INVALIDATE; }),
				compute_jobs.end());
	}
	if (!compute_jobs.empty()) {
		std::vector<PendingJob> original_jobs = compute_jobs;
		if (!_record_jobs(compute_jobs, p_generation, p_page_size, p_border, p_stored_size, p_material_count)) {
			std::lock_guard<std::mutex> lock(_mutex);
			if (_generation == p_generation) {
				for (const PendingJob &job : original_jobs) {
					_pending.emplace(job.slot, job);
				}
				_invalidate_all = _invalidate_all || p_invalidate_all;
			}
			return false;
		}
		for (const PendingJob &job : compute_jobs) {
			if (job.kind == PENDING_BAKE) {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_baked_pages++;
				}
				// The bake dispatch is recorded just above, so the encoder dispatch requested
				// below reads the staging layer this same recording wrote.
				if (_tier_uses_sampled(job.tier) && job.slot >= 0 && job.slot < int(_encode_pending.size())) {
					_encode_pending[size_t(job.slot)] = 1;
				}
				_set_ready(job.slot, true, p_generation, p_material_version, job.sequence);
			} else {
				{
					std::lock_guard<std::mutex> lock(_mutex);
					_invalidated_pages++;
				}
				_set_ready(job.slot, false, p_generation, p_material_version, job.sequence);
			}
		}
	}
	// Every page produced by this callback (bake or cell copy) is read back here, in the
	// same recording that wrote it.
	_request_encodes();
	return true;
}

///////////////////////////
// The ring's bake
///////////////////////////

// One ring's descriptor set: the ring's own atlas as both inputs of the bake shader and the ring's
// three arrays as its outputs. Built here rather than through the bundle path because nothing about
// it is a page - its size is the ring's texel count, its layers are the ring's levels, and its inputs
// are the very texels the bake reads rather than a page's staging copy.
bool Terrain3DSurfaceBaker::_ensure_ring_bake(Terrain3DClipmap *p_ring) {
	if (p_ring == nullptr || !_rd || !_resources.shader.is_valid() || !_resources.pipeline.is_valid() ||
			!_resources.job_buffer.is_valid() || !_resources.material_buffer.is_valid() ||
			!_resources.sampler_nearest.is_valid() || !_resources.sampler_linear.is_valid()) {
		// No producer, no bake: the ring keeps serving its own texels (the payload) and every level
		// reports `baked` false. The bake shader, the material list and the job buffer are the page
		// producer's, so this is the state of a build whose material group never took the paged path -
		// which is also why the owner publishes that list to this producer for a ring (see
		// `Terrain3D::_setup_vt_clipmap()`).
		return false;
	}
	// The bake shader writes exactly three arrays, and the payload and the height are two layers of
	// one: a channel that declares another shape is not one this path can fill, and refusing here is
	// what keeps a ring from holding layers nothing would write.
	if (p_ring->get_baked_channel_count() != 3 || p_ring->get_channel_count() < 2) {
		return false;
	}
	const RID atlas = resolve_main_texture(p_ring->get_texture_rid());
	if (!atlas.is_valid() || !_rd->texture_is_valid(atlas)) {
		return false;
	}
	const RID outputs[3] = { p_ring->get_baked_device_rid(0), p_ring->get_baked_device_rid(1),
		p_ring->get_baked_device_rid(2) };
	if (!outputs[0].is_valid() || !outputs[1].is_valid() || !outputs[2].is_valid()) {
		return false;
	}
	// The set survives a tick: it is rebuilt when the ring it describes is not this one, when the
	// ring's atlas changed (a reconfigure makes a new texture), when its shape did, or when the bundle
	// it takes its buffers, samplers and shader from was replaced - a set that named a retired
	// bundle's buffer would dispatch against a resource the device no longer owns.
	if (_ring_bake.ring == p_ring && _ring_bake.uniform_set.is_valid() && _ring_bake.atlas_rd == atlas &&
			_ring_bake.job_buffer == _resources.job_buffer && _ring_bake.size == p_ring->get_size()) {
		return true;
	}
	_free_ring_bake();
	RID albedo_rd;
	RID normal_rd;
	_resolve_material_rd(_resources, albedo_rd, normal_rd, _material_albedo_rs, _material_normal_rs);
	TypedArray<Ref<RDUniform>> uniforms;
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
			_resources.sampler_nearest, atlas);
	// The same texture twice: the payload and the height are two layers of one array, and the job
	// names both, which is the whole reason `indices.w` exists.
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
			_resources.sampler_nearest, atlas);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
			_resources.sampler_linear, albedo_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3,
			_resources.sampler_linear, normal_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 4, _resources.material_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 5, _resources.job_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 6, outputs[0]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 7, outputs[1]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 8, outputs[2]);
	const RID set = _rd->uniform_set_create(uniforms, _resources.shader, 0);
	if (!set.is_valid()) {
		LOG(WARN, "Could not create the clipmap ring bake uniform set");
		return false;
	}
	_ring_bake.ring = p_ring;
	_ring_bake.atlas_rd = atlas;
	_ring_bake.job_buffer = _resources.job_buffer;
	_ring_bake.size = p_ring->get_size();
	_ring_bake.uniform_set = set;
	return true;
}

void Terrain3DSurfaceBaker::_free_ring_bake() {
	if (_ring_bake.uniform_set.is_valid() && _rd && _rd->uniform_set_is_valid(_ring_bake.uniform_set)) {
		_rd->free_rid(_ring_bake.uniform_set);
	}
	_ring_bake.uniform_set = RID();
	_ring_bake.atlas_rd = RID();
	_ring_bake.job_buffer = RID();
	_ring_bake.ring = nullptr;
	_ring_bake.size = 0;
	std::lock_guard<std::mutex> lock(_mutex);
	_ring_bake.collected.clear();
	_ring_bake.queued.clear();
	_ring_bake.landed.clear();
}

int Terrain3DSurfaceBaker::_queue_clipmap_ring(Terrain3DClipmap *p_ring, const int p_budget_texels) {
	if (p_ring == nullptr || !p_ring->is_configured() || p_ring->get_baked_channel_count() != 3) {
		return 0;
	}
	if (!_ensure_ring_bake(p_ring)) {
		return 0;
	}
	const int channels = MAX(1, p_ring->get_channel_count());
	std::vector<RingJob> fresh;
	std::vector<RingJob> previous;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const RingJob &landed : _ring_bake.landed) {
			// The ring is what decides, not this thread: a rect whose level moved after the dispatch, or
			// whose shape changed, describes texels the bake never read, and the ring keeps it queued -
			// serving those layers to a fragment is exactly what the lease exists to prevent.
			if (_ring_bake.ring == p_ring) {
				p_ring->acknowledge_bake(landed.rect());
			}
		}
		_ring_bake.landed.clear();
		previous = std::move(_ring_bake.collected);
		// The rects the ring has produced and no bake has covered, in the order it produced them -
		// which is not the order of its levels: a strip of the finest level and a fill of the coarsest
		// are the same kind of entry here, because both are "this rect is not baked yet".
		int budget = MAX(0, p_budget_texels);
		for (int index = 0; index < p_ring->get_pending_bake_count(); index++) {
			const Terrain3DClipmap::BakeRect &rect = p_ring->get_pending_bake(index);
			// A rect already on its way to a dispatch is not collected twice: the second bake would
			// read the same texels and land the same layers.
			bool already = false;
			for (const RingJob &job : previous) {
				already = already || (job.level == rect.unit && job.x0 == rect.x0 && job.y0 == rect.y0 &&
											 job.x1 == rect.x1 && job.y1 == rect.y1);
			}
			for (const RingJob &job : fresh) {
				already = already || (job.level == rect.unit && job.x0 == rect.x0 && job.y0 == rect.y0 &&
											 job.x1 == rect.x1 && job.y1 == rect.y1);
			}
			if (already) {
				continue;
			}
			const int64_t texels = int64_t(rect.x1 - rect.x0) * int64_t(rect.y1 - rect.y0) *
					int64_t(channels);
			// The budget is the production budget's own unit - channel texels - and it is a *soft* one:
			// at least one rect is collected per offer, because a whole-level fill is larger than a
			// tick's budget and a budget that never admitted it would leave the level unbaked forever.
			// What is left stays in the ring's queue for the next offer, which is the same deferral the
			// production budget makes.
			if (!fresh.empty() && budget > 0 && texels > int64_t(budget)) {
				break;
			}
			budget -= int(texels);
			RingJob job;
			job.level = rect.unit;
			job.x0 = rect.x0;
			job.y0 = rect.y0;
			job.x1 = rect.x1;
			job.y1 = rect.y1;
			// The *rect's* lease, not a fresh one from the level: it is the content this rect holds, and
			// the ring accepts the bake only while the rect still carries it.
			job.lease = rect.lease;
			// The material list this offer was made under. The dispatch reads whatever list the
			// buffer holds, so a rect collected before a replacement is dropped rather than baked
			// with the new materials and reported as the old rect's content.
			job.material_version = _material_version;
			job.texel = p_ring->get_texel_world(rect.unit);
			// The level's world origin, which with its texel size is the whole of what the shader needs
			// to turn a *stored* texel back into the world position it stands for.
			job.level_origin = p_ring->get_level_world_bounds(rect.unit).position;
			// The rotation the level's stored content is under. The shader *reads* it - a stored texel's
			// world position is its logical one, which is this offset turned back - and the lease taken
			// above is what makes a level whose ring turned before the dispatch stale instead of wrongly
			// baked.
			job.ring = p_ring->get_ring(rect.unit);
			// Layer `level * channels + 0` is the payload, `+ 1` the height: one array, two layers,
			// named separately because the bake reads them through two samplers at one job.
			job.payload_layer = rect.unit * channels;
			job.height_layer = job.payload_layer + 1;
			fresh.push_back(job);
		}
		// This tick collects, the next dispatches: the payload of a rect collected now is a
		// RenderingServer command that has not run yet, and a device dispatch issued in the same tick
		// would race that queue and read the texels the rect is replacing.
		_ring_bake.collected = std::move(fresh);
		_ring_bake.queued = std::move(previous);
	}
	return int(_ring_bake.collected.size());
}

// ---- The three bake sets' liveness ---------------------------------------------------------------

// Whether a descriptor set the producer built still exists on the device. A set is a RID that names
// the textures and buffers it was built from, so freeing any of them - the layer's own texture, its
// baked arrays, the bundle's job buffer - invalidates the set rather than leaving it usable. The
// device answers that question and this is where it is asked.
bool Terrain3DSurfaceBaker::_bake_set_is_live(const RID &p_set) const {
	return _rd != nullptr && p_set.is_valid() && _rd->uniform_set_is_valid(p_set);
}

// Forgets every bake set the device has released. It is called from a dispatch that just found its own
// set stale, so the next offer rebuilds the set from the storage that is live now. The queue is left
// alone: the storage owning the work still holds its rects (nothing was acknowledged), and the dispatch
// below drains its own `queued` list on the way to the check.
void Terrain3DSurfaceBaker::_retire_stale_bake_sets() {
	if (!_bake_set_is_live(_ring_bake.uniform_set)) {
		_ring_bake.uniform_set = RID();
		_ring_bake.atlas_rd = RID();
		_ring_bake.ring = nullptr;
		_ring_bake.size = 0;
	}
	if (!_bake_set_is_live(_atlas_bake.uniform_set)) {
		_atlas_bake.uniform_set = RID();
		_atlas_bake.atlas_rd = RID();
		_atlas_bake.atlas = nullptr;
		_atlas_bake.width = 0;
		_atlas_bake.height = 0;
	}
	if (!_bake_set_is_live(_detail_bake.uniform_set)) {
		_detail_bake.uniform_set = RID();
		_detail_bake.payload_rd = RID();
		_detail_bake.height_rd = RID();
		_detail_bake.detail = nullptr;
		_detail_bake.stored_size = 0;
	}
}

int Terrain3DSurfaceBaker::_dispatch_ring_bake() {
	std::vector<RingJob> jobs;
	RID set;
	RID job_buffer;
	int size = 0;
	int material_count = 0;
	uint64_t material_version = 0;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		// A set that names a bundle this callback just replaced would dispatch against a freed job
		// buffer. Nothing is drained: the next offer rebuilds the set from the live bundle and
		// collects the ring's rects again, because the ring never acknowledged them.
		if (_ring_bake.job_buffer != _resources.job_buffer) {
			return 0;
		}
		if (_ring_bake.queued.empty()) {
			return 0;
		}
		jobs = std::move(_ring_bake.queued);
		_ring_bake.queued.clear();
		set = _ring_bake.uniform_set;
		size = _ring_bake.size;
		material_count = _material_count;
		material_version = _material_version;
		// The set's own buffer, not the bundle's: they are the same resource or the set is stale, and
		// `_ensure_ring_bake()` is where that is decided.
		job_buffer = _ring_bake.job_buffer;
	}
	// A rect offered under a material list that has since been replaced is not a rect this dispatch
	// can cover: the layers it would write evaluate the *new* list, while the ring would be told the
	// bake describes the content it queued under the old one. Dropping it is what makes the material
	// generation a discard rather than a mislabel; the ring keeps the rect and re-offers it.
	jobs.erase(std::remove_if(jobs.begin(), jobs.end(),
					  [material_version](const RingJob &p_job) { return p_job.material_version != material_version; }),
			jobs.end());
	// No material list means the shader would invalidate every output instead of baking it, and a
	// dispatch that wrote black into a level must not be allowed to mark it baked: nothing is
	// dispatched, and the levels come back through the next offer.
	if (!_rd || !set.is_valid() || !job_buffer.is_valid() || size <= 0 || material_count <= 0 || jobs.empty()) {
		// Nothing is dispatched and nothing lands, so no level is marked: a ring baked with an empty
		// material list would write black into a level and then serve it. The levels stay queued out of
		// this tick and come back through the next offer, which is what makes this a delay rather than a
		// lost bake. `Terrain3D::_setup_vt_clipmap()` is what makes sure the list is published at all for
		// a configuration whose material group takes no page.
		return 0;
	}
	// The set still has to *exist*: the layer's implementation may have been replaced since the offer,
	// which frees the texture and the baked arrays the set names. Dispatching it is the device's
	// null-uniform-set error and a write nothing lands, so the producer forgets it and returns; the
	// ring keeps its rects (none of them was acknowledged) and re-offers them next tick.
	if (!_bake_set_is_live(set)) {
		_retire_stale_bake_sets();
		return 0;
	}
	// One dispatch per rect, one job in the buffer at a time: a rect's ring offset is part of what its
	// job *reads*, so it cannot ride in the push constant of a batch that carries several rects - and
	// such a batch would have to be cut to the job buffer's page-sized capacity, which is a coupling
	// between the ring and the page pool that a channel delivered by the ring alone must not have. The
	// dispatch covers the rect, which is what keeps a level that turned a strip from paying a bake of
	// its whole square. See `surface_bake_source_coord()` for what the source words mean to the shader.
	std::vector<RingJob> landed;
	for (const RingJob &job : jobs) {
		const int width = job.x1 - job.x0;
		const int height = job.y1 - job.y0;
		if (width <= 0 || height <= 0) {
			continue;
		}
		PackedByteArray job_bytes;
		job_bytes.resize(JOB_STRIDE);
		// The job's own rect in world terms - its extent, and the level's origin rather than the rect's,
		// because a *stored* rect's world position is not affine in the rect: the shader reaches it
		// through the level's policy grid, ring offset and all. A page's job is the affine one, which is
		// what its `source.x == 0` says.
		encode_vec4(job_bytes, 0, job.level_origin.x, job.level_origin.y, float(width) * float(job.texel),
				float(height) * float(job.texel));
		// No border: a ring rect *is* the world rect it covers. `page.z` is the level's texel count,
		// `page.w` the border, and a tap that leaves the layer wraps rather than clamps, which is what
		// a level without a border needs.
		encode_vec4(job_bytes, 16, float(job.texel), float(job.texel), float(size), 0.f);
		job_bytes.encode_u32(32, uint32_t(MAX(0, job.payload_layer)));
		job_bytes.encode_u32(36, uint32_t(MAX(0, job.level)));
		job_bytes.encode_u32(40, 1u);
		job_bytes.encode_u32(44, uint32_t(MAX(0, job.height_layer)));
		// The source grid is the *level's* own rect at the level's own texel size, so a world position
		// maps back to the logical texel the payload was read from - which for a rect of the level is
		// its own origin inside the level, not zero.
		encode_vec4(job_bytes, 48, 1.0f, job.level_origin.x, job.level_origin.y, float(job.texel));
		if (_rd->buffer_update(job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
			LOG(WARN, "Could not upload a clipmap ring bake job");
			break;
		}
		PackedByteArray push;
		push.resize(48);
		push.encode_u32(0, uint32_t(size));
		push.encode_u32(4, 1u);
		push.encode_u32(8, uint32_t(MAX(0, material_count)));
		push.encode_u32(12, 0u);
		// The source square wraps by the level's own ring, and the payload layer is the ring's raw
		// `FORMAT_RF` rather than a page's normalised `R16_UNORM`.
		push.encode_u32(16, uint32_t(size));
		push.encode_u32(20, uint32_t(MAX(0, job.ring.x)));
		push.encode_u32(24, uint32_t(MAX(0, job.ring.y)));
		push.encode_u32(28, 1u);
		// Where in the output layer this rect goes, and how big it is: the dispatch below covers it,
		// and the shader writes each invocation at its own texel inside it.
		push.encode_u32(32, uint32_t(MAX(0, job.x0)));
		push.encode_u32(36, uint32_t(MAX(0, job.y0)));
		push.encode_u32(40, uint32_t(width));
		push.encode_u32(44, uint32_t(height));
		SurfaceVTLabel label(_rd, "Clipmap Ring Bake - level " + String::num_int64(job.level) + " rect " +
						String::num_int64(job.x0) + "," + String::num_int64(job.y0));
		const int64_t compute_list = _rd->compute_list_begin();
		if (compute_list < 0) {
			LOG(WARN, "Could not begin a clipmap ring bake compute list");
			break;
		}
		_rd->compute_list_bind_compute_pipeline(compute_list, _resources.pipeline);
		_rd->compute_list_bind_uniform_set(compute_list, set, 0);
		_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
		_rd->compute_list_dispatch(compute_list, uint32_t((width + 7) / 8), uint32_t((height + 7) / 8), 1u);
		_rd->compute_list_end();
		// Only a rect that was actually recorded is a rect that landed: a batch that failed to record
		// must not report its rects as written.
		landed.push_back(job);
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const RingJob &job : landed) {
			_ring_bake.landed.push_back(job);
		}
		_ring_bake.dispatches += uint64_t(landed.size());
	}
	return int(landed.size());
}

///////////////////////////
// The clipmap layer's bake
///////////////////////////

// The one entry the layer's owner calls, whichever implementation is selected. It forwards to the
// storage-specific offer below: the queue's *shape*, its budget, its lease and its acknowledgment are
// the shared contract's (`TerrainClipmap::BakeRect`), so this is the only place in the addon that has
// to know which storage a rect lands in - and the reason it is here rather than at the call sites is
// that the descriptor sets and the job encoding are this producer's own plumbing.
int Terrain3DSurfaceBaker::queue_clipmap_layer(Terrain3DClipmapLayer *p_layer, const int p_budget_texels) {
	if (p_layer == nullptr || !p_layer->is_configured()) {
		return 0;
	}
	if (p_layer->get_implementation() == TerrainClipmap::Implementation::Atlas) {
		return _queue_clipmap_atlas(p_layer->atlas_impl(), p_budget_texels);
	}
	return _queue_clipmap_ring(p_layer->lod_impl(), p_budget_texels);
}

///////////////////////////
// The atlas's bake
///////////////////////////

// One atlas's descriptor set: the atlas's own texture as both inputs of the bake shader and the
// atlas's three baked arrays as its outputs. Nothing about it is a page - its size is the atlas, its
// outputs are rects of one array each - so it is built here rather than through the bundle path, the
// same way the ring's is.
bool Terrain3DSurfaceBaker::_ensure_atlas_bake(Terrain3DClipmapAtlas *p_atlas) {
	if (p_atlas == nullptr || !p_atlas->is_configured() || p_atlas->get_baked_channel_count() < 3 ||
			p_atlas->get_channel_count() < 2) {
		// The material channel declares the payload and the height, and the bake writes three arrays:
		// a channel that declares another shape is not one this path can fill.
		return false;
	}
	if (!_rd || !_resources.shader.is_valid() || !_resources.pipeline.is_valid() ||
			!_resources.job_buffer.is_valid() || !_resources.material_buffer.is_valid() ||
			!_resources.sampler_nearest.is_valid() || !_resources.sampler_linear.is_valid()) {
		return false;
	}
	const RID atlas = resolve_main_texture(p_atlas->get_texture_rid());
	if (!atlas.is_valid() || !_rd->texture_is_valid(atlas)) {
		return false;
	}
	const RID outputs[3] = { p_atlas->get_baked_device_rid(0), p_atlas->get_baked_device_rid(1),
		p_atlas->get_baked_device_rid(2) };
	if (!outputs[0].is_valid() || !outputs[1].is_valid() || !outputs[2].is_valid()) {
		return false;
	}
	if (_atlas_bake.atlas == p_atlas && _atlas_bake.uniform_set.is_valid() &&
			_atlas_bake.atlas_rd == atlas && _atlas_bake.job_buffer == _resources.job_buffer &&
			_atlas_bake.width == p_atlas->get_atlas_width() &&
			_atlas_bake.height == p_atlas->get_atlas_height()) {
		return true;
	}
	_free_atlas_bake();
	RID albedo_rd;
	RID normal_rd;
	_resolve_material_rd(_resources, albedo_rd, normal_rd, _material_albedo_rs, _material_normal_rs);
	TypedArray<Ref<RDUniform>> uniforms;
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
			_resources.sampler_nearest, atlas);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
			_resources.sampler_nearest, atlas);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
			_resources.sampler_linear, albedo_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3,
			_resources.sampler_linear, normal_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 4, _resources.material_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 5, _resources.job_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 6, outputs[0]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 7, outputs[1]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 8, outputs[2]);
	const RID set = _rd->uniform_set_create(uniforms, _resources.shader, 0);
	if (!set.is_valid()) {
		LOG(WARN, "Could not create the clipmap atlas bake uniform set");
		return false;
	}
	_atlas_bake.atlas = p_atlas;
	_atlas_bake.atlas_rd = atlas;
	_atlas_bake.job_buffer = _resources.job_buffer;
	_atlas_bake.width = p_atlas->get_atlas_width();
	_atlas_bake.height = p_atlas->get_atlas_height();
	_atlas_bake.uniform_set = set;
	return true;
}

void Terrain3DSurfaceBaker::_free_atlas_bake() {
	if (_atlas_bake.uniform_set.is_valid() && _rd && _rd->uniform_set_is_valid(_atlas_bake.uniform_set)) {
		_rd->free_rid(_atlas_bake.uniform_set);
	}
	_atlas_bake.uniform_set = RID();
	_atlas_bake.atlas_rd = RID();
	_atlas_bake.job_buffer = RID();
	_atlas_bake.atlas = nullptr;
	_atlas_bake.width = 0;
	_atlas_bake.height = 0;
	std::lock_guard<std::mutex> lock(_mutex);
	_atlas_bake.collected.clear();
	_atlas_bake.queued.clear();
	_atlas_bake.landed.clear();
}

int Terrain3DSurfaceBaker::_queue_clipmap_atlas(Terrain3DClipmapAtlas *p_atlas, const int p_budget_texels) {
	if (p_atlas == nullptr || !p_atlas->is_configured() || p_atlas->get_baked_channel_count() != 3) {
		return 0;
	}
	if (!_ensure_atlas_bake(p_atlas)) {
		return 0;
	}
	const int channels = MAX(1, p_atlas->get_channel_count());
	std::vector<AtlasJob> fresh;
	std::vector<AtlasJob> previous;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const AtlasJob &landed : _atlas_bake.landed) {
			// The atlas decides, not this thread: a rect whose slot has been reused for another block
			// describes content no bake read, and the atlas refuses the acknowledgment so the cell
			// keeps falling back rather than serving a stale rect.
			if (_atlas_bake.atlas == p_atlas) {
				p_atlas->acknowledge_bake(landed.rect());
			}
		}
		_atlas_bake.landed.clear();
		previous = std::move(_atlas_bake.collected);
		// The blocks the atlas has produced and no bake has covered, in the order it produced them.
		int budget = MAX(0, p_budget_texels);
		for (int index = 0; index < p_atlas->get_pending_bake_count(); index++) {
			const Terrain3DClipmapAtlas::BakeRect &rect = p_atlas->get_pending_bake(index);
			bool already = false;
			for (const AtlasJob &job : previous) {
				already = already || (job.slot == rect.unit && job.serial == rect.lease);
			}
			for (const AtlasJob &job : fresh) {
				already = already || (job.slot == rect.unit && job.serial == rect.lease);
			}
			if (already) {
				continue;
			}
			// The block's texel size is the slot's, and the shared entry's rect *is* the slot's rect:
			// the producer reads both back off the slot the entry names rather than carrying a second
			// copy of them in the queue.
			const int block_texels = p_atlas->get_slot_texels(rect.unit);
			const int64_t texels = int64_t(block_texels) * int64_t(block_texels) * int64_t(channels);
			// The budget is the production budget's own unit - channel texels - and it is a soft one:
			// at least one block is collected per offer, because a block is larger than a tick's
			// budget and a budget that never admitted it would leave the block unbaked forever.
			if (!fresh.empty() && budget > 0 && texels > int64_t(budget)) {
				break;
			}
			budget -= int(texels);
			AtlasJob job;
			job.slot = rect.unit;
			job.ring = p_atlas->get_slot_ring(rect.unit);
			job.serial = rect.lease;
			job.x0 = rect.x0;
			job.y0 = rect.y0;
			job.texels = block_texels;
			job.block_origin = p_atlas->get_slot_block_origin(rect.unit);
			job.texel = p_atlas->get_slot_texel_world(rect.unit);
			// Layer 0 is the payload and layer 1 the height: one array of two layers, named
			// separately because the bake reads them through two samplers at one job.
			job.payload_layer = 0;
			job.height_layer = 1;
			job.material_version = _material_version;
			fresh.push_back(job);
		}
		// This tick collects, the next dispatches: the payload of a block collected now is a
		// RenderingServer command that has not run yet, and a device dispatch issued in the same tick
		// would race that queue and read the texels the block is replacing.
		_atlas_bake.collected = std::move(fresh);
		_atlas_bake.queued = std::move(previous);
	}
	return int(_atlas_bake.collected.size());
}

int Terrain3DSurfaceBaker::_dispatch_atlas_bake() {
	std::vector<AtlasJob> jobs;
	RID set;
	RID job_buffer;
	int material_count = 0;
	uint64_t material_version = 0;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_atlas_bake.job_buffer != _resources.job_buffer) {
			return 0;
		}
		if (_atlas_bake.queued.empty()) {
			return 0;
		}
		jobs = std::move(_atlas_bake.queued);
		_atlas_bake.queued.clear();
		set = _atlas_bake.uniform_set;
		material_count = _material_count;
		material_version = _material_version;
		job_buffer = _atlas_bake.job_buffer;
	}
	jobs.erase(std::remove_if(jobs.begin(), jobs.end(),
					  [material_version](const AtlasJob &p_job) { return p_job.material_version != material_version; }),
			jobs.end());
	if (!_rd || !set.is_valid() || !job_buffer.is_valid() || material_count <= 0 || jobs.empty()) {
		return 0;
	}
	// Same liveness rule as the ring's: replacing the implementation, or reconfiguring the atlas, frees
	// the atlas texture and its baked arrays and invalidates this set. The atlas keeps every rect it
	// queued, so forgetting the set costs a tick rather than a bake.
	if (!_bake_set_is_live(set)) {
		_retire_stale_bake_sets();
		return 0;
	}
	std::vector<AtlasJob> landed;
	for (const AtlasJob &job : jobs) {
		const int width = job.texels;
		const int height = job.texels;
		if (width <= 0 || height <= 0) {
			continue;
		}
		PackedByteArray job_bytes;
		job_bytes.resize(JOB_STRIDE);
		// The block's world square: `policy.yz` is the square's origin and `page.xy` its texel, so a
		// content index maps to `origin + (index + 0.5) * texel` - the affine map the block was
		// produced from. `world_rect` is not read for an atlas job, whose source wraps inside its own
		// block rather than naming a whole level.
		encode_vec4(job_bytes, 0, job.block_origin.x, job.block_origin.y, float(width) * float(job.texel),
				float(height) * float(job.texel));
		encode_vec4(job_bytes, 16, float(job.texel), float(job.texel), float(job.texels), 0.f);
		job_bytes.encode_u32(32, uint32_t(MAX(0, job.payload_layer)));
		// The output array's written layer: the baked textures are one-layer arrays, so the rect is
		// the whole address and the layer is zero.
		job_bytes.encode_u32(36, 0u);
		job_bytes.encode_u32(40, 1u);
		job_bytes.encode_u32(44, uint32_t(MAX(0, job.height_layer)));
		encode_vec4(job_bytes, 48, 1.0f, job.block_origin.x, job.block_origin.y, float(job.texel));
		if (_rd->buffer_update(job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
			LOG(WARN, "Could not upload a clipmap atlas bake job");
			break;
		}
		PackedByteArray push;
		push.resize(48);
		// `dims.x` is the block's wrap size and `dims.w` the flag that tells the shader a block's
		// rect is a *rect of the atlas*: the source read is offset by `dest.xy` and the stored index
		// is the invocation's own, not the atlas position.
		push.encode_u32(0, uint32_t(job.texels));
		push.encode_u32(4, 1u);
		push.encode_u32(8, uint32_t(MAX(0, material_count)));
		push.encode_u32(12, 1u);
		// A block's source wraps inside its own square and the payload layer is the atlas's raw
		// `FORMAT_RF`. The phase is zero: a block's content is a function of its world square, not a
		// rotating level, so the stored index is the logical one.
		push.encode_u32(16, uint32_t(job.texels));
		push.encode_u32(20, 0u);
		push.encode_u32(24, 0u);
		push.encode_u32(28, 1u);
		// Where in the baked atlas this block goes, and how big it is.
		push.encode_u32(32, uint32_t(MAX(0, job.x0)));
		push.encode_u32(36, uint32_t(MAX(0, job.y0)));
		push.encode_u32(40, uint32_t(width));
		push.encode_u32(44, uint32_t(height));
		SurfaceVTLabel label(_rd, "Clipmap Atlas Bake - slot " + String::num_int64(job.slot) + " rect " +
						String::num_int64(job.x0) + "," + String::num_int64(job.y0));
		const int64_t compute_list = _rd->compute_list_begin();
		if (compute_list < 0) {
			LOG(WARN, "Could not begin a clipmap atlas bake compute list");
			break;
		}
		_rd->compute_list_bind_compute_pipeline(compute_list, _resources.pipeline);
		_rd->compute_list_bind_uniform_set(compute_list, set, 0);
		_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
		_rd->compute_list_dispatch(compute_list, uint32_t((width + 7) / 8), uint32_t((height + 7) / 8), 1u);
		_rd->compute_list_end();
		landed.push_back(job);
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const AtlasJob &job : landed) {
			_atlas_bake.landed.push_back(job);
		}
		_atlas_bake.dispatches += uint64_t(landed.size());
	}
	return int(landed.size());
}

///////////////////////////
// The detail layer's bake
///////////////////////////

// One detail layer's descriptor set: the layer's own source arrays as the bake's two inputs, the
// bundle's material arrays, and the layer's three arrays as the outputs. Built here rather than
// through the bundle path because nothing about it is a page - its size is the tile's stored size,
// its layers are the layer's slots, and its inputs are the very texels the manager uploaded a
// pipeline result into rather than a page's staging copy. The job format, the material list and the
// job buffer are the page producer's, which is what makes one shader serve a page, a ring rect and a
// detail tile.
bool Terrain3DSurfaceBaker::_ensure_detail_bake(Terrain3DMaterialClipmapDetail *p_detail) {
	if (p_detail == nullptr || !p_detail->is_enabled()) {
		return false;
	}
	if (!_rd || !_resources.shader.is_valid() || !_resources.pipeline.is_valid() ||
			!_resources.job_buffer.is_valid() || !_resources.material_buffer.is_valid() ||
			!_resources.sampler_nearest.is_valid() || !_resources.sampler_linear.is_valid()) {
		// No producer, no bake: the layer keeps its source and serves nothing, which is the state of
		// a build whose material group never took a page - and therefore has no bake pipeline - or a
		// configuration Stage 1 has not finished unlocking. The layer reports the tiles as pending
		// and the shader falls back to the coarse ring.
		return false;
	}
	const int stored_size = p_detail->get_stored_size();
	const int slots = p_detail->get_slot_count();
	const RID payload_rd = resolve_main_texture(p_detail->get_payload_texture_rid());
	const RID height_rd = resolve_main_texture(p_detail->get_height_texture_rid());
	const RID outputs[3] = { p_detail->get_baked_device_rid(0), p_detail->get_baked_device_rid(1),
		p_detail->get_baked_device_rid(2) };
	if (!payload_rd.is_valid() || !height_rd.is_valid() || stored_size <= 0 || slots <= 0 ||
			!outputs[0].is_valid() || !outputs[1].is_valid() || !outputs[2].is_valid()) {
		return false;
	}
	// The set survives a tick: it is rebuilt when the bundle it takes its buffers, samplers and
	// shader from was replaced, and rebuilt *and* the jobs dropped when the layer's own shape or
	// arrays changed. The two are different because a bundle rebuild does not invalidate the work the
	// layer already produced: `_free_detail_set()` keeps the queues, so a dispatch collected before
	// the rebuild still lands, and a landing that still owes an acknowledgment is not thrown away
	// before it is reported.
	const bool same_shape = _detail_bake.detail == p_detail && _detail_bake.stored_size == stored_size &&
			_detail_bake.slots == slots && _detail_bake.payload_rd == payload_rd &&
			_detail_bake.height_rd == height_rd;
	if (same_shape && _detail_bake.uniform_set.is_valid() &&
			_detail_bake.job_buffer == _resources.job_buffer) {
		return true;
	}
	if (!same_shape) {
		// The old shape's landings still describe the old layer's slots, so they are reported before
		// the jobs go: dropping them would leave the layer's `bake_in_flight` flag set with no
		// acknowledgment until its own timeout. The acknowledgment is only attempted when the manager
		// these jobs were dispatched for *is* the one being offered now: a layer that was torn down
		// and replaced leaves a pointer to a manager that no longer exists, and dereferencing it would
		// be a use-after-free. A torn-down layer's pending tiles died with it, so there is nothing left
		// to acknowledge in that case. `drop_detail_bake()` is what normally prevents the stale pointer
		// from being here at all; this keeps the comparison path safe on its own.
		if (_detail_bake.detail == p_detail) {
			std::lock_guard<std::mutex> lock(_mutex);
			for (const DetailJob &landed : _detail_bake.landed) {
				p_detail->acknowledge_bake(landed.slot, landed.generation);
			}
		}
		_free_detail_bake();
	} else {
		_free_detail_set();
	}
	RID albedo_rd;
	RID normal_rd;
	_resolve_material_rd(_resources, albedo_rd, normal_rd, _material_albedo_rs, _material_normal_rs);
	TypedArray<Ref<RDUniform>> uniforms;
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0,
			_resources.sampler_nearest, payload_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
			_resources.sampler_nearest, height_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2,
			_resources.sampler_linear, albedo_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3,
			_resources.sampler_linear, normal_rd);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 4, _resources.material_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 5, _resources.job_buffer);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 6, outputs[0]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 7, outputs[1]);
	append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 8, outputs[2]);
	const RID set = _rd->uniform_set_create(uniforms, _resources.shader, 0);
	if (!set.is_valid()) {
		LOG(WARN, "Could not create the detail material bake uniform set");
		return false;
	}
	_detail_bake.detail = p_detail;
	_detail_bake.payload_rd = payload_rd;
	_detail_bake.height_rd = height_rd;
	_detail_bake.job_buffer = _resources.job_buffer;
	_detail_bake.stored_size = stored_size;
	_detail_bake.slots = slots;
	_detail_bake.uniform_set = set;
	return true;
}

void Terrain3DSurfaceBaker::_free_detail_set() {
	if (_detail_bake.uniform_set.is_valid() && _rd && _rd->uniform_set_is_valid(_detail_bake.uniform_set)) {
		_rd->free_rid(_detail_bake.uniform_set);
	}
	_detail_bake.uniform_set = RID();
	_detail_bake.payload_rd = RID();
	_detail_bake.height_rd = RID();
	_detail_bake.job_buffer = RID();
	_detail_bake.detail = nullptr;
	_detail_bake.stored_size = 0;
	_detail_bake.slots = 0;
}

void Terrain3DSurfaceBaker::_free_detail_bake() {
	_free_detail_set();
	std::lock_guard<std::mutex> lock(_mutex);
	_detail_bake.collected.clear();
	_detail_bake.queued.clear();
	_detail_bake.landed.clear();
}

// The node's half of the layer's lifetime: it is called when the layer is about to be freed, so the
// set that names the layer's textures and the jobs that name its slots are dropped while the layer
// (and this bundle's job buffer) are still alive. See the declaration for why this cannot be left to
// the next `queue_detail_tiles()`.
void Terrain3DSurfaceBaker::drop_detail_bake() {
	_free_detail_bake();
}

int Terrain3DSurfaceBaker::queue_detail_tiles(Terrain3DMaterialClipmapDetail *p_detail, const int p_budget_texels) {
	if (p_detail == nullptr || !p_detail->is_enabled()) {
		return 0;
	}
	if (!_ensure_detail_bake(p_detail)) {
		// The offers stay with the layer: it re-offers them after its own timeout, so a producer
		// that is not ready yet delays the bake instead of losing it.
		std::lock_guard<std::mutex> lock(_mutex);
		_detail_bake.set_failures++;
		return 0;
	}
	std::vector<DetailJob> fresh;
	std::vector<DetailJob> previous;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const DetailJob &landed : _detail_bake.landed) {
			// The layer is what decides, not this thread: a slot that was reused, or a tile whose
			// content an edit invalidated while the dispatch was in flight, carries a different
			// generation - and serving those texels to a fragment is exactly what the generation
			// exists to prevent.
			if (_detail_bake.detail == p_detail) {
				p_detail->acknowledge_bake(landed.slot, landed.generation);
			}
		}
		_detail_bake.landed.clear();
		previous = std::move(_detail_bake.collected);
		// The tiles the layer has produced a source for and no bake has covered, in the order it
		// produced them. A tile already on its way to a dispatch is not collected twice: the second
		// bake would read the same source and land the same layers.
		int budget = MAX(0, p_budget_texels);
		// A copy of the layer's offers, because taking one mutates the layer's queue: iterating the
		// live queue while erasing from it would skip entries and read past its end.
		std::vector<Terrain3DMaterialClipmapDetail::BakeOffer> offers;
		const int offer_count = p_detail->get_pending_bake_count();
		offers.reserve(size_t(offer_count));
		for (int index = 0; index < offer_count; index++) {
			offers.push_back(p_detail->get_pending_bake(index));
		}
		for (const Terrain3DMaterialClipmapDetail::BakeOffer &offer : offers) {
			bool already = false;
			for (const DetailJob &job : previous) {
				already = already || (job.slot == offer.slot && job.generation == offer.generation);
			}
			for (const DetailJob &job : fresh) {
				already = already || (job.slot == offer.slot && job.generation == offer.generation);
			}
			if (already) {
				continue;
			}
			const int64_t texels = int64_t(offer.stored_size) * int64_t(offer.stored_size);
			// The budget is the ring's own unit - channel texels - and it is a *soft* one: at least
			// one tile is collected per offer, because a single 1024-density tile is larger than the
			// default tick budget and a budget that never admitted it would leave the layer unbaked
			// forever. After that first tile the budget is a real bound - it is clamped at zero, so a
			// tile that overspent it is the last of this offer rather than the first of an unbounded
			// batch. What is left stays with the layer for the next offer.
			if (!fresh.empty() && texels > budget) {
				break;
			}
			budget = int(MAX(int64_t(0), int64_t(budget) - texels));
			DetailJob job;
			job.slot = offer.slot;
			job.level = offer.level;
			job.generation = offer.generation;
			job.world_rect = offer.world_rect;
			job.source_grid = offer.source_grid;
			job.texel = offer.texel_world;
			job.border = offer.border;
			job.stored_size = offer.stored_size;
			fresh.push_back(job);
			// The offer is taken here rather than cleared wholesale after the loop: the budget
			// admits one tile at the default shape, and every offer it deferred has a tile already
			// marked in flight - clearing the queue would lose those until their timeout.
			p_detail->take_pending_bake(offer.slot, offer.generation);
		}
		_detail_bake.collected = std::move(fresh);
		_detail_bake.offers_taken += uint64_t(_detail_bake.collected.size());
		// This tick collects, the next dispatches: the source upload the layer just issued is a
		// RenderingServer command that has not run yet, and a device dispatch issued in the same tick
		// would race that queue and read the texels the upload is replacing. The batch is *appended*
		// to whatever the render callback has not drained yet: assigning it instead dropped every
		// batch collected while more than one tick ran between two callbacks - measured, 84 offers
		// taken and 6 dispatches in a configuration whose frames carried several physics ticks, so
		// the tiles the view asked for were collected and then thrown away.
		for (const DetailJob &job : previous) {
			_detail_bake.queued.push_back(job);
		}
	}
	return int(_detail_bake.collected.size());
}

int Terrain3DSurfaceBaker::_dispatch_detail_bake() {
	std::vector<DetailJob> jobs;
	RID set;
	RID job_buffer;
	int stored_size = 0;
	int material_count = 0;
	// The bundle's page count, read under the lock with everything else: it is the number of jobs the
	// bundle's job buffer was allocated for, and therefore the batch a single recording may carry.
	int job_capacity = 1;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_detail_bake.queued.empty()) {
			return 0;
		}
		// The set names the bundle's job buffer, and the bundle can be replaced between the offer
		// that built the set and this callback - the page bundle a far field selection creates is
		// exactly that, and its predecessor is retired and freed. Dispatching from a set that names
		// the freed buffer is what the renderer reports as an invalid buffer argument, so the guard
		// is the ring's own and it is checked before the jobs are taken: they stay queued, and the
		// next offer rebuilds the set against the live buffer and dispatches them there.
		if (_detail_bake.job_buffer != _resources.job_buffer) {
			return 0;
		}
		jobs = std::move(_detail_bake.queued);
		_detail_bake.queued.clear();
		set = _detail_bake.uniform_set;
		job_buffer = _detail_bake.job_buffer;
		stored_size = _detail_bake.stored_size;
		material_count = _material_count;
		job_capacity = MAX(1, _page_count);
	}
	// No material list means the shader would invalidate every output instead of baking it, and a
	// dispatch that wrote black into a tile must not be allowed to mark it readable. Nothing is
	// dispatched, and the jobs go back to the queue: a delay rather than a lost bake.
	if (!_rd || !set.is_valid() || !job_buffer.is_valid() || stored_size <= 0 || material_count <= 0 ||
			jobs.empty()) {
		std::lock_guard<std::mutex> lock(_mutex);
		for (const DetailJob &job : jobs) {
			_detail_bake.queued.push_back(job);
		}
		return 0;
	}
	// The same liveness rule as the two clipmap bakes: the detail layer's own directory and tile arrays
	// can have been freed under the set, which makes binding it a null-uniform-set dispatch. The jobs go
	// back to the queue rather than being dropped, because this path has somewhere to put them.
	if (!_bake_set_is_live(set)) {
		_retire_stale_bake_sets();
		std::lock_guard<std::mutex> lock(_mutex);
		for (const DetailJob &job : jobs) {
			_detail_bake.queued.push_back(job);
		}
		return 0;
	}
	PackedByteArray job_bytes;
	// The bundle's job buffer holds one job per page slot, and a ring-only bundle - the configuration
	// a material ring alone owns - allocates exactly one, because a page never uses more and a ring
	// rect is dispatched one at a time. A detail offer, however, collects as many tiles as the budget
	// admitted, so one `buffer_update` of the whole batch would overrun that buffer and record
	// nothing: measured, a ring-only configuration baked exactly the ticks whose batch happened to be
	// one tile. The batch is therefore cut into chunks the buffer actually holds and each chunk is its
	// own recording, which is also what the ring's one-dispatch-per-rect path does by construction.
	const int chunk_size = job_capacity;
	int dispatched = 0;
	std::vector<DetailJob> landed;
	for (size_t base = 0; base < jobs.size(); base += size_t(chunk_size)) {
		const size_t count = MIN(jobs.size() - base, size_t(chunk_size));
		job_bytes.resize(int64_t(count) * JOB_STRIDE);
		for (size_t index = 0; index < count; index++) {
			const DetailJob &job = jobs[base + index];
			const int64_t offset = int64_t(index) * JOB_STRIDE;
			// A detail tile's job is page-shaped: an affine world rect, the output texel size, the tile's
			// stored size and gutter, and the *source* grid the pipeline produced (`policy.yz` its origin
			// and `policy.w` its step). That last pair is what makes a 1024 texels/m output filtered from
			// real source corners rather than read from the same low-density texel: the shader reaches a
			// source tap through the grid, not through the output texel.
			const real_t texel_x = job.texel;
			const real_t texel_z = job.texel;
			encode_vec4(job_bytes, offset, job.world_rect.position.x, job.world_rect.position.y,
					job.world_rect.size.x, job.world_rect.size.y);
			encode_vec4(job_bytes, offset + 16, float(texel_x), float(texel_z), float(stored_size),
					float(job.border));
			// The source layer *is* the slot: one array holds the payload and one the height, so the two
			// indices are the same number into two textures (`indices.w` names the second).
			job_bytes.encode_u32(offset + 32, uint32_t(MAX(0, job.slot)));
			job_bytes.encode_u32(offset + 36, uint32_t(MAX(0, job.slot)));
			job_bytes.encode_u32(offset + 40, 1u);
			job_bytes.encode_u32(offset + 44, uint32_t(MAX(0, job.slot)));
			encode_vec4(job_bytes, offset + 48, 1.0f, job.source_grid.x, job.source_grid.y, job.source_grid.z);
		}
		if (_rd->buffer_update(job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
			LOG(WARN, "Could not upload the detail material bake jobs");
			break;
		}
		PackedByteArray push;
		push.resize(48);
		push.encode_u32(0, uint32_t(stored_size));
		push.encode_u32(4, uint32_t(count));
		push.encode_u32(8, uint32_t(MAX(0, material_count)));
		push.encode_u32(12, 0u);
		// `source.x == 0`: a tile's source is a stored rect with a gutter whose taps clamp, exactly like
		// a page's. `source.w == 0` is the normalised `R16_UNORM` payload read, which is the format the
		// layer's source array carries.
		push.encode_u32(16, 0u);
		push.encode_u32(20, 0u);
		push.encode_u32(24, 0u);
		push.encode_u32(28, 0u);
		// A tile's job covers the layer it fills: origin zero, the stored size either way.
		push.encode_u32(32, 0u);
		push.encode_u32(36, 0u);
		push.encode_u32(40, uint32_t(stored_size));
		push.encode_u32(44, uint32_t(stored_size));
		SurfaceVTLabel dispatch_label(_rd, "Detail Material Bake - " + String::num_int64(count) + " tiles");
		const int64_t compute_list = _rd->compute_list_begin();
		if (compute_list < 0) {
			LOG(WARN, "Could not begin a detail material bake compute list");
			break;
		}
		_rd->compute_list_bind_compute_pipeline(compute_list, _resources.pipeline);
		_rd->compute_list_bind_uniform_set(compute_list, set, 0);
		_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
		_rd->compute_list_dispatch(compute_list, uint32_t((stored_size + 7) / 8),
				uint32_t((stored_size + 7) / 8), uint32_t(count));
		_rd->compute_list_end();
		for (size_t index = 0; index < count; index++) {
			landed.push_back(jobs[base + index]);
		}
		dispatched += int(count);
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const DetailJob &job : landed) {
			_detail_bake.landed.push_back(job);
		}
		_detail_bake.dispatches += uint64_t(dispatched);
		// A chunk that could not be recorded keeps its tiles for the next callback, exactly as a batch
		// the material list or the device refused does: the layer's offers are re-collected, not lost.
		for (size_t index = size_t(dispatched); index < jobs.size(); index++) {
			_detail_bake.queued.push_back(jobs[index]);
		}
	}
	return dispatched;
}

Dictionary Terrain3DSurfaceBaker::get_detail_bake_stats() const {
	Dictionary stats;
	std::lock_guard<std::mutex> lock(_mutex);
	stats["dispatches"] = int64_t(_detail_bake.dispatches);
	stats["pending"] = int64_t(_detail_bake.collected.size() + _detail_bake.queued.size());
	stats["configured"] = _detail_bake.uniform_set.is_valid();
	stats["offers_taken"] = int64_t(_detail_bake.offers_taken);
	stats["set_failures"] = int64_t(_detail_bake.set_failures);
	stats["landed"] = int64_t(_detail_bake.landed.size());
	return stats;
}

Dictionary Terrain3DSurfaceBaker::get_atlas_bake_stats() const {
	Dictionary stats;
	std::lock_guard<std::mutex> lock(_mutex);
	stats["dispatches"] = int64_t(_atlas_bake.dispatches);
	stats["pending"] = int64_t(_atlas_bake.collected.size() + _atlas_bake.queued.size());
	stats["configured"] = _atlas_bake.uniform_set.is_valid();
	stats["landed"] = int64_t(_atlas_bake.landed.size());
	return stats;
}

void Terrain3DSurfaceBaker::render_pending(const Ref<RefCounted> &p_keep_alive) {
	(void)p_keep_alive;
	std::map<int, PendingJob> pending;
	uint64_t generation;
	uint64_t material_version;
	PackedByteArray material_bytes;
	RID material_albedo;
	RID material_normal;
	int page_size;
	int border;
	int page_count;
	int requested_capacity;
	int stored_size;
	int material_count;
	bool invalidate_all;
	bool materials_dirty;
	Ref<Terrain3DCellStore> cell_store;
	// The device drops a uniform set when a texture it bound is freed, and an asset edit frees
	// the arrays this set binds. Rebuild it through the materials path instead of dispatching
	// with a set the device no longer has: the renderer reports that as a null uniform set on
	// the bind and a missing set 0 on the dispatch. Reporting the materials as stale as well
	// asks the caller for the current pair, which is what makes the rebuild bind live arrays.
	// A ring-only bundle owns no page uniform set at all, so the state below is its normal one
	// and not a reason to report the materials stale.
	if (!_ring_only.load() && _resources.pipeline.is_valid() && !_resources.uniform_set.is_valid()) {
		std::lock_guard<std::mutex> lock(_mutex);
		_materials_dirty = true;
		_materials_stale = true;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (!_configured) {
			return;
		}
		generation = _generation;
		material_version = _material_version;
		material_bytes = _material_bytes;
		material_albedo = _material_albedo_rs;
		material_normal = _material_normal_rs;
		material_count = _material_count;
		page_size = _page_size;
		border = _border;
		page_count = _page_count;
		requested_capacity = _requested_capacity;
		stored_size = _stored_size;
		invalidate_all = _invalidate_all;
		materials_dirty = _materials_dirty;
		// Kept alive for the whole callback: a queued cell copy names a layer of this store.
		cell_store = _cell_store;
		pending.swap(_pending);
		_invalidate_all = false;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || !server->is_on_render_thread()) {
		// Parent registration should always route this method to the render thread.  Do
		// not touch a main RD from a game thread; restore the snapshot for a later call.
		std::lock_guard<std::mutex> lock(_mutex);
		for (const auto &entry : pending) {
			_pending.emplace(entry.first, entry.second);
		}
		_invalidate_all = _invalidate_all || invalidate_all;
		return;
	}
	_retire_acknowledged_bundles();
	if (!_ensure_resources(generation, page_count, stored_size,
				material_albedo, material_normal, material_bytes)) {
		std::lock_guard<std::mutex> lock(_mutex);
		for (const auto &entry : pending) {
			_pending.emplace(entry.first, entry.second);
		}
		_invalidate_all = _invalidate_all || invalidate_all;
		return;
	}
	if (materials_dirty) {
		// The material list is uploaded in both shapes: a ring-only bundle's bake reads it out of
		// the same buffer, and the page uniform set that names it is the only part a ring-only
		// bundle does not have.
		const bool uploaded = _upload_materials(material_bytes);
		const bool bound = uploaded && (_ring_only.load() ||
				_rebuild_uniform_set(_resources, material_albedo, material_normal));
		if (!bound) {
			std::lock_guard<std::mutex> lock(_mutex);
			// The snapshot named an array the asset system already replaced and freed. Forget
			// the cached pair so no later snapshot repeats it, and report the staleness: the
			// caller publishes the current pair, which also invalidates the pages this pass
			// would otherwise have baked from the fallback array.
			_material_albedo_rs = RID();
			_material_normal_rs = RID();
			_materials_stale = true;
			for (const auto &entry : pending) {
				_pending.emplace(entry.first, entry.second);
			}
			_invalidate_all = true;
			return;
		}
		std::lock_guard<std::mutex> lock(_mutex);
		if (_material_version == material_version) {
			_materials_dirty = false;
		}
	}

	// And the ring's bake, before the page batch: it reads the material list out of the buffer the
	// block above just wrote, and it must not depend on this frame having page work - a ring whose
	// channel is delivered by the ring has no pages at all, and `_dispatch_frame_jobs()` refuses an
	// empty batch, so a ring baked after it would only ever bake on frames the pages did.
	_dispatch_ring_bake();
	// And the block atlas's, which is the same bake with a rect instead of a level: a configuration
	// whose material group takes the atlas has no pages either, so it must not depend on this frame
	// having page work.
	_dispatch_atlas_bake();
	// And the detail layer's, for the same reason and in the same place: its tiles are not pages, so
	// its dispatch must not depend on this frame having page work either.
	_dispatch_detail_bake();

	// A ring-only bundle has no page arrays and no page uniform set, so the page batch below has
	// nothing it could dispatch into. The ring's bake above is the frame's whole device work.
	if (!_ring_only.load()) {
		// Material updates invalidate every old result, but a newer operation for a slot	// supersedes that invalidation.  Keeping one operation per slot also avoids races
		// between two z slices of the compute dispatch.
		std::vector<PendingJob> jobs = _build_frame_jobs(pending, invalidate_all, generation, page_count);

		if (!_dispatch_frame_jobs(jobs, generation, material_version, page_count, page_size, border,
					stored_size, material_count, invalidate_all, cell_store.ptr())) {
			return;
		}
		if (requested_capacity > page_count) {
			// Migrate after this frame's writes so both the still-bound old arrays and
			// the newly published arrays contain the same completed page contents.
			_ensure_resources(generation, requested_capacity, stored_size, material_albedo, material_normal, material_bytes);
		}
	}
}

///////////////////////////
// Read-only state and explicit export
///////////////////////////

// Single-channel getters kept for callers that predate the bundle read. They report the AVT
// tier, which is the tier the legacy single compression setting addresses; anything that has
// to bind both tiers at once reads get_published_arrays() instead.
RID Terrain3DSurfaceBaker::get_albedo_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_channel_uses_sampled(TIER_AVT, 0)) {
		return _resources.sampled[TIER_AVT].albedo_rs;
	}
	return _resources.output_albedo_rs;
}

// The three sampled arrays of one bundle, read under a single lock. The three getters above
// take the mutex separately, and the render thread replaces the whole bundle between two of
// them, so a caller that used them one by one could bind the albedo of one generation beside
// the normal of the next. That mix is the material sampling an array the release below is
// about to free, which the renderer reports once per draw as a missing material uniform set.
//
// Both tiers are published at once: the AVT arrays under the legacy keys, the SVT arrays
// under an `svt_` prefix. A tier that is stored uncompressed resolves to the staging arrays,
// which is what makes one setting able to be compressed while the other is not.
Dictionary Terrain3DSurfaceBaker::get_published_arrays() const {
	std::lock_guard<std::mutex> lock(_mutex);
	Dictionary result;
	if (_resource_generation != _generation) {
		return result;
	}
	auto publish = [this](Dictionary &r_result, int p_tier, const String &p_prefix) {
		const bool albedo_compressed = _tier_channel_uses_sampled(p_tier, 0);
		const bool normal_compressed = _tier_channel_uses_sampled(p_tier, 1);
		const bool params_compressed = _tier_channel_uses_sampled(p_tier, 2);
		r_result[p_prefix + String("albedo_height")] = albedo_compressed
				? _resources.sampled[p_tier].albedo_rs
				: _resources.output_albedo_rs;
		r_result[p_prefix + String("normal_roughness")] = normal_compressed
				? _resources.sampled[p_tier].normal_rs
				: _resources.output_normal_rs;
		r_result[p_prefix + String("params")] = params_compressed
				? _resources.sampled[p_tier].params_rs
				: _resources.output_params_rs;
		r_result[p_prefix + String("normal_encoding")] = normal_compressed
				? _tiers[p_tier].normal_applied.load() : int(SURFACE_NORMAL_UNCOMPRESSED);
		r_result[p_prefix + String("params_encoded")] = params_compressed;
	};
	publish(result, TIER_AVT, String());
	publish(result, TIER_SVT, String("svt_"));
	result["generation"] = int64_t(_resource_generation);
	return result;
}

// Generation of the arrays get_published_arrays() hands out. A material has to rebind whenever
// this changes, not only when the near field's albedo does: both tiers' sets are replaced as a
// bundle, and a far-field-only change would otherwise leave the material sampling freed arrays.
uint64_t Terrain3DSurfaceBaker::get_published_generation() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _resource_generation == _generation ? _resource_generation : 0;
}

RID Terrain3DSurfaceBaker::get_normal_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_channel_uses_sampled(TIER_AVT, 1)) {
		return _resources.sampled[TIER_AVT].normal_rs;
	}
	return _resources.output_normal_rs;
}

RID Terrain3DSurfaceBaker::get_params_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_resource_generation != _generation) {
		return RID();
	}
	if (_tier_channel_uses_sampled(TIER_AVT, 2)) {
		return _resources.sampled[TIER_AVT].params_rs;
	}
	return _resources.output_params_rs;
}

bool Terrain3DSurfaceBaker::is_page_ready(int p_slot) const {
	std::lock_guard<std::mutex> lock(_mutex);
	return p_slot >= 0 && p_slot < int(_ready.size()) && _ready[size_t(p_slot)] != 0;
}

// The idle gate of the near field asks about every resident slot on every tick, which is the
// same question `is_page_ready` answers one slot at a time - and one lock per slot turns that
// loop into the most expensive thing a settled view does. Answering the whole set under one
// lock is the same read of the same array.
int Terrain3DSurfaceBaker::count_unready_pages(const std::vector<int> &p_slots) const {
	std::lock_guard<std::mutex> lock(_mutex);
	const int count = int(_ready.size());
	int unready = 0;
	for (const int slot : p_slots) {
		if (slot < 0 || slot >= count || !_ready[size_t(slot)]) {
			++unready;
		}
	}
	return unready;
}

// The far field's version of the same read: it needs to know *which* slots are short of
// content, not how many, and it verifies both its protected roots and its detail set on
// every tick.
void Terrain3DSurfaceBaker::query_page_readiness(const std::vector<int> &p_slots,
		std::vector<uint8_t> &r_ready) const {
	std::lock_guard<std::mutex> lock(_mutex);
	const int count = int(_ready.size());
	r_ready.resize(p_slots.size());
	for (size_t i = 0; i < p_slots.size(); ++i) {
		const int slot = p_slots[i];
		r_ready[i] = (slot >= 0 && slot < count && _ready[size_t(slot)]) ? uint8_t(1) : uint8_t(0);
	}
}

Dictionary Terrain3DSurfaceBaker::export_page(int p_slot) const {
	Dictionary result;
	result["valid"] = false;
	result["generation"] = int64_t(0);
	if (!is_page_ready(p_slot)) {
		return result;
	}
	RID albedo;
	RID normal;
	RID params;
	uint64_t generation;
	int tier = TIER_AVT;
	bool albedo_srgb = false;
	int normal_encoding = SURFACE_NORMAL_UNCOMPRESSED;
	bool params_encoded = false;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (p_slot < 0 || p_slot >= int(_ready.size()) || !_ready[size_t(p_slot)]) {
			return result;
		}
		tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
		const bool sampled_albedo = _tier_channel_uses_sampled(tier, 0);
		const bool sampled_normal = _tier_channel_uses_sampled(tier, 1);
		const bool sampled_params = _tier_channel_uses_sampled(tier, 2);
		// A mixed tier may keep canonical staging for one channel while the other channels
		// have already been recycled into block arrays. Select each source independently.
		albedo = sampled_albedo ? _sampled_rs(tier, 0) : _resources.output_albedo_rs;
		normal = sampled_normal ? _sampled_rs(tier, 1) : _resources.output_normal_rs;
		params = sampled_params ? _sampled_rs(tier, 2) : _resources.output_params_rs;
		albedo_srgb = sampled_albedo;
		normal_encoding = sampled_normal ? _tiers[tier].normal_applied.load() : SURFACE_NORMAL_UNCOMPRESSED;
		params_encoded = sampled_params;
		generation = _generation;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || !albedo.is_valid() || !normal.is_valid() || !params.is_valid()) {
		return result;
	}
	// This is intentionally the only synchronous readback path.  Runtime render
	// callbacks never call export_page; offline/editor code may call it once a slot is
	// ready to serialize the persistent SVT channels.
	Ref<Image> albedo_image = server->texture_2d_layer_get(albedo, p_slot);
	Ref<Image> normal_image = server->texture_2d_layer_get(normal, p_slot);
	Ref<Image> params_image = server->texture_2d_layer_get(params, p_slot);
	if (albedo_image.is_null() || normal_image.is_null() || params_image.is_null()) {
		return result;
	}
	// A block-compressed layer comes back compressed, and every caller wants texels: the
	// offline SVT bake crops the border off and generates mipmaps from them.
	for (Ref<Image> *image : { &albedo_image, &normal_image, &params_image }) {
		if ((*image)->is_compressed() && (*image)->decompress() != OK) {
			return result;
		}
	}
	if (albedo_srgb) {
		// The albedo array is an sRGB codec, so the bytes just decoded are the sRGB encoding
		// of the page's colour. Undoing it here is the same conversion the hardware's sRGB
		// decode applies when the material samples the array, which is what makes an exported
		// page match both the rendered one and the uncompressed staging array it came from.
		const Image::Format decoded_format = albedo_image->get_format();
		if (decoded_format == Image::FORMAT_RGBA8 || decoded_format == Image::FORMAT_RGB8) {
			albedo_image->srgb_to_linear();
		}
	}
	const Ref<Image> packed_params = params_image;
	if (normal_encoding != SURFACE_NORMAL_UNCOMPRESSED || params_encoded) {
		normal_image = surface_decode_normal_page(normal_image, packed_params, normal_encoding, params_encoded);
	}
	if (params_encoded) {
		params_image = surface_decode_params_page(packed_params);
	}
	// Cached SVT pages have a fixed RGBAH canonical contract. A RenderingDevice readback of a
	// compressed UNORM target is commonly RGBA8, so normalize every export after decoding.
	for (Ref<Image> *image : { &albedo_image, &normal_image, &params_image }) {
		if ((*image)->get_format() != Image::FORMAT_RGBAH) {
			(*image)->convert(Image::FORMAT_RGBAH);
		}
	}
	result["albedo_height"] = albedo_image;
	result["normal_roughness"] = normal_image;
	result["params"] = params_image;
	result["valid"] = true;
	result["generation"] = int64_t(generation);
	return result;
}

Ref<Image> Terrain3DSurfaceBaker::get_page_preview(int p_slot) const {
	Dictionary page = export_page(p_slot);
	return page.get("albedo_height", Ref<Image>());
}

bool Terrain3DSurfaceBaker::has_render_work() const {
	std::lock_guard<std::mutex> lock(_mutex);
	// A queued ring rect is device work with no page behind it: a ring-only configuration has an
	// empty `_pending` and still needs the render callback to run, so it is part of this answer. The
	// detail layer's queued tiles are the same statement one level down - they are collected a tick
	// before they are dispatched, and a frame that skipped the callback would leave them there.
	return _configured && (!_pending.empty() || _invalidate_all || _materials_dirty || _materials_stale ||
			_requested_capacity > _page_count || !_retired.empty() || _retire_ready ||
			!_ring_bake.queued.empty() || !_detail_bake.queued.empty() || !_atlas_bake.queued.empty());
}

Dictionary Terrain3DSurfaceBaker::get_stats() const {
	std::lock_guard<std::mutex> lock(_mutex);
	Dictionary stats;
	stats["configured"] = _configured;
	stats["page_size"] = _page_size;
	stats["border"] = _border;
	stats["page_count"] = _page_count;
	stats["pending"] = int64_t(_pending.size());
	stats["generation"] = int64_t(_generation);
	stats["ready_pages"] = int64_t(std::count(_ready.begin(), _ready.end(), uint8_t(1)));
	stats["baked_pages"] = int64_t(_baked_pages);
	stats["cached_uploads"] = int64_t(_cached_uploads);
	stats["migrated_pages"] = int64_t(_migrated_pages);
	stats["invalidated_pages"] = int64_t(_invalidated_pages);
	stats["source_uploads"] = int64_t(_source_uploads);
	stats["dispatch_count"] = int64_t(_dispatch_count);
	// The ring's own dispatches, recorded rather than acknowledged: a rect the ring later refuses (its
	// lease moved before the bake landed) is counted here and re-queued there, so the two numbers
	// together are what says whether a moving focus is being baked at all. See `vt_clipmap_render`.
	// This function holds `_mutex` already, which is also what the three counters above rely on.
	stats["ring_bake_dispatches"] = int64_t(_ring_bake.dispatches);
	// Replaced arrays still alive because the material has not been rebound yet. This
	// has to read 0 in a settled frame, otherwise a rebuild is leaking its predecessor.
	stats["retired_bundles"] = int64_t(_retired.size());
	// A snapshot whose arrays were freed before the render thread bound them. It must return
	// to false on the following publish; a stuck true means the bake is using the fallback
	// array and the material pages it produces are not the artist's material.
	stats["materials_stale"] = _materials_stale;
	// The AVT tier under the legacy keys, both tiers under their own. `applied` is what the
	// tier's pages are actually stored in, which is what a test checks against the request.
	stats["atlas_compression"] = _tiers[TIER_AVT].requested;
	stats["atlas_compression_available"] = _tiers[TIER_AVT].effective.load();
	stats["atlas_compression_applied"] = _tiers[TIER_AVT].applied.load();
	stats["atlas_compression_name"] = String(page_codec(_tiers[TIER_AVT].effective.load()).name);
	stats["atlas_compression_reason"] = get_tier_compression_info(TIER_AVT).get("reason", String());
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const String prefix = tier == TIER_SVT ? String("svt_compression") : String("avt_compression");
		const Dictionary info = get_tier_compression_info(tier);
		stats[prefix + String("_requested")] = info.get("requested", 0);
		stats[prefix + String("_available")] = info.get("available", 0);
		stats[prefix + String("_applied")] = info.get("applied", 0);
		stats[prefix + String("_name")] = info.get("name", String());
		stats[prefix + String("_reason")] = info.get("reason", String());
		stats[prefix + String("_normal_requested")] = info.get("normal_requested", SURFACE_NORMAL_AUTO);
		stats[prefix + String("_normal_applied")] = info.get("normal_applied", SURFACE_NORMAL_UNCOMPRESSED);
		stats[prefix + String("_normal_name")] = info.get("normal_name", String("Uncompressed"));
		stats[prefix + String("_params_encoded")] = info.get("params_encoded", false);
	}
	stats["encode_pending"] = int64_t(std::count(_encode_pending.begin(), _encode_pending.end(), uint8_t(1)));
	// The half-float pool's shape: page sized while a tier samples it by slot, the encoder
	// ring once every tier is compressed. `staging_bytes` is what the pool costs - the
	// three RGBA16F outputs at 8 bytes per texel plus the R16/R32F sources at 6 - and
	// `material_bytes` is what the page arrays cost in total, which is the number the
	// compression settings move: the pool plus one compressed copy per tier that resolved.
	stats["staging_layers"] = _staging_layers;
	stats["staging_scratch"] = _staging_is_scratch();
	const int64_t staging_bytes = int64_t(_staging_layers) * _stored_size * _stored_size * 30;
	stats["staging_bytes"] = staging_bytes;
	int64_t compressed_bytes = 0;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const int64_t tier_bytes = _tier_sampled_bytes(tier);
		compressed_bytes += tier_bytes;
		const String tier_key = tier == TIER_SVT ? String("svt_") : String("avt_");
		stats[tier_key + String("bytes")] = tier_bytes;
	}
	stats["compressed_bytes"] = compressed_bytes;
	stats["material_bytes"] = staging_bytes + compressed_bytes;
	// Pool occupancy per tier: the slots whose content was produced for that tier, and how
	// many of those hold a page the material can sample. With the pool shared, a setting is
	// only worth its memory if the pages that use it are the ones resident.
	int64_t tier_slots[TIER_COUNT] = { 0, 0 };
	int64_t tier_ready[TIER_COUNT] = { 0, 0 };
	for (size_t slot = 0; slot < _slot_sequence.size(); ++slot) {
		if (_slot_sequence[slot] == 0) {
			continue;
		}
		const int tier = slot < _slot_tier.size() && _slot_tier[slot] < TIER_COUNT ? _slot_tier[slot] : TIER_AVT;
		tier_slots[tier]++;
		if (slot < _ready.size() && _ready[slot]) {
			tier_ready[tier]++;
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		const String tier_key = tier == TIER_SVT ? String("svt_") : String("avt_");
		stats[tier_key + String("slots")] = tier_slots[tier];
		stats[tier_key + String("ready_slots")] = tier_ready[tier];
	}
	stats["encode_ring_capacity"] = _encode_ring_capacity.load();
	stats["encode_ring_allocated"] = _encode_ring_allocated.load();
	// The peak the caller's page-budget settings admit and the depth that would need to serve it, so
	// the cost table reads "this tier needs this ring" rather than inferring it from the allocation.
	stats["page_budget_ceiling"] = _page_budget_ceiling.load();
	// Bytes one ring position costs, i.e. what one more page in flight costs in staging.
	stats["encode_page_bytes"] = _encode_page_bytes();
	stats["encode_requests"] = int64_t(_encode_requests);
	stats["encode_readbacks"] = int64_t(_encode_readbacks);
	stats["encode_updates"] = int64_t(_encode_updates);
	stats["ready_latency_samples"] = int64_t(_ready_latency_samples);
	stats["ready_latency_frames_mean"] = _ready_latency_samples
			? double(_ready_latency_sum) / double(_ready_latency_samples)
			: 0.0;
	stats["ready_latency_frames_max"] = int64_t(_ready_latency_max);
	stats["encode_failures"] = int64_t(_encode_failures);
	stats["encode_ring_pages"] = int64_t(std::count_if(_encode_ring_held.begin(), _encode_ring_held.end(),
			[](uint8_t p_held) { return p_held != 0; }));
	return stats;
}

int64_t Terrain3DSurfaceBaker::get_material_bytes() const {
	std::lock_guard<std::mutex> lock(_mutex);
	int64_t total = int64_t(_staging_layers) * _stored_size * _stored_size * 30;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		total += _tier_sampled_bytes(tier);
	}
	return total;
}

int Terrain3DSurfaceBaker::get_ready_page_count() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return int(std::count(_ready.begin(), _ready.end(), uint8_t(1)));
}

int Terrain3DSurfaceBaker::get_pending_page_count() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return int(_pending.size());
}

///////////////////////////
// Godot bindings
///////////////////////////

void Terrain3DSurfaceBaker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "page_size", "border", "page_count"),
			&Terrain3DSurfaceBaker::configure);
	ClassDB::bind_method(D_METHOD("set_tier_compression", "tier", "mode"),
			&Terrain3DSurfaceBaker::set_tier_compression);
	ClassDB::bind_method(D_METHOD("set_tier_normal_compression", "tier", "mode"),
			&Terrain3DSurfaceBaker::set_tier_normal_compression);
	ClassDB::bind_method(D_METHOD("get_tier_compression_info", "tier"),
			&Terrain3DSurfaceBaker::get_tier_compression_info);
	ClassDB::bind_method(D_METHOD("set_materials", "albedo_array_rid", "normal_array_rid", "colors",
								 "normal_depths", "ao_strengths", "ao_affects", "roughness_mods", "uv_scales", "detiles",
								 "slope_params"),
			&Terrain3DSurfaceBaker::set_materials);
	ClassDB::bind_method(D_METHOD("queue_page", "slot", "idweights", "height", "world_rect", "slope_factor", "source_grid", "tier"),
			&Terrain3DSurfaceBaker::queue_page, DEFVAL(1.0f), DEFVAL(Vector3()), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("queue_cached_page", "slot", "channels", "tier"),
			&Terrain3DSurfaceBaker::queue_cached_page, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("invalidate_slot", "slot"), &Terrain3DSurfaceBaker::invalidate_slot);
	ClassDB::bind_method(D_METHOD("render_pending", "keep_alive"), &Terrain3DSurfaceBaker::render_pending,
			DEFVAL(Ref<RefCounted>()));
	ClassDB::bind_method(D_METHOD("get_albedo_rid"), &Terrain3DSurfaceBaker::get_albedo_rid);
	ClassDB::bind_method(D_METHOD("get_normal_rid"), &Terrain3DSurfaceBaker::get_normal_rid);
	ClassDB::bind_method(D_METHOD("get_params_rid"), &Terrain3DSurfaceBaker::get_params_rid);
	ClassDB::bind_method(D_METHOD("is_page_ready", "slot"), &Terrain3DSurfaceBaker::is_page_ready);
	ClassDB::bind_method(D_METHOD("export_page", "slot"), &Terrain3DSurfaceBaker::export_page);
	ClassDB::bind_method(D_METHOD("get_page_preview", "slot"), &Terrain3DSurfaceBaker::get_page_preview);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DSurfaceBaker::get_stats);
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DSurfaceBaker::clear);
}
