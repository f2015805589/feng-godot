// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, the detail material layer's bake: the descriptor set that binds the layer's
// own source arrays and the bundle's material arrays to the bake shader, the tile dispatch and its
// offers, the landing of the baked arrays, and the stats the layer reports. The page producer's own
// machinery is in terrain_3d_surface_baker.cpp, ..._pipelines.cpp, ..._queue.cpp and ..._frame.cpp;
// everything here is what the detail layer, as opposed to a page or an atlas block, adds.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"
#include "terrain_3d_material_clipmap_detail.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <mutex>
#include <utility>

using namespace terrain_surface_baker;

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

