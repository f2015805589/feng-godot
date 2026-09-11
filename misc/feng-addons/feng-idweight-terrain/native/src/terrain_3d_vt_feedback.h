// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_FEEDBACK_CLASS_H
#define TERRAIN3D_VT_FEEDBACK_CLASS_H

#include <vector>

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/projection.hpp>

#include "constants.h"

/**
 * GPU page demand for the surface virtual texture.
 *
 * The CPU distance rule cannot see the camera: it does not know the field of view, the
 * resolution, the viewing angle, or what is off screen. This runs a compute pass that
 * projects every candidate page, measures its screen extent and writes the local mip
 * that would put roughly one page texel on one screen pixel, or NO_REQUEST when the
 * page is behind the camera, off screen or too small to matter.
 *
 * It uses its own local RenderingDevice (RenderingServer::create_local_rendering_device)
 * so it cannot disturb the main renderer's frame, and reads the result back
 * asynchronously with RenderingDevice::texture_get_data_async. The result of a dispatch
 * is therefore only available a few frames later, which is what the caller's
 * `is_readback_pending()` check is for.
 *
 * The output grid is one texel per candidate page: `chunk_origin` plus
 * grid_width x grid_height chunks, `pages_per_axis` squared pages each. A texel holds
 * `mip + 1`, or NO_REQUEST.
 */
class Terrain3DVTFeedback : public Object {
	GDCLASS(Terrain3DVTFeedback, Object);
	CLASS_NAME();

public:
	static inline const uint32_t NO_REQUEST = 0xFFFFFFFFu;
	// Diagnostic sentinels the shader writes for its early-outs, so a caller can tell
	// which branch fired. Kept in sync with the GLSL by hand; read them back with
	// get_raw().
	static inline const uint32_t REJECT_BEHIND = 0xFFFFFFFEu;
	static inline const uint32_t REJECT_OFFSCREEN = 0xFFFFFFFDu;
	static inline const uint32_t REJECT_TOO_SMALL = 0xFFFFFFFCu;
	// Pages whose screen extent is below this many pixels are left to the texture array.
	static inline const real_t DEFAULT_MIN_SCREEN_EXTENT = 8.f;

private:
	RenderingDevice *_rd = nullptr;
	RID _shader;
	RID _pipeline;
	RID _texture;
	RID _params;
	RID _uniform_set;
	int _grid_width = 0;
	int _grid_height = 0;

	// Readback
	bool _dispatched = false;
	bool _submitted = false;
	bool _readback_pending = false;
	PackedByteArray _result;
	std::vector<int> _mips;

	// Diagnostics
	int _dispatch_count = 0;
	int _readback_count = 0;
	int _request_count = 0;

	void _on_readback(const PackedByteArray &p_data);
	void _decode();
	void _free_rd_resources();

public:
	Terrain3DVTFeedback() {}
	~Terrain3DVTFeedback() { clear(); }

	Error initialize(const int p_grid_width, const int p_grid_height);
	void clear();
	bool is_initialized() const { return _rd != nullptr && _texture.is_valid(); }

	// `p_view_projection` maps a world position as (x, 0, z, 1) to clip space.
	Error dispatch(const Projection &p_view_projection, const int p_pages_per_axis,
			const real_t p_region_size, const real_t p_page_world_size, const int p_page_size,
			const int p_max_local_mip, const Vector2i &p_chunk_origin,
			const Vector2i &p_viewport_size,
			const real_t p_min_screen_extent = DEFAULT_MIN_SCREEN_EXTENT);

	// Queues the asynchronous download into the frame dispatch() just submitted. The
	// callback fires during the following sync(), so the result is one frame late,
	// which is the usual feedback latency.
	Error request_readback();
	// Completes the outstanding submit and delivers the readback callback. A local
	// device has no frame advance of its own, so this is the only place the download
	// is flushed.
	Error sync();
	bool is_readback_pending() const { return _readback_pending; }
	bool has_result() const { return !_result.is_empty(); }
	// Local mip for a grid position, or -1 when the pass asked for no page there.
	int get_mip(const int p_grid_x, const int p_grid_y) const;
	// The raw 32-bit output, including the diagnostic early-out sentinels.
	uint32_t get_raw(const int p_grid_x, const int p_grid_y) const;
	int get_request_count() const { return _request_count; }
	int get_grid_width() const { return _grid_width; }
	int get_grid_height() const { return _grid_height; }
	// True when the local mip for this chunk and page is finer than `p_mip`.
	int get_mip_for_page(const Vector2i &p_chunk, const int p_pages_per_axis, const int p_page_x,
			const int p_page_y, const Vector2i &p_chunk_origin) const;

	Dictionary get_stats() const;
	void reset_stats();

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_VT_FEEDBACK_CLASS_H
