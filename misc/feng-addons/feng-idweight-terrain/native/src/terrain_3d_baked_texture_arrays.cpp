// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d_baked_texture_arrays.h"

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

using namespace godot;

void terrain_baked_arrays::clear(RenderingServer *p_server, RenderingDevice *p_rd,
		std::vector<RID> &r_device, std::vector<RID> &r_shader) {
	for (const RID &rid : r_shader) {
		if (rid.is_valid() && p_server != nullptr) {
			p_server->free_rid(rid);
		}
	}
	for (const RID &rid : r_device) {
		if (rid.is_valid() && p_rd != nullptr) {
			p_rd->free_rid(rid);
		}
	}
	r_device.clear();
	r_shader.clear();
}

int terrain_baked_arrays::create(RenderingServer *p_server, RenderingDevice *p_rd,
		int p_width, int p_height, int p_layers, int p_channels, const String &p_name,
		std::vector<RID> &r_device, std::vector<RID> &r_shader) {
	clear(p_server, p_rd, r_device, r_shader);
	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	// The shared bake shader writes rgba16f storage images for every channel.
	format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
	format->set_width(uint32_t(p_width));
	format->set_height(uint32_t(p_height));
	format->set_depth(1);
	format->set_array_layers(uint32_t(p_layers < 2 ? 2 : p_layers));
	format->set_mipmaps(1);
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	TypedArray<PackedByteArray> initial;
	for (int channel = 0; channel < p_channels; channel++) {
		const RID device = p_rd->texture_create(format, view, initial);
		const RID shader = device.is_valid()
				? p_server->texture_rd_create(device, RenderingServer::TEXTURE_LAYERED_2D_ARRAY)
				: RID();
		if (!shader.is_valid()) {
			// This channel has no wrapper; previous channels do, and their wrappers
			// still have to be freed before their device textures.
			if (device.is_valid()) {
				p_rd->free_rid(device);
			}
			clear(p_server, p_rd, r_device, r_shader);
			return channel;
		}
		p_rd->set_resource_name(device, p_name + String::num_int64(channel));
		r_device.push_back(device);
		r_shader.push_back(shader);
	}
	return -1;
}
