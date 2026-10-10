/**************************************************************************/
/*  dxc_compiler_d3d12.cpp                                                */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/**************************************************************************/

#include "dxc_compiler_d3d12.h"

#include "core/io/file_access.h"
#include "core/os/os.h"
#include "core/templates/vector.h"

#include <windows.h>
#include <unknwn.h>
#include <objidl.h>
#include <dxcapi.h>
#include <d3d12shader.h>
#include <wrl/client.h>
#include <cstring>

using Microsoft::WRL::ComPtr;

namespace {

static const char *get_stage_name(RenderingDeviceCommons::ShaderStage p_stage) {
	switch (p_stage) {
		case RenderingDeviceCommons::SHADER_STAGE_RAYGEN:
			return "ray generation";
		case RenderingDeviceCommons::SHADER_STAGE_ANY_HIT:
			return "any hit";
		case RenderingDeviceCommons::SHADER_STAGE_CLOSEST_HIT:
			return "closest hit";
		case RenderingDeviceCommons::SHADER_STAGE_MISS:
			return "miss";
		case RenderingDeviceCommons::SHADER_STAGE_INTERSECTION:
			return "intersection";
		default:
			return "unknown";
	}
}

static D3D12_SHADER_VERSION_TYPE get_expected_shader_type(RenderingDeviceCommons::ShaderStage p_stage) {
	switch (p_stage) {
		case RenderingDeviceCommons::SHADER_STAGE_RAYGEN:
			return D3D12_SHVER_RAY_GENERATION_SHADER;
		case RenderingDeviceCommons::SHADER_STAGE_ANY_HIT:
			return D3D12_SHVER_ANY_HIT_SHADER;
		case RenderingDeviceCommons::SHADER_STAGE_CLOSEST_HIT:
			return D3D12_SHVER_CLOSEST_HIT_SHADER;
		case RenderingDeviceCommons::SHADER_STAGE_MISS:
			return D3D12_SHVER_MISS_SHADER;
		case RenderingDeviceCommons::SHADER_STAGE_INTERSECTION:
			return D3D12_SHVER_INTERSECTION_SHADER;
		default:
			return D3D12_SHVER_RESERVED0;
	}
}

static bool is_native_hlsl_export_identifier(const String &p_export_name) {
	CharString export_utf8 = p_export_name.utf8();
	if (export_utf8.length() <= 0) {
		return false;
	}
	const char *name = export_utf8.get_data();
	auto is_identifier_start = [](char p_char) {
		return (p_char >= 'A' && p_char <= 'Z') || (p_char >= 'a' && p_char <= 'z') || p_char == '_';
	};
	auto is_identifier_continue = [&](char p_char) {
		return is_identifier_start(p_char) || (p_char >= '0' && p_char <= '9');
	};
	if (!is_identifier_start(name[0])) {
		return false;
	}
	for (int i = 1; i < export_utf8.length(); i++) {
		if (!is_identifier_continue(name[i])) {
			return false;
		}
	}
	return true;
}

static bool reflection_name_matches_export(const char *p_reflection_name, const String &p_export_name) {
	if (!p_reflection_name) {
		return false;
	}
	const String reflection_name = String::utf8(p_reflection_name);
	if (reflection_name == p_export_name) {
		return true;
	}

	// DXC's ID3D12LibraryReflection returns MSVC-decorated names for global
	// HLSL functions (for example: "\x01?RayGen@@YAXXZ"), while D3D12's
	// D3D12_EXPORT_DESC uses the source-level export name ("RayGen"). Match
	// that exact global identifier and its mangling boundary; never use a
	// substring search that could accept a different function.
	const char *symbol = p_reflection_name;
	if (symbol[0] == '\x01') {
		symbol++;
	}
	if (symbol[0] != '?') {
		return false;
	}
	symbol++;
	CharString export_utf8 = p_export_name.utf8();
	const int export_length = export_utf8.length();
	if (export_length <= 0 || std::strlen(symbol) < size_t(export_length) + 3 ||
			std::memcmp(symbol, export_utf8.get_data(), export_length) != 0) {
		return false;
	}
	symbol += export_length;
	return symbol[0] == '@' && symbol[1] == '@' && symbol[2] != '\0';
}

static bool get_resource_class(D3D_SHADER_INPUT_TYPE p_type, uint32_t &r_class) {
	switch (p_type) {
		case D3D_SIT_CBUFFER:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_CBV;
			return true;
		case D3D_SIT_SAMPLER:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_SAMPLER;
			return true;
		case D3D_SIT_TEXTURE:
		case D3D_SIT_RTACCELERATIONSTRUCTURE:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_SRV;
			return true;
		case D3D_SIT_BYTEADDRESS:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_SRV;
			return true;
		case D3D_SIT_UAV_RWTYPED:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_UAV;
			return true;
		case D3D_SIT_UAV_RWBYTEADDRESS:
			r_class = DxcCompilerD3D12::NATIVE_RESOURCE_UAV;
			return true;
		case D3D_SIT_STRUCTURED:
		case D3D_SIT_UAV_RWSTRUCTURED:
		case D3D_SIT_UAV_APPEND_STRUCTURED:
		case D3D_SIT_UAV_CONSUME_STRUCTURED:
		case D3D_SIT_UAV_RWSTRUCTURED_WITH_COUNTER:
			// The D3D12 RenderingDevice maps storage buffers to R32_TYPELESS raw
			// views. Structured HLSL buffers do not match that byte-address ABI.
			return false;
		default:
			return false;
	}
}

static bool get_resource_dimension(D3D_SRV_DIMENSION p_dimension, uint32_t &r_dimension) {
	switch (p_dimension) {
		case D3D_SRV_DIMENSION_BUFFER:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_BUFFER;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE1D:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_1D;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE1DARRAY:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_1D_ARRAY;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE2D:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_2D;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE2DARRAY:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_2D_ARRAY;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE2DMS:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_2D_MS;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE2DMSARRAY:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_2D_MS_ARRAY;
			return true;
		case D3D_SRV_DIMENSION_TEXTURE3D:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_3D;
			return true;
		case D3D_SRV_DIMENSION_TEXTURECUBE:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_CUBE;
			return true;
		case D3D_SRV_DIMENSION_TEXTURECUBEARRAY:
			r_dimension = DxcCompilerD3D12::NATIVE_DIMENSION_TEXTURE_CUBE_ARRAY;
			return true;
		default:
			return false;
	}
}

static String get_dxc_output_text(IDxcResult *p_result, DXC_OUT_KIND p_kind) {
	ComPtr<IDxcBlobUtf8> text;
	if (FAILED(p_result->GetOutput(p_kind, IID_PPV_ARGS(text.GetAddressOf()), nullptr)) || !text) {
		return String();
	}
	return String::utf8(text->GetStringPointer(), (int)text->GetStringLength());
}

static String get_module_path(HMODULE p_module) {
	WCHAR path[MAX_PATH * 4] = {};
	constexpr DWORD path_capacity = DWORD(sizeof(path) / sizeof(path[0]));
	DWORD path_length = GetModuleFileNameW(p_module, path, path_capacity);
	if (path_length == 0 || path_length >= path_capacity) {
		return String();
	}
	String result;
	result.append_utf16((const char16_t *)path, path_length);
	return result;
}

static HMODULE load_companion_dll(const String &p_preferred_path, const wchar_t *p_module_name) {
	if (!p_preferred_path.is_empty()) {
		Char16String preferred_path_utf16 = p_preferred_path.utf16();
		HMODULE module = LoadLibraryExW((LPCWSTR)preferred_path_utf16.get_data(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
		if (module) {
			return module;
		}
	}
	return LoadLibraryExW(p_module_name, nullptr,
			LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
}

} // namespace

struct DxcCompilerD3D12::Impl {
	HMODULE module = nullptr;
	HMODULE validator_module = nullptr;
	DxcCreateInstanceProc create_instance = nullptr;
	IDxcUtils *utils = nullptr;
	IDxcCompiler3 *compiler = nullptr;
	IDxcValidator *validator = nullptr;
	Mutex compile_mutex;

	~Impl() {
		if (validator) {
			validator->Release();
		}
		if (compiler) {
			compiler->Release();
		}
		if (utils) {
			utils->Release();
		}
		if (module) {
			FreeLibrary(module);
		}
		if (validator_module) {
			FreeLibrary(validator_module);
		}
	}
};

DxcCompilerD3D12::DxcCompilerD3D12() {
	_initialize();
}

DxcCompilerD3D12::~DxcCompilerD3D12() {
	memdelete(impl);
}

void DxcCompilerD3D12::_initialize() {
	impl = memnew(Impl);

	const String adjacent_path = OS::get_singleton()->get_executable_path().get_base_dir().path_join("dxcompiler.dll");
	impl->module = load_companion_dll(adjacent_path, L"dxcompiler.dll");
	if (impl->module) {
		compiler_path = get_module_path(impl->module);
	} else {
		unavailable_reason = "dxcompiler.dll was not found beside the executable or in the configured Windows DLL directories.";
		memdelete(impl);
		impl = nullptr;
		return;
	}

	if (compiler_path.is_empty()) {
		unavailable_reason = "The loaded dxcompiler.dll path could not be resolved.";
		memdelete(impl);
		impl = nullptr;
		return;
	}

	const String adjacent_validator_path = compiler_path.get_base_dir().path_join("dxil.dll");
	impl->validator_module = load_companion_dll(adjacent_validator_path, L"dxil.dll");
	if (!impl->validator_module) {
		unavailable_reason = "dxil.dll validator was not found beside dxcompiler.dll or in the configured Windows DLL directories.";
		memdelete(impl);
		impl = nullptr;
		return;
	}
	validator_path = get_module_path(impl->validator_module);
	if (validator_path.is_empty()) {
		unavailable_reason = "The loaded dxil.dll validator path could not be resolved.";
		memdelete(impl);
		impl = nullptr;
		return;
	}

	impl->create_instance = (DxcCreateInstanceProc)GetProcAddress(impl->module, "DxcCreateInstance");
	if (!impl->create_instance) {
		unavailable_reason = "dxcompiler.dll does not export DxcCreateInstance.";
		memdelete(impl);
		impl = nullptr;
		return;
	}

	HRESULT hr = impl->create_instance(CLSID_DxcUtils, __uuidof(IDxcUtils), (void **)&impl->utils);
	if (FAILED(hr) || !impl->utils) {
		unavailable_reason = vformat("DXC utility interface creation failed (0x%08x).", uint32_t(hr));
		memdelete(impl);
		impl = nullptr;
		return;
	}

	hr = impl->create_instance(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), (void **)&impl->compiler);
	if (FAILED(hr) || !impl->compiler) {
		unavailable_reason = vformat("DXC compiler interface creation failed (0x%08x).", uint32_t(hr));
		memdelete(impl);
		impl = nullptr;
		return;
	}

	hr = impl->create_instance(CLSID_DxcValidator, __uuidof(IDxcValidator), (void **)&impl->validator);
	if (FAILED(hr) || !impl->validator) {
		unavailable_reason = vformat("DXIL validator interface creation failed (0x%08x).", uint32_t(hr));
		memdelete(impl);
		impl = nullptr;
		return;
	}

	const String dxc_hash = FileAccess::get_sha256(compiler_path);
	validator_hash = FileAccess::get_sha256(validator_path);
	if (dxc_hash.length() != 64 || validator_hash.length() != 64) {
		unavailable_reason = "DXC or its DXIL validator loaded, but a toolchain DLL could not be SHA-256 identified.";
		memdelete(impl);
		impl = nullptr;
		compiler_hash = String();
		validator_hash = String();
		return;
	}
	compiler_hash = ("dxcompiler.dll:" + dxc_hash + "\ndxil.dll:" + validator_hash).sha256_text();
}

bool DxcCompilerD3D12::compile_library(
		RenderingDeviceCommons::ShaderStage p_stage,
		uint32_t p_shader_model,
		const String &p_source,
		const String &p_export_name,
		CompiledLibrary &r_library,
		String &r_error) const {
	ERR_FAIL_COND_V_MSG(!impl, false, unavailable_reason);
	ERR_FAIL_COND_V_MSG(p_source.strip_edges().is_empty(), false, "Native HLSL source is empty.");
	ERR_FAIL_COND_V_MSG(p_export_name.strip_edges().is_empty(), false, "Native HLSL export name is empty.");
	ERR_FAIL_COND_V_MSG(!is_native_hlsl_export_identifier(p_export_name), false,
			"Native HLSL export name must be a simple global HLSL identifier.");
	const D3D12_SHADER_VERSION_TYPE expected_type = get_expected_shader_type(p_stage);
	ERR_FAIL_COND_V_MSG(expected_type == D3D12_SHVER_RESERVED0, false, "Native HLSL compilation was requested for a non-ray-tracing shader stage.");
	ERR_FAIL_COND_V_MSG(p_shader_model != 63 && p_shader_model != 65, false, vformat("Unsupported native HLSL shader model %d; only 6.3 and 6.5 are supported.", p_shader_model));

	MutexLock lock(impl->compile_mutex);

	CharString source_utf8 = p_source.utf8();
	DxcBuffer source_buffer = {};
	source_buffer.Ptr = source_utf8.get_data();
	source_buffer.Size = source_utf8.length();
	source_buffer.Encoding = DXC_CP_UTF8;

	// These options are intentionally fixed so the compiler hash and source
	// fingerprint identify one deterministic library compilation contract.
	Vector<String> argument_strings;
	argument_strings.push_back("-T");
	argument_strings.push_back(vformat("lib_%d_%d", p_shader_model / 10, p_shader_model % 10));
	argument_strings.push_back("-HV");
	argument_strings.push_back("2021");
	argument_strings.push_back("-Ges");
	argument_strings.push_back("-O3");
	argument_strings.push_back("-Zpc");

	Vector<Char16String> wide_arguments;
	Vector<LPCWSTR> argument_pointers;
	wide_arguments.resize(argument_strings.size());
	argument_pointers.resize(argument_strings.size());
	for (int i = 0; i < argument_strings.size(); i++) {
		wide_arguments.write[i] = argument_strings[i].utf16();
		argument_pointers.write[i] = (LPCWSTR)wide_arguments[i].get_data();
	}

	ComPtr<IDxcIncludeHandler> include_handler;
	HRESULT hr = impl->utils->CreateDefaultIncludeHandler(include_handler.GetAddressOf());
	if (FAILED(hr)) {
		r_error = vformat("DXC include handler creation failed (0x%08x).", uint32_t(hr));
		return false;
	}

	ComPtr<IDxcResult> result;
	hr = impl->compiler->Compile(&source_buffer, argument_pointers.ptrw(), argument_pointers.size(), include_handler.Get(),
			__uuidof(IDxcResult), (void **)result.GetAddressOf());
	if (FAILED(hr) || !result) {
		r_error = vformat("DXC library compilation call failed (0x%08x).", uint32_t(hr));
		return false;
	}

	String diagnostics = get_dxc_output_text(result.Get(), DXC_OUT_ERRORS);
	HRESULT compile_status = E_FAIL;
	result->GetStatus(&compile_status);
	if (FAILED(compile_status)) {
		r_error = vformat("DXC failed to compile the %s export '%s'.\n%s", get_stage_name(p_stage), p_export_name, diagnostics);
		return false;
	}

	ComPtr<IDxcBlob> object;
	hr = result->GetOutput(DXC_OUT_OBJECT, IID_PPV_ARGS(object.GetAddressOf()), nullptr);
	if (FAILED(hr) || !object || object->GetBufferSize() == 0 || object->GetBufferSize() > UINT32_MAX) {
		r_error = vformat("DXC returned no valid library object for export '%s' (0x%08x).", p_export_name, uint32_t(hr));
		return false;
	}

	ComPtr<IDxcOperationResult> validation_result;
	hr = impl->validator->Validate(object.Get(), 0, validation_result.GetAddressOf());
	if (FAILED(hr) || !validation_result) {
		r_error = vformat("DXIL validator could not validate library '%s' (0x%08x).", p_export_name, uint32_t(hr));
		return false;
	}
	HRESULT validation_status = E_FAIL;
	validation_result->GetStatus(&validation_status);
	if (FAILED(validation_status)) {
		ComPtr<IDxcBlobEncoding> validation_errors;
		String validation_message;
		if (SUCCEEDED(validation_result->GetErrorBuffer(validation_errors.GetAddressOf())) && validation_errors) {
			validation_message = String::utf8((const char *)validation_errors->GetBufferPointer(), (int)validation_errors->GetBufferSize());
		}
		r_error = vformat("DXIL validator rejected library '%s' (0x%08x). %s", p_export_name, uint32_t(validation_status), validation_message);
		return false;
	}
	ComPtr<IDxcBlob> validated_object;
	hr = validation_result->GetResult(validated_object.GetAddressOf());
	if (FAILED(hr) || !validated_object || validated_object->GetBufferSize() == 0 || validated_object->GetBufferSize() > UINT32_MAX) {
		r_error = vformat("DXIL validator returned no valid library for export '%s' (0x%08x).", p_export_name, uint32_t(hr));
		return false;
	}
	object = validated_object;

	ComPtr<IDxcContainerReflection> container_reflection;
	hr = impl->create_instance(CLSID_DxcContainerReflection, __uuidof(IDxcContainerReflection), (void **)container_reflection.GetAddressOf());
	if (FAILED(hr) || !container_reflection) {
		r_error = vformat("DXC container reflection creation failed (0x%08x).", uint32_t(hr));
		return false;
	}
	hr = container_reflection->Load(object.Get());
	if (FAILED(hr)) {
		r_error = vformat("DXC could not load the compiled library for reflection (0x%08x).", uint32_t(hr));
		return false;
	}

	UINT32 dxil_part_index = 0;
	hr = container_reflection->FindFirstPartKind(DXC_PART_DXIL, &dxil_part_index);
	if (FAILED(hr)) {
		r_error = vformat("DXC output has no DXIL part for export '%s'.", p_export_name);
		return false;
	}
	ComPtr<ID3D12LibraryReflection> library_reflection;
	hr = container_reflection->GetPartReflection(dxil_part_index, __uuidof(ID3D12LibraryReflection), (void **)library_reflection.GetAddressOf());
	if (FAILED(hr) || !library_reflection) {
		r_error = vformat("DXC library reflection failed (0x%08x).", uint32_t(hr));
		return false;
	}

	D3D12_LIBRARY_DESC library_desc = {};
	if (FAILED(library_reflection->GetDesc(&library_desc))) {
		r_error = "DXC library reflection returned an invalid library description.";
		return false;
	}

	ID3D12FunctionReflection *selected_function = nullptr;
	D3D12_FUNCTION_DESC selected_desc = {};
	uint32_t matching_function_count = 0;
	for (UINT i = 0; i < library_desc.FunctionCount; i++) {
		ID3D12FunctionReflection *function = library_reflection->GetFunctionByIndex((INT)i);
		if (!function) {
			continue;
		}
		D3D12_FUNCTION_DESC function_desc = {};
		if (FAILED(function->GetDesc(&function_desc)) || !function_desc.Name) {
			continue;
		}
		if (reflection_name_matches_export(function_desc.Name, p_export_name)) {
			matching_function_count++;
			selected_function = function;
			selected_desc = function_desc;
		}
	}
	if (!selected_function) {
		r_error = vformat("DXC library does not export the requested entry '%s'.", p_export_name);
		return false;
	}
	if (matching_function_count != 1) {
		r_error = vformat("DXC library has %d global functions matching the requested export '%s'; the export is ambiguous.", matching_function_count, p_export_name);
		return false;
	}
	if (D3D12_SHVER_GET_TYPE(selected_desc.Version) != expected_type) {
		r_error = vformat("DXC export '%s' is not the requested %s stage.", p_export_name, get_stage_name(p_stage));
		return false;
	}
	const uint32_t reflected_shader_model = D3D12_SHVER_GET_MAJOR(selected_desc.Version) * 10 + D3D12_SHVER_GET_MINOR(selected_desc.Version);
	if (reflected_shader_model != p_shader_model) {
		r_error = vformat("DXC export '%s' reflects shader model 6.%d, but profile 6.%d was requested.", p_export_name,
				D3D12_SHVER_GET_MINOR(selected_desc.Version), p_shader_model % 10);
		return false;
	}

	CompiledLibrary compiled;
	compiled.stage = p_stage;
	compiled.shader_model = reflected_shader_model;
	compiled.required_feature_flags = selected_desc.RequiredFeatureFlags;
	compiled.export_name = p_export_name;
	const uint32_t object_size = uint32_t(object->GetBufferSize());
	compiled.dxil_library.resize(object_size);
	memcpy(compiled.dxil_library.ptrw(), object->GetBufferPointer(), object_size);

	for (UINT i = 0; i < selected_desc.BoundResources; i++) {
		D3D12_SHADER_INPUT_BIND_DESC binding_desc = {};
		if (FAILED(selected_function->GetResourceBindingDesc(i, &binding_desc))) {
			r_error = vformat("DXC could not reflect active resource %d in export '%s'.", i, p_export_name);
			return false;
		}
		if (binding_desc.BindCount == 0 || binding_desc.BindCount == UINT32_MAX || binding_desc.BindPoint > UINT32_MAX - binding_desc.BindCount) {
			r_error = vformat("DXC export '%s' uses an unbounded or overflowing descriptor range, which the current D3D12 layout does not support.", p_export_name);
			return false;
		}
		uint32_t resource_class = 0;
		if (!get_resource_class(binding_desc.Type, resource_class)) {
			r_error = vformat("DXC export '%s' uses unsupported resource type %d ('%s'). Storage buffers must use ByteAddressBuffer/RWByteAddressBuffer.",
					p_export_name, uint32_t(binding_desc.Type), binding_desc.Name ? binding_desc.Name : "unnamed");
			return false;
		}

		NativeBinding binding;
		binding.set = binding_desc.Space;
		binding.binding = binding_desc.BindPoint;
		binding.resource_class = resource_class;
		binding.count = binding_desc.BindCount;
		switch (binding_desc.Type) {
			case D3D_SIT_CBUFFER: {
				binding.resource_kind = NATIVE_KIND_CONSTANT_BUFFER;
				if (!binding_desc.Name) {
					r_error = vformat("DXC returned an unnamed constant buffer in export '%s'.", p_export_name);
					return false;
				}
				ID3D12ShaderReflectionConstantBuffer *constant_buffer = selected_function->GetConstantBufferByName(binding_desc.Name);
				D3D12_SHADER_BUFFER_DESC constant_buffer_desc = {};
				if (!constant_buffer || FAILED(constant_buffer->GetDesc(&constant_buffer_desc))) {
					r_error = vformat("DXC could not reflect constant-buffer size for '%s' in export '%s'.", binding_desc.Name ? binding_desc.Name : "unnamed", p_export_name);
					return false;
				}
				binding.constant_buffer_size_bytes = constant_buffer_desc.Size;
			} break;
			case D3D_SIT_SAMPLER: {
				binding.resource_kind = NATIVE_KIND_SAMPLER;
			} break;
			case D3D_SIT_TEXTURE: {
				binding.resource_kind = NATIVE_KIND_SAMPLED_TEXTURE;
				if (!get_resource_dimension(binding_desc.Dimension, binding.resource_dimension)) {
					r_error = vformat("DXC export '%s' uses unsupported texture dimension %d.", p_export_name, uint32_t(binding_desc.Dimension));
					return false;
				}
			} break;
			case D3D_SIT_RTACCELERATIONSTRUCTURE: {
				// D3D_SIT_RTACCELERATIONSTRUCTURE identifies this binding kind. The
				// shader-reflection D3D_SRV_DIMENSION enum has no acceleration
				// structure value (the similarly named value belongs to
				// D3D12_SRV_DIMENSION), so don't interpret Dimension for this kind.
				binding.resource_kind = NATIVE_KIND_ACCELERATION_STRUCTURE;
				binding.resource_dimension = NATIVE_DIMENSION_ACCELERATION_STRUCTURE;
			} break;
			case D3D_SIT_BYTEADDRESS: {
				if (binding_desc.Dimension != D3D_SRV_DIMENSION_BUFFER) {
					r_error = vformat("DXC export '%s' reports an unexpected dimension for a ByteAddressBuffer.", p_export_name);
					return false;
				}
				binding.resource_kind = NATIVE_KIND_RAW_BUFFER;
				binding.resource_dimension = NATIVE_DIMENSION_BUFFER;
			} break;
			case D3D_SIT_UAV_RWTYPED: {
				binding.resource_kind = NATIVE_KIND_STORAGE_TEXTURE;
				if (!get_resource_dimension(binding_desc.Dimension, binding.resource_dimension)) {
					r_error = vformat("DXC export '%s' uses unsupported writable texture dimension %d.", p_export_name, uint32_t(binding_desc.Dimension));
					return false;
				}
			} break;
			case D3D_SIT_UAV_RWBYTEADDRESS: {
				if (binding_desc.Dimension != D3D_SRV_DIMENSION_BUFFER) {
					r_error = vformat("DXC export '%s' reports an unexpected dimension for an RWByteAddressBuffer.", p_export_name);
					return false;
				}
				binding.resource_kind = NATIVE_KIND_RAW_BUFFER;
				binding.resource_dimension = NATIVE_DIMENSION_BUFFER;
			} break;
			default: {
				r_error = vformat("DXC export '%s' uses unsupported resource type %d.", p_export_name, uint32_t(binding_desc.Type));
				return false;
			} break;
		}
		compiled.active_bindings.push_back(binding);
	}

	r_library = compiled;
	return true;
}
