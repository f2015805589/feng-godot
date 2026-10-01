#include "device_double.h"
#include "terrain_3d_baked_texture_arrays.h"

#include <iostream>

using namespace godot;

static void check_shape(const DeviceState &state, const std::vector<RID> &devices,
		const std::vector<RID> &wrappers, int width, int height, int layers) {
	assert(devices.size() == 3 && wrappers.size() == 3);
	for (size_t i = 0; i < devices.size(); i++) {
		assert(state.wrappers.at(wrappers[i].id) == devices[i].id);
		const auto &texture = state.devices.at(devices[i].id);
		const auto &format = texture.format;
		assert(format.texture_type == RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
		assert(format.format == RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
		assert(format.width == uint32_t(width) && format.height == uint32_t(height));
		assert(format.depth == 1 && format.mipmaps == 1);
		assert(format.array_layers == uint32_t(layers < 2 ? 2 : layers));
		assert(format.usage_bits == (RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
				RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT));
		assert(texture.name == "Baked " + std::to_string(i));
	}
}

static void success_and_replacement() {
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(state);
	std::vector<RID> devices, wrappers;
	for (int cycle = 0; cycle < 6; cycle++) {
		// Ring: one or multiple level slices. Atlas: non-square arrays. Detail: many slots.
		const int width = 32 + cycle * 8, height = 48 + cycle * 8, layers = cycle == 0 ? 1 : cycle * 3;
		state.events.clear();
		assert(terrain_baked_arrays::create(&server, &rd, width, height, layers, 3,
				"Baked ", devices, wrappers) == -1);
		if (cycle > 0) {
			for (int i = 0; i < 3; i++) { assert(state.events[i].find("wrapper:") == 0); }
			for (int i = 3; i < 6; i++) { assert(state.events[i].find("device:") == 0); }
			assert(state.events[6].find("create:") == 0);
		}
		check_shape(state, devices, wrappers, width, height, layers);
		assert(state.devices.size() == 3 && state.wrappers.size() == 3);
		const auto stable_devices = devices;
		for (int update = 0; update < 4; update++) {
			PackedByteArray bytes;
			bytes.assign(8, uint8_t(cycle + update));
			for (size_t channel = 0; channel < devices.size(); channel++) {
				rd.texture_update(devices[channel], bytes);
				assert(devices[channel].id == stable_devices[channel].id);
				assert(state.devices.at(state.wrappers.at(wrappers[channel].id)).bytes == bytes);
			}
		}
	}
	state.events.clear();
	terrain_baked_arrays::clear(&server, &rd, devices, wrappers);
	assert(devices.empty() && wrappers.empty() && state.devices.empty() && state.wrappers.empty());
	for (int i = 0; i < 3; i++) { assert(state.events[i].find("wrapper:") == 0); }
	for (int i = 3; i < 6; i++) { assert(state.events[i].find("device:") == 0); }
	const auto events = state.events;
	terrain_baked_arrays::clear(&server, &rd, devices, wrappers);
	assert(state.events == events); // Teardown is idempotent.
	assert(state.updates == 72);
}

static void partial_failures_and_retry() {
	for (bool wrapping : {false, true}) {
		for (int channel = 0; channel < 3; channel++) {
			DeviceState state;
			RenderingDevice rd(state);
			RenderingServer server(state);
			std::vector<RID> devices, wrappers;
			if (wrapping) { state.fail_wrap = channel; }
			else { state.fail_create = channel; }
			assert(terrain_baked_arrays::create(&server, &rd, 64, 64, 5, 3,
					"Baked ", devices, wrappers) == channel);
			assert(devices.empty() && wrappers.empty() && state.devices.empty() && state.wrappers.empty());
			assert(state.creates == channel + 1);
			assert(state.wraps == channel + (wrapping ? 1 : 0));
			state.fail_wrap = state.fail_create = -1;
			assert(terrain_baked_arrays::create(&server, &rd, 64, 64, 5, 3,
					"Baked ", devices, wrappers) == -1);
			check_shape(state, devices, wrappers, 64, 64, 5);
			terrain_baked_arrays::clear(&server, &rd, devices, wrappers);
			assert(state.devices.empty() && state.wrappers.empty());
		}
	}
}

static void shutdown_and_empty_inventory() {
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(state);
	// Invalid entries are ignored, including mismatched inventories during shutdown.
	std::vector<RID> devices(2), wrappers(1);
	terrain_baked_arrays::clear(&server, &rd, devices, wrappers);
	assert(devices.empty() && wrappers.empty() && state.events.empty());
	assert(terrain_baked_arrays::create(&server, &rd, 16, 16, 2, 3,
			"Baked ", devices, wrappers) == -1);
	terrain_baked_arrays::clear(&server, nullptr, devices, wrappers);
	assert(devices.empty() && wrappers.empty() && state.wrappers.empty());
	assert(state.devices.size() == 3); // No device means no device call, as before.
	devices = {{123}};
	wrappers = {{456}};
	terrain_baked_arrays::clear(nullptr, nullptr, devices, wrappers);
	assert(devices.empty() && wrappers.empty());
}

int main() {
	success_and_replacement();
	partial_failures_and_retry();
	shutdown_and_empty_inventory();
	std::cout << "PASS baked arrays: shapes, 6 replacements, 72 updates, teardown order, "
			"all 6 partial failures, retry, null-device shutdown\n";
}
