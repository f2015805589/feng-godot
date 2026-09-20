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
		job_bytes.encode_u32(offset + 44, 0);
		encode_vec4(job_bytes, offset + 48, std::clamp(job.slope_factor, 0.0f, 1.0f), job.source_grid.x, job.source_grid.y, job.source_grid.z);
	}
	if (_rd->buffer_update(_resources.job_buffer, 0, uint32_t(job_bytes.size()), job_bytes) != OK) {
		LOG(WARN, "Could not upload surface bake jobs");
		return false;
	}
	PackedByteArray push;
	push.resize(16);
	push.encode_u32(0, uint32_t(p_stored_size));
	push.encode_u32(4, uint32_t(p_jobs.size()));
	push.encode_u32(8, uint32_t(std::max(0, p_material_count)));
	push.encode_u32(12, uint32_t(p_generation & 0xFFFFFFFFu));
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
	if (_resources.pipeline.is_valid() && !_resources.uniform_set.is_valid()) {
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
		if (!_upload_materials(material_bytes) || !_rebuild_uniform_set(_resources, material_albedo, material_normal)) {
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

	// Material updates invalidate every old result, but a newer operation for a slot
	// supersedes that invalidation.  Keeping one operation per slot also avoids races
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
	return _configured && (!_pending.empty() || _invalidate_all || _materials_dirty || _materials_stale ||
			_requested_capacity > _page_count || !_retired.empty() || _retire_ready);
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
