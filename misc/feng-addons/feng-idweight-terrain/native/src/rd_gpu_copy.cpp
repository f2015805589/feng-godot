#include "rd_gpu_copy.h"

#include <godot_cpp/core/engine_ptrcall.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

namespace {

// `texture_copy_from_buffer(texture: RID, buffer: RID, buffer_offset: int, row_pitch: int,
// layer: int, mipmap: int, region: Rect2i) -> Error`. Taken from this fork's own
// `--dump-extension-api` output; the engine compares it against the bound method's signature
// hash, so a mismatch resolves to no method at all rather than to a wrong call. Refresh it if
// the engine-side signature is ever changed (the extension then silently uses the readback path
// until it is).
constexpr uint32_t TEXTURE_COPY_FROM_BUFFER_HASH = 1147505037u;

GDExtensionMethodBindPtr g_bind = nullptr;
GDExtensionObjectPtr g_device = nullptr;
bool g_resolved = false;

void resolve(RenderingDevice *p_device) {
	g_resolved = true;
	if (p_device == nullptr || !p_device->has_method("texture_copy_from_buffer")) {
		return;
	}
	g_bind = internal::gdextension_interface_classdb_get_method_bind(
			RenderingDevice::get_class_static()._native_ptr(),
			StringName("texture_copy_from_buffer")._native_ptr(),
			TEXTURE_COPY_FROM_BUFFER_HASH);
	if (g_bind == nullptr) {
		return;
	}
	// The device is the singleton the whole renderer uses, so its object pointer is resolved
	// once and reused: a call is then a plain pointer call with no Variant marshalling.
	g_device = internal::gdextension_interface_object_get_instance_from_id(p_device->get_instance_id());
	if (g_device == nullptr) {
		g_bind = nullptr;
	}
}

} // namespace

bool FengRDGpuCopy::available(RenderingDevice *p_device) {
	if (!g_resolved) {
		resolve(p_device);
	}
	return g_bind != nullptr;
}

Error FengRDGpuCopy::copy(RenderingDevice *p_device, const RID &p_texture, const RID &p_buffer,
		uint64_t p_buffer_offset, uint32_t p_row_pitch, uint32_t p_layer, uint32_t p_mipmap,
		const Rect2i &p_region) {
	if (!available(p_device)) {
		return ERR_UNAVAILABLE;
	}
	// Every integer argument travels as the 64 bit form the method bind expects.
	const int64_t offset = int64_t(p_buffer_offset);
	const int64_t pitch = int64_t(p_row_pitch);
	const int64_t layer = int64_t(p_layer);
	const int64_t mipmap = int64_t(p_mipmap);
	return (Error)internal::_call_native_mb_ret<int64_t>(g_bind, g_device, &p_texture, &p_buffer,
			&offset, &pitch, &layer, &mipmap, &p_region);
}
