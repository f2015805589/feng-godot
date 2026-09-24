// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The one function terrain_3d_debug.h declares: the bridge from a translation unit that only prints
// to the level the Terrain3D node owns. It is the only file that needs both halves.

#include "terrain_3d_debug.h"

#include "terrain_3d.h"

int terrain3d_debug_level() {
	return int(Terrain3D::debug_level);
}
