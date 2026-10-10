/**************************************************************************/
/*  rendering_shader_container_d3d12.cpp                                  */
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

#include "rendering_shader_container_d3d12.h"

#include "core/crypto/crypto_core.h"
#include "core/templates/sort_array.h"
#include "drivers/d3d12/dxil_hash.h"

#include <drivers/d3d12/godot_d3d12ma.h>
#include <drivers/d3d12/godot_d3dx12.h>
#include <drivers/d3d12/godot_nir.h>
#include <thirdparty/spirv-reflect/spirv_reflect.h>
#include <wrl/client.h>
#include <zlib.h>

static bool checked_add_u32(uint32_t p_base, uint64_t p_increment, uint32_t &r_result) {
	if (p_increment > UINT32_MAX || p_base > UINT32_MAX - uint32_t(p_increment)) {
		return false;
	}
	r_result = p_base + uint32_t(p_increment);
	return true;
}

static bool align_up_u32(uint32_t p_value, uint32_t p_alignment, uint32_t &r_result) {
	if (p_alignment == 0 || (p_alignment & (p_alignment - 1)) != 0) {
		return false;
	}
	const uint32_t remainder = p_value & (p_alignment - 1);
	const uint32_t padding = remainder == 0 ? 0 : p_alignment - remainder;
	if (p_value > UINT32_MAX - padding) {
		return false;
	}
	r_result = p_value + padding;
	return true;
}

extern "C" {
void dxil_reassign_driver_locations(nir_shader *s, nir_variable_mode modes,
		uint64_t other_stage_mask, const BITSET_WORD *other_stage_frac_mask);
}

// SPIR-V to DXIL does way too many allocations, which causes worker threads
// to bottleneck each other due to sharing the same global process heap.
// This can be solved by making each thread allocate from its own heap.
#define SPIRV_TO_DXIL_ENABLE_HEAP_PER_THREAD

#ifdef SPIRV_TO_DXIL_ENABLE_HEAP_PER_THREAD

namespace {
struct Win32Heap {
	HANDLE handle;
	SafeRefCount ref_count;

	Win32Heap() {
		handle = HeapCreate(0, 0, 0);
		ref_count.init();
	}

	~Win32Heap() {
		HeapDestroy(handle);
	}
};

constexpr size_t ALLOC_HEADER_SIZE = sizeof(Win32Heap *) * 2;
} //namespace

extern "C" {
void *godot_nir_malloc(size_t p_size) {
	// This RAII helper is for allowing the heap to be destroyed when the thread quits.
	struct Win32HeapHolder {
		Win32Heap *win32_heap = nullptr;

		Win32HeapHolder() {
			win32_heap = memnew(Win32Heap);
		}

		~Win32HeapHolder() {
			if (win32_heap->ref_count.unref()) {
				memdelete(win32_heap);
			}
		}
	};

	thread_local Win32HeapHolder holder;

	void *block = HeapAlloc(holder.win32_heap->handle, 0, p_size + ALLOC_HEADER_SIZE);

	// Store the heap in the allocation for the realloc/free operations.
	*(Win32Heap **)block = holder.win32_heap;
	holder.win32_heap->ref_count.ref();

	return (uint8_t *)block + ALLOC_HEADER_SIZE;
}

void *godot_nir_realloc(void *p_block, size_t p_size) {
	uint8_t *actual_block = (uint8_t *)p_block - ALLOC_HEADER_SIZE;
	Win32Heap *win32_heap = *(Win32Heap **)actual_block;
	return (uint8_t *)HeapReAlloc(win32_heap->handle, 0, actual_block, p_size + ALLOC_HEADER_SIZE) + ALLOC_HEADER_SIZE;
}

void godot_nir_free(void *p_block) {
	if (p_block != nullptr) {
		uint8_t *actual_block = (uint8_t *)p_block - ALLOC_HEADER_SIZE;
		Win32Heap *win32_heap = *(Win32Heap **)actual_block;
		HeapFree(win32_heap->handle, 0, actual_block);

		// Allocations can outlive the threads they were created in if they were stored globally.
		if (win32_heap->ref_count.unref()) {
			memdelete(win32_heap);
		}
	}
}
}

#else

extern "C" {
void *godot_nir_malloc(size_t p_size) {
	return malloc(p_size);
}

void *godot_nir_realloc(void *p_block, size_t p_size) {
	return realloc(p_block, p_size);
}

void godot_nir_free(void *p_block) {
	return free(p_block);
}
}

#endif

static D3D12_SHADER_VISIBILITY stages_to_d3d12_visibility(uint32_t p_stages_mask) {
	switch (p_stages_mask) {
		case RenderingDeviceCommons::SHADER_STAGE_VERTEX_BIT:
			return D3D12_SHADER_VISIBILITY_VERTEX;
		case RenderingDeviceCommons::SHADER_STAGE_FRAGMENT_BIT:
			return D3D12_SHADER_VISIBILITY_PIXEL;
		default:
			return D3D12_SHADER_VISIBILITY_ALL;
	}
}

uint32_t RenderingDXIL::patch_specialization_constant(
		RenderingDeviceCommons::PipelineSpecializationConstantType p_type,
		const void *p_value,
		const uint64_t (&p_stages_bit_offsets)[D3D12_BITCODE_OFFSETS_NUM_STAGES],
		HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_stages_bytecodes,
		bool p_is_first_patch) {
	int64_t patch_val = 0;
	switch (p_type) {
		case RenderingDeviceCommons::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_INT: {
			patch_val = *((const int32_t *)p_value);
		} break;
		case RenderingDeviceCommons::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_BOOL: {
			bool bool_value = *((const bool *)p_value);
			patch_val = (int32_t)bool_value;
		} break;
		case RenderingDeviceCommons::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_FLOAT: {
			patch_val = *((const int32_t *)p_value);
		} break;
	}

	// Encode to signed VBR.
	if (patch_val >= 0) {
		patch_val <<= 1;
	} else {
		patch_val = ((-patch_val) << 1) | 1;
	}

	auto tamper_bits = [](uint8_t *p_start, uint64_t p_bit_offset, uint64_t p_tb_value) -> uint64_t {
		uint64_t original = 0;
		uint32_t curr_input_byte = p_bit_offset / 8;
		uint8_t curr_input_bit = p_bit_offset % 8;
		auto get_curr_input_bit = [&]() -> bool {
			return ((p_start[curr_input_byte] >> curr_input_bit) & 1);
		};
		auto move_to_next_input_bit = [&]() {
			if (curr_input_bit == 7) {
				curr_input_bit = 0;
				curr_input_byte++;
			} else {
				curr_input_bit++;
			}
		};
		auto tamper_input_bit = [&](bool p_new_bit) {
			p_start[curr_input_byte] &= ~((uint8_t)1 << curr_input_bit);
			if (p_new_bit) {
				p_start[curr_input_byte] |= (uint8_t)1 << curr_input_bit;
			}
		};
		uint8_t value_bit_idx = 0;
		for (uint32_t i = 0; i < 5; i++) { // 32 bits take 5 full bytes in VBR.
			for (uint32_t j = 0; j < 7; j++) {
				bool input_bit = get_curr_input_bit();
				original |= (uint64_t)(input_bit ? 1 : 0) << value_bit_idx;
				tamper_input_bit((p_tb_value >> value_bit_idx) & 1);
				move_to_next_input_bit();
				value_bit_idx++;
			}
#ifdef DEV_ENABLED
			bool input_bit = get_curr_input_bit();
			DEV_ASSERT((i < 4 && input_bit) || (i == 4 && !input_bit));
#endif
			move_to_next_input_bit();
		}
		return original;
	};
	uint32_t stages_patched_mask = 0;
	for (int stage = 0; stage < RenderingDeviceCommons::SHADER_STAGE_MAX; stage++) {
		if (!r_stages_bytecodes.has((RenderingDeviceCommons::ShaderStage)stage)) {
			continue;
		}

		uint64_t offset = p_stages_bit_offsets[RenderingShaderContainerD3D12::SHADER_STAGES_BIT_OFFSET_INDICES[stage]];
		if (offset == 0) {
			// This constant does not appear at this stage.
			continue;
		}

		Vector<uint8_t> &bytecode = r_stages_bytecodes[(RenderingDeviceCommons::ShaderStage)stage];
#ifdef DEV_ENABLED
		uint64_t orig_patch_val = tamper_bits(bytecode.ptrw(), offset, (uint64_t)patch_val);
		// Checking against the value the NIR patch should have set.
		DEV_ASSERT(!p_is_first_patch || ((orig_patch_val >> 1) & GODOT_NIR_SC_SENTINEL_MAGIC_MASK) == GODOT_NIR_SC_SENTINEL_MAGIC);
		uint64_t readback_patch_val = tamper_bits(bytecode.ptrw(), offset, (uint64_t)patch_val);
		DEV_ASSERT(readback_patch_val == (uint64_t)patch_val);
#else
		tamper_bits(bytecode.ptrw(), offset, (uint64_t)patch_val);
#endif

		stages_patched_mask |= (1 << stage);
	}

	return stages_patched_mask;
}

void RenderingDXIL::sign_bytecode(RenderingDeviceCommons::ShaderStage p_stage, Vector<uint8_t> &r_dxil_blob) {
	uint8_t *w = r_dxil_blob.ptrw();
	compute_dxil_hash(w + 20, r_dxil_blob.size() - 20, w + 4);
}

// RenderingShaderContainerD3D12

uint32_t RenderingShaderContainerD3D12::_format() const {
	return 0x43443344;
}

uint32_t RenderingShaderContainerD3D12::_format_version() const {
	return FORMAT_VERSION;
}

bool RenderingShaderContainerD3D12::_is_format_version_supported(uint32_t p_version) const {
	return p_version == FORMAT_VERSION;
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_reflection_extra_data(const uint8_t *p_bytes) {
	reflection_data_d3d12 = *(const ReflectionDataD3D12 *)(p_bytes);
	compiler_hash = String();
	compile_fingerprint = String();
	compiler_hash.append_utf8(reflection_data_d3d12.compiler_hash, sizeof(reflection_data_d3d12.compiler_hash));
	compile_fingerprint.append_utf8(reflection_data_d3d12.compile_fingerprint, sizeof(reflection_data_d3d12.compile_fingerprint));
	reflection_binding_set_data_d3d12.resize(reflection_data.set_count);
	for (uint32_t i = 0; i < reflection_binding_set_data_d3d12.size(); i++) {
		reflection_binding_set_data_d3d12.ptrw()[i] = *(const ReflectionBindingSetDataD3D12 *)(p_bytes + sizeof(ReflectionDataD3D12) + (i * sizeof(ReflectionBindingSetDataD3D12)));
	}
	return sizeof(ReflectionDataD3D12) + (reflection_binding_set_data_d3d12.size() * sizeof(ReflectionBindingSetDataD3D12));
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_reflection_binding_uniform_extra_data_start(const uint8_t *p_bytes) {
	reflection_binding_set_uniforms_data_d3d12.resize(reflection_binding_set_uniforms_data.size());
	return 0;
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_reflection_binding_uniform_extra_data(const uint8_t *p_bytes, uint32_t p_index) {
	reflection_binding_set_uniforms_data_d3d12.ptrw()[p_index] = *(const ReflectionBindingDataD3D12 *)(p_bytes);
	return sizeof(ReflectionBindingDataD3D12);
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_reflection_specialization_extra_data_start(const uint8_t *p_bytes) {
	reflection_specialization_data_d3d12.resize(reflection_specialization_data.size());
	return 0;
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_reflection_specialization_extra_data(const uint8_t *p_bytes, uint32_t p_index) {
	reflection_specialization_data_d3d12.ptrw()[p_index] = *(const ReflectionSpecializationDataD3D12 *)(p_bytes);
	return sizeof(ReflectionSpecializationDataD3D12);
}

uint32_t RenderingShaderContainerD3D12::_from_bytes_footer_extra_data(const uint8_t *p_bytes) {
	native_hlsl_stage_info.clear();
	root_signature_bytes.clear();
	root_signature_crc = 0;
	ContainerFooterD3D12 footer = *(const ContainerFooterD3D12 *)(p_bytes);
	root_signature_crc = footer.root_signature_crc;
	root_signature_bytes.resize(footer.root_signature_length);
	uint32_t offset = sizeof(ContainerFooterD3D12);
	memcpy(root_signature_bytes.ptrw(), p_bytes + offset, root_signature_bytes.size());
	offset += footer.root_signature_length;

	ERR_FAIL_COND_V_MSG(footer.native_hlsl_stage_count > RenderingDeviceCommons::SHADER_STAGE_MAX, 0, "D3D12 container has too many native HLSL stages.");
	native_hlsl_stage_info.resize(footer.native_hlsl_stage_count);
	uint32_t seen_shader_indices = 0;
	for (uint32_t i = 0; i < footer.native_hlsl_stage_count; i++) {
		NativeHlslStageFooterD3D12 stage_footer = *(const NativeHlslStageFooterD3D12 *)(p_bytes + offset);
		offset += sizeof(NativeHlslStageFooterD3D12);
		ERR_FAIL_COND_V_MSG(stage_footer.shader_index >= shaders.size() || stage_footer.shader_index >= 32, 0, "D3D12 native HLSL stage references an invalid shader index.");
		ERR_FAIL_COND_V_MSG(stage_footer.shader_stage < RenderingDeviceCommons::SHADER_STAGE_RAYGEN || stage_footer.shader_stage > RenderingDeviceCommons::SHADER_STAGE_INTERSECTION, 0, "D3D12 native HLSL metadata contains a non-RT stage.");
		ERR_FAIL_COND_V_MSG(seen_shader_indices & (1U << stage_footer.shader_index), 0, "D3D12 native HLSL metadata references a shader stage more than once.");
		seen_shader_indices |= 1U << stage_footer.shader_index;
		ERR_FAIL_COND_V_MSG(shaders[stage_footer.shader_index].shader_stage != stage_footer.shader_stage, 0, "D3D12 native HLSL metadata stage does not match its bytecode entry.");
		ERR_FAIL_COND_V_MSG(stage_footer.export_name_length == 0 || stage_footer.export_name_length > 4096, 0, "D3D12 native HLSL export name has an invalid length.");
		ERR_FAIL_COND_V_MSG(stage_footer.active_binding_count > 4096, 0, "D3D12 native HLSL stage has too many active bindings.");
		ERR_FAIL_COND_V_MSG((stage_footer.shader_model != 63 && stage_footer.shader_model != 65) ||
				stage_footer.shader_model != reflection_data_d3d12.native_hlsl_shader_model || stage_footer.reserved != 0,
				0, "D3D12 native HLSL stage has an invalid or inconsistent shader model declaration.");
		NativeHlslStageInfoD3D12 &stage_info = native_hlsl_stage_info.write[i];
		stage_info.shader_index = stage_footer.shader_index;
		stage_info.stage = RenderingDeviceCommons::ShaderStage(stage_footer.shader_stage);
		stage_info.shader_model = stage_footer.shader_model;
		stage_info.required_feature_flags = stage_footer.required_feature_flags;
		stage_info.export_name.append_utf8((const char *)(p_bytes + offset), stage_footer.export_name_length);
		uint32_t export_end = 0;
		ERR_FAIL_COND_V_MSG(!checked_add_u32(offset, stage_footer.export_name_length, export_end) || !align_up_u32(export_end, sizeof(uint32_t), offset),
				0, "D3D12 native HLSL export name offset overflows the container.");
		stage_info.active_bindings.resize(stage_footer.active_binding_count);
		for (uint32_t j = 0; j < stage_footer.active_binding_count; j++) {
			DxcCompilerD3D12::NativeBinding binding = *(const DxcCompilerD3D12::NativeBinding *)(p_bytes + offset);
			offset += sizeof(DxcCompilerD3D12::NativeBinding);
			ERR_FAIL_COND_V_MSG(binding.set >= RenderingDeviceCommons::MAX_UNIFORM_SETS || binding.count == 0 ||
					binding.resource_class < DxcCompilerD3D12::NATIVE_RESOURCE_CBV || binding.resource_class > DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER ||
					binding.resource_kind < DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER || binding.resource_kind > DxcCompilerD3D12::NATIVE_KIND_ACCELERATION_STRUCTURE ||
					binding.resource_dimension > DxcCompilerD3D12::NATIVE_DIMENSION_ACCELERATION_STRUCTURE ||
					((binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER) != (binding.constant_buffer_size_bytes > 0)) ||
					(binding.resource_kind != DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER && binding.constant_buffer_size_bytes != 0),
					0, "D3D12 native HLSL binding metadata is invalid.");
			const bool class_kind_match =
					(binding.resource_class == DxcCompilerD3D12::NATIVE_RESOURCE_CBV && binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER) ||
					(binding.resource_class == DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER && binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_SAMPLER) ||
					(binding.resource_class == DxcCompilerD3D12::NATIVE_RESOURCE_SRV &&
							(binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_SAMPLED_TEXTURE || binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_RAW_BUFFER || binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_ACCELERATION_STRUCTURE)) ||
					(binding.resource_class == DxcCompilerD3D12::NATIVE_RESOURCE_UAV &&
							(binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_STORAGE_TEXTURE || binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_RAW_BUFFER));
			ERR_FAIL_COND_V_MSG(!class_kind_match, 0, "D3D12 native HLSL resource class and resource kind disagree.");
		const bool kind_dimension_match =
					((binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER || binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_SAMPLER) && binding.resource_dimension == DxcCompilerD3D12::NATIVE_DIMENSION_NONE) ||
					(binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_RAW_BUFFER && binding.resource_dimension == DxcCompilerD3D12::NATIVE_DIMENSION_BUFFER) ||
					(binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_ACCELERATION_STRUCTURE && binding.resource_dimension == DxcCompilerD3D12::NATIVE_DIMENSION_ACCELERATION_STRUCTURE) ||
					((binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_SAMPLED_TEXTURE || binding.resource_kind == DxcCompilerD3D12::NATIVE_KIND_STORAGE_TEXTURE) &&
							binding.resource_dimension >= DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_1D && binding.resource_dimension <= DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_CUBE_ARRAY);
		ERR_FAIL_COND_V_MSG(!kind_dimension_match, 0, "D3D12 native HLSL resource kind and dimension disagree.");
			stage_info.active_bindings.write[j] = binding;
		}
	}

	ERR_FAIL_COND_V_MSG((reflection_data_d3d12.uses_native_hlsl_rt != 0) != !native_hlsl_stage_info.is_empty(), 0, "D3D12 native HLSL metadata is inconsistent.");
	if (reflection_data_d3d12.uses_native_hlsl_rt) {
		ERR_FAIL_COND_V_MSG(reflection_data.pipeline_type != RenderingDeviceCommons::PIPELINE_TYPE_RAYTRACING || footer.native_hlsl_stage_count != reflection_data.stage_count,
				0, "D3D12 native HLSL metadata does not cover the full ray-tracing pipeline.");
		ERR_FAIL_COND_V_MSG(compiler_hash.length() != 64 || compile_fingerprint.length() != 64 ||
				reflection_data_d3d12.max_attribute_size_bytes > 32 ||
				(reflection_data_d3d12.native_hlsl_shader_model != 63 && reflection_data_d3d12.native_hlsl_shader_model != 65),
				0, "D3D12 native HLSL metadata has invalid compiler fingerprints or size declarations.");
	} else {
		ERR_FAIL_COND_V_MSG(reflection_data_d3d12.native_hlsl_shader_model != 0 || reflection_data_d3d12.max_payload_size_bytes != 0 ||
				reflection_data_d3d12.max_attribute_size_bytes != 0 || !compiler_hash.is_empty() || !compile_fingerprint.is_empty(),
				0, "D3D12 non-native shader contains native HLSL metadata.");
	}
	return offset;
}

uint32_t RenderingShaderContainerD3D12::_to_bytes_reflection_extra_data(uint8_t *p_bytes) const {
	if (p_bytes != nullptr) {
		*(ReflectionDataD3D12 *)(p_bytes) = reflection_data_d3d12;
		for (uint32_t i = 0; i < reflection_binding_set_data_d3d12.size(); i++) {
			*(ReflectionBindingSetDataD3D12 *)(p_bytes + sizeof(ReflectionDataD3D12) + (i * sizeof(ReflectionBindingSetDataD3D12))) = reflection_binding_set_data_d3d12[i];
		}
	}

	return sizeof(ReflectionDataD3D12) + (reflection_binding_set_data_d3d12.size() * sizeof(ReflectionBindingSetDataD3D12));
}

uint32_t RenderingShaderContainerD3D12::_to_bytes_reflection_binding_uniform_extra_data(uint8_t *p_bytes, uint32_t p_index) const {
	if (p_bytes != nullptr) {
		*(ReflectionBindingDataD3D12 *)(p_bytes) = reflection_binding_set_uniforms_data_d3d12[p_index];
	}

	return sizeof(ReflectionBindingDataD3D12);
}

uint32_t RenderingShaderContainerD3D12::_to_bytes_reflection_specialization_extra_data(uint8_t *p_bytes, uint32_t p_index) const {
	if (p_bytes != nullptr) {
		*(ReflectionSpecializationDataD3D12 *)(p_bytes) = reflection_specialization_data_d3d12[p_index];
	}

	return sizeof(ReflectionSpecializationDataD3D12);
}

uint32_t RenderingShaderContainerD3D12::_to_bytes_footer_extra_data(uint8_t *p_bytes) const {
	if (p_bytes != nullptr) {
		ContainerFooterD3D12 &footer = *(ContainerFooterD3D12 *)(p_bytes);
		footer.root_signature_length = root_signature_bytes.size();
		footer.root_signature_crc = root_signature_crc;
		footer.native_hlsl_stage_count = native_hlsl_stage_info.size();
		uint32_t offset = sizeof(ContainerFooterD3D12);
		memcpy(p_bytes + offset, root_signature_bytes.ptr(), root_signature_bytes.size());
		offset += root_signature_bytes.size();
		for (const NativeHlslStageInfoD3D12 &stage_info : native_hlsl_stage_info) {
			NativeHlslStageFooterD3D12 stage_footer;
			stage_footer.shader_index = stage_info.shader_index;
			stage_footer.shader_stage = stage_info.stage;
			stage_footer.export_name_length = stage_info.export_name.utf8().length();
			stage_footer.active_binding_count = stage_info.active_bindings.size();
			stage_footer.shader_model = stage_info.shader_model;
			stage_footer.required_feature_flags = stage_info.required_feature_flags;
			*(NativeHlslStageFooterD3D12 *)(p_bytes + offset) = stage_footer;
			offset += sizeof(NativeHlslStageFooterD3D12);
			CharString export_name = stage_info.export_name.utf8();
			ERR_FAIL_COND_V_MSG(export_name.length() > 4096, 0, "D3D12 native HLSL export name exceeds the container limit.");
			memcpy(p_bytes + offset, export_name.ptr(), export_name.length());
			uint32_t export_end = 0;
			ERR_FAIL_COND_V_MSG(!checked_add_u32(offset, export_name.length(), export_end) || !align_up_u32(export_end, sizeof(uint32_t), offset),
					0, "D3D12 native HLSL export name offset overflows the container.");
			if (!stage_info.active_bindings.is_empty()) {
				memcpy(p_bytes + offset, stage_info.active_bindings.ptr(), stage_info.active_bindings.size() * sizeof(DxcCompilerD3D12::NativeBinding));
				uint32_t next_offset = 0;
				ERR_FAIL_COND_V_MSG(!checked_add_u32(offset, uint64_t(stage_info.active_bindings.size()) * sizeof(DxcCompilerD3D12::NativeBinding), next_offset),
						0, "D3D12 native HLSL binding metadata overflows the container.");
				offset = next_offset;
			}
		}
		return offset;
	}

	uint32_t size = sizeof(ContainerFooterD3D12) + root_signature_bytes.size();
	for (const NativeHlslStageInfoD3D12 &stage_info : native_hlsl_stage_info) {
		uint32_t export_end = 0;
		uint32_t aligned_export_end = 0;
		uint32_t next_size = 0;
		const uint64_t export_name_bytes = stage_info.export_name.utf8().length();
		const uint64_t binding_bytes = uint64_t(stage_info.active_bindings.size()) * sizeof(DxcCompilerD3D12::NativeBinding);
		ERR_FAIL_COND_V_MSG(export_name_bytes > 4096 ||
				!checked_add_u32(size, sizeof(NativeHlslStageFooterD3D12), export_end) ||
				!checked_add_u32(export_end, export_name_bytes, export_end) ||
				!align_up_u32(export_end, sizeof(uint32_t), aligned_export_end) ||
				!checked_add_u32(aligned_export_end, binding_bytes, next_size),
				0, "D3D12 native HLSL footer size overflows the container.");
		size = next_size;
	}
	return size;
}

#if NIR_ENABLED
bool RenderingShaderContainerD3D12::_convert_spirv_to_nir(Span<ReflectShaderStage> p_spirv, const nir_shader_compiler_options *p_compiler_options, HashMap<int, nir_shader *> &r_stages_nir_shaders, Vector<RenderingDeviceCommons::ShaderStage> &r_stages, BitField<RenderingDeviceCommons::ShaderStage> &r_stages_processed) {
	r_stages_processed.clear();

	dxil_spirv_runtime_conf dxil_runtime_conf = {};
	dxil_runtime_conf.runtime_data_cbv.base_shader_register = RUNTIME_DATA_REGISTER;
	dxil_runtime_conf.push_constant_cbv.base_shader_register = ROOT_CONSTANT_REGISTER;
	dxil_runtime_conf.first_vertex_and_base_instance_mode = DXIL_SPIRV_SYSVAL_TYPE_ZERO;
	dxil_runtime_conf.workgroup_id_mode = DXIL_SPIRV_SYSVAL_TYPE_ZERO;

	// Explicitly keeping these false because converting UAV descriptors to SRVs do not seem to have real performance benefits on desktop GPUs.
	// It also makes it easier to implement descriptor heaps and enhanced barriers.
	dxil_runtime_conf.declared_read_only_images_as_srvs = false;
	dxil_runtime_conf.inferred_read_only_images_as_srvs = false;

	// Translate SPIR-V to NIR.
	for (uint64_t i = 0; i < p_spirv.size(); i++) {
		RenderingDeviceCommons::ShaderStage stage = p_spirv[i].shader_stage;
		RenderingDeviceCommons::ShaderStage stage_flag = (RenderingDeviceCommons::ShaderStage)(1 << stage);
		r_stages.push_back(stage);
		r_stages_processed.set_flag(stage_flag);

		const char *entry_point = "main";
		static const mesa_shader_stage SPIRV_TO_MESA_STAGES[RenderingDeviceCommons::SHADER_STAGE_MAX] = {
			MESA_SHADER_VERTEX, // SHADER_STAGE_VERTEX
			MESA_SHADER_FRAGMENT, // SHADER_STAGE_FRAGMENT
			MESA_SHADER_TESS_CTRL, // SHADER_STAGE_TESSELATION_CONTROL
			MESA_SHADER_TESS_EVAL, // SHADER_STAGE_TESSELATION_EVALUATION
			MESA_SHADER_COMPUTE, // SHADER_STAGE_COMPUTE
		};

		Span<uint32_t> code = p_spirv[i].spirv();
		nir_shader *shader = spirv_to_nir(
				code.ptr(),
				code.size(),
				nullptr,
				0,
				SPIRV_TO_MESA_STAGES[stage],
				entry_point,
				dxil_spirv_nir_get_spirv_options(),
				p_compiler_options);

		ERR_FAIL_NULL_V_MSG(shader, false, "Shader translation (step 1) at stage " + String(RenderingDeviceCommons::SHADER_STAGE_NAMES[stage]) + " failed.");

		if (stage == RenderingDeviceCommons::SHADER_STAGE_VERTEX) {
			dxil_runtime_conf.yz_flip.y_mask = 0xffff;
			dxil_runtime_conf.yz_flip.mode = DXIL_SPIRV_Y_FLIP_UNCONDITIONAL;
		} else {
			dxil_runtime_conf.yz_flip.y_mask = 0;
			dxil_runtime_conf.yz_flip.mode = DXIL_SPIRV_YZ_FLIP_NONE;
		}

		dxil_spirv_nir_prep(shader);
		dxil_spirv_metadata dxil_metadata = {};
		dxil_spirv_nir_passes(shader, &dxil_runtime_conf, &dxil_metadata);

		r_stages_nir_shaders[stage] = shader;
	}

	// Link NIR shaders.
	for (int i = RenderingDeviceCommons::SHADER_STAGE_MAX - 1; i >= 0; i--) {
		if (!r_stages_nir_shaders.has(i)) {
			continue;
		}
		nir_shader *shader = r_stages_nir_shaders[i];
		nir_shader *prev_shader = nullptr;
		for (int j = i - 1; j >= 0; j--) {
			if (r_stages_nir_shaders.has(j)) {
				prev_shader = r_stages_nir_shaders[j];
				break;
			}
		}
		if (prev_shader) {
			dxil_spirv_metadata dxil_metadata = {};
			dxil_spirv_nir_link(shader, prev_shader, &dxil_runtime_conf, &dxil_metadata);
		}
		// There is a bug in the Direct3D runtime during creation of a PSO with view instancing. If a fragment
		// shader uses front/back face detection (SV_IsFrontFace), its signature must include the pixel position
		// builtin variable (SV_Position), otherwise an Internal Runtime error will occur.
		if (i == RenderingDeviceCommons::SHADER_STAGE_FRAGMENT) {
			const bool use_front_face =
					nir_find_variable_with_location(shader, nir_var_shader_in, VARYING_SLOT_FACE) ||
					(shader->info.inputs_read & VARYING_BIT_FACE) ||
					nir_find_variable_with_location(shader, nir_var_system_value, SYSTEM_VALUE_FRONT_FACE) ||
					BITSET_TEST(shader->info.system_values_read, SYSTEM_VALUE_FRONT_FACE);
			const bool use_position =
					nir_find_variable_with_location(shader, nir_var_shader_in, VARYING_SLOT_POS) ||
					(shader->info.inputs_read & VARYING_BIT_POS) ||
					nir_find_variable_with_location(shader, nir_var_system_value, SYSTEM_VALUE_FRAG_COORD) ||
					BITSET_TEST(shader->info.system_values_read, SYSTEM_VALUE_FRAG_COORD);
			if (use_front_face && !use_position) {
				nir_variable *const pos = nir_variable_create(shader, nir_var_shader_in, glsl_vec4_type(), "gl_FragCoord");
				pos->data.location = VARYING_SLOT_POS;
				shader->info.inputs_read |= VARYING_BIT_POS;

				if (prev_shader) {
					dxil_reassign_driver_locations(shader, nir_var_shader_in, prev_shader->info.outputs_written, nullptr);
					dxil_reassign_driver_locations(prev_shader, nir_var_shader_out, shader->info.inputs_read, nullptr);
				}
			}
		}
	}

	return true;
}

struct GodotNirCallbackUserData {
	RenderingShaderContainerD3D12 *container;
	RenderingDeviceCommons::ShaderStage stage;
};

static dxil_shader_model shader_model_d3d_to_dxil(D3D_SHADER_MODEL p_d3d_shader_model) {
	static_assert(SHADER_MODEL_6_0 == 0x60000);
	static_assert(SHADER_MODEL_6_3 == 0x60003);
	static_assert(D3D_SHADER_MODEL_6_0 == 0x60);
	static_assert(D3D_SHADER_MODEL_6_3 == 0x63);
	return (dxil_shader_model)((p_d3d_shader_model >> 4) * 0x10000 + (p_d3d_shader_model & 0xf));
}

bool RenderingShaderContainerD3D12::_convert_nir_to_dxil(const HashMap<int, nir_shader *> &p_stages_nir_shaders, BitField<RenderingDeviceCommons::ShaderStage> p_stages_processed, HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_dxil_blobs) {
	// Translate NIR to DXIL.
	for (KeyValue<int, nir_shader *> it : p_stages_nir_shaders) {
		RenderingDeviceCommons::ShaderStage stage = (RenderingDeviceCommons::ShaderStage)(it.key);
		GodotNirCallbackUserData godot_nir_callback_user_data;
		godot_nir_callback_user_data.container = this;
		godot_nir_callback_user_data.stage = stage;

		GodotNirCallbacks godot_nir_callbacks = {};
		godot_nir_callbacks.data = &godot_nir_callback_user_data;
		godot_nir_callbacks.report_resource = _nir_report_resource;
		godot_nir_callbacks.report_sc_bit_offset_fn = _nir_report_sc_bit_offset;
		godot_nir_callbacks.report_bitcode_bit_offset_fn = _nir_report_bitcode_bit_offset;

		nir_to_dxil_options nir_to_dxil_options = {};
		nir_to_dxil_options.environment = DXIL_ENVIRONMENT_VULKAN;
		nir_to_dxil_options.shader_model_max = shader_model_d3d_to_dxil(D3D_SHADER_MODEL(REQUIRED_SHADER_MODEL));
		nir_to_dxil_options.validator_version_max = NO_DXIL_VALIDATION;
		nir_to_dxil_options.godot_nir_callbacks = &godot_nir_callbacks;

		dxil_logger logger = {};
		logger.log = [](void *p_priv, const char *p_msg) {
#ifdef DEBUG_ENABLED
			print_verbose(p_msg);
#endif
		};

		blob dxil_blob = {};
		bool ok = nir_to_dxil(it.value, &nir_to_dxil_options, &logger, &dxil_blob);
		ERR_FAIL_COND_V_MSG(!ok, false, "Shader translation at stage " + String(RenderingDeviceCommons::SHADER_STAGE_NAMES[stage]) + " failed.");

		Vector<uint8_t> blob_copy;
		blob_copy.resize(dxil_blob.size);
		memcpy(blob_copy.ptrw(), dxil_blob.data, dxil_blob.size);
		blob_finish(&dxil_blob);
		r_dxil_blobs.insert(stage, blob_copy);
	}

	return true;
}

bool RenderingShaderContainerD3D12::_convert_spirv_to_dxil(Span<ReflectShaderStage> p_spirv, HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &r_dxil_blobs, Vector<RenderingDeviceCommons::ShaderStage> &r_stages, BitField<RenderingDeviceCommons::ShaderStage> &r_stages_processed) {
	r_dxil_blobs.clear();

	HashMap<int, nir_shader *> stages_nir_shaders;
	auto free_nir_shaders = [&]() {
		for (KeyValue<int, nir_shader *> &E : stages_nir_shaders) {
			ralloc_free(E.value);
		}
		stages_nir_shaders.clear();
	};

	// This structure must live as long as the shaders are alive.
	nir_shader_compiler_options compiler_options = {};
	const unsigned supported_bit_sizes = 16 | 32 | 64;
	dxil_get_nir_compiler_options(&compiler_options, shader_model_d3d_to_dxil(D3D_SHADER_MODEL(REQUIRED_SHADER_MODEL)), supported_bit_sizes, supported_bit_sizes);
	compiler_options.lower_base_vertex = false;

	// This is based on spirv2dxil.c. May need updates when it changes.
	// Also, this has to stay around until after linking.
	if (!_convert_spirv_to_nir(p_spirv, &compiler_options, stages_nir_shaders, r_stages, r_stages_processed)) {
		free_nir_shaders();
		return false;
	}

	if (!_convert_nir_to_dxil(stages_nir_shaders, r_stages_processed, r_dxil_blobs)) {
		free_nir_shaders();
		return false;
	}

	free_nir_shaders();
	return true;
}

static bool get_spirv_image_dimension(const SpvReflectImageTraits &p_image, uint32_t &r_dimension) {
	using Kind = DxcCompilerD3D12;
	switch (p_image.dim) {
		case SpvDim1D:
			if (p_image.ms) {
				return false;
			}
		r_dimension = p_image.arrayed ? Kind::NATIVE_DIMENSION_TEXTURE_1D_ARRAY : Kind::NATIVE_DIMENSION_TEXTURE_1D;
			return true;
		case SpvDim2D:
			if (p_image.ms) {
				r_dimension = p_image.arrayed ? Kind::NATIVE_DIMENSION_TEXTURE_2D_MS_ARRAY : Kind::NATIVE_DIMENSION_TEXTURE_2D_MS;
			} else {
				r_dimension = p_image.arrayed ? Kind::NATIVE_DIMENSION_TEXTURE_2D_ARRAY : Kind::NATIVE_DIMENSION_TEXTURE_2D;
			}
			return true;
		case SpvDim3D:
			if (p_image.arrayed || p_image.ms) {
				return false;
			}
			r_dimension = Kind::NATIVE_DIMENSION_TEXTURE_3D;
			return true;
		case SpvDimCube:
			if (p_image.ms) {
				return false;
			}
			r_dimension = p_image.arrayed ? Kind::NATIVE_DIMENSION_TEXTURE_CUBE_ARRAY : Kind::NATIVE_DIMENSION_TEXTURE_CUBE;
			return true;
		case SpvDimSubpassData:
			if (p_image.arrayed || p_image.ms) {
				return false;
			}
			r_dimension = Kind::NATIVE_DIMENSION_TEXTURE_2D;
			return true;
		default:
			return false;
	}
}

bool RenderingShaderContainerD3D12::_add_expected_binding(Vector<DxcCompilerD3D12::NativeBinding> &r_bindings, uint32_t p_set, uint32_t p_binding, uint32_t p_class, uint32_t p_count, uint32_t p_kind, uint32_t p_dimension, uint32_t p_constant_buffer_size_bytes) {
	if (p_count == 0) {
		return false;
	}
	for (const DxcCompilerD3D12::NativeBinding &existing : r_bindings) {
		if (existing.set == p_set && existing.binding == p_binding && existing.resource_class == p_class) {
			return existing.count == p_count && existing.resource_kind == p_kind && existing.resource_dimension == p_dimension &&
					existing.constant_buffer_size_bytes == p_constant_buffer_size_bytes;
		}
	}
	DxcCompilerD3D12::NativeBinding expected;
	expected.set = p_set;
	expected.binding = p_binding;
	expected.resource_class = p_class;
	expected.count = p_count;
	expected.resource_kind = p_kind;
	expected.resource_dimension = p_dimension;
	expected.constant_buffer_size_bytes = p_constant_buffer_size_bytes;
	r_bindings.push_back(expected);
	return true;
}

bool RenderingShaderContainerD3D12::_validate_native_hlsl_bindings(const ReflectShader &p_shader, NativeHlslStageInfoD3D12 &r_stage_info, const DxcCompilerD3D12::CompiledLibrary &p_library, String &r_error) {
	using RDC = RenderingDeviceCommons;
	Vector<DxcCompilerD3D12::NativeBinding> expected_bindings;

	for (uint32_t set = 0; set < p_shader.uniform_sets.size(); set++) {
		for (const ReflectUniform &uniform : p_shader.uniform_sets[set]) {
			if (!uniform.has_spv_reflect(r_stage_info.stage)) {
				continue;
			}

			const SpvReflectDescriptorBinding &spv_binding = uniform.get_spv_reflect(r_stage_info.stage);
		uint32_t image_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_NONE;
		if ((uniform.type == RDC::UNIFORM_TYPE_TEXTURE || uniform.type == RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE ||
				uniform.type == RDC::UNIFORM_TYPE_IMAGE || uniform.type == RDC::UNIFORM_TYPE_INPUT_ATTACHMENT) &&
				!get_spirv_image_dimension(spv_binding.image, image_dimension)) {
			r_error = vformat("SPIR-V image at set %d, binding %d uses a dimension or array/MS combination unsupported by the D3D12 native ABI.", set, uniform.binding);
			return false;
		}
			uint64_t reflected_descriptor_count = 1;
			for (uint32_t array_dim = 0; array_dim < spv_binding.array.dims_count; array_dim++) {
				if (spv_binding.array.dims[array_dim] == 0 || reflected_descriptor_count > UINT32_MAX / spv_binding.array.dims[array_dim]) {
					r_error = vformat("SPIR-V descriptor at set %d, binding %d has an unsupported runtime or overflowing array.", set, uniform.binding);
					return false;
				}
				reflected_descriptor_count *= spv_binding.array.dims[array_dim];
			}
			const uint32_t array_descriptor_count = uint32_t(reflected_descriptor_count);
			bool supported = true;
			switch (uniform.type) {
				case RDC::UNIFORM_TYPE_SAMPLER:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER, array_descriptor_count,
							DxcCompilerD3D12::NATIVE_KIND_SAMPLER);
					break;
				case RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_SRV, array_descriptor_count,
							DxcCompilerD3D12::NATIVE_KIND_SAMPLED_TEXTURE, image_dimension) &&
							_add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER, array_descriptor_count,
							DxcCompilerD3D12::NATIVE_KIND_SAMPLER);
					break;
				case RDC::UNIFORM_TYPE_TEXTURE:
				case RDC::UNIFORM_TYPE_INPUT_ATTACHMENT:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_SRV, array_descriptor_count,
							DxcCompilerD3D12::NATIVE_KIND_SAMPLED_TEXTURE, image_dimension);
					break;
				case RDC::UNIFORM_TYPE_IMAGE:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_UAV, array_descriptor_count,
							DxcCompilerD3D12::NATIVE_KIND_STORAGE_TEXTURE, image_dimension);
					break;
				case RDC::UNIFORM_TYPE_UNIFORM_BUFFER:
				case RDC::UNIFORM_TYPE_UNIFORM_BUFFER_DYNAMIC:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_CBV, 1,
							DxcCompilerD3D12::NATIVE_KIND_CONSTANT_BUFFER, DxcCompilerD3D12::NATIVE_DIMENSION_NONE, uniform.length);
					break;
				case RDC::UNIFORM_TYPE_STORAGE_BUFFER:
				case RDC::UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding,
							uniform.writable ? DxcCompilerD3D12::NATIVE_RESOURCE_UAV : DxcCompilerD3D12::NATIVE_RESOURCE_SRV, 1,
							DxcCompilerD3D12::NATIVE_KIND_RAW_BUFFER, DxcCompilerD3D12::NATIVE_DIMENSION_BUFFER);
					break;
				case RDC::UNIFORM_TYPE_ACCELERATION_STRUCTURE:
					supported = _add_expected_binding(expected_bindings, set, uniform.binding, DxcCompilerD3D12::NATIVE_RESOURCE_SRV, 1,
							DxcCompilerD3D12::NATIVE_KIND_ACCELERATION_STRUCTURE, DxcCompilerD3D12::NATIVE_DIMENSION_ACCELERATION_STRUCTURE);
					break;
				case RDC::UNIFORM_TYPE_TEXTURE_BUFFER:
				case RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE_BUFFER:
				case RDC::UNIFORM_TYPE_IMAGE_BUFFER:
					r_error = "Native HLSL RT does not support texel-buffer descriptors in the current D3D12 container.";
					return false;
				default:
					r_error = vformat("Native HLSL RT does not support reflected uniform type %d.", uint32_t(uniform.type));
					return false;
			}
			if (!supported) {
				r_error = vformat("SPIR-V has conflicting descriptor declarations at set %d, binding %d.", set, uniform.binding);
				return false;
			}
		}
	}

	for (uint32_t i = 0; i < p_library.active_bindings.size(); i++) {
		const DxcCompilerD3D12::NativeBinding &actual = p_library.active_bindings[i];
		bool found = false;
		for (const DxcCompilerD3D12::NativeBinding &expected : expected_bindings) {
			if (actual.set == expected.set && actual.binding == expected.binding && actual.resource_class == expected.resource_class && actual.count == expected.count &&
					actual.resource_kind == expected.resource_kind && actual.resource_dimension == expected.resource_dimension &&
					actual.constant_buffer_size_bytes == expected.constant_buffer_size_bytes) {
				found = true;
				break;
			}
		}
		if (!found) {
			r_error = vformat("Native HLSL export '%s' has an incompatible descriptor: set %d, binding %d, class %d, count %d, kind %d, dimension %d, CBV bytes %d.",
					r_stage_info.export_name, actual.set, actual.binding, actual.resource_class, actual.count, actual.resource_kind, actual.resource_dimension, actual.constant_buffer_size_bytes);
			for (const DxcCompilerD3D12::NativeBinding &expected : expected_bindings) {
				if (expected.binding == actual.binding && expected.set == actual.set) {
					r_error += vformat(" Expected class %d, count %d, kind %d, dimension %d, CBV bytes %d.", expected.resource_class, expected.count, expected.resource_kind, expected.resource_dimension, expected.constant_buffer_size_bytes);
				}
			}
			return false;
		}
		for (uint32_t j = i + 1; j < p_library.active_bindings.size(); j++) {
			const DxcCompilerD3D12::NativeBinding &other = p_library.active_bindings[j];
			const uint64_t actual_end = uint64_t(actual.binding) + actual.count;
			const uint64_t other_end = uint64_t(other.binding) + other.count;
			const bool register_ranges_overlap = actual.binding < other_end && other.binding < actual_end;
			if (actual.set == other.set && actual.resource_class == other.resource_class && register_ranges_overlap) {
				r_error = vformat("Native HLSL export '%s' has overlapping register ranges in set %d, register class %d.", r_stage_info.export_name, actual.set, actual.resource_class);
				return false;
			}
		}
	}

	r_stage_info.active_bindings = p_library.active_bindings;
	return true;
}

bool RenderingShaderContainerD3D12::_set_native_hlsl_code_from_spirv(const ReflectShader &p_shader) {
	ERR_FAIL_COND_V_MSG(p_shader.pipeline_type != RenderingDeviceCommons::PIPELINE_TYPE_RAYTRACING, false, "Native HLSL sidecars are only accepted for ray-tracing pipelines.");
	ERR_FAIL_COND_V_MSG(!dxc_compiler || !dxc_compiler->is_available(), false,
			dxc_compiler ? dxc_compiler->get_unavailable_reason() : "The D3D12 shader container has no DXC compiler instance.");
	ERR_FAIL_COND_V_MSG(p_shader.push_constant_size != 0, false, "D3D12 native HLSL RT currently requires shader data in uniform descriptors; push constants are not supported by the canonical register ABI.");
	ERR_FAIL_COND_V_MSG(!p_shader.specialization_constants.is_empty(), false, "D3D12 native HLSL RT does not support specialization constants yet.");
	ERR_FAIL_COND_V_MSG(p_shader.shader_stages.is_empty(), false, "The native HLSL RT shader has no stages.");

	const int32_t declared_payload_size = p_shader.shader_stages[0].native_hlsl_max_payload_size_bytes();
	const int32_t declared_attribute_size = p_shader.shader_stages[0].native_hlsl_max_attribute_size_bytes();
	const int32_t declared_shader_model = p_shader.shader_stages[0].native_hlsl_shader_model();
	ERR_FAIL_COND_V_MSG(declared_payload_size < 0 || declared_attribute_size < 0 || declared_attribute_size > 32, false, "D3D12 native HLSL RT requires supported payload and hit-attribute size declarations.");
	ERR_FAIL_COND_V_MSG(declared_shader_model != 63 && declared_shader_model != 65, false, vformat("D3D12 native HLSL RT shader model %d is unsupported; use 63 or 65.", declared_shader_model));
	reflection_data_d3d12 = ReflectionDataD3D12();
	reflection_data_d3d12.nir_runtime_data_root_param_idx = UINT32_MAX;
	reflection_data_d3d12.uses_native_hlsl_rt = 1;
	reflection_data_d3d12.max_payload_size_bytes = uint32_t(declared_payload_size);
	reflection_data_d3d12.max_attribute_size_bytes = uint32_t(declared_attribute_size);
	reflection_data_d3d12.native_hlsl_shader_model = uint32_t(declared_shader_model);
	compiler_hash = dxc_compiler->get_compiler_hash();
	ERR_FAIL_COND_V_MSG(compiler_hash.length() != 64, false, "DXC does not have a valid compiler SHA-256 identity.");
	memcpy(reflection_data_d3d12.compiler_hash, compiler_hash.utf8().ptr(), sizeof(reflection_data_d3d12.compiler_hash));

	String fingerprint_source = "DXC_NATIVE_RT\n" + compiler_hash + "\nlib_6_" + itos(declared_shader_model % 10) + "\n-HV 2021\n-Ges\n-O3\n-Zpc\n" +
		itos(declared_payload_size) + ":" + itos(declared_attribute_size) + "\n";
	Vector<DxcCompilerD3D12::CompiledLibrary> compiled_libraries;
	compiled_libraries.resize(p_shader.shader_stages.size());
	native_hlsl_stage_info.clear();
	native_hlsl_stage_info.resize(p_shader.shader_stages.size());
	BitField<RenderingDeviceCommons::ShaderStage> stages_processed = {};

	for (int64_t i = 0; i < p_shader.shader_stages.size(); i++) {
		const ReflectShaderStage &shader_stage = p_shader.shader_stages[i];
		ERR_FAIL_COND_V_MSG(shader_stage.native_hlsl_source().strip_edges().is_empty() || shader_stage.native_hlsl_export().strip_edges().is_empty(), false,
				vformat("D3D12 native RT stage '%s' requires a paired HLSL source and export.", RenderingDeviceCommons::SHADER_STAGE_NAMES[shader_stage.shader_stage]));
		ERR_FAIL_COND_V_MSG(shader_stage.native_hlsl_max_payload_size_bytes() != declared_payload_size || shader_stage.native_hlsl_max_attribute_size_bytes() != declared_attribute_size, false,
				"All D3D12 native HLSL RT stages must use matching payload and hit-attribute declarations.");
		ERR_FAIL_COND_V_MSG(shader_stage.native_hlsl_shader_model() != declared_shader_model, false,
				"All D3D12 native HLSL RT stages must use the same shader model profile.");

		DxcCompilerD3D12::CompiledLibrary &compiled = compiled_libraries.write[i];
		String error;
		ERR_FAIL_COND_V_MSG(!dxc_compiler->compile_library(shader_stage.shader_stage, uint32_t(declared_shader_model), shader_stage.native_hlsl_source(), shader_stage.native_hlsl_export(), compiled, error), false,
				vformat("Native HLSL compilation failed for '%s': %s", shader_stage.native_hlsl_export(), error));

		NativeHlslStageInfoD3D12 &stage_info = native_hlsl_stage_info.write[i];
		stage_info.shader_index = i;
		stage_info.stage = shader_stage.shader_stage;
		stage_info.shader_model = compiled.shader_model;
		stage_info.required_feature_flags = compiled.required_feature_flags;
		stage_info.export_name = compiled.export_name;
		if (!_validate_native_hlsl_bindings(p_shader, stage_info, compiled, error)) {
			const String failed_export_name = stage_info.export_name;
			native_hlsl_stage_info.clear();
			reflection_data_d3d12.uses_native_hlsl_rt = 0;
			ERR_FAIL_V_MSG(false, vformat("Native HLSL binding validation failed for '%s': %s", failed_export_name, error));
		}
		const uint32_t stage_bit = 1U << shader_stage.shader_stage;
		stages_processed.set_flag((RenderingDeviceCommons::ShaderStage)stage_bit);
		uint32_t binding_start = 0;
		for (uint32_t set = 0; set < p_shader.uniform_sets.size(); set++) {
			for (const DxcCompilerD3D12::NativeBinding &binding : stage_info.active_bindings) {
				if (binding.set != set) {
					continue;
				}
				bool found_uniform = false;
				for (uint32_t uniform_index = 0; uniform_index < p_shader.uniform_sets[set].size(); uniform_index++) {
					const ReflectUniform &uniform = p_shader.uniform_sets[set][uniform_index];
					if (uniform.binding != binding.binding) {
						continue;
					}
					ReflectionBindingDataD3D12 &binding_data = reflection_binding_set_uniforms_data_d3d12.write[binding_start + uniform_index];
					binding_data.dxil_stages |= stage_bit;
					switch (binding.resource_class) {
						case DxcCompilerD3D12::NATIVE_RESOURCE_CBV:
							binding_data.resource_class = RES_CLASS_CBV;
							break;
						case DxcCompilerD3D12::NATIVE_RESOURCE_SRV:
							binding_data.resource_class = RES_CLASS_SRV;
							break;
						case DxcCompilerD3D12::NATIVE_RESOURCE_UAV:
							binding_data.resource_class = RES_CLASS_UAV;
							break;
						case DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER:
							binding_data.has_sampler = 1;
							break;
						default:
							ERR_FAIL_V_MSG(false, "DXC returned an invalid native resource class.");
					}
					found_uniform = true;
					break;
				}
				ERR_FAIL_COND_V_MSG(!found_uniform, false, "Validated native HLSL binding was not found in the SPIR-V uniform sets.");
			}
			binding_start += p_shader.uniform_sets[set].size();
		}

		fingerprint_source += itos(shader_stage.shader_stage) + ":" + itos(compiled.shader_model) + "\n" +
				shader_stage.native_hlsl_export() + "\n" + shader_stage.native_hlsl_source() + "\n";
	}
	compile_fingerprint = fingerprint_source.sha256_text();
	ERR_FAIL_COND_V_MSG(compile_fingerprint.length() != 64, false, "Could not produce the native HLSL compile fingerprint.");
	memcpy(reflection_data_d3d12.compile_fingerprint, compile_fingerprint.utf8().ptr(), sizeof(reflection_data_d3d12.compile_fingerprint));

	shaders.resize(compiled_libraries.size());
	for (int64_t i = 0; i < compiled_libraries.size(); i++) {
		const DxcCompilerD3D12::CompiledLibrary &compiled = compiled_libraries[i];
		RenderingShaderContainer::Shader &shader = shaders.write[i];
		shader.shader_stage = compiled.stage;
		shader.code_decompressed_size = compiled.dxil_library.size();
		shader.code_compressed_bytes.resize(shader.code_decompressed_size);
		uint32_t compressed_size = 0;
		ERR_FAIL_COND_V_MSG(!compress_code(compiled.dxil_library.ptr(), shader.code_decompressed_size, shader.code_compressed_bytes.ptrw(), &compressed_size, &shader.code_compression_flags), false,
				vformat("Failed to compress DXIL library for native RT stage '%s'.", compiled.export_name));
		shader.code_compressed_bytes.resize(compressed_size);
	}

	return _generate_root_signature(stages_processed);
}

bool RenderingShaderContainerD3D12::_generate_root_signature(BitField<RenderingDeviceCommons::ShaderStage> p_stages_processed) {
	if (reflection_data_d3d12.uses_native_hlsl_rt) {
		struct NativeRegisterRange {
			uint32_t set = 0;
			uint32_t binding = 0;
			uint32_t count = 0;
			uint32_t resource_class = 0;
		};
		Vector<NativeRegisterRange> register_ranges;
		auto add_native_range = [&](uint32_t p_set, uint32_t p_binding, uint32_t p_count, uint32_t p_resource_class) {
			if (p_count == 0 || p_binding > UINT32_MAX - (p_count - 1)) {
				return false;
			}
			const uint64_t candidate_end = uint64_t(p_binding) + p_count;
			for (const NativeRegisterRange &existing : register_ranges) {
				const uint64_t existing_end = uint64_t(existing.binding) + existing.count;
				if (existing.set == p_set && existing.resource_class == p_resource_class && p_binding < existing_end && existing.binding < candidate_end) {
					return false;
				}
			}
			NativeRegisterRange range;
			range.set = p_set;
			range.binding = p_binding;
			range.count = p_count;
			range.resource_class = p_resource_class;
			register_ranges.push_back(range);
			return true;
		};

		uint32_t native_binding_start = 0;
		for (uint32_t set = 0; set < reflection_binding_set_uniforms_count.size(); set++) {
			for (uint32_t i = 0; i < reflection_binding_set_uniforms_count[set]; i++) {
				const ReflectionBindingData &uniform = reflection_binding_set_uniforms_data[native_binding_start + i];
				const uint32_t descriptor_count = MAX(1u, uniform.length);
				bool valid_ranges = true;
				switch (uniform.type) {
					case RDC::UNIFORM_TYPE_SAMPLER:
						valid_ranges = add_native_range(set, uniform.binding, descriptor_count, D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER);
						break;
					case RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE:
						valid_ranges = add_native_range(set, uniform.binding, descriptor_count, D3D12_DESCRIPTOR_RANGE_TYPE_SRV) &&
								add_native_range(set, uniform.binding, descriptor_count, D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER);
						break;
					case RDC::UNIFORM_TYPE_TEXTURE:
					case RDC::UNIFORM_TYPE_INPUT_ATTACHMENT:
						valid_ranges = add_native_range(set, uniform.binding, descriptor_count, D3D12_DESCRIPTOR_RANGE_TYPE_SRV);
						break;
					case RDC::UNIFORM_TYPE_IMAGE:
						valid_ranges = add_native_range(set, uniform.binding, descriptor_count, D3D12_DESCRIPTOR_RANGE_TYPE_UAV);
						break;
					case RDC::UNIFORM_TYPE_UNIFORM_BUFFER:
					case RDC::UNIFORM_TYPE_UNIFORM_BUFFER_DYNAMIC:
						valid_ranges = add_native_range(set, uniform.binding, 1, D3D12_DESCRIPTOR_RANGE_TYPE_CBV);
						break;
					case RDC::UNIFORM_TYPE_STORAGE_BUFFER:
					case RDC::UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC:
						valid_ranges = add_native_range(set, uniform.binding, 1, uniform.writable ? D3D12_DESCRIPTOR_RANGE_TYPE_UAV : D3D12_DESCRIPTOR_RANGE_TYPE_SRV);
						break;
					case RDC::UNIFORM_TYPE_ACCELERATION_STRUCTURE:
						valid_ranges = add_native_range(set, uniform.binding, 1, D3D12_DESCRIPTOR_RANGE_TYPE_SRV);
						break;
					default:
						ERR_FAIL_V_MSG(false, "Native HLSL RT cannot generate a register ABI for this uniform type.");
				}
				ERR_FAIL_COND_V_MSG(!valid_ranges, false,
						vformat("Native D3D12 register ranges overlap or overflow at set %d, binding %d.", set, uniform.binding));
			}
			native_binding_start += reflection_binding_set_uniforms_count[set];
		}
	}

	// Root (push) constants.
	LocalVector<D3D12_ROOT_PARAMETER1> root_params;
	if (reflection_data_d3d12.dxil_push_constant_stages) {
		CD3DX12_ROOT_PARAMETER1 push_constant;
		push_constant.InitAsConstants(
				reflection_data.push_constant_size / sizeof(uint32_t),
				ROOT_CONSTANT_REGISTER,
				0,
				stages_to_d3d12_visibility(reflection_data_d3d12.dxil_push_constant_stages));

		root_params.push_back(push_constant);
	}

	// NIR-DXIL runtime data.
	if (reflection_data_d3d12.nir_runtime_data_root_param_idx == 1) { // Set above to 1 when discovering runtime data is needed.
		bool is_compute = (reflection_data.pipeline_type == RDC::PIPELINE_TYPE_COMPUTE);
		uint32_t runtime_data_size = (is_compute ? sizeof(dxil_spirv_compute_runtime_data) : sizeof(dxil_spirv_vertex_runtime_data));
		D3D12_SHADER_VISIBILITY visibility = (is_compute ? D3D12_SHADER_VISIBILITY_ALL : D3D12_SHADER_VISIBILITY_VERTEX);

		reflection_data_d3d12.nir_runtime_data_root_param_idx = root_params.size();
		CD3DX12_ROOT_PARAMETER1 nir_runtime_data;
		nir_runtime_data.InitAsConstants(
				runtime_data_size / sizeof(uint32_t),
				RUNTIME_DATA_REGISTER,
				0,
				visibility);
		root_params.push_back(nir_runtime_data);
	}

	// Descriptor tables (up to two per uniform set, for resources and/or samplers).
	// These have to stay around until serialization!
	struct TraceableDescriptorTable {
		uint32_t stages_mask = {};
		Vector<D3D12_DESCRIPTOR_RANGE1> ranges;
		uint32_t set = UINT_MAX;
	};

	uint32_t binding_start = 0;
	Vector<TraceableDescriptorTable> resource_tables_maps;
	Vector<TraceableDescriptorTable> sampler_tables_maps;
	for (uint32_t i = 0; i < reflection_binding_set_uniforms_count.size(); i++) {
		bool first_resource_in_set = true;
		bool first_sampler_in_set = true;
		uint32_t uniform_count = reflection_binding_set_uniforms_count[i];
		for (uint32_t j = 0; j < uniform_count; j++) {
			const ReflectionBindingData &uniform = reflection_binding_set_uniforms_data[binding_start + j];
			ReflectionBindingDataD3D12 &uniform_d3d12 = reflection_binding_set_uniforms_data_d3d12.ptrw()[binding_start + j];
#ifdef DEV_ENABLED
			bool really_used = uniform_d3d12.dxil_stages != 0;
			bool anybody_home = (ResourceClass)(uniform_d3d12.resource_class) != RES_CLASS_INVALID || uniform_d3d12.has_sampler;
			DEV_ASSERT(anybody_home == really_used);
#endif

			auto insert_range = [i](D3D12_DESCRIPTOR_RANGE_TYPE p_range_type,
										uint32_t p_num_descriptors,
										uint32_t p_dxil_register,
											uint32_t p_dxil_space,
										uint32_t p_dxil_stages_mask,
										uint32_t &r_descriptor_offset,
										uint32_t &r_descriptor_count,
										bool &r_first_in_set,
										Vector<TraceableDescriptorTable> &r_tables) {
				r_descriptor_offset = r_descriptor_count;

				if (r_first_in_set) {
					r_tables.resize(r_tables.size() + 1);
					r_first_in_set = false;
				}

				TraceableDescriptorTable &table = r_tables.write[r_tables.size() - 1];
				DEV_ASSERT(table.set == UINT_MAX || table.set == i);

				table.stages_mask |= p_dxil_stages_mask;
				table.set = i;

				CD3DX12_DESCRIPTOR_RANGE1 range;

				// Due to the aliasing hack for SRV-UAV of different families,
				// we can be causing an unintended change of data (sometimes the validation layers catch it).
				D3D12_DESCRIPTOR_RANGE_FLAGS flags = D3D12_DESCRIPTOR_RANGE_FLAG_NONE;
				if (p_range_type == D3D12_DESCRIPTOR_RANGE_TYPE_SRV || p_range_type == D3D12_DESCRIPTOR_RANGE_TYPE_UAV) {
					flags = D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;
				} else if (p_range_type == D3D12_DESCRIPTOR_RANGE_TYPE_CBV) {
					flags = D3D12_DESCRIPTOR_RANGE_FLAG_DATA_STATIC_WHILE_SET_AT_EXECUTE;
				}

				range.Init(p_range_type, p_num_descriptors, p_dxil_register, p_dxil_space, flags, r_descriptor_offset);
				r_descriptor_count += p_num_descriptors;
				table.ranges.push_back(range);
			};

			D3D12_DESCRIPTOR_RANGE_TYPE range_type = (D3D12_DESCRIPTOR_RANGE_TYPE)UINT_MAX;
			bool has_sampler = false;
			uint32_t num_descriptors = 1;

			switch (uniform.type) {
				case RDC::UNIFORM_TYPE_SAMPLER: {
					has_sampler = true;
					num_descriptors = uniform.length;
				} break;
				case RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
					has_sampler = true;
					num_descriptors = MAX(1u, uniform.length);
				} break;
				case RDC::UNIFORM_TYPE_TEXTURE: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
					num_descriptors = MAX(1u, uniform.length);
				} break;
				case RDC::UNIFORM_TYPE_IMAGE: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
					num_descriptors = MAX(1u, uniform.length);
				} break;
				case RDC::UNIFORM_TYPE_TEXTURE_BUFFER: {
					CRASH_NOW_MSG("Unimplemented!");
				} break;
				case RDC::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE_BUFFER: {
					CRASH_NOW_MSG("Unimplemented!");
				} break;
				case RDC::UNIFORM_TYPE_IMAGE_BUFFER: {
					CRASH_NOW_MSG("Unimplemented!");
				} break;
				case RDC::UNIFORM_TYPE_UNIFORM_BUFFER: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
				} break;
				case RDC::UNIFORM_TYPE_UNIFORM_BUFFER_DYNAMIC: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
				} break;
				case RDC::UNIFORM_TYPE_STORAGE_BUFFER: {
					range_type = uniform.writable ? D3D12_DESCRIPTOR_RANGE_TYPE_UAV : D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
				} break;
				case RDC::UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC: {
					range_type = uniform.writable ? D3D12_DESCRIPTOR_RANGE_TYPE_UAV : D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
				} break;
				case RDC::UNIFORM_TYPE_ACCELERATION_STRUCTURE: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
				} break;
				case RDC::UNIFORM_TYPE_INPUT_ATTACHMENT: {
					range_type = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
				} break;
				default: {
					DEV_ASSERT(false);
				}
			}

			uint32_t dxil_register = reflection_data_d3d12.uses_native_hlsl_rt ? uniform.binding : i * GODOT_NIR_DESCRIPTOR_SET_MULTIPLIER + uniform.binding * GODOT_NIR_BINDING_MULTIPLIER;
			uint32_t dxil_space = reflection_data_d3d12.uses_native_hlsl_rt ? i : 0;
			if (range_type != (D3D12_DESCRIPTOR_RANGE_TYPE)UINT_MAX) {
				// Dynamic buffers are converted to root descriptors to prevent copying descriptors during command recording.
				// Out of bounds accesses are not a concern because that's already undefined behavior on Vulkan.
				if (uniform.type == RDC::UNIFORM_TYPE_UNIFORM_BUFFER_DYNAMIC || uniform.type == RDC::UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC) {
					CD3DX12_ROOT_PARAMETER1 root_param = {};
					D3D12_SHADER_VISIBILITY visibility = stages_to_d3d12_visibility(uniform.stages);

					switch (range_type) {
						case D3D12_DESCRIPTOR_RANGE_TYPE_CBV: {
							root_param.InitAsConstantBufferView(dxil_register, dxil_space, D3D12_ROOT_DESCRIPTOR_FLAG_DATA_STATIC_WHILE_SET_AT_EXECUTE, visibility);
						} break;
						case D3D12_DESCRIPTOR_RANGE_TYPE_SRV: {
							root_param.InitAsShaderResourceView(dxil_register, dxil_space, D3D12_ROOT_DESCRIPTOR_FLAG_DATA_VOLATILE, visibility);
						} break;
						case D3D12_DESCRIPTOR_RANGE_TYPE_UAV: {
							root_param.InitAsUnorderedAccessView(dxil_register, dxil_space, D3D12_ROOT_DESCRIPTOR_FLAG_DATA_VOLATILE, visibility);
						} break;
						default: {
							DEV_ASSERT(false && "Unrecognized range type.");
						} break;
					}

					uniform_d3d12.root_param_idx = root_params.size();
					root_params.push_back(root_param);
				} else {
					insert_range(
							range_type,
							num_descriptors,
							dxil_register,
							dxil_space,
							uniform.stages,
							uniform_d3d12.resource_descriptor_offset,
							reflection_binding_set_data_d3d12.ptrw()[i].resource_descriptor_count,
							first_resource_in_set,
							resource_tables_maps);
				}
			}

			if (has_sampler) {
				insert_range(
						D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,
						num_descriptors,
						dxil_register,
					dxil_space,
						uniform.stages,
						uniform_d3d12.sampler_descriptor_offset,
						reflection_binding_set_data_d3d12.ptrw()[i].sampler_descriptor_count,
						first_sampler_in_set,
						sampler_tables_maps);
			}
		}

		binding_start += uniform_count;
	}

	for (const TraceableDescriptorTable &table : resource_tables_maps) {
		CD3DX12_ROOT_PARAMETER1 root_table = {};
		root_table.InitAsDescriptorTable(table.ranges.size(), table.ranges.ptr(), stages_to_d3d12_visibility(table.stages_mask));
		reflection_binding_set_data_d3d12.ptrw()[table.set].resource_root_param_idx = root_params.size();
		root_params.push_back(root_table);
	}

	for (const TraceableDescriptorTable &table : sampler_tables_maps) {
		CD3DX12_ROOT_PARAMETER1 root_table = {};
		root_table.InitAsDescriptorTable(table.ranges.size(), table.ranges.ptr(), stages_to_d3d12_visibility(table.stages_mask));
		reflection_binding_set_data_d3d12.ptrw()[table.set].sampler_root_param_idx = root_params.size();
		root_params.push_back(root_table);
	}

	CD3DX12_VERSIONED_ROOT_SIGNATURE_DESC root_sig_desc = {};
	D3D12_ROOT_SIGNATURE_FLAGS root_sig_flags =
			D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS |
			D3D12_ROOT_SIGNATURE_FLAG_DENY_DOMAIN_SHADER_ROOT_ACCESS |
			D3D12_ROOT_SIGNATURE_FLAG_DENY_GEOMETRY_SHADER_ROOT_ACCESS;

	if (!p_stages_processed.has_flag(RenderingDeviceCommons::SHADER_STAGE_VERTEX_BIT)) {
		root_sig_flags |= D3D12_ROOT_SIGNATURE_FLAG_DENY_VERTEX_SHADER_ROOT_ACCESS;
	}

	if (!p_stages_processed.has_flag(RenderingDeviceCommons::SHADER_STAGE_FRAGMENT_BIT)) {
		root_sig_flags |= D3D12_ROOT_SIGNATURE_FLAG_DENY_PIXEL_SHADER_ROOT_ACCESS;
	}

	if (reflection_data.vertex_input_mask) {
		root_sig_flags |= D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
	}

	root_sig_desc.Init_1_1(root_params.size(), root_params.ptr(), 0, nullptr, root_sig_flags);

	// Create and store the root signature and its CRC32.
	ID3DBlob *error_blob = nullptr;
	ID3DBlob *root_sig_blob = nullptr;
	HRESULT res = D3DX12SerializeVersionedRootSignature(HMODULE(lib_d3d12), &root_sig_desc, D3D_ROOT_SIGNATURE_VERSION_1_1, &root_sig_blob, &error_blob);
	if (SUCCEEDED(res)) {
		root_signature_bytes.resize(root_sig_blob->GetBufferSize());
		memcpy(root_signature_bytes.ptrw(), root_sig_blob->GetBufferPointer(), root_sig_blob->GetBufferSize());

		root_signature_crc = crc32(0, nullptr, 0);
		root_signature_crc = crc32(root_signature_crc, (const Bytef *)root_sig_blob->GetBufferPointer(), root_sig_blob->GetBufferSize());

		return true;
	} else {
		if (root_sig_blob != nullptr) {
			root_sig_blob->Release();
		}

		String error_string;
		if (error_blob != nullptr) {
			error_string = vformat("Serialization of root signature failed with error 0x%08ux and the following message:\n%s", uint32_t(res), String::ascii(Span((char *)error_blob->GetBufferPointer(), error_blob->GetBufferSize())));
			error_blob->Release();
		} else {
			error_string = vformat("Serialization of root signature failed with error 0x%08ux", uint32_t(res));
		}

		ERR_FAIL_V_MSG(false, error_string);
	}
}

void RenderingShaderContainerD3D12::_nir_report_resource(uint32_t p_register, uint32_t p_space, uint32_t p_dxil_type, void *p_data) {
	const GodotNirCallbackUserData &user_data = *(GodotNirCallbackUserData *)p_data;

	// Types based on Mesa's dxil_container.h.
	static const uint32_t DXIL_RES_SAMPLER = 1;
	static const ResourceClass DXIL_TYPE_TO_CLASS[] = {
		RES_CLASS_INVALID, // DXIL_RES_INVALID
		RES_CLASS_INVALID, // DXIL_RES_SAMPLER
		RES_CLASS_CBV, // DXIL_RES_CBV
		RES_CLASS_SRV, // DXIL_RES_SRV_TYPED
		RES_CLASS_SRV, // DXIL_RES_SRV_RAW
		RES_CLASS_SRV, // DXIL_RES_SRV_STRUCTURED
		RES_CLASS_UAV, // DXIL_RES_UAV_TYPED
		RES_CLASS_UAV, // DXIL_RES_UAV_RAW
		RES_CLASS_UAV, // DXIL_RES_UAV_STRUCTURED
		RES_CLASS_INVALID, // DXIL_RES_UAV_STRUCTURED_WITH_COUNTER
	};

	DEV_ASSERT(p_dxil_type < ARRAY_SIZE(DXIL_TYPE_TO_CLASS));
	ResourceClass resource_class = DXIL_TYPE_TO_CLASS[p_dxil_type];

	if (p_register == ROOT_CONSTANT_REGISTER && p_space == 0) {
		DEV_ASSERT(resource_class == RES_CLASS_CBV);
		user_data.container->reflection_data_d3d12.dxil_push_constant_stages |= (1 << user_data.stage);
	} else if (p_register == RUNTIME_DATA_REGISTER && p_space == 0) {
		DEV_ASSERT(resource_class == RES_CLASS_CBV);
		user_data.container->reflection_data_d3d12.nir_runtime_data_root_param_idx = 1; // Temporary, to be determined later.
	} else {
		DEV_ASSERT(p_space == 0);

		uint32_t set = p_register / GODOT_NIR_DESCRIPTOR_SET_MULTIPLIER;
		uint32_t binding = (p_register % GODOT_NIR_DESCRIPTOR_SET_MULTIPLIER) / GODOT_NIR_BINDING_MULTIPLIER;

		DEV_ASSERT(set < (uint32_t)user_data.container->reflection_binding_set_uniforms_count.size());

		uint32_t binding_start = 0;
		for (uint32_t i = 0; i < set; i++) {
			binding_start += user_data.container->reflection_binding_set_uniforms_count[i];
		}

		[[maybe_unused]] bool found = false;
		for (uint32_t i = 0; i < user_data.container->reflection_binding_set_uniforms_count[set]; i++) {
			const ReflectionBindingData &uniform = user_data.container->reflection_binding_set_uniforms_data[binding_start + i];
			ReflectionBindingDataD3D12 &uniform_d3d12 = user_data.container->reflection_binding_set_uniforms_data_d3d12.ptrw()[binding_start + i];
			if (uniform.binding != binding) {
				continue;
			}

			uniform_d3d12.dxil_stages |= (1 << user_data.stage);
			if (resource_class != RES_CLASS_INVALID) {
				DEV_ASSERT(uniform_d3d12.resource_class == (uint32_t)RES_CLASS_INVALID || uniform_d3d12.resource_class == (uint32_t)resource_class);
				uniform_d3d12.resource_class = resource_class;
			} else if (p_dxil_type == DXIL_RES_SAMPLER) {
				uniform_d3d12.has_sampler = (uint32_t)true;
			} else {
				DEV_ASSERT(false && "Unknown resource class.");
			}
			found = true;
		}

		DEV_ASSERT(found);
	}
}

void RenderingShaderContainerD3D12::_nir_report_sc_bit_offset(uint32_t p_sc_id, uint64_t p_bit_offset, void *p_data) {
	const GodotNirCallbackUserData &user_data = *(GodotNirCallbackUserData *)p_data;
	[[maybe_unused]] bool found = false;
	for (int64_t i = 0; i < user_data.container->reflection_specialization_data.size(); i++) {
		const ReflectionSpecializationData &sc = user_data.container->reflection_specialization_data[i];
		ReflectionSpecializationDataD3D12 &sc_d3d12 = user_data.container->reflection_specialization_data_d3d12.ptrw()[i];
		if (sc.constant_id != p_sc_id) {
			continue;
		}

		uint32_t offset_idx = SHADER_STAGES_BIT_OFFSET_INDICES[user_data.stage];
		DEV_ASSERT(sc_d3d12.stages_bit_offsets[offset_idx] == 0);
		sc_d3d12.stages_bit_offsets[offset_idx] = p_bit_offset;
		found = true;
		break;
	}

	DEV_ASSERT(found);
}

void RenderingShaderContainerD3D12::_nir_report_bitcode_bit_offset(uint64_t p_bit_offset, void *p_data) {
	DEV_ASSERT(p_bit_offset % 8 == 0);

	const GodotNirCallbackUserData &user_data = *(GodotNirCallbackUserData *)p_data;
	uint32_t offset_idx = SHADER_STAGES_BIT_OFFSET_INDICES[user_data.stage];
	for (int64_t i = 0; i < user_data.container->reflection_specialization_data.size(); i++) {
		ReflectionSpecializationDataD3D12 &sc_d3d12 = user_data.container->reflection_specialization_data_d3d12.ptrw()[i];
		if (sc_d3d12.stages_bit_offsets[offset_idx] == 0) {
			// This SC has been optimized out from this stage.
			continue;
		}

		sc_d3d12.stages_bit_offsets[offset_idx] += p_bit_offset;
	}
}
#endif

void RenderingShaderContainerD3D12::_set_from_shader_reflection_post(const ReflectShader &p_shader) {
	reflection_binding_set_data_d3d12.resize(reflection_binding_set_uniforms_count.size());
	reflection_binding_set_uniforms_data_d3d12.resize(reflection_binding_set_uniforms_data.size());
	reflection_specialization_data_d3d12.resize(reflection_specialization_data.size());

	// Sort bindings inside each uniform set. This guarantees the root signature will be generated in the correct order.
	SortArray<ReflectionBindingData> sorter;
	uint32_t binding_start = 0;
	for (uint32_t i = 0; i < reflection_binding_set_uniforms_count.size(); i++) {
		uint32_t uniform_count = reflection_binding_set_uniforms_count[i];
		if (uniform_count > 0) {
			sorter.sort(&reflection_binding_set_uniforms_data.ptrw()[binding_start], uniform_count);
			binding_start += uniform_count;
		}
	}
}

bool RenderingShaderContainerD3D12::_set_code_from_spirv(const ReflectShader &p_shader) {
	if (p_shader.pipeline_type == RenderingDeviceCommons::PIPELINE_TYPE_RAYTRACING) {
		return _set_native_hlsl_code_from_spirv(p_shader);
	}
	for (const ReflectShaderStage &stage : p_shader.shader_stages) {
		ERR_FAIL_COND_V_MSG(!stage.native_hlsl_source().strip_edges().is_empty() || !stage.native_hlsl_export().strip_edges().is_empty(), false,
				"Native HLSL sidecars are not accepted for non-ray-tracing D3D12 pipelines.");
	}
#if NIR_ENABLED
	const LocalVector<ReflectShaderStage> &p_spirv = p_shader.shader_stages;
	reflection_data_d3d12.nir_runtime_data_root_param_idx = UINT32_MAX;

	for (int64_t i = 0; i < reflection_specialization_data.size(); i++) {
		DEV_ASSERT(reflection_specialization_data[i].constant_id < (sizeof(reflection_data_d3d12.spirv_specialization_constants_ids_mask) * 8) && "Constant IDs with values above 31 are not supported.");
		reflection_data_d3d12.spirv_specialization_constants_ids_mask |= (1 << reflection_specialization_data[i].constant_id);
	}

	// Translate SPIR-V shaders to DXIL, and collect shader info from the new representation.
	HashMap<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> dxil_blobs;
	Vector<RenderingDeviceCommons::ShaderStage> stages;
	BitField<RenderingDeviceCommons::ShaderStage> stages_processed = {};
	if (!_convert_spirv_to_dxil(p_spirv, dxil_blobs, stages, stages_processed)) {
		return false;
	}

	// Patch with default values of specialization constants.
	DEV_ASSERT(reflection_specialization_data.size() == reflection_specialization_data_d3d12.size());
	for (int32_t i = 0; i < reflection_specialization_data.size(); i++) {
		const ReflectionSpecializationData &sc = reflection_specialization_data[i];
		const ReflectionSpecializationDataD3D12 &sc_d3d12 = reflection_specialization_data_d3d12[i];
		RenderingDXIL::patch_specialization_constant((RenderingDeviceCommons::PipelineSpecializationConstantType)(sc.type), &sc.int_value, sc_d3d12.stages_bit_offsets, dxil_blobs, true);
	}

	// Sign.
	uint32_t shader_index = 0;
	for (KeyValue<RenderingDeviceCommons::ShaderStage, Vector<uint8_t>> &E : dxil_blobs) {
		RenderingDXIL::sign_bytecode(E.key, E.value);
	}

	// Store compressed DXIL blobs as the shaders.
	shaders.resize(p_spirv.size());
	for (int64_t i = 0; i < shaders.size(); i++) {
		const PackedByteArray &dxil_bytes = dxil_blobs[stages[i]];
		RenderingShaderContainer::Shader &shader = shaders.ptrw()[i];
		uint32_t compressed_size = 0;
		shader.shader_stage = stages[i];
		shader.code_decompressed_size = dxil_bytes.size();
		shader.code_compressed_bytes.resize(dxil_bytes.size());

		bool compressed = compress_code(dxil_bytes.ptr(), dxil_bytes.size(), shader.code_compressed_bytes.ptrw(), &compressed_size, &shader.code_compression_flags);
		ERR_FAIL_COND_V_MSG(!compressed, false, vformat("Failed to compress native code to native for SPIR-V #%d.", shader_index));

		shader.code_compressed_bytes.resize(compressed_size);
	}

	if (!_generate_root_signature(stages_processed)) {
		return false;
	}

	return true;
#else
	ERR_FAIL_V_MSG(false, "Shader compilation is not supported at runtime without NIR.");
#endif
}

RenderingShaderContainerD3D12::RenderingShaderContainerD3D12() {
	// Default empty constructor.
}

RenderingShaderContainerD3D12::RenderingShaderContainerD3D12(void *p_lib_d3d12, const DxcCompilerD3D12 *p_dxc_compiler) {
	lib_d3d12 = p_lib_d3d12;
	dxc_compiler = p_dxc_compiler;
}

RenderingShaderContainerD3D12::ShaderReflectionD3D12 RenderingShaderContainerD3D12::get_shader_reflection_d3d12() const {
	ShaderReflectionD3D12 reflection;
	reflection.spirv_specialization_constants_ids_mask = reflection_data_d3d12.spirv_specialization_constants_ids_mask;
	reflection.dxil_push_constant_stages = reflection_data_d3d12.dxil_push_constant_stages;
	reflection.nir_runtime_data_root_param_idx = reflection_data_d3d12.nir_runtime_data_root_param_idx;
	reflection.uses_native_hlsl_rt = reflection_data_d3d12.uses_native_hlsl_rt != 0;
	reflection.max_payload_size_bytes = reflection_data_d3d12.max_payload_size_bytes;
	reflection.max_attribute_size_bytes = reflection_data_d3d12.max_attribute_size_bytes;
	reflection.native_hlsl_shader_model = reflection_data_d3d12.native_hlsl_shader_model;
	reflection.compiler_hash = compiler_hash;
	reflection.compile_fingerprint = compile_fingerprint;
	reflection.reflection_binding_sets_d3d12 = reflection_binding_set_data_d3d12;
	reflection.reflection_specialization_data_d3d12 = reflection_specialization_data_d3d12;
	reflection.root_signature_bytes = root_signature_bytes;
	reflection.root_signature_crc = root_signature_crc;

	// Transform data vector into a vector of vectors that's easier to user.
	uint32_t uniform_index = 0;
	reflection.reflection_binding_set_uniforms_d3d12.resize(reflection_binding_set_uniforms_count.size());
	for (int64_t i = 0; i < reflection.reflection_binding_set_uniforms_d3d12.size(); i++) {
		Vector<ReflectionBindingDataD3D12> &uniforms = reflection.reflection_binding_set_uniforms_d3d12.ptrw()[i];
		uniforms.resize(reflection_binding_set_uniforms_count[i]);
		for (int64_t j = 0; j < uniforms.size(); j++) {
			uniforms.ptrw()[j] = reflection_binding_set_uniforms_data_d3d12[uniform_index];
			uniform_index++;
		}
	}

	if (reflection.uses_native_hlsl_rt) {
		reflection.native_hlsl_stages.resize(native_hlsl_stage_info.size());
		for (int64_t i = 0; i < native_hlsl_stage_info.size(); i++) {
			const NativeHlslStageInfoD3D12 &stage_info = native_hlsl_stage_info[i];
			ERR_FAIL_COND_V_MSG(stage_info.shader_index >= shaders.size(), reflection, "Native HLSL reflection references an invalid shader index.");
			const RenderingShaderContainer::Shader &shader = shaders[stage_info.shader_index];
			ShaderReflectionD3D12::NativeHlslStage &native_stage = reflection.native_hlsl_stages.write[i];
			native_stage.stage = stage_info.stage;
			native_stage.shader_model = stage_info.shader_model;
			native_stage.required_feature_flags = stage_info.required_feature_flags;
			native_stage.export_name = stage_info.export_name;
			native_stage.active_bindings = stage_info.active_bindings;
			native_stage.dxil_library.resize(shader.code_decompressed_size);
			ERR_FAIL_COND_V_MSG(!decompress_code(shader.code_compressed_bytes.ptr(), shader.code_compressed_bytes.size(), shader.code_compression_flags,
					native_stage.dxil_library.ptrw(), native_stage.dxil_library.size()), reflection,
				vformat("Failed to decompress native HLSL library for export '%s'.", stage_info.export_name));
		}
	}

	return reflection;
}

// RenderingShaderContainerFormatD3D12

void RenderingShaderContainerFormatD3D12::set_lib_d3d12(void *p_lib_d3d12) {
	lib_d3d12 = p_lib_d3d12;
}

Ref<RenderingShaderContainer> RenderingShaderContainerFormatD3D12::create_container() const {
	return memnew(RenderingShaderContainerD3D12(lib_d3d12, &dxc_compiler));
}

bool RenderingShaderContainerFormatD3D12::supports_native_raytracing() const {
	return dxc_compiler.is_available();
}

String RenderingShaderContainerFormatD3D12::get_native_raytracing_unavailable_reason() const {
	return dxc_compiler.get_unavailable_reason();
}

RenderingDeviceCommons::ShaderLanguageVersion RenderingShaderContainerFormatD3D12::get_shader_language_version() const {
	// NIR-DXIL is Vulkan 1.1-conformant.
	return SHADER_LANGUAGE_VULKAN_VERSION_1_1;
}

RenderingDeviceCommons::ShaderSpirvVersion RenderingShaderContainerFormatD3D12::get_shader_spirv_version() const {
	// The SPIR-V part of Mesa supports 1.6, but:
	// - SPIRV-Reflect won't be able to parse the compute workgroup size.
	// - We want to play it safe with NIR-DXIL.
	return SHADER_SPIRV_VERSION_1_5;
}

RenderingShaderContainerFormatD3D12::RenderingShaderContainerFormatD3D12() {
	glsl_type_singleton_init_or_ref();
}

RenderingShaderContainerFormatD3D12::~RenderingShaderContainerFormatD3D12() {
	glsl_type_singleton_decref();
}
