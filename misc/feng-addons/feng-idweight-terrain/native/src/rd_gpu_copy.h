#pragma once

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/rid.hpp>

// The fork-local engine capability this project builds on: copying a texture region straight from
// a device buffer, so content a compute pass produced reaches the texture it is sampled from
// without a CPU round trip. The engine side is `RenderingDevice::texture_copy_from_buffer`, added
// by `servers/rendering/rendering_device_gpu_buffer_copy.cpp` (see the addon's
// `docs/engine_patch_surface.md` for the whole patch surface).
//
// It is resolved by name at runtime, so nothing here is a link-time dependency on the fork: on a
// stock engine, or on a fork whose method signature has moved on, `available()` reports false and
// the caller keeps its readback path. That is the whole point of the indirection - the terrain
// must still produce pages on an engine without the patch, just with the extra frame of latency.
namespace FengRDGpuCopy {

// Whether the engine this process runs on carries the method. Cheap after the first call.
bool available(godot::RenderingDevice *p_device);

// Copies `p_region` texels of `p_texture` from `p_buffer`, at `p_buffer_offset` bytes with
// `p_row_pitch` bytes per row. Must be called where recording is allowed (between passes, not
// inside a draw or compute list), and the destination texture needs the engine's
// `TEXTURE_USAGE_CAN_COPY_TO_BIT`.
godot::Error copy(godot::RenderingDevice *p_device, const godot::RID &p_texture, const godot::RID &p_buffer,
		uint64_t p_buffer_offset, uint32_t p_row_pitch, uint32_t p_layer, uint32_t p_mipmap,
		const godot::Rect2i &p_region);

} // namespace FengRDGpuCopy
