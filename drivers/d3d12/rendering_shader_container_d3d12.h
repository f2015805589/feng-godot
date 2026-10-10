/**************************************************************************/
/*  rendering_shader_container_d3d12.h                                    */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include "servers/rendering/rendering_shader_container.h"
#include "drivers/d3d12/dxc_compiler_d3d12.h"

#define NIR_ENABLED 1

#ifdef SHADER_BAKER_RUNTIME_ENABLED
#undef NIR_ENABLED
#endif

#include "drivers/d3d12/d3d12_godot_nir_bridge.h"

#define D3D12_BITCODE_OFFSETS_NUM_STAGES 3

#if NIR_ENABLED
struct nir_shader;
struct nir_shader_compiler_options;
#endif

enum RootSignatureLocationType {
	RS_LOC_TYPE_RESOURCE,
	RS_LOC_TYPE_SAMPLER,
};

enum ResourceClass {
	RES_CLASS_INVALID,
	RES_CLASS_CBV,
	RES_CLASS_SRV,
	RES_CLASS_UAV,
};

struct RenderingDXIL {
	static uint32_t patch_specialization_constant(
			RenderingDeviceCommons::PipelineSpecializationConstantType p_type,
			const void *p_value,
			const uint64_t (&p_stages_bit_offsets)[D3D12_BITCODE_OFFSETS_NUM_STAGES],
			HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_stages_bytecodes,
			bool p_is_first_patch);

	static void sign_bytecode(RenderingDeviceCommons::ShaderStage p_stage, Vector<uint8_t> &r_dxil_blob);
};

class RenderingShaderContainerD3D12 : public RenderingShaderContainer {
	GDSOFTCLASS(RenderingShaderContainerD3D12, RenderingShaderContainer);

public:
	static constexpr uint32_t REQUIRED_SHADER_MODEL = 0x62; // NIR path minimum: D3D_SHADER_MODEL_6_2.
	static constexpr uint32_t ROOT_CONSTANT_REGISTER = GODOT_NIR_DESCRIPTOR_SET_MULTIPLIER * (RenderingDeviceCommons::MAX_UNIFORM_SETS + 1);
	static constexpr uint32_t RUNTIME_DATA_REGISTER = GODOT_NIR_DESCRIPTOR_SET_MULTIPLIER * (RenderingDeviceCommons::MAX_UNIFORM_SETS + 2);
	static constexpr uint32_t FORMAT_VERSION = 3;
	static constexpr uint32_t SHADER_STAGES_BIT_OFFSET_INDICES[RenderingDeviceCommons::SHADER_STAGE_MAX] = {
		0, // SHADER_STAGE_VERTEX
		1, // SHADER_STAGE_FRAGMENT
		UINT32_MAX, // SHADER_STAGE_TESSELATION_CONTROL
		UINT32_MAX, // SHADER_STAGE_TESSELATION_EVALUATION
		2, // SHADER_STAGE_COMPUTE
	};

	struct ReflectionBindingSetDataD3D12 {
		uint32_t resource_root_param_idx = UINT32_MAX;
		uint32_t resource_descriptor_count = 0;
		uint32_t sampler_root_param_idx = UINT32_MAX;
		uint32_t sampler_descriptor_count = 0;
	};

	struct ReflectionBindingDataD3D12 {
		uint32_t resource_class = 0;
		uint32_t has_sampler = 0;
		uint32_t dxil_stages = 0;
		uint32_t resource_descriptor_offset = UINT32_MAX;
		uint32_t sampler_descriptor_offset = UINT32_MAX;
		uint32_t root_param_idx = UINT32_MAX; // Root descriptor only.
	};

	struct ReflectionSpecializationDataD3D12 {
		uint64_t stages_bit_offsets[D3D12_BITCODE_OFFSETS_NUM_STAGES] = {};
	};

protected:
	struct ReflectionDataD3D12 {
		uint32_t spirv_specialization_constants_ids_mask = 0;
		uint32_t dxil_push_constant_stages = 0;
		uint32_t nir_runtime_data_root_param_idx = 0;
		uint32_t uses_native_hlsl_rt = 0;
		uint32_t max_payload_size_bytes = 0;
		uint32_t max_attribute_size_bytes = 0;
		uint32_t native_hlsl_shader_model = 0;
		char compiler_hash[64] = {};
		char compile_fingerprint[64] = {};
	};

	struct ContainerFooterD3D12 {
		uint32_t root_signature_length = 0;
		uint32_t root_signature_crc = 0;
		uint32_t native_hlsl_stage_count = 0;
	};

	struct NativeHlslStageFooterD3D12 {
		uint32_t shader_index = 0;
		uint32_t shader_stage = 0;
		uint32_t export_name_length = 0;
		uint32_t active_binding_count = 0;
		uint32_t shader_model = 0;
		uint32_t reserved = 0;
		uint64_t required_feature_flags = 0;
	};

	struct NativeHlslStageInfoD3D12 {
		uint32_t shader_index = 0;
		RenderingDeviceCommons::ShaderStage stage = RenderingDeviceCommons::SHADER_STAGE_MAX;
		uint32_t shader_model = 0;
		uint64_t required_feature_flags = 0;
		String export_name;
		Vector<DxcCompilerD3D12::NativeBinding> active_bindings;
	};

	void *lib_d3d12 = nullptr;
	ReflectionDataD3D12 reflection_data_d3d12;
	Vector<ReflectionBindingSetDataD3D12> reflection_binding_set_data_d3d12;
	Vector<ReflectionBindingDataD3D12> reflection_binding_set_uniforms_data_d3d12;
	Vector<ReflectionSpecializationDataD3D12> reflection_specialization_data_d3d12;
	Vector<uint8_t> root_signature_bytes;
	uint32_t root_signature_crc = 0;
	Vector<NativeHlslStageInfoD3D12> native_hlsl_stage_info;
	String compiler_hash;
	String compile_fingerprint;
	const DxcCompilerD3D12 *dxc_compiler = nullptr;

	bool _generate_root_signature(BitField<RenderingDeviceCommons::ShaderStage> p_stages_processed);
	bool _set_native_hlsl_code_from_spirv(const ReflectShader &p_shader);
	bool _validate_native_hlsl_bindings(const ReflectShader &p_shader, NativeHlslStageInfoD3D12 &r_stage_info, const DxcCompilerD3D12::CompiledLibrary &p_library, String &r_error);
	static bool _add_expected_binding(Vector<DxcCompilerD3D12::NativeBinding> &r_bindings, uint32_t p_set, uint32_t p_binding, uint32_t p_class, uint32_t p_count, uint32_t p_kind, uint32_t p_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_NONE, uint32_t p_constant_buffer_size_bytes = 0);

#if NIR_ENABLED
	bool _convert_spirv_to_nir(Span<ReflectShaderStage> p_spirv, const nir_shader_compiler_options *p_compiler_options, HashMap<int, nir_shader *> &r_stages_nir_shaders, Vector<RenderingDeviceCommons::ShaderStage> &r_stages, BitField<RenderingDeviceCommons::ShaderStage> &r_stages_processed);
	bool _convert_nir_to_dxil(const HashMap<int, nir_shader *> &p_stages_nir_shaders, BitField<RenderingDeviceCommons::ShaderStage> p_stages_processed, HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_dxil_blobs);
	bool _convert_spirv_to_dxil(Span<ReflectShaderStage> p_spirv, HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_dxil_blobs, Vector<RenderingDeviceCommons::ShaderStage> &r_stages, BitField<RenderingDeviceCommons::ShaderStage> &r_stages_processed);

	// GodotNirCallbacks.
	static void _nir_report_resource(uint32_t p_register, uint32_t p_space, uint32_t p_dxil_type, void *p_data);
	static void _nir_report_sc_bit_offset(uint32_t p_sc_id, uint64_t p_bit_offset, void *p_data);
	static void _nir_report_bitcode_bit_offset(uint64_t p_bit_offset, void *p_data);
#endif

	// RenderingShaderContainer overrides.
	virtual uint32_t _format() const override;
	virtual uint32_t _format_version() const override;
	virtual bool _is_format_version_supported(uint32_t p_version) const override;
	virtual uint32_t _from_bytes_reflection_extra_data(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_binding_uniform_extra_data_start(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_binding_uniform_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;
	virtual uint32_t _from_bytes_reflection_specialization_extra_data_start(const uint8_t *p_bytes) override;
	virtual uint32_t _from_bytes_reflection_specialization_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;
	virtual uint32_t _from_bytes_footer_extra_data(const uint8_t *p_bytes) override;
	virtual uint32_t _to_bytes_reflection_extra_data(uint8_t *p_bytes) const override;
	virtual uint32_t _to_bytes_reflection_binding_uniform_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;
	virtual uint32_t _to_bytes_reflection_specialization_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;
	virtual uint32_t _to_bytes_footer_extra_data(uint8_t *p_bytes) const override;
	virtual void _set_from_shader_reflection_post(const ReflectShader &p_shader) override;
	virtual bool _set_code_from_spirv(const ReflectShader &p_shader) override;

public:
	struct ShaderReflectionD3D12 {
		struct NativeHlslStage {
			RenderingDeviceCommons::ShaderStage stage = RenderingDeviceCommons::SHADER_STAGE_MAX;
			uint32_t shader_model = 0;
			uint64_t required_feature_flags = 0;
			String export_name;
			Vector<uint8_t> dxil_library;
			Vector<DxcCompilerD3D12::NativeBinding> active_bindings;
		};

		uint32_t spirv_specialization_constants_ids_mask = 0;
		uint32_t dxil_push_constant_stages = 0;
		uint32_t nir_runtime_data_root_param_idx = 0;
		bool uses_native_hlsl_rt = false;
		uint32_t max_payload_size_bytes = 0;
		uint32_t max_attribute_size_bytes = 0;
		uint32_t native_hlsl_shader_model = 0;
		String compiler_hash;
		String compile_fingerprint;
		Vector<NativeHlslStage> native_hlsl_stages;
		Vector<ReflectionBindingSetDataD3D12> reflection_binding_sets_d3d12;
		Vector<Vector<ReflectionBindingDataD3D12>> reflection_binding_set_uniforms_d3d12;
		Vector<ReflectionSpecializationDataD3D12> reflection_specialization_data_d3d12;
		Vector<uint8_t> root_signature_bytes;
		uint32_t root_signature_crc = 0;
	};

	RenderingShaderContainerD3D12();
	RenderingShaderContainerD3D12(void *p_lib_d3d12, const DxcCompilerD3D12 *p_dxc_compiler = nullptr);
	ShaderReflectionD3D12 get_shader_reflection_d3d12() const;
};

class RenderingShaderContainerFormatD3D12 : public RenderingShaderContainerFormat {
protected:
	void *lib_d3d12 = nullptr;
	DxcCompilerD3D12 dxc_compiler;

public:
	void set_lib_d3d12(void *p_lib_d3d12);
	virtual Ref<RenderingShaderContainer> create_container() const override;
	virtual ShaderLanguageVersion get_shader_language_version() const override;
	virtual ShaderSpirvVersion get_shader_spirv_version() const override;
	bool supports_native_raytracing() const;
	String get_native_raytracing_unavailable_reason() const;
	RenderingShaderContainerFormatD3D12();
	virtual ~RenderingShaderContainerFormatD3D12();
};
