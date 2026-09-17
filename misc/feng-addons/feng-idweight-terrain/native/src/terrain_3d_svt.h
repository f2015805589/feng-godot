// SVT demand pass data types.
//
// The far field's demand pass scans the visible regions, walks their footprints into pages, and plans
// the root pyramid those pages fall back to. Its stages are member functions, and two of them hand
// each other the records below, so the records live here rather than nested inside the pass - the same
// reason terrain_3d_avt.h gives for the near field's plan types.
//
// No algorithm belongs in this file.

#ifndef TERRAIN3D_SVT_TYPES_H
#define TERRAIN3D_SVT_TYPES_H

// The visibility header comes first on purpose: it pulls in the Godot class headers, and in this
// GDExtension version the `variant/` headers alone do not define `Rect2` or `Vector2` for a
// translation unit that has not included a class header yet. This header is included first by
// terrain_3d_vt_demand.cpp, so it cannot rely on someone else having done it.
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

// One region the view can see: the world rect it covers, the height bounds it was sampled with, how
// far the view is from it and from its farthest corner, and the footprint the view resolved for it.
struct Terrain3DSVTRegion {
	godot::Rect2 rect;
	godot::Vector2 heights;
	float distance = 0.f;
	float farthest = 0.f;
	TerrainVT::VisiblePatch visible;
};

// One page a visible footprint resolves to: its world-aligned address in mip 0 page coordinates, the
// mip the view selected for it, and how far the footprint that asked for it is.
struct Terrain3DSVTPage {
	godot::Vector2i address;
	int mip = 0;
	float distance = 0.f;
};

#endif // TERRAIN3D_SVT_TYPES_H
