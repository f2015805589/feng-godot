// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 4 of 6: page storage and the block encoder.
//
// What a page is stored in - which codec a tier resolved to, and why a request was refused -
// the ring of in-flight encode pages, the dispatches that turn a staging layer into compressed
// blocks, and the readbacks that publish those blocks as the tier's sampled layers. The codec
// vocabulary itself lives in terrain_3d_surface_baker_internal.h.
//
// The other halves: terrain_3d_surface_baker.cpp (the device and its objects),
// terrain_3d_surface_baker_bundle.cpp (the ResourceBundle's lifetime),
// terrain_3d_surface_baker_pipelines.cpp (the two GPU programs),
// terrain_3d_surface_baker_queue.cpp and terrain_3d_surface_baker_frame.cpp.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"
#include "rd_gpu_copy.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/rect2i.hpp>

#include <algorithm>
#include <cmath>
#include <utility>

// The codec vocabulary, the shared constants and the small helpers of the four halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

///////////////////////////
// CPU queue and uploads
///////////////////////////

void Terrain3DSurfaceBaker::configure(int p_page_size, int p_border, int p_page_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_page_size = std::max(1, p_page_size);
	_border = std::max(0, p_border);
	_page_count = std::max(1, p_page_count);
	_requested_capacity = _page_count;
	_stored_size = _page_size + 2 * _border;
	_configured = true;
	++_generation;
	_pending.clear();
	_ready.assign(size_t(_page_count), 0);
	_produced_frame.assign(size_t(_page_count), 0);
	_sampled_channel_mask.assign(size_t(_page_count), 0);
	_slot_sequence.assign(size_t(_page_count), 0);
	_slot_tier.assign(size_t(_page_count), uint8_t(TIER_AVT));
	_slot_scratch.assign(size_t(_page_count), ENCODE_RING_NONE);
	_encode_pending.assign(size_t(_page_count), 0);
	_next_sequence = 1;
	_invalidate_all = true;
	_resource_generation = 0;
}

void Terrain3DSurfaceBaker::set_tier_compression(const int p_tier, const int p_mode) {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int mode = CLAMP(p_mode, 0, int(SURFACE_PAGE_COUNT) - 1);
	if (mode == _tiers[tier].requested && _configured) {
		return;
	}
	_tiers[tier].requested = mode;
	_resolve_tier_compression(tier);
	// Auto normal compression follows the diffuse request, so a diffuse setting change is
	// itself enough to change the resolved channel mask.
	if (_tiers[tier].normal_requested == SURFACE_NORMAL_AUTO) {
		_resolve_tier_normal_compression(tier);
	}
	LOG(INFO, "Surface page compression requested for ", tier == TIER_SVT ? "SVT" : "AVT", ": ",
			page_codec(_tiers[tier].requested).name,
			"; effective: ", page_codec(_tiers[tier].effective.load()).name,
			_tiers[tier].reason.is_empty() ? String() : String(" (") + _tiers[tier].reason + ")");
	if (_configured) {
		// The pages of that tier live in the previous format, so every page of the tier is
		// stale. Both tiers share the pool, and the bundle is rebuilt as one, so the whole
		// pool is re-produced rather than trying to keep the other tier's pages alive across
		// the rebuild.
		std::lock_guard<std::mutex> lock(_mutex);
		++_generation;
		_materials_dirty = true;
		_invalidate_all = true;
		_resource_generation = 0;
		std::fill(_ready.begin(), _ready.end(), uint8_t(0));
		std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
	}
}

void Terrain3DSurfaceBaker::set_tier_normal_compression(const int p_tier, const int p_mode) {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int mode = CLAMP(p_mode, int(SURFACE_NORMAL_AUTO), int(SURFACE_NORMAL_COUNT) - 1);
	if (mode == _tiers[tier].normal_requested && _configured) {
		return;
	}
	_tiers[tier].normal_requested = mode;
	_resolve_tier_normal_compression(tier);
	LOG(INFO, "Surface normal compression requested for ", tier == TIER_SVT ? "SVT" : "AVT", ": ",
			mode == SURFACE_NORMAL_AUTO ? String("Auto") : String(normal_codec_name(_tiers[tier].normal_effective.load())),
			"; effective: ", normal_codec_name(_tiers[tier].normal_effective.load()),
			_tiers[tier].normal_reason.is_empty() ? String() : String(" (") + _tiers[tier].normal_reason + ")");
	if (_configured) {
		std::lock_guard<std::mutex> lock(_mutex);
		++_generation;
		_materials_dirty = true;
		_invalidate_all = true;
		_resource_generation = 0;
		std::fill(_ready.begin(), _ready.end(), uint8_t(0));
		std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
	}
}

// Resolves one tier's request against this device's sampling support. Which codecs a page can
// be stored in at all is decided by the page codec list and its mapping to the block encoder's
// table; the two invariants that list exists for are checked here as well, so a table edit
// that broke one of them would be refused rather than stored as a page nothing can encode.
void Terrain3DSurfaceBaker::_resolve_tier_compression(const int p_tier) {
	TierState &tier = _tiers[p_tier];
	const String tier_name = p_tier == TIER_SVT ? String("SVT") : String("AVT");
	tier.effective = 0;
	tier.format = RenderingDevice::DATA_FORMAT_MAX;
	tier.format_srgb = RenderingDevice::DATA_FORMAT_MAX;
	tier.reason = String();
	if (tier.requested == 0) {
		return;
	}
	const AtlasCodec &codec = page_codec(tier.requested);
	if (codec.channels != Image::USED_CHANNELS_RGBA) {
		tier.reason = String(codec.name) +
				" keeps no alpha channel, and the material pages store height, roughness and the validity bit in alpha";
		return;
	}
	if (codec.gpu_codec == GPU_CODEC_NONE) {
		// The pages are encoded by shaders/bc_encode.glsl on the GPU. A codec it has no
		// encoder for would need a CPU block encoder per page, which is the cost this path
		// exists to remove, so it is refused rather than silently paid.
		tier.reason = String(codec.name) + " has no GPU block encoder, and page compression never runs a CPU codec";
		return;
	}
	// The renderer format comes from the codec table, so the table stays the single
	// vocabulary for every terrain texture array.
	const RenderingDevice::DataFormat format = codec.rd_format;
	if (format == RenderingDevice::DATA_FORMAT_MAX) {
		tier.reason = String(codec.name) + " has no renderer format";
		return;
	}
	const RenderingDevice::DataFormat format_srgb = codec.rd_format_srgb;
	if (format_srgb == RenderingDevice::DATA_FORMAT_MAX) {
		// A page's albedo is a colour and has to be stored in the codec's sRGB format: the
		// encoder writes sRGB texels and the hardware decodes them, which is the only way a
		// block codec's handful of bits per channel can hold the darks of a linear colour.
		// Refusing here keeps that from silently degrading into a hue shift.
		tier.reason = String(codec.name) + " has no sRGB renderer format for the albedo page";
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server ? server->get_rendering_device() : nullptr;
	if (rd && (!rd->texture_is_format_supported_for_usage(format,
					   RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT) ||
					 !rd->texture_is_format_supported_for_usage(format_srgb,
							 RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT))) {
		tier.reason = String(codec.name) + " cannot be sampled and updated on this rendering device";
		return;
	}
	tier.effective = tier.requested;
	tier.format = format;
	tier.format_srgb = format_srgb;
	LOG(DEBUG, "Surface page compression for ", tier_name, " resolved to ", codec.name);
}

void Terrain3DSurfaceBaker::_resolve_tier_normal_compression(const int p_tier) {
	TierState &tier = _tiers[p_tier];
	const String tier_name = p_tier == TIER_SVT ? String("SVT") : String("AVT");
	tier.normal_effective = SURFACE_NORMAL_UNCOMPRESSED;
	tier.normal_format = RenderingDevice::DATA_FORMAT_MAX;
	tier.normal_reason = String();
	int mode = tier.normal_requested;
	if (mode == SURFACE_NORMAL_AUTO) {
		// The public tier setting selects the same block format for every page channel.
		mode = normal_mode_for_page_codec(tier.requested);
	}
	if (mode == SURFACE_NORMAL_UNCOMPRESSED) {
		return;
	}
	const AtlasCodec &codec = normal_codec(mode);
	if (codec.gpu_codec == GPU_CODEC_NONE || codec.rd_format == RenderingDevice::DATA_FORMAT_MAX) {
		tier.normal_reason = String(codec.name) + " has no GPU block encoder or renderer format";
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server ? server->get_rendering_device() : nullptr;
	if (rd && !rd->texture_is_format_supported_for_usage(codec.rd_format,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT)) {
		tier.normal_reason = String(codec.name) + " cannot be sampled and updated on this rendering device";
		return;
	}
	tier.normal_effective = mode;
	tier.normal_format = codec.rd_format;
	LOG(DEBUG, "Surface normal compression for ", tier_name, " resolved to ", codec.name);
}

Dictionary Terrain3DSurfaceBaker::get_tier_compression_info(const int p_tier) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const TierState &state = _tiers[tier];
	Dictionary info;
	info["tier"] = tier;
	info["requested"] = state.requested;
	// `available` is what the block encoder and this device can store and sample; `applied`
	// is what the tier's page arrays are actually kept in. The two differ while the arrays
	// have not been built yet, and they also differ when the device refused the real
	// allocation after accepting the capability query, so the reported state never claims a
	// format the pages are not stored in.
	const int available = state.effective.load();
	info["available"] = available;
	info["applied"] = state.applied.load();
	info["name"] = String(page_codec(available).name);
	String reason = state.reason;
	if (reason.is_empty() && available == 0 && state.requested != 0) {
		reason = String(page_codec(state.requested).name) +
				String(" was resolved for this device, but the compressed page arrays could not be created");
	}
	info["reason"] = reason;
	info["rd_format"] = int(state.format.load());
	info["rd_format_albedo"] = int(state.format_srgb.load());
	const int normal_available = state.normal_effective.load();
	info["normal_requested"] = state.normal_requested;
	info["normal_available"] = normal_available;
	info["normal_applied"] = state.normal_applied.load();
	info["normal_name"] = String(normal_codec_name(state.normal_applied.load()));
	String normal_reason = state.normal_reason;
	if (normal_reason.is_empty() && normal_available == SURFACE_NORMAL_UNCOMPRESSED &&
			state.normal_requested != SURFACE_NORMAL_AUTO && state.normal_requested != SURFACE_NORMAL_UNCOMPRESSED) {
		normal_reason = String(normal_codec_name(state.normal_requested)) +
				String(" was resolved for this device, but the compressed normal array could not be created");
	}
	info["normal_reason"] = normal_reason;
	info["normal_rd_format"] = int(state.normal_format.load());
	info["params_encoded"] = state.params_encoded.load();
	info["params_rd_format"] = int(state.params_format.load());
	return info;
}

RID Terrain3DSurfaceBaker::_staging_rd_of(const ResourceBundle &p_resources, const int p_channel) {
	switch (p_channel) {
		case 0:
			return p_resources.output_albedo_rd;
		case 1:
			return p_resources.output_normal_rd;
		default:
			return p_resources.output_params_rd;
	}
}

RID Terrain3DSurfaceBaker::_staging_rd(const int p_channel) const {
	return _staging_rd_of(_resources, p_channel);
}

RID Terrain3DSurfaceBaker::_sampled_rd(const int p_tier, const int p_channel) const {
	const SampledSet &set = _resources.sampled[CLAMP(p_tier, 0, TIER_COUNT - 1)];
	switch (p_channel) {
		case 0:
			return set.albedo_rd;
		case 1:
			return set.normal_rd;
		default:
			return set.params_rd;
	}
}

RID Terrain3DSurfaceBaker::_sampled_rs(const int p_tier, const int p_channel) const {
	const SampledSet &set = _resources.sampled[CLAMP(p_tier, 0, TIER_COUNT - 1)];
	switch (p_channel) {
		case 0:
			return set.albedo_rs;
		case 1:
			return set.normal_rs;
		default:
			return set.params_rs;
	}
}

// True when this tier's pages are stored in its own compressed set and not in the staging
// arrays. A tier that did not resolve to a codec samples the staging arrays, which is why
// an uncompressed tier costs no memory at all beyond the pool it already has.
bool Terrain3DSurfaceBaker::_tier_uses_sampled(const int p_tier) const {
	return _tier_channel_mask(p_tier, true) != 0;
}

uint8_t Terrain3DSurfaceBaker::_tier_channel_mask(const int p_tier, const bool p_applied) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const TierState &state = _tiers[tier];
	const int diffuse = p_applied ? state.applied.load() : state.effective.load();
	const int normal = p_applied ? state.normal_applied.load() : state.normal_effective.load();
	const bool params = p_applied ? state.params_encoded.load() : (diffuse != 0 || normal != 0);
	uint8_t mask = 0;
	if (diffuse != 0) { mask |= uint8_t(1u << 0); }
	if (normal != SURFACE_NORMAL_UNCOMPRESSED) { mask |= uint8_t(1u << 1); }
	if (params) { mask |= uint8_t(1u << 2); }
	return mask;
}

int Terrain3DSurfaceBaker::_tier_channel_codec(const int p_tier, const int p_channel,
		const bool p_applied) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const TierState &state = _tiers[tier];
	if (p_channel == 0) {
		const int mode = p_applied ? state.applied.load() : state.effective.load();
		return page_codec_atlas(mode);
	}
	if (p_channel == 1) {
		const int mode = p_applied ? state.normal_applied.load() : state.normal_effective.load();
		return normal_codec_atlas(mode);
	}
	const int diffuse = p_applied ? state.applied.load() : state.effective.load();
	const int normal = p_applied ? state.normal_applied.load() : state.normal_effective.load();
	return _tier_channel_mask(tier, p_applied) & uint8_t(1u << 2)
			? params_codec_for_channels(diffuse, normal) : 0;
}

bool Terrain3DSurfaceBaker::_tier_channel_uses_sampled(const int p_tier, const int p_channel) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int channel = CLAMP(p_channel, 0, ENCODE_CHANNELS - 1);
	return (_tier_channel_mask(tier, true) & uint8_t(1u << uint32_t(channel))) != 0 &&
			_sampled_rd(tier, channel).is_valid();
}

bool Terrain3DSurfaceBaker::_any_tier_uses_sampled(const bool p_applied) const {
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		if (_tier_channel_mask(tier, p_applied) != 0) {
			return true;
		}
	}
	return false;
}

// True when every tier resolved to a compressed format, so no consumer samples the RGBA16F
// staging arrays by slot and they can shrink to the encoder ring. Decided from the resolved
// state, not from `applied`: the arrays are allocated before a bundle becomes the current one,
// and the answer has to be the same for the arrays and for the code that indexes them.
bool Terrain3DSurfaceBaker::_staging_is_scratch() const {
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		if (_tier_channel_mask(tier, false) != 0x7u) {
			return false;
		}
	}
	return true;
}

// Bytes one ring position costs. The encoder writes three channel regions per page, and
// under the scratch regime the same position also owns the half-float staging layer the page
// is produced into, which is the larger of the two and the one that decides the ceiling.
int64_t Terrain3DSurfaceBaker::_encode_page_bytes() const {
	const int64_t regions = int64_t(_encode_region_bytes) * ENCODE_CHANNELS;
	if (!_staging_is_scratch()) {
		return regions;
	}
	return regions + int64_t(_stored_size) * _stored_size * 30;
}

// The depth the ring may ever hold: what the byte ceiling affords, what the slot count justifies
// (a compressed pool must still cost less than the page-sized one it replaces) and what the
// encoder may have in flight. This is the allocation's question, not the budget's, and it is the
// only place either is answered: `_derive_encode_ring_pages()` asks it for the bound, and the
// bundle build asks it for what to size the staging layers and the encoder's output buffer for.
int Terrain3DSurfaceBaker::_encode_ring_depth_ceiling() const {
	const int64_t page_bytes = _encode_page_bytes();
	const int64_t affordable = page_bytes > 0 ? ENCODE_RING_BUDGET_BYTES / page_bytes
											  : int64_t(ENCODE_PAGES_MAX);
	const int slot_bound = MAX(_page_count / 2, ENCODE_PAGES_MIN);
	return int(CLAMP(MIN(affordable, int64_t(slot_bound)), int64_t(ENCODE_PAGES_MIN),
			int64_t(ENCODE_PAGES_MAX)));
}

// Depth the ring has to admit so that the caller's page budget, not the ring, decides how many
// pages a frame finishes: a page's regions are held for about two frames, so the ring has to
// hold two budgets' worth, bounded by what it was allocated for and by the ceiling above.
int Terrain3DSurfaceBaker::_derive_encode_ring_pages() const {
	const int wanted = _page_budget.load() * ENCODE_READBACK_FRAMES;
	return CLAMP(MIN(wanted, _encode_ring_depth_ceiling()), ENCODE_PAGES_MIN, ENCODE_PAGES_MAX);
}

void Terrain3DSurfaceBaker::_refresh_encode_ring_capacity() {
	int capacity = CLAMP(MIN(_derive_encode_ring_pages(), _encode_ring_allocated.load()),
			ENCODE_PAGES_MIN, ENCODE_PAGES_MAX);
	// The scratch regime indexes the staging layers that were allocated with the bundle, so
	// the admitted depth can never exceed them.
	const int layers = _staging_layers;
	if (layers > 0) {
		capacity = MIN(capacity, layers);
	}
	_encode_ring_capacity.store(capacity);
}

// Bytes the independently compressed arrays of one tier cost in the current bundle's slot count.
int64_t Terrain3DSurfaceBaker::_tier_sampled_bytes(const int p_tier) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	const int64_t blocks = (int64_t(_stored_size) + 3) / 4;
	int64_t total = 0;
	for (int channel = 0; channel < ENCODE_CHANNELS; ++channel) {
		if (!_tier_channel_uses_sampled(tier, channel)) {
			continue;
		}
		const AtlasCodec &codec = ATLAS_CODECS[_tier_channel_codec(tier, channel, true)];
		if (codec.block_words != 0) {
			total += blocks * blocks * codec.block_words * int64_t(sizeof(uint32_t)) * _page_count;
		}
	}
	return total;
}

void Terrain3DSurfaceBaker::_mark_sampled_channel_ready(const int p_tier, const int p_slot,
		const int p_channel, const uint64_t p_generation, const uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_generation != p_generation || p_slot < 0 || p_slot >= int(_ready.size()) ||
			p_slot >= int(_sampled_channel_mask.size()) || p_slot >= int(_slot_sequence.size()) ||
			_slot_sequence[size_t(p_slot)] != p_sequence ||
			_slot_tier[size_t(p_slot)] != uint8_t(CLAMP(p_tier, 0, TIER_COUNT - 1))) {
		return;
	}
	_sampled_channel_mask[size_t(p_slot)] |= uint8_t(1u << uint32_t(p_channel));
	if ((_sampled_channel_mask[size_t(p_slot)] & _tier_channel_mask(p_tier, true)) ==
			_tier_channel_mask(p_tier, true)) {
		_ready[size_t(p_slot)] = 1;
		if (p_slot < int(_produced_frame.size()) && _produced_frame[size_t(p_slot)] != 0) {
			Engine *engine = Engine::get_singleton();
			const uint64_t now = engine ? uint64_t(engine->get_process_frames()) : 0;
			const uint64_t produced = _produced_frame[size_t(p_slot)];
			const uint64_t waited = now >= produced ? now - produced : 0;
			_ready_latency_sum += waited;
			_ready_latency_max = MAX(_ready_latency_max, waited);
			_ready_latency_samples++;
		}
	}
}

void Terrain3DSurfaceBaker::debug_clear_readiness(const int p_slot) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (p_slot < 0 || p_slot >= int(_ready.size())) {
		return;
	}
	_ready[size_t(p_slot)] = 0;
	if (p_slot < int(_sampled_channel_mask.size())) {
		_sampled_channel_mask[size_t(p_slot)] = 0;
	}
}

// A page whose encode did not land is reported as not ready, so the tier that owns it
// produces it again instead of sampling a layer nothing ever filled. The flag was cleared
// when the page was produced (a compressed page is only ready once its blocks arrive), so
// this is what restores the retry the demand passes rely on.
void Terrain3DSurfaceBaker::_mark_encode_failed(const int p_slot, const uint64_t p_generation,
		const uint64_t p_sequence) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_generation != p_generation || p_slot < 0 || p_slot >= int(_ready.size()) ||
			p_slot >= int(_slot_sequence.size()) || _slot_sequence[size_t(p_slot)] != p_sequence) {
		return;
	}
	_ready[size_t(p_slot)] = 0;
	if (p_slot < int(_sampled_channel_mask.size())) {
		_sampled_channel_mask[size_t(p_slot)] = 0;
	}
}

// The recording-time half of the encode. The readback callback only queues the blocks it
// received; this uploads them into the tier's sampling array while the frame's draw graph is
// recording, because an update recorded outside one is dropped by the render graph.
bool Terrain3DSurfaceBaker::_upload_encoded_layer(const int p_tier, const int p_channel,
		const int p_slot, const uint64_t p_generation, const uint64_t p_sequence,
		const PackedByteArray &p_data) {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_generation != p_generation || p_slot < 0 || p_slot >= _page_count ||
				p_slot >= int(_slot_sequence.size()) || _slot_sequence[size_t(p_slot)] != p_sequence ||
				_slot_tier[size_t(p_slot)] != uint8_t(tier)) {
			return false;
		}
	}
	const RID target = _sampled_rd(tier, p_channel);
	if (!_rd || !_tier_channel_uses_sampled(tier, p_channel) || !target.is_valid() || p_data.is_empty()) {
		return false;
	}
	if (_rd->texture_update(target, uint32_t(p_slot), p_data) != OK) {
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Could not upload a compressed material page; compressed pages will stay blank");
		}
		_encode_failures++;
		return false;
	}
	_encode_updates++;
	_mark_sampled_channel_ready(tier, p_slot, p_channel, p_generation, p_sequence);
	return true;
}

// Uploads the layers the readback callbacks compressed. Called from the render callback
// while its draw graph is recording; a layer encoded against an array bundle that has since
// been replaced is dropped, because a rebuild invalidates every page and re-encodes it.
void Terrain3DSurfaceBaker::_flush_encodes(uint64_t p_generation) {
	std::vector<EncodedLayer> layers;
	{
		std::lock_guard<std::mutex> lock(_encode_mutex);
		if (_encoded_layers.empty()) {
			return;
		}
		layers.swap(_encoded_layers);
	}
	for (const EncodedLayer &layer : layers) {
		if (layer.generation != p_generation) {
			continue;
		}
		_upload_encoded_layer(layer.tier, layer.channel, layer.slot, layer.generation, layer.sequence, layer.data);
	}
}

// Records the block-encoder dispatches for every pending page that can be given an output
// region, and requests one buffer readback per channel. A synchronous readback is not safe
// from inside the render callback, and a block-compressed texture cannot be a storage image,
// so the words have to travel through a buffer - a few tens of kilobytes per layer instead of
// the whole half-float page.
void Terrain3DSurfaceBaker::_request_encodes() {
	if (!_rd || !_resources.encode_pipeline.is_valid() || _encode_region_words <= 0) {
		return;
	}
	bool any_sampled = false;
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		any_sampled = any_sampled || _tier_uses_sampled(tier);
	}
	if (!any_sampled) {
		return;
	}
	int64_t compute_list = -1;
	// With the engine's buffer to texture copy available, an encoded page is stored by a copy
	// recorded after the dispatches, and the page is ready on this frame. Without it the blocks
	// have to travel back through the CPU, which is what costs the frames until they are
	// uploaded; the readback below stays as that path.
	const bool direct_store = FengRDGpuCopy::available(_rd);
	struct PendingStore {
		int tier = 0;
		int channel = 0;
		int slot = 0;
		int ring_page = ENCODE_RING_NONE;
		uint32_t offset = 0;
		uint32_t row_pitch = 0;
		uint64_t generation = 0;
		uint64_t sequence = 0;
	};
	std::vector<PendingStore> pending_stores;
	for (size_t slot = 0; slot < _encode_pending.size(); ++slot) {
		if (!_encode_pending[slot]) {
			continue;
		}
		uint64_t generation = 0;
		uint64_t sequence = 0;
		int tier = 0;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if (slot >= _slot_sequence.size() || slot >= _slot_tier.size()) {
				continue;
			}
			tier = _slot_tier[slot];
			if (tier >= TIER_COUNT) {
				continue;
			}
			generation = _generation;
			sequence = _slot_sequence[slot];
		}
		if (!_tier_uses_sampled(tier)) {
			// The tier is stored uncompressed, so its pages already sample the staging
			// arrays and there is nothing to encode.
			_encode_pending[slot] = 0;
			continue;
		}
		const int blocks = (_stored_size + 3) / 4;
		// Under the scratch regime the page already owns a ring page: it was taken when the
		// page was produced, it is the layer the production wrote into, and it is what holds
		// that layer until the readbacks below have been delivered. Otherwise only the
		// encoder's output region has to be reserved, and the staging layer is the slot.
		int ring_page = -1;
		int source_layer = int(slot);
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if (slot < _slot_scratch.size() && _slot_scratch[slot] != ENCODE_RING_NONE) {
				ring_page = int(_slot_scratch[slot]);
				source_layer = ring_page;
			}
		}
		if (ring_page < 0) {
			// Reserve one ring page per pending page. Without a free page the page waits for
			// a later frame: its readbacks have not been delivered, so reusing the regions
			// would let a readback observe a later page's blocks. The ring is as deep as the
			// page budget needs it to be, so this is a frame's worth of readback latency
			// rather than the production rate.
			const int ring_depth = _encode_ring_capacity.load();
			std::lock_guard<std::mutex> lock(_encode_mutex);
			for (int page_index = 0; page_index < ring_depth; ++page_index) {
				if (_encode_ring_held[size_t(page_index)] != 0) {
					continue;
				}
				ring_page = page_index;
				_encode_ring_held[size_t(page_index)] = uint8_t(ENCODE_CHANNELS);
				break;
			}
		}
		if (ring_page < 0) {
			// Keep the flag set so a later frame encodes this page.
			continue;
		}
		if (compute_list < 0) {
			compute_list = _rd->compute_list_begin();
			if (compute_list < 0) {
				_hold_encode_page(ring_page, 0);
				return;
			}
			_rd->compute_list_bind_compute_pipeline(compute_list, _resources.encode_pipeline);
		}
		SurfaceVTLabel label(_rd, "Surface Block Encode - slot " + String::num_int64(int(slot)));
		PackedByteArray push;
		push.resize(32);
		push.encode_u32(0, uint32_t(_stored_size));
		push.encode_u32(4, uint32_t(source_layer));
		push.encode_u32(12, uint32_t(blocks));
		int outstanding = 0;
		bool requested = true;
		for (int channel = 0; channel < ENCODE_CHANNELS && requested; ++channel) {
			if (!_tier_channel_uses_sampled(tier, channel)) {
				continue;
			}
			const AtlasCodec &codec = ATLAS_CODECS[_tier_channel_codec(tier, channel, true)];
			push.encode_u32(8, codec.gpu_codec);
			const int region = ring_page * ENCODE_CHANNELS + channel;
			push.encode_u32(16, uint32_t(region * _encode_region_words));
			// The albedo array is the tier's sRGB one, so its words hold the sRGB encoding of
			// the linear staging texels; the normal and parameter pages stay linear, and the
			// alpha channel is linear in every codec.
			push.encode_u32(20, channel == 0 ? 1u : 0u);
			push.encode_u32(24, uint32_t(channel));
			push.encode_u32(28, channel == 1 ? uint32_t(_tiers[tier].normal_applied.load()) : 0u);
			if (!_resources.encode_uniform[channel].is_valid()) {
				requested = false;
				break;
			}
			_rd->compute_list_bind_uniform_set(compute_list, _resources.encode_uniform[channel], 0);
			_rd->compute_list_set_push_constant(compute_list, push, uint32_t(push.size()));
			_rd->compute_list_dispatch(compute_list, uint32_t((blocks * blocks + 63) / 64), 1, 1);
			// The encoder reads the staging layer this frame's bake or cell copy wrote, so
			// this dispatch has to be ordered after that write, not merely recorded after it.
			_rd->compute_list_add_barrier(compute_list);
			const uint32_t offset = uint32_t(region * _encode_region_bytes);
			if (direct_store) {
				// The blocks stay on the GPU: the copy into the sampling array is recorded
				// once the compute list is closed, which is why no readback is requested here.
				PendingStore store;
				store.tier = tier;
				store.channel = channel;
				store.slot = int(slot);
				store.ring_page = ring_page;
				store.offset = offset;
				store.row_pitch = uint32_t(blocks * codec.block_words * int(sizeof(uint32_t)));
				store.generation = generation;
				store.sequence = sequence;
				pending_stores.push_back(store);
				continue;
			}
			const uint32_t layer_bytes = uint32_t(blocks * blocks * codec.block_words * int(sizeof(uint32_t)));
			requested = _rd->buffer_get_data_async(_resources.encode_buffer,
							   callable_mp(this, &Terrain3DSurfaceBaker::_on_encode_readback)
									   .bind(int(slot), channel, tier, ring_page, generation, sequence),
							   offset, layer_bytes) == OK;
			if (requested) {
				++outstanding;
			}
		}
		if (requested) {
			_encode_pending[slot] = 0;
			_encode_requests++;
			continue;
		}
		// The readback was refused (or a uniform set is missing): the page keeps its pending
		// flag so a later frame retries it, and the ring page drops back to the readbacks that
		// really are in flight - releasing all three here would leave the callbacks of the
		// ones that were issued with nothing to decrement, and the page would never free.
		_hold_encode_page(ring_page, outstanding);
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Could not request a block encoder readback; compressed pages will stay blank");
		}
	}
	if (compute_list >= 0) {
		_rd->compute_list_end();
	}
	if (direct_store && !pending_stores.empty()) {
		// A block compressed texture cannot be a storage image, so a page used to be read back
		// and uploaded again a few frames later. Recording the copy in the same submission as
		// the dispatch that produced the blocks is what makes the page resident on this frame:
		// the material that samples it is drawn after this, and the render graph orders the two
		// through the encoder buffer's tracker.
		const Rect2i store_region(0, 0, _stored_size, _stored_size);
		for (const PendingStore &store : pending_stores) {
			bool stored = _tier_channel_uses_sampled(store.tier, store.channel);
			const RID target = stored ? _sampled_rd(store.tier, store.channel) : RID();
			if (target.is_valid()) {
				stored = FengRDGpuCopy::copy(_rd, target, _resources.encode_buffer, store.offset,
								 store.row_pitch, uint32_t(store.slot), 0, store_region) == OK;
			} else {
				stored = false;
			}
			if (stored) {
				_encode_updates++;
				_mark_sampled_channel_ready(store.tier, store.slot, store.channel, store.generation, store.sequence);
			} else {
				// Same contract as a readback that never arrived: the page is not ready, so the
				// tier produces it again rather than sampling a layer nothing filled.
				_mark_encode_failed(store.slot, store.generation, store.sequence);
			}
			// The ring page was the staging layer the dispatch read, and the copy that consumes
			// its blocks is recorded in this submission as well, so nothing waits on it any
			// more: a later frame may take it, which is one ring page per page in flight rather
			// than one per page awaiting a readback.
			_hold_encode_page(store.ring_page, 0);
		}
	}
}

// Takes the scratch layer a page about to be produced writes its half-float channels into.
// Under the page-sized staging arrays that is the slot itself and nothing has to be held;
// under the scratch regime it is a ring page, held until that page's block readbacks have
// been delivered, because the half-float content only exists for as long as the encode needs
// it. Returns -1 when every ring page is held, which defers the production to a later frame.
int Terrain3DSurfaceBaker::_take_staging_layer(const int p_slot) {
	if (!_staging_is_scratch()) {
		if (p_slot >= 0 && p_slot < int(_slot_scratch.size())) {
			_slot_scratch[size_t(p_slot)] = ENCODE_RING_NONE;
		}
		return p_slot;
	}
	std::lock_guard<std::mutex> lock(_encode_mutex);
	for (int page = 0; page < _encode_ring_capacity.load(); ++page) {
		if (_encode_ring_held[size_t(page)] != 0) {
			continue;
		}
		_encode_ring_held[size_t(page)] = uint8_t(ENCODE_CHANNELS);
		if (p_slot >= 0 && p_slot < int(_slot_scratch.size())) {
			_slot_scratch[size_t(p_slot)] = uint8_t(page);
		}
		return page;
	}
	return -1;
}

// Sets one ring page's outstanding readback count. Takes the encode mutex alone.
void Terrain3DSurfaceBaker::_hold_encode_page(const int p_page, const int p_outstanding) {
	std::lock_guard<std::mutex> lock(_encode_mutex);
	if (p_page < 0 || p_page >= int(_encode_ring_held.size())) {
		return;
	}
	_encode_ring_held[size_t(p_page)] = uint8_t(CLAMP(p_outstanding, 0, ENCODE_CHANNELS));
}

// Releases one ring page's regions. Only the completion callback calls this, and it never
// holds the world mutex, so the ring is released under the encode mutex alone.
void Terrain3DSurfaceBaker::_release_encode_page(const int p_page) {
	std::lock_guard<std::mutex> lock(_encode_mutex);
	if (p_page < 0 || p_page >= int(_encode_ring_held.size()) || _encode_ring_held[size_t(p_page)] == 0) {
		// The ring was rebuilt under this callback, so the count belongs to a bundle that no
		// longer exists.
		return;
	}
	_encode_ring_held[size_t(p_page)]--;
}

void Terrain3DSurfaceBaker::_on_encode_readback(const PackedByteArray &p_data, const int p_slot,
		const int p_channel, const int p_tier, const int p_page, const uint64_t p_generation,
		const uint64_t p_sequence) {
	_release_encode_page(p_page);
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	bool stale = false;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		stale = _generation != p_generation || p_slot < 0 || p_slot >= int(_slot_sequence.size()) ||
				_slot_sequence[size_t(p_slot)] != p_sequence;
	}
	if (stale) {
		return;
	}
	if (p_channel < 0 || p_channel >= ENCODE_CHANNELS || !_tier_channel_uses_sampled(tier, p_channel)) {
		return;
	}
	const AtlasCodec &codec = ATLAS_CODECS[_tier_channel_codec(tier, p_channel, true)];
	const int blocks = (_stored_size + 3) / 4;
	const int64_t expected = int64_t(blocks) * blocks * codec.block_words * int64_t(sizeof(uint32_t));
	if (codec.block_words == 0 || p_data.size() != expected) {
		if (!_encode_warned) {
			_encode_warned = true;
			LOG(WARN, "Block encoder readback size ", int64_t(p_data.size()), " does not match ", expected);
		}
		_encode_failures++;
		_mark_encode_failed(p_slot, p_generation, p_sequence);
		return;
	}
	_encode_readbacks++;
	// This callback runs inside the frame stall, where the draw graph has already been
	// ended: queue the blocks and let the next render callback, which records, upload them.
	EncodedLayer layer;
	layer.channel = p_channel;
	layer.slot = p_slot;
	layer.tier = tier;
	layer.generation = p_generation;
	layer.sequence = p_sequence;
	layer.data = p_data;
	{
		std::lock_guard<std::mutex> lock(_encode_mutex);
		if (_encoded_layers.size() >= size_t(MAX(4, _page_count) * 3)) {
			_encode_failures++;
			_mark_encode_failed(p_slot, p_generation, p_sequence);
			return;
		}
		_encoded_layers.push_back(std::move(layer));
	}
}

// Compresses and decodes one image through the codec a tier resolved to, reporting the error
// it introduced. This is the CPU reference for the codec's error bound: the page pipeline
// itself never runs a CPU codec (the block encoder does that on the GPU), so the probe is
// what a test can call to state how lossy a codec is. Uncompressed - and every refused
// request - must round trip exactly.
Dictionary Terrain3DSurfaceBaker::probe_tier_compression(const int p_tier, const Ref<Image> &p_image) const {
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	Dictionary result;
	result["tier"] = tier;
	result["mode"] = _tiers[tier].effective.load();
	result["applied"] = _tiers[tier].applied.load();
	result["name"] = String(page_codec(_tiers[tier].effective.load()).name);
	result["valid"] = false;
	result["max_error"] = 0.0;
	result["mean_error"] = 0.0;
	if (p_image.is_null()) {
		return result;
	}
	const AtlasCodec &codec = page_codec(_tiers[tier].effective.load());
	if (codec.mode == Image::COMPRESS_MAX || codec.channels != Image::USED_CHANNELS_RGBA) {
		result["valid"] = true;
		return result;
	}
	Ref<Image> source = p_image->duplicate();
	source->convert(Image::FORMAT_RGBA8);
	Ref<Image> decoded = source->duplicate();
	if (decoded->compress_from_channels(codec.mode, codec.channels, codec.block) != OK || !decoded->is_compressed() ||
			decoded->decompress() != OK) {
		return result;
	}
	const int width = source->get_width();
	const int height = source->get_height();
	double max_error = 0.0;
	double total = 0.0;
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			const Color reference = source->get_pixel(x, y);
			const Color actual = decoded->get_pixel(x, y);
			for (int channel = 0; channel < 4; ++channel) {
				const double error = Math::abs(double(reference[channel]) - double(actual[channel]));
				max_error = MAX(max_error, error);
				total += error;
			}
		}
	}
	result["valid"] = true;
	result["max_error"] = max_error;
	result["mean_error"] = total / double(width * height * 4);
	return result;
}
