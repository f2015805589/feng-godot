// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_BAKED_TEXTURE_ARRAYS_H
#define TERRAIN3D_BAKED_TEXTURE_ARRAYS_H

#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <vector>

namespace godot {
class RenderingDevice;
class RenderingServer;
}

// The clipmap ring, atlas and detail cache own identically formatted baked channels.
// They retain the RIDs and decide when allocation, publication and teardown are safe;
// these functions only perform the device work, on the caller's existing thread.
namespace terrain_baked_arrays {

// Release all wrappers before any device textures, then forget both inventories.
// Null server/device pointers are allowed during shutdown, as in the owners' teardown.
void clear(godot::RenderingServer *p_server, godot::RenderingDevice *p_rd,
		std::vector<godot::RID> &r_device, std::vector<godot::RID> &r_shader);

// Replace the inventories with uninitialised RGBA16F storage/sampling arrays. Owners
// gate reads on bake readiness; blank initial uploads would serve no reader. At least
// two layers are required by RenderingServer's layered wrapper, even for one slice.
// Requires a live server/device and positive dimensions/count. Returns -1 on success
// or the failed channel index; any failure leaves both inventories empty. The owner
// retains its own logging and retry/fallback policy.
int create(godot::RenderingServer *p_server, godot::RenderingDevice *p_rd,
		int p_width, int p_height, int p_layers, int p_channels, const godot::String &p_name,
		std::vector<godot::RID> &r_device, std::vector<godot::RID> &r_shader);

} // namespace terrain_baked_arrays

#endif // TERRAIN3D_BAKED_TEXTURE_ARRAYS_H
