// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 1 of 6: the device and the objects on it.
//
// One of six files that define Terrain3DSurfaceBaker. This half finds the RenderingDevice,
// creates the textures and samplers every bundle is built from, checks that what a bake needs
// is resident, and uploads the material table the shaders read.
//
// The other halves: terrain_3d_surface_baker_bundle.cpp (the ResourceBundle's lifetime),
// terrain_3d_surface_baker_pipelines.cpp (the two GPU programs),
// terrain_3d_surface_baker_storage.cpp (page storage and the block encoder),
// terrain_3d_surface_baker_queue.cpp (the caller-facing queue) and
// terrain_3d_surface_baker_frame.cpp (one frame's jobs and the published state).

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"

#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

// The codec vocabulary, the shared constants and the small helpers of the halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

///////////////////////////
// Resource management
///////////////////////////

RID Terrain3DSurfaceBaker::_create_texture(RenderingDevice *p_rd, RenderingDevice::DataFormat p_format,
		int p_size, int p_layers, uint64_t p_usage, const PackedByteArray &p_first_layer) {
	if (!p_rd || p_size <= 0 || p_layers <= 0) {
		return RID();
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(p_format);
	format->set_width(uint32_t(p_size));
	format->set_height(uint32_t(p_size));
	format->set_depth(1);
	format->set_array_layers(uint32_t(p_layers));
	format->set_mipmaps(1);
	format->set_usage_bits(static_cast<BitField<RenderingDevice::TextureUsageBits>>(p_usage));
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> data;
	if (p_first_layer.size() > 0) {
		data.push_back(p_first_layer);
	}
	return p_rd->texture_create(format, view, data);
}

RID Terrain3DSurfaceBaker::_create_sampler(RenderingDevice *p_rd,
		RenderingDevice::SamplerFilter p_filter, RenderingDevice::SamplerRepeatMode p_repeat,
		float p_max_lod) {
	if (!p_rd) {
		return RID();
	}
	Ref<RDSamplerState> state;
	state.instantiate();
	state->set_mag_filter(p_filter);
	state->set_min_filter(p_filter);
	state->set_mip_filter(p_filter);
	state->set_repeat_u(p_repeat);
	state->set_repeat_v(p_repeat);
	state->set_repeat_w(p_repeat);
	state->set_min_lod(0.0f);
	state->set_max_lod(p_max_lod);
	return p_rd->sampler_create(state);
}

// Takes the main device the first time a bundle is needed, and reports whether there is one at all.
// Split out because every stage below assumes `_rd` and none of them is about acquiring it.
bool Terrain3DSurfaceBaker::_acquire_device() {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server) {
		return false;
	}
	if (!_rd) {
		RenderingDevice *main_rd = server->get_rendering_device();
		std::lock_guard<std::mutex> lock(_mutex);
		if (!_rd) {
			_rd = main_rd;
		}
	}
	if (!_rd) {
		LOG(ERROR, "No main RenderingDevice available for surface bake");
		return false;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_ensure_resources(uint64_t p_generation,
		int p_page_count, int p_stored_size, const RID &p_albedo_array_rs, const RID &p_normal_array_rs,
		const PackedByteArray &p_material_bytes) {
	if (!_acquire_device()) {
		return false;
	}
	bool growing = false;
	int old_count = 0;
	uint64_t old_generation = 0;
	ResourceBundle old;
	std::vector<uint8_t> ready;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_resource_generation == p_generation && _resources.pipeline.is_valid()) {
			if (_resource_page_count >= p_page_count || !_retired.empty()) { return true; }
			growing = true; old_count = _resource_page_count;
			old = _resources; old_generation = _resource_generation; ready = _ready;
		}
	}
	if (!growing) {
		old_generation = _take_resources(old);
		if (old.output_albedo_rd.is_valid()) {
			// Keep the previous pair alive: the published RIDs are still what the
			// material samples until the main thread rebinds it after this rebuild.
			std::lock_guard<std::mutex> lock(_mutex);
			_retire_ready = false;
			_retired.push_back({ old_generation, old });
		} else {
			_free_bundle(_rd, old);
		}
	}
	ResourceBundle next;
	if (!_create_bundle_resources(next, p_stored_size, p_page_count)) {
		return false;
	}
	const String layer_note = _staging_is_scratch()
			? String(" (scratch layer = encoder ring page)")
			: String(" (layer = physical slot)");
	_rd->set_resource_name(next.source_id_rd, "Surface VT Source IDWeights" + layer_note);
	_rd->set_resource_name(next.source_height_rd, "Surface VT Source Height" + layer_note);
	_rd->set_resource_name(next.output_albedo_rd, "Surface VT Albedo Height" + layer_note);
	_rd->set_resource_name(next.output_normal_rd, "Surface VT Normal Roughness" + layer_note);
	_rd->set_resource_name(next.output_params_rd, "Surface VT Parameters" + layer_note);
	next.output_albedo_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_albedo_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	next.output_normal_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_normal_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	next.output_params_rs = RenderingServer::get_singleton()->texture_rd_create(
			next.output_params_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	if (!next.output_albedo_rs.is_valid() || !next.output_normal_rs.is_valid() ||
			!next.output_params_rs.is_valid()) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not wrap surface bake arrays as RS textures");
		return false;
	}
	PackedByteArray initial_materials = p_material_bytes;
	if (initial_materials.size() != MATERIAL_COUNT * MATERIAL_STRIDE) {
		initial_materials.resize(MATERIAL_COUNT * MATERIAL_STRIDE);
		for (int64_t i = 0; i < initial_materials.size(); i++) {
			initial_materials[i] = 0;
		}
	}
	next.material_buffer = _rd->storage_buffer_create(uint32_t(initial_materials.size()), initial_materials);
	next.job_buffer = _rd->storage_buffer_create(uint32_t(std::max(1, p_page_count) * JOB_STRIDE));
	if (!next.material_buffer.is_valid() || !next.job_buffer.is_valid() || !_compile_pipeline(next) ||
			!_rebuild_uniform_set(next, p_albedo_array_rs, p_normal_array_rs)) {
		_free_bundle(_rd, next);
		LOG(ERROR, "Could not allocate surface bake buffers or pipeline");
		return false;
	}
	// The block encoder is only built when at least one channel actually resolved to a
	// compressed format.
	// A build whose encoder cannot compile drops both tiers back to uncompressed: a page
	// that samples an array nothing ever fills renders as the missing-page diagnostic, which
	// is worse than the memory the codec would have saved.
	if (_any_tier_uses_sampled(true) && !_compile_encode_pipeline(next)) {
		for (int tier = 0; tier < TIER_COUNT; ++tier) {
			_tiers[tier].applied.store(0);
			_tiers[tier].normal_applied.store(SURFACE_NORMAL_UNCOMPRESSED);
			_tiers[tier].params_encoded.store(false);
			_tiers[tier].effective.store(0);
			_tiers[tier].normal_effective.store(SURFACE_NORMAL_UNCOMPRESSED);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].format_srgb.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].normal_format.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].params_format.store(RenderingDevice::DATA_FORMAT_MAX);
			next.sampled[tier] = SampledSet();
		}
		_free_bundle(_rd, next);
		LOG(WARN, "Could not build the surface block encoder; keeping every page uncompressed");
		return false;
	}
	_rd->set_resource_name(next.job_buffer, "Surface VT Jobs (64 bytes: world rect, texel size, slot, mode)");
	_rd->set_resource_name(next.material_buffer, "Surface VT Material Parameters");
	_rd->set_resource_name(next.shader, "Surface VT Page Baker");
	// A fresh output has no valid pages.  Clearing all channels is recorded on the
	// main device; no submit or sync is performed here.
	_rd->texture_clear(next.output_albedo_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	_rd->texture_clear(next.output_normal_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	_rd->texture_clear(next.output_params_rd, Color(0.0f, 0.0f, 0.0f, 0.0f), 0, 1, 0, uint32_t(_staging_layers));
	if (growing && !_adopt_grown_pages(old, next, old_count, ready, old_generation, p_stored_size)) {
		return false;
	}
	_adopt_bundle(next, p_generation, p_page_count);
	return true;
}

bool Terrain3DSurfaceBaker::_upload_materials(const PackedByteArray &p_material_bytes) {
	if (!_rd || !_resources.material_buffer.is_valid() ||
			p_material_bytes.size() != MATERIAL_COUNT * MATERIAL_STRIDE) {
		return false;
	}
	return _rd->buffer_update(_resources.material_buffer, 0, uint32_t(p_material_bytes.size()),
				   p_material_bytes) == OK;
}
