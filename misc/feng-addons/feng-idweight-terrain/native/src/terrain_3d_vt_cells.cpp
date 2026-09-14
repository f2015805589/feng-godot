// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_vt_cells.h"

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

namespace {
// One layer's whole mip chain, in bytes, for the RGBA16F channels this store holds.
int64_t chain_bytes(int p_resolution, int p_levels) {
	int64_t total = 0;
	for (int mip = 0; mip < p_levels; ++mip) {
		const int size = MAX(1, p_resolution >> mip);
		total += int64_t(size) * size * 8;
	}
	return total;
}

int64_t cell_key(const Vector2i &p_cell) {
	return (int64_t(p_cell.x) << 32) ^ uint32_t(p_cell.y);
}
} // namespace

void Terrain3DCellStore::initialize(RenderingDevice *p_rd, int p_layer_capacity, int p_resolution) {
	clear();
	if (!p_rd || p_layer_capacity <= 0 || p_resolution <= 0) {
		return;
	}
	_rd = p_rd;
	_layers = p_layer_capacity;
	_resolution = p_resolution;
	_level_count = 1;
	while ((_resolution >> (_level_count - 1)) > 1) {
		_level_count++;
	}
	const uint64_t usage = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	for (int channel = 0; channel < 3; ++channel) {
		Ref<RDTextureFormat> format;
		format.instantiate();
		format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
		format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
		format->set_width(uint32_t(_resolution));
		format->set_height(uint32_t(_resolution));
		format->set_depth(1);
		format->set_array_layers(uint32_t(_layers));
		format->set_mipmaps(uint32_t(_level_count));
		format->set_usage_bits(static_cast<BitField<RenderingDevice::TextureUsageBits>>(usage));
		Ref<RDTextureView> view;
		view.instantiate();
		TypedArray<PackedByteArray> data;
		_channel_rd[channel] = _rd->texture_create(format, view, data);
		if (!_channel_rd[channel].is_valid()) {
			clear();
			return;
		}
	}
	_rd->set_resource_name(_channel_rd[0], "SVT Cell Albedo Height (layer = cell)");
	_rd->set_resource_name(_channel_rd[1], "SVT Cell Normal Roughness (layer = cell)");
	_rd->set_resource_name(_channel_rd[2], "SVT Cell Parameters (layer = cell)");
	_free_layers.reserve(size_t(_layers));
	for (int layer = _layers - 1; layer >= 0; --layer) {
		_free_layers.push_back(layer);
	}
}

void Terrain3DCellStore::clear() {
	if (_rd) {
		for (RID &texture : _channel_rd) {
			if (texture.is_valid()) {
				_rd->free_rid(texture);
				texture = RID();
			}
		}
	}
	_rd = nullptr;
	_layers = 0;
	_resolution = 0;
	_level_count = 0;
	_free_layers.clear();
	_cells.clear();
	_use_counter = 0;
	_published_cells = 0;
	_evicted_cells = 0;
}

Terrain3DCellStore::~Terrain3DCellStore() {
	clear();
}

int Terrain3DCellStore::_acquire_layer(const Vector2i &p_cell, Vector2i *r_evicted) {
	if (!_free_layers.empty()) {
		const int layer = _free_layers.back();
		_free_layers.pop_back();
		return layer;
	}
	// Every layer is assigned: recycle the one that has gone unused longest. Cells are
	// long-lived sources, so this is the bake cache evicting, not page residency, and the
	// caller has to invalidate the pages that were built from the evicted cell.
	int64_t oldest_key = 0;
	const Cell *oldest = nullptr;
	for (const std::pair<const int64_t, Cell> &entry : _cells) {
		if (!oldest || entry.second.last_use < oldest->last_use) {
			oldest = &entry.second;
			oldest_key = entry.first;
		}
	}
	if (!oldest) {
		return -1;
	}
	const int layer = oldest->layer;
	if (r_evicted) {
		*r_evicted = Vector2i(int(oldest_key >> 32), int(int32_t(oldest_key & 0xffffffff)));
	}
	_cells.erase(oldest_key);
	_evicted_cells++;
	return layer;
}

void Terrain3DCellStore::_release_layer(int p_layer) {
	_free_layers.push_back(p_layer);
}

const Terrain3DCellStore::Cell *Terrain3DCellStore::find_cell(const Vector2i &p_cell, uint32_t p_signature) const {
	const auto found = _cells.find(cell_key(p_cell));
	if (found == _cells.end() || found->second.signature != p_signature) {
		return nullptr;
	}
	return &found->second;
}

void Terrain3DCellStore::touch_cell(const Vector2i &p_cell) {
	const auto found = _cells.find(cell_key(p_cell));
	if (found != _cells.end()) {
		found->second.last_use = ++_use_counter;
	}
}

bool Terrain3DCellStore::publish_cell(const Vector2i &p_cell, uint32_t p_signature,
		const Rect2 &p_world_rect, const Ref<Image> *p_channels, int p_resolution, Vector2i *r_evicted) {
	if (!is_initialized() || !p_channels || p_resolution != _resolution) {
		return false;
	}
	const int64_t expected = chain_bytes(_resolution, _level_count);
	PackedByteArray uploads[3];
	for (int channel = 0; channel < 3; ++channel) {
		const Ref<Image> image = p_channels[channel];
		if (image.is_null() || image->get_width() != p_resolution || image->get_height() != p_resolution) {
			return false;
		}
		const PackedByteArray source = image->get_data();
		const int source_levels = image->get_mipmap_count() + 1;
		PackedByteArray chain;
		chain.resize(expected);
		int64_t offset = 0;
		for (int mip = 0; mip < _level_count; ++mip) {
			const int level = MIN(mip, source_levels - 1);
			const int64_t begin = image->get_mipmap_offset(level);
			const int64_t end = level < image->get_mipmap_count()
					? image->get_mipmap_offset(level + 1)
					: source.size();
			const int64_t length = end - begin;
			const int size = MAX(1, _resolution >> mip);
			const int64_t wanted = int64_t(size) * size * 8;
			if (length <= 0 || length > wanted || offset + wanted > expected) {
				return false;
			}
			memcpy(chain.ptrw() + offset, source.ptr() + begin, size_t(length));
			// A bake whose chain is shorter than the store's repeats its coarsest level,
			// so every level holds something the page assembly can sample.
			for (int64_t tail = length; tail < wanted;) {
				const int64_t chunk = MIN(length, wanted - tail);
				memcpy(chain.ptrw() + offset + tail, source.ptr() + begin, size_t(chunk));
				tail += chunk;
			}
			offset += wanted;
		}
		uploads[channel] = chain;
	}
	const auto existing = _cells.find(cell_key(p_cell));
	int layer = existing != _cells.end() ? existing->second.layer : _acquire_layer(p_cell, r_evicted);
	if (layer < 0) {
		return false;
	}
	for (int channel = 0; channel < 3; ++channel) {
		if (_rd->texture_update(_channel_rd[channel], uint32_t(layer), uploads[channel]) != OK) {
			return false;
		}
	}
	Cell cell;
	cell.layer = layer;
	cell.resolution = p_resolution;
	cell.levels = _level_count;
	cell.signature = p_signature;
	cell.world_rect = p_world_rect;
	cell.last_use = ++_use_counter;
	_cells[cell_key(p_cell)] = cell;
	_published_cells++;
	return true;
}

void Terrain3DCellStore::forget_cell(const Vector2i &p_cell) {
	const auto found = _cells.find(cell_key(p_cell));
	if (found == _cells.end()) {
		return;
	}
	_release_layer(found->second.layer);
	_cells.erase(found);
}

RID Terrain3DCellStore::get_texture_rid(int p_channel) const {
	return p_channel >= 0 && p_channel < 3 ? _channel_rd[p_channel] : RID();
}

RID Terrain3DCellStore::create_sample_view(int p_channel, int p_layer, int p_mip) const {
	if (!is_initialized() || p_channel < 0 || p_channel > 2 || p_layer < 0 || p_layer >= _layers ||
			p_mip < 0 || p_mip >= _level_count) {
		return RID();
	}
	Ref<RDTextureView> view;
	view.instantiate();
	return _rd->texture_create_shared_from_slice(view, _channel_rd[p_channel], uint32_t(p_layer),
			uint32_t(p_mip), 1, RenderingDevice::TEXTURE_SLICE_2D);
}

Array Terrain3DCellStore::get_catalog() const {
	Array result;
	for (const std::pair<const int64_t, Cell> &entry : _cells) {
		Dictionary tile;
		const Vector2i address(int(entry.first >> 32), int(int32_t(entry.first & 0xffffffff)));
		tile["address"] = address;
		tile["mip"] = 0;
		tile["kind"] = "SVT";
		tile["slot"] = -1;
		tile["border"] = 0;
		tile["world_rect"] = entry.second.world_rect;
		tile["resolution"] = entry.second.resolution;
		tile["levels"] = entry.second.levels;
		tile["layer"] = entry.second.layer;
		tile["signature"] = int64_t(entry.second.signature);
		// A resident cell has no file behind it, and the browser reports that by leaving the
		// path empty rather than naming a bake that would have to be read to be used.
		tile["path"] = String();
		tile["storage"] = "Resident cell channel arrays";
		result.push_back(tile);
	}
	return result;
}

Dictionary Terrain3DCellStore::get_stats() const {
	Dictionary stats;
	stats["initialized"] = is_initialized();
	stats["resolution"] = _resolution;
	stats["levels"] = _level_count;
	stats["layers"] = _layers;
	stats["cells"] = int64_t(_cells.size());
	stats["free_layers"] = int64_t(_free_layers.size());
	stats["published_cells"] = int64_t(_published_cells);
	stats["evicted_cells"] = int64_t(_evicted_cells);
	stats["bytes"] = int64_t(chain_bytes(_resolution, _level_count)) * 3 * _layers;
	return stats;
}

void Terrain3DCellStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DCellStore::get_stats);
	ClassDB::bind_method(D_METHOD("get_catalog"), &Terrain3DCellStore::get_catalog);
	ClassDB::bind_method(D_METHOD("get_resolution"), &Terrain3DCellStore::get_resolution);
	ClassDB::bind_method(D_METHOD("get_level_count"), &Terrain3DCellStore::get_level_count);
	ClassDB::bind_method(D_METHOD("get_cell_count"), &Terrain3DCellStore::get_cell_count);
	ClassDB::bind_method(D_METHOD("get_texture_rid", "channel"), &Terrain3DCellStore::get_texture_rid);
}
