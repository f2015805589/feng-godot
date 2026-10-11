#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/projection.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <NRD.h>
#include <cstring>
#include <vector>

using namespace godot;

// CPU-only adapter. RenderingDevice owns all GPU resources and synchronization.
class FengNRDBridge : public RefCounted {
	GDCLASS(FengNRDBridge, RefCounted)
	nrd::Instance *instance = nullptr;
	static constexpr nrd::Identifier identifier = 0;
	static PackedByteArray bytes(const void *data, size_t size) {
		PackedByteArray result;
		result.resize(size);
		if (size) std::memcpy(result.ptrw(), data, size);
		return result;
	}
	static void matrix(float *out, const Projection &value) {
		for (int c = 0; c < 4; ++c) for (int r = 0; r < 4; ++r) out[c * 4 + r] = value[c][r];
	}
	static Array textures(const nrd::TextureDesc *pool, uint32_t count) {
		Array result;
		for (uint32_t i = 0; i < count; ++i) {
			Dictionary texture;
			texture["format"] = int(pool[i].format);
			texture["downsample"] = pool[i].downsampleFactor;
			result.append(texture);
		}
		return result;
	}
	// Godot's compute entry point is fixed to "main". Only rename OpEntryPoint;
	// the function ID and its interface remain the original NRD binary.
	static PackedByteArray shader_bytes(const nrd::ComputeShaderDesc &shader) {
		if (!shader.bytecode || shader.size < 20 || shader.size % 4) return {};
		const auto *words = static_cast<const uint32_t *>(shader.bytecode);
		std::vector<uint32_t> output(words, words + 5);
		for (size_t i = 5; i < shader.size / 4;) {
			uint32_t count = words[i] >> 16, opcode = words[i] & 0xffff;
			if (!count || i + count > shader.size / 4) return {};
			if (opcode == 15 && count >= 4) {
				size_t name_words = (std::strlen(reinterpret_cast<const char *>(words + i + 3)) + 4) / 4;
				output.push_back(uint32_t(count - name_words + 2) << 16 | opcode);
				output.push_back(words[i + 1]); output.push_back(words[i + 2]);
				output.push_back(0x6e69616d); output.push_back(0);
				output.insert(output.end(), words + i + 3 + name_words, words + i + count);
			} else output.insert(output.end(), words + i, words + i + count);
			i += count;
		}
		return bytes(output.data(), output.size() * 4);
	}
	static String resource_name(nrd::ResourceType type) {
		// Use enum identities: upstream 4.18 diagnostic names have a different order.
		switch (type) {
#define RESOURCE_NAME(name) case nrd::ResourceType::name: return #name;
			RESOURCE_NAME(IN_MV)
			RESOURCE_NAME(IN_NORMAL_ROUGHNESS)
			RESOURCE_NAME(IN_VIEWZ)
			RESOURCE_NAME(IN_DIFF_RADIANCE_HITDIST)
			RESOURCE_NAME(OUT_DIFF_RADIANCE_HITDIST)
			RESOURCE_NAME(IN_DIFF_CONFIDENCE)
			RESOURCE_NAME(IN_DISOCCLUSION_THRESHOLD_MIX)
			RESOURCE_NAME(TRANSIENT_POOL)
			RESOURCE_NAME(PERMANENT_POOL)
#undef RESOURCE_NAME
			default: return "UNSUPPORTED";
		}
	}
protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("initialize"), &FengNRDBridge::initialize);
		ClassDB::bind_method(D_METHOD("get_layout"), &FengNRDBridge::get_layout);
		ClassDB::bind_method(D_METHOD("get_dispatches", "frame"), &FengNRDBridge::get_dispatches);
	}
public:
	~FengNRDBridge() { if (instance) nrd::DestroyInstance(*instance); }
	bool initialize() {
		if (instance) return true;
		nrd::DenoiserDesc denoiser{identifier, nrd::Denoiser::RELAX_DIFFUSE};
		nrd::InstanceCreationDesc desc{};
		desc.denoisers = &denoiser; desc.denoisersNum = 1;
		if (nrd::CreateInstance(desc, instance) != nrd::Result::SUCCESS) return false;
		nrd::RelaxSettings settings;
		settings.enableAntiFirefly = true;
		return nrd::SetDenoiserSettings(*instance, identifier, &settings) == nrd::Result::SUCCESS;
	}
	Dictionary get_layout() const {
		Dictionary result;
		if (!instance) return result;
		const auto &desc = *nrd::GetInstanceDesc(*instance);
		const auto &offset = nrd::GetLibraryDesc()->spirvBindingOffsets;
		result["sampler_binding"] = offset.samplerOffset + desc.samplersBaseRegisterIndex;
		result["constant_binding"] = offset.constantBufferOffset + desc.constantBufferRegisterIndex;
		result["texture_binding"] = offset.textureOffset + desc.resourcesBaseRegisterIndex;
		result["storage_binding"] = offset.storageTextureAndBufferOffset + desc.resourcesBaseRegisterIndex;
		result["constant_set"] = desc.constantBufferAndSamplersSpaceIndex;
		result["resource_set"] = desc.resourcesSpaceIndex;
		result["constant_size"] = desc.constantBufferMaxDataSize;
		result["permanent"] = textures(desc.permanentPool, desc.permanentPoolSize);
		result["transient"] = textures(desc.transientPool, desc.transientPoolSize);
		Array pipelines;
		for (uint32_t i = 0; i < desc.pipelinesNum; ++i) {
			Dictionary pipeline;
			pipeline["spirv"] = shader_bytes(desc.pipelines[i].computeShaderSPIRV);
			pipeline["name"] = String(desc.pipelines[i].shaderIdentifier);
			pipeline["constants"] = desc.pipelines[i].hasConstantData;
			pipelines.append(pipeline);
		}
		result["pipelines"] = pipelines;
		return result;
	}
	Array get_dispatches(const Dictionary &frame) {
		Array result;
		if (!instance) return result;
		nrd::CommonSettings settings;
		matrix(settings.viewToClipMatrix, frame["projection"]);
		matrix(settings.viewToClipMatrixPrev, frame["previous_projection"]);
		matrix(settings.worldToViewMatrix, frame["view"]);
		matrix(settings.worldToViewMatrixPrev, frame["previous_view"]);
		Vector2i size = frame["size"];
		Vector2 jitter = frame.get("jitter", Vector2());
		Vector2 previous_jitter = frame.get("previous_jitter", Vector2());
		for (int axis = 0; axis < 2; ++axis) {
			settings.cameraJitter[axis] = jitter[axis];
			settings.cameraJitterPrev[axis] = previous_jitter[axis];
			settings.resourceSize[axis] = settings.resourceSizePrev[axis] = size[axis];
			settings.rectSize[axis] = settings.rectSizePrev[axis] = size[axis];
		}
		settings.frameIndex = int64_t(frame["index"]);
		settings.timeDeltaBetweenFrames = double(frame.get("delta_ms", 16.6667));
		settings.isMotionVectorInWorldSpace = true;
		settings.motionVectorScale[2] = 1.0f;
		settings.accumulationMode = bool(frame["reset"]) ? nrd::AccumulationMode::CLEAR_AND_RESTART : nrd::AccumulationMode::CONTINUE;
		if (nrd::SetCommonSettings(*instance, settings) != nrd::Result::SUCCESS) return result;
		const nrd::DispatchDesc *dispatches = nullptr;
		uint32_t count = 0;
		if (nrd::GetComputeDispatches(*instance, &identifier, 1, dispatches, count) != nrd::Result::SUCCESS) return result;
		for (uint32_t i = 0; i < count; ++i) {
			const auto &source = dispatches[i];
			Dictionary dispatch;
			dispatch["name"] = String(source.name);
			dispatch["pipeline"] = source.pipelineIndex;
			dispatch["grid"] = Vector2i(source.gridWidth, source.gridHeight);
			dispatch["constants"] = bytes(source.constantBufferData, source.constantBufferDataSize);
			Array resources;
			for (uint32_t j = 0; j < source.resourcesNum; ++j) {
				const auto &resource = source.resources[j];
				Dictionary binding;
				binding["type"] = resource_name(resource.type);
				binding["storage"] = resource.descriptorType == nrd::DescriptorType::STORAGE_TEXTURE;
				binding["index"] = resource.indexInPool;
				resources.append(binding);
			}
			dispatch["resources"] = resources;
			result.append(dispatch);
		}
		return result;
	}
};

extern "C" GDExtensionBool GDE_EXPORT feng_nrd_init(GDExtensionInterfaceGetProcAddress get_proc,
		GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc, library, initialization);
	init.register_initializer([](ModuleInitializationLevel level) {
		if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<FengNRDBridge>();
	});
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
