/**************************************************************************/
/*  dxc_compiler_d3d12.h                                                  */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/**************************************************************************/

#pragma once

#include "core/templates/vector.h"
#include "core/string/ustring.h"
#include "servers/rendering/rendering_device_commons.h"

class DxcCompilerD3D12 {
public:
	enum NativeResourceClass : uint32_t {
		NATIVE_RESOURCE_CBV = 1,
		NATIVE_RESOURCE_SRV = 2,
		NATIVE_RESOURCE_UAV = 3,
		NATIVE_RESOURCE_SAMPLER = 4,
	};

	enum NativeResourceKind : uint32_t {
		NATIVE_KIND_INVALID = 0,
		NATIVE_KIND_CONSTANT_BUFFER,
		NATIVE_KIND_SAMPLER,
		NATIVE_KIND_SAMPLED_TEXTURE,
		NATIVE_KIND_STORAGE_TEXTURE,
		NATIVE_KIND_RAW_BUFFER,
		NATIVE_KIND_ACCELERATION_STRUCTURE,
	};

	enum NativeResourceDimension : uint32_t {
		NATIVE_DIMENSION_NONE = 0,
		NATIVE_DIMENSION_BUFFER,
		NATIVE_DIMENSION_TEXTURE_1D,
		NATIVE_DIMENSION_TEXTURE_1D_ARRAY,
		NATIVE_DIMENSION_TEXTURE_2D,
		NATIVE_DIMENSION_TEXTURE_2D_ARRAY,
		NATIVE_DIMENSION_TEXTURE_2D_MS,
		NATIVE_DIMENSION_TEXTURE_2D_MS_ARRAY,
		NATIVE_DIMENSION_TEXTURE_3D,
		NATIVE_DIMENSION_TEXTURE_CUBE,
		NATIVE_DIMENSION_TEXTURE_CUBE_ARRAY,
		NATIVE_DIMENSION_ACCELERATION_STRUCTURE,
	};

	struct NativeBinding {
		uint32_t set = 0;
		uint32_t binding = 0;
		uint32_t resource_class = 0;
		uint32_t count = 0;
		uint32_t resource_kind = NATIVE_KIND_INVALID;
		uint32_t resource_dimension = NATIVE_DIMENSION_NONE;
		uint32_t constant_buffer_size_bytes = 0;
	};

	struct CompiledLibrary {
		RenderingDeviceCommons::ShaderStage stage = RenderingDeviceCommons::SHADER_STAGE_MAX;
		uint32_t shader_model = 0;
		uint64_t required_feature_flags = 0;
		String export_name;
		Vector<uint8_t> dxil_library;
		Vector<NativeBinding> active_bindings;
	};

private:
	struct Impl;
	Impl *impl = nullptr;
	String unavailable_reason;
	String compiler_hash;
	String compiler_path;
	String validator_path;
	String validator_hash;

	void _initialize();

public:
	DxcCompilerD3D12();
	~DxcCompilerD3D12();

	DxcCompilerD3D12(const DxcCompilerD3D12 &) = delete;
	DxcCompilerD3D12 &operator=(const DxcCompilerD3D12 &) = delete;

	bool is_available() const { return impl != nullptr; }
	const String &get_unavailable_reason() const { return unavailable_reason; }
	const String &get_compiler_hash() const { return compiler_hash; }
	const String &get_compiler_path() const { return compiler_path; }
	const String &get_validator_path() const { return validator_path; }
	const String &get_validator_hash() const { return validator_hash; }

	bool compile_library(
			RenderingDeviceCommons::ShaderStage p_stage,
			uint32_t p_shader_model,
			const String &p_source,
			const String &p_export_name,
			CompiledLibrary &r_library,
			String &r_error) const;
};
