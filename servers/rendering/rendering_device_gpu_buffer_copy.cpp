/**************************************************************************/
/*  rendering_device_gpu_buffer_copy.cpp                                  */
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

// Fork-local file. The whole of this engine-side addition lives here plus a declaration in
// `rendering_device.h` and one binding in `rendering_device.cpp`; `servers/rendering/SCsub`
// compiles this directory with a `*.cpp` glob, so no build file mentions it. Keeping the code
// in its own translation unit is deliberate: an engine upgrade only has to re-apply the two
// one-line edits outside this file. See `misc/feng-addons/feng-idweight-terrain/docs/
// engine_patch_surface.md`.

#include "rendering_device.h"
#include "rendering_device_graph.h"

// `rendering_device.cpp` defines these for its own translation unit; the guard is repeated here
// because it has to hold for this entry point too, and a macro cannot be shared across files.
#define ERR_RENDER_THREAD_MSG String("This function (") + String(__func__) + String(") can only be called from the render thread. ")
#define ERR_RENDER_THREAD_GUARD_V(m_ret) ERR_FAIL_COND_V_MSG(render_thread_id != Thread::get_caller_id(), (m_ret), ERR_RENDER_THREAD_MSG);

// Copies a region of a texture straight from a device buffer. This is the primitive an upload
// path needs when the content was produced on the GPU: `texture_update()` takes CPU bytes, so a
// page a compute pass just encoded has to be read back to the CPU and uploaded again, which
// costs the frame in between. A block compressed texture cannot be a storage image either, so
// the readback used to be unavoidable - this records the same copy the upload path records
// (`RDG::TYPE_TEXTURE_UPDATE`, i.e. a buffer to image copy on both backends) with the producer's
// buffer as the source, and the resource tracker that goes with it.
//
// The consequence that matters to a producer: the copy is part of the submission the producing
// command is in, so once it is recorded the texture holds the content, and a page table may name
// the slot on the same frame instead of a few frames later.
Error RenderingDevice::texture_copy_from_buffer(RID p_texture, RID p_buffer, uint64_t p_buffer_offset, uint32_t p_row_pitch, uint32_t p_layer, uint32_t p_mipmap, const Rect2i &p_region) {
	ERR_RENDER_THREAD_GUARD_V(ERR_UNAVAILABLE);

	ERR_FAIL_COND_V_MSG(draw_list.active, ERR_INVALID_PARAMETER, "Copying into a texture is forbidden during creation of a draw list.");
	ERR_FAIL_COND_V_MSG(compute_list.active, ERR_INVALID_PARAMETER, "Copying into a texture is forbidden during creation of a compute list.");
	ERR_FAIL_COND_V_MSG(raytracing_list.active, ERR_INVALID_PARAMETER, "Copying into a texture is forbidden during creation of a raytracing list.");

	Texture *texture = texture_owner.get_or_null(p_texture);
	ERR_FAIL_NULL_V(texture, ERR_INVALID_PARAMETER);

	if (texture->owner != RID()) {
		p_texture = texture->owner;
		texture = texture_owner.get_or_null(texture->owner);
		ERR_FAIL_NULL_V(texture, ERR_BUG); // This is a bug.
	}

	Buffer *buffer = _get_buffer_from_owner(p_buffer);
	ERR_FAIL_NULL_V_MSG(buffer, ERR_INVALID_PARAMETER, "Buffer is invalid.");

	ERR_FAIL_COND_V_MSG(p_row_pitch == 0, ERR_INVALID_PARAMETER, "Row pitch must be non-zero.");
	ERR_FAIL_COND_V_MSG(p_region.size.x <= 0 || p_region.size.y <= 0, ERR_INVALID_PARAMETER, "Copy region must not be empty.");
	ERR_FAIL_COND_V_MSG(p_region.position.x < 0 || p_region.position.y < 0, ERR_INVALID_PARAMETER, "Copy region must be inside the destination texture.");
	ERR_FAIL_COND_V_MSG(!(texture->usage_flags & (TEXTURE_USAGE_CAN_COPY_TO_BIT | TEXTURE_USAGE_CAN_UPDATE_BIT)), ERR_INVALID_PARAMETER,
			"Destination texture requires the `RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT` or `RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT` flag to be a copy destination.");

	RDD::BufferTextureCopyRegion copy_region;
	copy_region.buffer_offset = p_buffer_offset;
	copy_region.row_pitch = p_row_pitch;
	copy_region.texture_subresource.aspect = RDD::TEXTURE_ASPECT_COLOR;
	copy_region.texture_subresource.mipmap = p_mipmap;
	copy_region.texture_subresource.layer = p_layer;
	copy_region.texture_offset = Vector3i(p_region.position.x, p_region.position.y, 0);
	copy_region.texture_region_size = Vector3i(p_region.size.x, p_region.size.y, 1);

	RDG::RecordedBufferToTextureCopy buffer_to_texture_copy;
	buffer_to_texture_copy.from_buffer = buffer->driver_id;
	buffer_to_texture_copy.region = copy_region;

	// The source was written by an earlier command of this submission (a compute dispatch, for
	// the producer this exists for), so its tracker travels with the copy: the graph orders the
	// copy after that write and barriers the two. An upload that filled its staging buffer from
	// the CPU passes no tracker, because no command on the GPU produced that content.
	RDG::ResourceTracker *buffer_tracker = buffer->draw_tracker;

	if (_texture_make_mutable(texture, p_texture)) {
		// The texture must be mutable to be used as a copy destination.
		draw_graph.add_synchronization();
	}

	if (buffer_tracker != nullptr) {
		draw_graph.add_texture_update(texture->driver_id, texture->draw_tracker, VectorView(buffer_to_texture_copy), VectorView(&buffer_tracker, 1));
	} else {
		draw_graph.add_texture_update(texture->driver_id, texture->draw_tracker, VectorView(buffer_to_texture_copy));
	}

	return OK;
}
