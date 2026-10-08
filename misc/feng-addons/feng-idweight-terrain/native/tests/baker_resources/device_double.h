#pragma once

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#define MAX(a, b) std::max((a), (b))
#define CLAMP(a, b, c) std::clamp((a), (b), (c))
#define LOG(...) ((void)0)
constexpr int WARN = 1, ERROR = 2, OK = 0;
constexpr int SURFACE_PAGE_UNCOMPRESSED = 0, SURFACE_PAGE_BC7 = 1;
constexpr int SURFACE_NORMAL_UNCOMPRESSED = 0, SURFACE_NORMAL_AUTO = -1;
constexpr int MATERIAL_COUNT = 32, MATERIAL_STRIDE = 64, JOB_STRIDE = 64;

namespace godot {
struct RID {
	int id = 0;
	bool is_valid() const { return id != 0; }
	bool operator==(RID other) const { return id == other.id; }
	bool operator!=(RID other) const { return id != other.id; }
};
struct String : std::string {
	using std::string::string;
	String(const std::string &value) : std::string(value) {}
	bool is_empty() const { return empty(); }
};
struct PackedByteArray : std::vector<uint8_t> {
	int64_t size() const { return int64_t(std::vector<uint8_t>::size()); }
};
struct Array : std::vector<RID> {
	int size() const { return int(std::vector<RID>::size()); }
};
template <class T> using TypedArray = std::vector<T>;
template <class T> struct Ref {
	std::shared_ptr<T> value;
	void instantiate() { value = std::make_shared<T>(); }
	T *operator->() const { return value.get(); }
	bool is_null() const { return !value; }
};
struct Color { Color(float, float, float, float) {} };
struct Vector3 { Vector3(int = 0, int = 0, int = 0) {} };
struct RDShaderSource {
	String source;
	void set_language(int) {}
	void set_stage_source(int, const char *code) { source = code; }
};
struct RDShaderSPIRV {
	String error;
	String get_stage_compile_error(int) const { return error; }
};
struct RDUniform { std::vector<RID> ids; };

struct DeviceState {
	struct Resource { std::string kind; std::vector<RID> dependencies; };
	int next_id = 1, allocations = 0, copies = 0;
	int fail_allocation = -1, fail_copy = -1;
	bool support_storage = true;
	std::string fail_compile;
	bool null_spirv = false;
	std::map<int, Resource> devices;
	std::map<int, int> wrappers;
	std::vector<std::string> attempts;
	RID allocate(const std::string &kind, const std::vector<RID> &dependencies = {}) {
		attempts.push_back(kind);
		if (allocations++ == fail_allocation) { return {}; }
		for (RID dependency : dependencies) { assert(devices.count(dependency.id)); }
		RID result{next_id++};
		devices.emplace(result.id, Resource{kind, dependencies});
		return result;
	}
	void assert_empty() const {
		if (!devices.empty() || !wrappers.empty()) {
			std::cerr << "Leaked " << devices.size() << " device RIDs and " << wrappers.size() << " wrappers\n";
		}
		assert(devices.empty() && wrappers.empty());
	}
};
class RenderingDevice {
public:
	enum DataFormat { DATA_FORMAT_MAX, DATA_FORMAT_R16_UNORM, DATA_FORMAT_R32_SFLOAT,
		DATA_FORMAT_R8G8B8A8_UNORM, DATA_FORMAT_R16G16B16A16_SFLOAT, BC7, BC7_SRGB };
	enum SamplerFilter { SAMPLER_FILTER_NEAREST, SAMPLER_FILTER_LINEAR };
	enum SamplerRepeatMode { SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, SAMPLER_REPEAT_MODE_REPEAT };
	enum UniformType { UNIFORM_TYPE_STORAGE_BUFFER, UNIFORM_TYPE_IMAGE, UNIFORM_TYPE_SAMPLER_WITH_TEXTURE };
	enum { SHADER_LANGUAGE_GLSL, SHADER_STAGE_COMPUTE };
	enum { TEXTURE_USAGE_SAMPLING_BIT = 1, TEXTURE_USAGE_STORAGE_BIT = 2,
		TEXTURE_USAGE_CAN_UPDATE_BIT = 4, TEXTURE_USAGE_CAN_COPY_FROM_BIT = 8, TEXTURE_USAGE_CAN_COPY_TO_BIT = 16 };
	DeviceState &state;
	explicit RenderingDevice(DeviceState &p_state) : state(p_state) {}
	Ref<RDShaderSPIRV> shader_compile_spirv_from_source(const Ref<RDShaderSource> &source) {
		Ref<RDShaderSPIRV> result;
		if (source->source == state.fail_compile && state.null_spirv) { return result; }
		result.instantiate();
		if (source->source == state.fail_compile) { result->error = "injected shader failure"; }
		return result;
	}
	RID shader_create_from_spirv(const Ref<RDShaderSPIRV> &, const String &name) { return state.allocate(name); }
	RID compute_pipeline_create(RID shader) { return state.allocate("pipeline", {shader}); }
	RID storage_buffer_create(uint32_t bytes, const PackedByteArray & = {}) {
		assert(bytes > 0);
		return state.allocate("buffer");
	}
	RID uniform_set_create(const TypedArray<Ref<RDUniform>> &uniforms, RID shader, int) {
		std::vector<RID> dependencies{shader};
		for (const auto &uniform : uniforms) {
			dependencies.insert(dependencies.end(), uniform->ids.begin(), uniform->ids.end());
		}
		return state.allocate("uniform", dependencies);
	}
	bool uniform_set_is_valid(RID rid) const { return state.devices.count(rid.id) != 0; }
	bool texture_is_format_supported_for_usage(DataFormat, uint64_t) const { return state.support_storage; }
	void set_resource_name(RID rid, const String &) { assert(state.devices.count(rid.id)); }
	void texture_clear(RID rid, Color, int, int, int, uint32_t) { assert(state.devices.count(rid.id)); }
	int texture_copy(RID from, RID to, Vector3, Vector3, Vector3, int, int, int, int) {
		assert(state.devices.count(from.id) && state.devices.count(to.id));
		return state.copies++ == state.fail_copy ? 1 : OK;
	}
	void free_rid(RID rid) {
		for (const auto &wrapper : state.wrappers) { assert(wrapper.second != rid.id); }
		for (const auto &resource : state.devices) {
			for (RID dependency : resource.second.dependencies) { assert(dependency.id != rid.id); }
		}
		assert(state.devices.erase(rid.id) == 1); // Reject invalid or double-free.
	}
};
class RenderingServer {
public:
	enum { TEXTURE_LAYERED_2D_ARRAY };
	inline static RenderingServer *singleton = nullptr;
	RenderingDevice &rd;
	explicit RenderingServer(RenderingDevice &p_rd) : rd(p_rd) { singleton = this; }
	~RenderingServer() { singleton = nullptr; }
	static RenderingServer *get_singleton() { return singleton; }
	RenderingDevice *get_rendering_device() { return &rd; }
	RID texture_rd_create(RID device, int) {
		assert(rd.state.devices.count(device.id));
		rd.state.attempts.push_back("wrapper");
		if (rd.state.allocations++ == rd.state.fail_allocation) { return {}; }
		RID result{rd.state.next_id++};
		rd.state.wrappers.emplace(result.id, device.id);
		return result;
	}
	void free_rid(RID rid) { assert(rd.state.wrappers.erase(rid.id) == 1); }
};
} // namespace godot
using namespace godot;

inline void append_uniform(TypedArray<Ref<RDUniform>> &uniforms, RenderingDevice::UniformType,
		int, RID first, RID second = {}) {
	Ref<RDUniform> uniform;
	uniform.instantiate();
	if (first.is_valid()) { uniform->ids.push_back(first); }
	if (second.is_valid()) { uniform->ids.push_back(second); }
	uniforms.push_back(uniform);
}
inline void append_bake_uniforms(TypedArray<Ref<RDUniform>> &uniforms, RID nearest, RID linear,
		RID source0, RID source1, RID albedo, RID normal, RID material, RID jobs, const RID (&outputs)[3]) {
	for (RID rid : {nearest, linear, source0, source1, albedo, normal, material, jobs, outputs[0], outputs[1], outputs[2]}) {
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 0, rid);
	}
}
inline void free_bake_set(RenderingDevice *rd, RID &set) {
	if (rd && set.is_valid() && rd->uniform_set_is_valid(set)) { rd->free_rid(set); }
	set = {};
}
struct AtlasCodec { RenderingDevice::DataFormat rd_format; int block_words = 4; };
inline constexpr AtlasCodec ATLAS_CODECS[] = {{RenderingDevice::DATA_FORMAT_MAX}, {RenderingDevice::BC7}};
inline int params_codec_for_channels(int diffuse, int normal) { return diffuse != 0 || normal != 0 ? 1 : 0; }
inline constexpr const char *SURFACE_BAKE_SHADER = "bake";
inline constexpr const char *SURFACE_ENCODE_SHADER = "encode";
inline constexpr const char *SURFACE_SOURCE_UPLOAD_SHADER = "upload";

// Deterministic lock-order instrumentation for the extracted methods. There is no
// thread scheduler here: acquiring world(1) under encode(2) immediately fails.
namespace test_std {
using namespace std;
struct mutex {
	int rank;
	inline static std::vector<int> held;
	explicit mutex(int p_rank) : rank(p_rank) {}
	void lock() {
		if (!held.empty() && held.back() >= rank) { std::cerr << "Inverted baker mutex order\n"; }
		assert(held.empty() || held.back() < rank);
		held.push_back(rank);
	}
	void unlock() {
		assert(!held.empty() && held.back() == rank);
		held.pop_back();
	}
};
} // namespace test_std
