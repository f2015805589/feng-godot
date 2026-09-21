// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 2 of 6: the ResourceBundle's lifetime.
//
// One of six files that define Terrain3DSurfaceBaker. A bundle is the three output arrays, the
// per-tier sampled sets, the encoders, buffers and samplers a bake writes into. This half
// creates one, grows it when the caller asks for more pages, adopts it as the live one and frees
// the one it replaced - at once, or a few frames later through `_free_deferred()`, because the
// renderer may still have draws built against it. `_collect_bundle_rids()` is the inventory all
// of that uses, and the reason a bundle can be freed without a leak.
//
// It never looks at a page: what fills a bundle is the storage half's business, and when it is
// filled is the frame half's.
//
// The other halves: terrain_3d_surface_baker.cpp (the device and its objects),
// terrain_3d_surface_baker_pipelines.cpp (the two GPU programs),
// terrain_3d_surface_baker_storage.cpp, terrain_3d_surface_baker_queue.cpp and
// terrain_3d_surface_baker_frame.cpp.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

// The codec vocabulary, the shared constants and the small helpers of the halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

void Terrain3DSurfaceBaker::_collect_bundle_rids(const ResourceBundle &p_resources,
		Array &r_rs_rids, Array &r_rd_rids) {
	for (const RID &wrapper : { p_resources.output_albedo_rs, p_resources.output_normal_rs,
				 p_resources.output_params_rs }) {
		if (wrapper.is_valid()) {
			r_rs_rids.push_back(wrapper);
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		for (const RID &wrapper : { p_resources.sampled[tier].albedo_rs,
					 p_resources.sampled[tier].normal_rs, p_resources.sampled[tier].params_rs }) {
			if (wrapper.is_valid()) {
				r_rs_rids.push_back(wrapper);
			}
		}
	}
	// Drop descriptor and pipeline objects before the resources they reference. The
	// RenderingDevice dependency tracker may invalidate a uniform set when one of its
	// textures is freed; freeing the texture first would make the later explicit
	// uniform-set free report an "invalid ID" during teardown.
	for (const RID &rid : { p_resources.uniform_set, p_resources.cell_pipeline, p_resources.cell_shader,
				 p_resources.pipeline, p_resources.shader }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (int channel = 0; channel < ENCODE_CHANNELS; ++channel) {
		if (p_resources.encode_uniform[channel].is_valid()) {
			r_rd_rids.push_back(p_resources.encode_uniform[channel]);
		}
	}
	for (const RID &rid : { p_resources.encode_pipeline, p_resources.encode_shader }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (const RID &rid : { p_resources.output_albedo_rd, p_resources.output_normal_rd, p_resources.output_params_rd,
				 p_resources.source_id_rd, p_resources.source_height_rd, p_resources.material_buffer,
				 p_resources.job_buffer, p_resources.dummy_albedo_rd, p_resources.dummy_normal_rd,
				 p_resources.sampler_nearest, p_resources.sampler_linear, p_resources.encode_buffer }) {
		if (rid.is_valid()) {
			r_rd_rids.push_back(rid);
		}
	}
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		for (const RID &rid : { p_resources.sampled[tier].albedo_rd, p_resources.sampled[tier].normal_rd,
					 p_resources.sampled[tier].params_rd }) {
			if (rid.is_valid()) {
				r_rd_rids.push_back(rid);
			}
		}
	}
}

void Terrain3DSurfaceBaker::_free_rids(RenderingDevice *p_rd, const Array &p_rs_rids,
		const Array &p_rd_rids) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (server) {
		for (int i = 0; i < p_rs_rids.size(); ++i) {
			const RID rid = p_rs_rids[i];
			if (rid.is_valid()) {
				server->free_rid(rid);
			}
		}
	}
	if (!p_rd) {
		return;
	}
	for (int i = 0; i < p_rd_rids.size(); ++i) {
		const RID rid = p_rd_rids[i];
		if (rid.is_valid()) {
			p_rd->free_rid(rid);
		}
	}
}

void Terrain3DSurfaceBaker::_free_bundle(RenderingDevice *p_rd, const ResourceBundle &p_resources) {
	Array rs_rids;
	Array rd_rids;
	_collect_bundle_rids(p_resources, rs_rids, rd_rids);
	_free_rids(p_rd, rs_rids, rd_rids);
}

void Terrain3DSurfaceBaker::_free_deferred(const Array &p_rs_rids, const Array &p_rd_rids) {
	RenderingServer *server = RenderingServer::get_singleton();
	_free_rids(server ? server->get_rendering_device() : nullptr, p_rs_rids, p_rd_rids);
}

uint64_t Terrain3DSurfaceBaker::_take_resources(ResourceBundle &r_resources) {
	std::lock_guard<std::mutex> lock(_mutex);
	const uint64_t generation = _resource_generation;
	r_resources = _resources;
	_resources = ResourceBundle();
	_resource_generation = 0;
	return generation;
}

Terrain3DSurfaceBaker::~Terrain3DSurfaceBaker() {
	clear();
}

void Terrain3DSurfaceBaker::clear() {
	std::vector<ResourceBundle> doomed;
	RenderingDevice *resource_rd = nullptr;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		resource_rd = _rd;
		if (_resources.output_albedo_rd.is_valid() || _resources.shader.is_valid()) {
			doomed.push_back(_resources);
		}
		for (const std::pair<uint64_t, ResourceBundle> &entry : _retired) {
			doomed.push_back(entry.second);
		}
		_retired.clear();
		_acknowledged_generation = 0;
		_retire_ready = false;
		_resources = ResourceBundle();
		_resource_generation = 0;
		_configured = false;
		_pending.clear();
		_ready.clear();
		_sampled_channel_mask.clear();
		_slot_sequence.clear();
		_slot_tier.clear();
		_slot_scratch.clear();
		_staging_layers = 0;
		_encode_pending.clear();
		{
			std::lock_guard<std::mutex> encode_lock(_encode_mutex);
			_encoded_layers.clear();
			// Sized to the deepest ring any budget can ask for; the admitted depth is
			// `_encode_ring_capacity`, which the bundle derives from the page budget and the
			// allocation below from the ring's whole ceiling.
			_encode_ring_held.assign(ENCODE_PAGES_MAX, 0);
		}
		_encode_region_bytes = 0;
		_encode_region_words = 0;
		_invalidate_all = false;
		++_generation;
		_rd = nullptr;
	}
	for (const ResourceBundle &resources : doomed) {
		if (!resources.shader.is_valid() && !resources.output_albedo_rd.is_valid() &&
				!resources.output_albedo_rs.is_valid()) {
			continue;
		}
		RenderingServer *server = RenderingServer::get_singleton();
		if (!server || server->is_on_render_thread()) {
			_free_bundle(resource_rd, resources);
			continue;
		}
		Array rs_rids;
		Array rd_rids;
		_collect_bundle_rids(resources, rs_rids, rd_rids);
		server->call_on_render_thread(callable_mp_static(&Terrain3DSurfaceBaker::_free_deferred)
											  .bind(rs_rids, rd_rids));
	}
}

// Carries a grown pool's finished pages into the bundle that replaces it, and queues the old bundle
// for retirement once the material has moved to the new one.
//
// Resource migration copies existing results; it does not rerun a page shader or restart source work.
// The old output has to stay alive until the next material update has bound the new arrays, including
// already prepared draws, which is why it goes through `_retired` rather than being freed here.
//
// Under the scratch regime there is nothing to copy: a page's half-float content only ever lives in
// the ring, and the compressed layers cannot be copied at all (a block format cannot carry the
// unordered-access flag `texture_copy` needs on D3D12). Every page is re-produced instead, which is
// what the caller already marked not ready. Returns false - with `p_next` freed - when a copy fails,
// in which case the caller has nothing to adopt.
bool Terrain3DSurfaceBaker::_adopt_grown_pages(const ResourceBundle &p_old, ResourceBundle &p_next,
		const int p_old_count, const std::vector<uint8_t> &p_ready, const uint64_t p_old_generation,
		const int p_stored_size) {
	uint64_t copied = 0;
	if (!_staging_is_scratch()) {
		for (int slot = 0; slot < p_old_count; ++slot) {
			if (slot >= int(p_ready.size()) || !p_ready[slot]) { continue; }
			const Vector3 extent(p_stored_size, p_stored_size, 1);
			if (_rd->texture_copy(p_old.output_albedo_rd, p_next.output_albedo_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK ||
					_rd->texture_copy(p_old.output_normal_rd, p_next.output_normal_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK ||
					_rd->texture_copy(p_old.output_params_rd, p_next.output_params_rd, Vector3(), Vector3(), extent, 0, 0, slot, slot) != OK) {
				_free_bundle(_rd, p_next); return false;
			}
			++copied;
		}
	}
	std::lock_guard<std::mutex> lock(_mutex);
	_retire_ready = false;
	_retired.push_back({ p_old_generation, p_old });
	_migrated_pages += copied;
	return true;
}

// Adopts a finished bundle as the one this baker produces into: everything indexed by the page count
// is resized together, so no slot can be read at a size the arrays do not have.
//
// A rebuilt bundle starts with empty compressed arrays. A grown bundle migrated the staging content
// of every ready page, so that content is encoded again into the new arrays; a block-compressed layer
// cannot be copied between formats, and the staging copy is what carries it across the resize.
// Without this every page that was ready before a capacity change would sample a zeroed compressed
// layer for the rest of the session. Under the scratch regime there is nothing to migrate - a page's
// half-float content only ever lives in the ring, and the ring belongs to the bundle just replaced -
// so every page is re-produced, exactly as the compressed arrays require anyway.
void Terrain3DSurfaceBaker::_adopt_bundle(ResourceBundle &p_next, const uint64_t p_generation,
		const int p_page_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_resources = p_next;
	_resource_generation = p_generation;
	_resource_page_count = p_page_count;
	_page_count = p_page_count;
	_ready.resize(size_t(p_page_count), 0);
	_produced_frame.resize(size_t(p_page_count), 0);
	_sampled_channel_mask.resize(size_t(p_page_count), 0);
	_slot_sequence.resize(size_t(p_page_count), 0);
	_slot_tier.resize(size_t(p_page_count), uint8_t(TIER_AVT));
	_slot_scratch.assign(size_t(p_page_count), uint8_t(ENCODE_RING_NONE));
	_encode_pending.assign(size_t(p_page_count), 0);
	{
		// The ring is the encoder's own state, so it is guarded by the encode mutex. Lock order is
		// _mutex then _encode_mutex everywhere; the readback callback takes them in separate scopes
		// and never holds one while taking the other.
		std::lock_guard<std::mutex> encode_lock(_encode_mutex);
		_encode_ring_held.assign(ENCODE_PAGES_MAX, 0);
	}
	if (_staging_is_scratch()) {
		std::fill(_ready.begin(), _ready.end(), uint8_t(0));
		std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
	}
	for (size_t slot = 0; slot < _ready.size(); ++slot) {
		if (_ready[slot] && _slot_tier[slot] < TIER_COUNT && _tier_uses_sampled(_slot_tier[slot])) {
			_encode_pending[slot] = 1;
		}
	}
}

// Creates every texture and sampler of one bundle, and validates them. The bundle is passed in
// rather than returned so a failure frees it in place: the caller has nothing to adopt either way.
// The three compressed tiers are built first, because whether the half-float staging arrays are
// page sized or only as deep as the encoder ring depends on which of them resolved - see the
// comment on `_staging_layers` below.
bool Terrain3DSurfaceBaker::_create_bundle_resources(ResourceBundle &r_next, const int p_stored_size,
		const int p_page_count) {
	const uint64_t sampled_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT;
	const uint64_t output_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT;
	PackedByteArray dummy_albedo;
	dummy_albedo.resize(4);
	dummy_albedo[0] = 255;
	dummy_albedo[1] = 255;
	dummy_albedo[2] = 255;
	dummy_albedo[3] = 255;
	PackedByteArray dummy_normal;
	dummy_normal.resize(4);
	dummy_normal[0] = 128;
	dummy_normal[1] = 128;
	dummy_normal[2] = 255;
	dummy_normal[3] = 255;
	r_next.dummy_albedo_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, 1, 1,
			sampled_usage, dummy_albedo);
	r_next.dummy_normal_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, 1, 1,
			sampled_usage, dummy_normal);
	r_next.sampler_nearest = _create_sampler(_rd, RenderingDevice::SAMPLER_FILTER_NEAREST,
			RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, 0.0f);
	r_next.sampler_linear = _create_sampler(_rd, RenderingDevice::SAMPLER_FILTER_LINEAR,
			RenderingDevice::SAMPLER_REPEAT_MODE_REPEAT, 1000.0f);
	// Compressed copies are channel independent. A raw channel keeps sampling its canonical
	// staging array, while the block encoder fills only the targets its mask names.
	//
	// The encoder's output region is a function of the stored page size, and every codec it
	// implements writes at most four words per block.
	_encode_region_bytes = ((p_stored_size + 3) / 4) * ((p_stored_size + 3) / 4) * 4 * int(sizeof(uint32_t));
	_encode_region_words = _encode_region_bytes / int(sizeof(uint32_t));
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		_tiers[tier].applied.store(0);
		_tiers[tier].normal_applied.store(SURFACE_NORMAL_UNCOMPRESSED);
		_tiers[tier].params_encoded.store(false);
		SampledSet &set = r_next.sampled[tier];
		const int diffuse_mode = _tiers[tier].effective.load();
		const int normal_mode = _tiers[tier].normal_effective.load();
		const bool want_albedo = diffuse_mode != SURFACE_PAGE_UNCOMPRESSED &&
				_tiers[tier].format_srgb.load() != RenderingDevice::DATA_FORMAT_MAX;
		const bool want_normal = normal_mode != SURFACE_NORMAL_UNCOMPRESSED &&
				_tiers[tier].normal_format.load() != RenderingDevice::DATA_FORMAT_MAX;
		const bool want_params = want_albedo || want_normal;
		const int params_codec = params_codec_for_channels(diffuse_mode, normal_mode);
		const RenderingDevice::DataFormat params_format = ATLAS_CODECS[params_codec].rd_format;
		_tiers[tier].params_format = want_params ? params_format : RenderingDevice::DATA_FORMAT_MAX;
		if (!want_albedo && !want_normal) {
			continue;
		}
		if (want_params && params_format == RenderingDevice::DATA_FORMAT_MAX) {
			_tiers[tier].effective.store(SURFACE_PAGE_UNCOMPRESSED);
			_tiers[tier].normal_effective.store(SURFACE_NORMAL_UNCOMPRESSED);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].format_srgb.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].normal_format.store(RenderingDevice::DATA_FORMAT_MAX);
			_free_bundle(_rd, r_next);
			LOG(WARN, "Parameter codec format is unavailable; keeping ", tier == TIER_SVT ? "SVT" : "AVT", " pages canonical");
			return false;
		}
		// Sampling, update, and readback. Copy-from is what lets a resident page be exported
		// (the dock preview, the offline bake) once the scratch pool has reused the layer it
		// was produced in: the page's content is then its block words. On D3D12 copy-from sets
		// no resource flag at all; copy-*to* would, and it is the one that has to stay off.
		const uint64_t compressed_usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
				RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
				RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
		set.albedo_rd = want_albedo ? _create_texture(_rd, _tiers[tier].format_srgb.load(), p_stored_size, p_page_count, compressed_usage) : RID();
		set.normal_rd = want_normal ? _create_texture(_rd, _tiers[tier].normal_format.load(), p_stored_size, p_page_count, compressed_usage) : RID();
		set.params_rd = want_params ? _create_texture(_rd, params_format, p_stored_size, p_page_count, compressed_usage) : RID();
		const String tier_name = tier == TIER_SVT ? String("SVT") : String("AVT");
		const bool allocated = (!want_albedo || set.albedo_rd.is_valid()) &&
				(!want_normal || set.normal_rd.is_valid()) && (!want_params || set.params_rd.is_valid());
		if (!allocated) {
			_tiers[tier].effective.store(SURFACE_PAGE_UNCOMPRESSED);
			_tiers[tier].normal_effective.store(SURFACE_NORMAL_UNCOMPRESSED);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].format_srgb.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].normal_format.store(RenderingDevice::DATA_FORMAT_MAX);
			_free_bundle(_rd, r_next);
			LOG(WARN, "Could not allocate the compressed surface arrays; keeping ", tier_name, " pages canonical");
			return false;
		}
		RenderingServer *server = RenderingServer::get_singleton();
		if (want_albedo) {
			_rd->set_resource_name(set.albedo_rd, "Surface VT " + tier_name + " Albedo Height (compressed)");
			set.albedo_rs = server ? server->texture_rd_create(set.albedo_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY) : RID();
		}
		if (want_normal) {
			_rd->set_resource_name(set.normal_rd, "Surface VT " + tier_name + " Normal Octahedral (compressed)");
			set.normal_rs = server ? server->texture_rd_create(set.normal_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY) : RID();
		}
		if (want_params) {
			_rd->set_resource_name(set.params_rd, "Surface VT " + tier_name + " Parameters (selected codec packed)");
			set.params_rs = server ? server->texture_rd_create(set.params_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY) : RID();
		}
		const bool wrapped = (!want_albedo || set.albedo_rs.is_valid()) &&
				(!want_normal || set.normal_rs.is_valid()) && (!want_params || set.params_rs.is_valid());
		if (!wrapped) {
			_tiers[tier].effective.store(SURFACE_PAGE_UNCOMPRESSED);
			_tiers[tier].normal_effective.store(SURFACE_NORMAL_UNCOMPRESSED);
			_tiers[tier].format.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].format_srgb.store(RenderingDevice::DATA_FORMAT_MAX);
			_tiers[tier].normal_format.store(RenderingDevice::DATA_FORMAT_MAX);
			_free_bundle(_rd, r_next);
			LOG(WARN, "Could not wrap the compressed surface arrays; keeping ", tier_name, " pages canonical");
			return false;
		}
		_tiers[tier].applied.store(want_albedo ? diffuse_mode : SURFACE_PAGE_UNCOMPRESSED);
		_tiers[tier].normal_applied.store(want_normal ? normal_mode : SURFACE_NORMAL_UNCOMPRESSED);
		_tiers[tier].params_encoded.store(want_params);
	}
	// The half-float staging arrays are page sized only while something samples them by slot.
	// With every tier compressed they exist to be encoded and nothing else, so they come down
	// to the encoder ring and the resident pool loses its largest allocation. A tier that
	// failed to build its arrays above keeps `applied` at 0 and samples staging by slot, which
	// is why the count is decided here and not from the request.
	//
	// The ring's *admitted* depth is derived from the page budget so that the budget, not the
	// ring, decides the page rate; the ring's *allocation* is the whole ceiling, because the
	// staging layers and the encoder's output buffer are fixed here and
	// `_refresh_encode_ring_capacity()` can never admit more than what this line reserved.
	// Allocating for the budget of this moment would make the setting a startup setting in
	// effect: measured in section 7.7.12, a session that raised `vt_pages_per_update` from 16 to
	// 64 kept the 32-position ring the build-time budget derived and produced the rate of a
	// 16-page budget. The ceiling is already bounded by bytes and by half the slot count, so the
	// headroom costs what the larger budget would have cost anyway.
	_encode_ring_allocated.store(_encode_ring_depth_ceiling());
	_staging_layers = _staging_is_scratch() ? _encode_ring_allocated.load() : p_page_count;
	_refresh_encode_ring_capacity();
	r_next.source_id_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16_UNORM, p_stored_size,
			_staging_layers, sampled_usage);
	r_next.source_height_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R32_SFLOAT, p_stored_size,
			_staging_layers, sampled_usage);
	r_next.output_albedo_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	r_next.output_normal_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	r_next.output_params_rd = _create_texture(_rd, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT,
			p_stored_size, _staging_layers, output_usage);
	if (!r_next.dummy_albedo_rd.is_valid() || !r_next.dummy_normal_rd.is_valid() ||
			!r_next.sampler_nearest.is_valid() || !r_next.sampler_linear.is_valid() ||
			!r_next.source_id_rd.is_valid() || !r_next.source_height_rd.is_valid() ||
			!r_next.output_albedo_rd.is_valid() || !r_next.output_normal_rd.is_valid() ||
			!r_next.output_params_rd.is_valid()) {
		_free_bundle(_rd, r_next);
		LOG(ERROR, "Could not allocate surface bake textures");
		return false;
	}
	return true;
}
