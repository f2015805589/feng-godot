// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DClipmapAtlas, the texture half: the atlas's own `Texture2DArray`, the block-sized staging
// textures a `texture_copy()` writes one block out of, and their lifetimes. The organisation these
// exist for - one rect a block, written out of a block-sized source rather than out of the whole
// atlas - is stated in terrain_3d_clipmap_atlas.h; what is left here is the allocation, which is the
// half that needs a device.

#include "terrain_3d_clipmap_atlas.h"

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include "logger.h"

static RenderingDevice::DataFormat _atlas_data_format(const Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return RenderingDevice::DATA_FORMAT_R8_UNORM;
		case Image::FORMAT_RGBA8:
			return RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
		case Image::FORMAT_RGBAH:
			return RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT;
		default:
			return RenderingDevice::DATA_FORMAT_R32_SFLOAT;
	}
}

// ---- Texture -----------------------------------------------------------------------------------

void Terrain3DClipmapAtlas::_free_textures() {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	for (const RID &rid : _staging_rd) {
		if (rid.is_valid() && rd != nullptr) {
			rd->free_rid(rid);
		}
	}
	_staging_rd.clear();
	if (_texture_rid.is_valid() && server != nullptr) {
		server->free_rid(_texture_rid);
	}
	if (_texture_rd.is_valid() && rd != nullptr) {
		rd->free_rid(_texture_rd);
	}
	_texture_rid = RID();
	_texture_rd = RID();
	_free_baked();
}

// The atlas is one `Texture2DArray` of `channels` layers, each layer a whole 2D atlas for one value
// of a texel. Two layers are allocated whatever the channel count: the renderer refuses to wrap a
// one-layer array as a layered texture (`texture_rd_create()` fails on `array_layers == 1`), and one
// unused layer of one value is cheaper than a second publish path for a one-channel group.
//
// `CAN_COPY_TO` is the flag the whole organisation rests on: it is what lets a block rect be written
// by `texture_copy()` out of a block-sized staging texture, so the transfer is one block and not the
// atlas - which is exactly the whole-layer cost this mechanism exists to remove.
void Terrain3DClipmapAtlas::_ensure_texture() {
	if (_texture_rd.is_valid() || _layout.width <= 0 || !is_configured()) {
		return;
	}
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		return;
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	format->set_format(_atlas_data_format(_config.format));
	format->set_width(uint32_t(_layout.width));
	format->set_height(uint32_t(_layout.height));
	format->set_depth(1);
	format->set_array_layers(uint32_t(_texture_layers));
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	_texture_rd = rd->texture_create(format, view, initial);
	if (!_texture_rd.is_valid()) {
		LOG(ERROR, "Could not allocate clipmap atlas (", get_source_name(), ")");
		_free_textures();
		return;
	}
	rd->set_resource_name(_texture_rd, "Terrain3D Clipmap atlas " + get_source_name());
	_texture_rid = server->texture_rd_create(_texture_rd, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
	if (!_texture_rid.is_valid()) {
		LOG(ERROR, "Could not wrap clipmap atlas (", get_source_name(), ")");
		_free_textures();
		return;
	}
	_ensure_staging();
	// The baked arrays the material arm samples are sized by the same layout, so they are allocated
	// where the layout is known: a device that appears after `configure()` gets them here.
	_ensure_baked();
}

// One staging texture per (ring, channel), each exactly that ring's block size: `texture_update()`
// demands a whole layer's worth of bytes, so a staging texture that matched the largest block would
// make a 32-texel block cost a 256-texel transfer - the very cost this organisation removes.
void Terrain3DClipmapAtlas::_ensure_staging() {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr || _config.rings <= 0) {
		return;
	}
	const size_t wanted = size_t(_config.rings) * size_t(_config.channels) + size_t(_config.channels);
	if (_staging_rd.size() == wanted && !_staging_rd.empty() && _staging_rd[0].is_valid()) {
		return;
	}
	for (const RID &rid : _staging_rd) {
		if (rid.is_valid()) {
			rd->free_rid(rid);
		}
	}
	_staging_rd.clear();
	// One entry per (ring, channel), then one per channel for the global block: the global block is
	// its own size, and a staging texture that matched a ring's would make the one-time upload a
	// mismatch rather than a transfer.
	for (int ring = 0; ring < _config.rings; ring++) {
		for (int channel = 0; channel < _config.channels; channel++) {
			_staging_rd.push_back(_create_staging(_texels_of_ring(ring)));
		}
	}
	for (int channel = 0; channel < _config.channels; channel++) {
		_staging_rd.push_back(_create_staging(MAX(1, _config.global_texels)));
	}
}

// One block-sized staging texture. `texture_update()` demands a whole layer's worth of bytes, so its
// size is what makes a transfer the block's own bytes.
RID Terrain3DClipmapAtlas::_create_staging(const int p_texels) {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server != nullptr ? server->get_rendering_device() : nullptr;
	if (rd == nullptr) {
		return RID();
	}
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	format->set_format(_atlas_data_format(_config.format));
	format->set_width(uint32_t(p_texels));
	format->set_height(uint32_t(p_texels));
	format->set_depth(1);
	format->set_array_layers(1);
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	RID staging = rd->texture_create(format, view, initial);
	if (!staging.is_valid()) {
		LOG(ERROR, "Could not allocate clipmap atlas staging (", get_source_name(), ")");
	}
	return staging;
}

