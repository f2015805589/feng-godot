// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_VIEWS_INTERNAL_H
#define TERRAIN3D_SURFACE_VIEWS_INTERNAL_H

#include "terrain_3d.h"

namespace {
// The source wake flush both demand passes owe: the workers a pass submitted to are woken when it
// is over, not in the middle of it. It is a guard whose destructor covers every return path, so it
// cannot be a call at the end of the pass.
//
// It is one definition here rather than a local struct in each pass because the two passes have to
// agree on it, and a copy is exactly where the two would drift apart. The anonymous namespace is
// deliberate and differs from the two earlier internal headers, whose symbols a half calls by name:
// here it keeps each translation unit's copy internal, exactly as the local struct it replaces was,
// and leaves both call sites byte-identical to the file this was split out of.
//
// `_flush_source_wakes_unless_ticking()` is public in terrain_3d.h, so the guard needs no
// friendship. The three halves that include this:
//   terrain_3d_surface_views.cpp      the view objects and their settings
//   terrain_3d_surface_views_far.cpp  the far field's demand pass
//   terrain_3d_surface_views_near.cpp the near field's demand pass, its feedback pass and the sectors
struct SourceWakeFlush {
	Terrain3D *terrain;
	~SourceWakeFlush() { terrain->_flush_source_wakes_unless_ticking(); }
};
} // namespace

#endif // TERRAIN3D_SURFACE_VIEWS_INTERNAL_H
