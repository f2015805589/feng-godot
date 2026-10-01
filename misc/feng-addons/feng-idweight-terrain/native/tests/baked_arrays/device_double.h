// A deterministic device/server double for the actual baked-array implementation.
// It validates the narrow API boundary; it does not simulate Godot rendering.
#pragma once

#include <cassert>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace godot {
struct RID {
	int id = 0;
	bool is_valid() const { return id != 0; }
};
struct String : std::string {
	using std::string::string;
	String(const std::string &value) : std::string(value) {}
	static String num_int64(int64_t value) { return std::to_string(value); }
};
template <class T> struct Ref {
	std::shared_ptr<T> value;
	void instantiate() { value = std::make_shared<T>(); }
	T *operator->() const { return value.get(); }
};
template <class T> struct TypedArray : std::vector<T> {};
struct PackedByteArray : std::vector<uint8_t> {};
struct RDTextureView {};
struct RDTextureFormat {
	uint32_t texture_type = 0, format = 0, width = 0, height = 0, depth = 0;
	uint32_t array_layers = 0, mipmaps = 0, usage_bits = 0;
#define SETTER(field) void set_##field(uint32_t value) { field = value; }
	SETTER(texture_type) SETTER(format) SETTER(width) SETTER(height) SETTER(depth)
	SETTER(array_layers) SETTER(mipmaps) SETTER(usage_bits)
#undef SETTER
};
struct DeviceState {
	struct Texture { RDTextureFormat format; String name; PackedByteArray bytes; };
	int next_id = 1, creates = 0, wraps = 0, updates = 0;
	int fail_create = -1, fail_wrap = -1;
	std::map<int, Texture> devices;
	std::map<int, int> wrappers;
	std::vector<std::string> events;
};
class RenderingDevice {
public:
	enum {
		TEXTURE_TYPE_2D_ARRAY = 9,
		DATA_FORMAT_R16G16B16A16_SFLOAT = 17,
		TEXTURE_USAGE_SAMPLING_BIT = 1,
		TEXTURE_USAGE_STORAGE_BIT = 2,
		TEXTURE_USAGE_CAN_UPDATE_BIT = 4
	};
	DeviceState &state;
	explicit RenderingDevice(DeviceState &p_state) : state(p_state) {}
	RID texture_create(const Ref<RDTextureFormat> &format, const Ref<RDTextureView> &view,
			const TypedArray<PackedByteArray> &initial) {
		assert(view.value && initial.empty());
		if (state.creates++ == state.fail_create) { return {}; }
		RID rid{state.next_id++};
		state.devices.emplace(rid.id, DeviceState::Texture{*format.value, {}, {}});
		state.events.push_back("create:" + std::to_string(rid.id));
		return rid;
	}
	void set_resource_name(RID rid, const String &name) {
		assert(state.devices.count(rid.id));
		state.devices.at(rid.id).name = name;
	}
	void texture_update(RID rid, const PackedByteArray &bytes) {
		assert(state.devices.count(rid.id));
		assert(state.devices.at(rid.id).format.usage_bits & TEXTURE_USAGE_CAN_UPDATE_BIT);
		state.devices.at(rid.id).bytes = bytes;
		state.updates++;
	}
	void free_rid(RID rid) {
		for (const auto &wrapper : state.wrappers) { assert(wrapper.second != rid.id); }
		assert(state.devices.erase(rid.id) == 1); // Invalid or double-free is a failure.
		state.events.push_back("device:" + std::to_string(rid.id));
	}
};
class RenderingServer {
public:
	enum { TEXTURE_LAYERED_2D_ARRAY = 6 };
	DeviceState &state;
	explicit RenderingServer(DeviceState &p_state) : state(p_state) {}
	RID texture_rd_create(RID device, int type) {
		assert(type == TEXTURE_LAYERED_2D_ARRAY && state.devices.count(device.id));
		assert(state.devices.at(device.id).format.array_layers >= 2);
		if (state.wraps++ == state.fail_wrap) { return {}; }
		RID rid{state.next_id++};
		state.wrappers.emplace(rid.id, device.id);
		state.events.push_back("wrap:" + std::to_string(rid.id));
		return rid;
	}
	void free_rid(RID rid) {
		assert(state.wrappers.erase(rid.id) == 1);
		state.events.push_back("wrapper:" + std::to_string(rid.id));
	}
};
} // namespace godot
