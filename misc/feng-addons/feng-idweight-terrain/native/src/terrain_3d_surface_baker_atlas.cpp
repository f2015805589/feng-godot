// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, the clipmap atlas's bake: the descriptor set that binds the atlas's own
// texture to the bake shader and its three arrays to the shader's outputs, the job encoding that
// turns an atlas's block rects into dispatches, and the stats the mechanism reports. The page
// producer's own machinery - the job buffer, the pipelines, the shader and the ring's bake - is in
// terrain_3d_surface_baker.cpp, ..._pipelines.cpp, ..._queue.cpp and ..._frame.cpp; everything here
// is what an atlas, as opposed to a page, adds.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"
#include "terrain_3d_clipmap_atlas.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <mutex>
#include <utility>

using namespace terrain_surface_baker;

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
	append_bake_uniforms(uniforms, _resources.sampler_nearest, _resources.sampler_linear, atlas, atlas,
			albedo_rd, normal_rd, _resources.material_buffer, _resources.job_buffer, outputs);
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
	free_bake_set(_rd, _atlas_bake.uniform_set);
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
	// The blocks the atlas has produced and no bake has covered, in the order it produced them.
	// `offer_bake_jobs()` is the loop itself (terrain_3d_surface_baker_internal.h), shared with the
	// ring and the detail layer; what is the atlas's own is the job a rect becomes.
	return offer_bake_jobs(_atlas_bake.collected, _atlas_bake.queued, p_budget_texels,
			p_atlas->get_pending_bake_count(),
			[&](const int p_index, BakeOfferKey &r_key, int64_t &r_texels) {
				const Terrain3DClipmapAtlas::BakeRect &rect = p_atlas->get_pending_bake(p_index);
				r_key = bake_offer_key(rect);
				// The block's texel size is the slot's, and the shared entry's rect *is* the slot's
				// rect: the producer reads both back off the slot the entry names rather than
				// carrying a second copy of them in the queue.
				const int block_texels = p_atlas->get_slot_texels(rect.unit);
				r_texels = int64_t(block_texels) * int64_t(block_texels) * int64_t(channels);
				return true;
			},
			[](const AtlasJob &p_job) { return bake_offer_key(p_job.rect()); },
			[&](const int p_index) {
				const Terrain3DClipmapAtlas::BakeRect &rect = p_atlas->get_pending_bake(p_index);
				AtlasJob job;
				job.slot = rect.unit;
				job.ring = p_atlas->get_slot_ring(rect.unit);
				job.serial = rect.lease;
				job.x0 = rect.x0;
				job.y0 = rect.y0;
				job.texels = p_atlas->get_slot_texels(rect.unit);
				job.block_origin = p_atlas->get_slot_block_origin(rect.unit);
				job.texel = p_atlas->get_slot_texel_world(rect.unit);
				// Layer 0 is the payload and layer 1 the height: one array of two layers, named
				// separately because the bake reads them through two samplers at one job.
				job.payload_layer = 0;
				job.height_layer = 1;
				job.material_version = _material_version;
				return job;
			});
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
		// block rather than naming a whole level. The output array's written layer is zero: the baked
		// textures are one-layer arrays, so the rect is the whole address.
		encode_bake_job(job_bytes, 0,
				Vector4(job.block_origin.x, job.block_origin.y, float(width) * float(job.texel),
						float(height) * float(job.texel)),
				Vector4(float(job.texel), float(job.texel), float(job.texels), 0.f),
				uint32_t(MAX(0, job.payload_layer)), 0u, 1u, uint32_t(MAX(0, job.height_layer)),
				Vector4(1.0f, job.block_origin.x, job.block_origin.y, float(job.texel)));
		const String label = "Clipmap Atlas Bake - slot " + String::num_int64(job.slot) + " rect " +
				String::num_int64(job.x0) + "," + String::num_int64(job.y0);
		// `dims.w` is set for an atlas job: the source read is offset by `dest.xy` and the stored index
		// is the invocation's own, not the atlas position. The source wraps inside the block's own
		// square and the payload layer is the atlas's raw `FORMAT_RF`; the phase is zero, because a
		// block's content is a function of its world square, not a rotating level.
		if (!record_bake_dispatch(_rd, job_buffer, set, _resources.pipeline, job_bytes,
					{ { uint32_t(job.texels), 1u, uint32_t(MAX(0, material_count)), 1u },
							{ uint32_t(job.texels), 0u, 0u, 1u },
							// Where in the baked atlas this block goes, and how big it is.
							{ uint32_t(MAX(0, job.x0)), uint32_t(MAX(0, job.y0)), uint32_t(width),
									uint32_t(height) } },
					(width + 7) / 8, (height + 7) / 8, 1, label)) {
			break;
		}
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

Dictionary Terrain3DSurfaceBaker::get_atlas_bake_stats() const {
	Dictionary stats;
	std::lock_guard<std::mutex> lock(_mutex);
	stats["dispatches"] = int64_t(_atlas_bake.dispatches);
	stats["pending"] = int64_t(_atlas_bake.collected.size() + _atlas_bake.queued.size());
	stats["configured"] = _atlas_bake.uniform_set.is_valid();
	stats["landed"] = int64_t(_atlas_bake.landed.size());
	return stats;
}

