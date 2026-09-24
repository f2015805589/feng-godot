// Copyright © 2026 Terrain3D contributors.

#ifndef TERRAIN3D_VT_SERVICE_INTERNAL_H
#define TERRAIN3D_VT_SERVICE_INTERNAL_H

#include "terrain_3d_data.h"
#include "terrain_3d_surface_baker.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

// The prologue the four translation units of the virtual texture service share. It is a header
// rather than a fifth .cpp because the two helpers are needed by different halves and a second copy
// would be a second cast and a second corner-capture:
//
//   * `baker()` turns the stored `Ref<RefCounted>` into the producer. Every half holds one, so
//     it is the one way that cast is written.
//   * `bake_source_grid()` captures a page's source corners, the ids and the height, so a bake
//     and a runtime page built from the same payload agree on where the corners are. The cell
//     store half and the bake half both call it.
//
// Both are `inline`, so all four units share the one definition. The four halves are:
//   terrain_3d_vt_service.cpp         the settings and the service's lifetime
//   terrain_3d_vt_service_pages.cpp   page invalidation, the material page queue, the cell store
//   terrain_3d_vt_service_report.cpp  the diagnostics the dock, inspector and tests read
//   terrain_3d_vt_service_bake.cpp    the far field's bake and its cell files
//
// Include this after terrain_3d.h and add `using namespace terrain_surface_vt;`. The node header
// itself is *not* included here: both helpers below work on the data object and the producer, so a
// header that only wants them does not have to pull the node, its state and its clipmap in.
namespace terrain_surface_vt {

inline Terrain3DSurfaceBaker *baker(const Ref<RefCounted> &p_ref) {
	return Object::cast_to<Terrain3DSurfaceBaker>(p_ref.ptr());
}

// Preserve source corner IDs instead of nearest-resampling them onto output pixels.
inline Vector3 bake_source_grid(Terrain3DData *data, const Rect2 &rect, int size, int border,
		float source_step, Ref<Image> &ids, Ref<Image> &height) {
	const float pixel = rect.size.x / size;
	if (pixel > source_step) { return Vector3(); } // Existing minified source path.
	const int stored = size + 2 * border;
	const Vector2 origin = ((rect.position - Vector2(pixel, pixel) * border) / source_step).floor() * source_step;
	const Vector2 end = rect.get_end() + Vector2(pixel, pixel) * border;
	const int extent = MIN(stored, int(Math::ceil(MAX(end.x - origin.x, end.y - origin.y) / source_step)) + 2);
	const Rect2 source_rect(origin - Vector2(source_step, source_step) * .5f, Vector2(extent, extent) * source_step);
	Ref<Image> corners;
	if (data->produce_surface_rect_page(source_rect, extent, 0, corners) < 0) { return Vector3(); }
	Ref<Image> heights = data->make_vt_height_page(source_rect, extent, 0);
	if (heights.is_null()) { return Vector3(); }
	ids = Image::create_empty(stored, stored, false, corners->get_format());
	height = Image::create_empty(stored, stored, false, heights->get_format());
	ids->blit_rect(corners, Rect2i(0, 0, extent, extent), Vector2i());
	height->blit_rect(heights, Rect2i(0, 0, extent, extent), Vector2i());
	return Vector3(origin.x, origin.y, source_step);
}

} // namespace terrain_surface_vt

#endif // TERRAIN3D_VT_SERVICE_INTERNAL_H
