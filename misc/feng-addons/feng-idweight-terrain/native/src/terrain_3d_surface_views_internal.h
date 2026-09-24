// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_SURFACE_VIEWS_INTERNAL_H
#define TERRAIN3D_SURFACE_VIEWS_INTERNAL_H

class Terrain3D;

// Wakes the workers a demand pass submitted to, once the pass is over. The implementation is
// `Terrain3D::_flush_source_wakes_unless_ticking()`; naming it through a free function is what lets
// the guard below - and so the four halves that include this header - need the node *declared*
// rather than defined. The node header used to be included here for this one symbol, which dragged
// the node, its VT state and its clipmap into every file that only wanted the guard.
void flush_source_wakes_unless_ticking(Terrain3D *p_terrain);

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
// The four halves that include this:
//   terrain_3d_surface_views.cpp          the view objects and their settings
//   terrain_3d_surface_views_far.cpp      the far field's pass and its level rule
//   terrain_3d_surface_views_far_walk.cpp the far field's root plan, visible walk and demand pass
//   terrain_3d_surface_views_near.cpp     the near field's demand pass, its feedback pass and the sectors
struct SourceWakeFlush {
	Terrain3D *terrain;
	~SourceWakeFlush() { flush_source_wakes_unless_ticking(terrain); }
};
} // namespace

#endif // TERRAIN3D_SURFACE_VIEWS_INTERNAL_H
