// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_DEBUG_H
#define TERRAIN3D_DEBUG_H

// The debug levels, and the one global level the LOG() macro filters on.
//
// They live beside the logger rather than inside Terrain3D because `logger.h` is included by nearly
// every translation unit and used to reach them through `terrain_3d.h`: that one include pulled the
// node class, its VT state and the clipmap headers into every file that only wanted to print. The
// level is still `Terrain3D::debug_level` - the class aliases this enum and owns the value - so the
// bound property, the setter and every `Terrain3D::debug_level` reader are unchanged.

namespace Terrain3DDebug {

enum Level {
	MESG = -2, // Always print except in release builds
	WARN = -1, // Always print except in release builds
	ERROR = 0, // Always print except in release builds
	INFO = 1, // Print every function call and important entries
	DEBUG = 2, // Print details within functions
	EXTREME = 3, // Continuous operations like snapping
};

} // namespace Terrain3DDebug

constexpr Terrain3DDebug::Level MESG = Terrain3DDebug::Level::MESG;
constexpr Terrain3DDebug::Level WARN = Terrain3DDebug::Level::WARN;
constexpr Terrain3DDebug::Level ERROR = Terrain3DDebug::Level::ERROR;
constexpr Terrain3DDebug::Level INFO = Terrain3DDebug::Level::INFO;
constexpr Terrain3DDebug::Level DEBUG = Terrain3DDebug::Level::DEBUG;
constexpr Terrain3DDebug::Level EXTREME = Terrain3DDebug::Level::EXTREME;

// The level LOG() filters on, so a translation unit that only prints does not have to see the class
// that owns it. Defined in terrain_3d_debug.cpp.
int terrain3d_debug_level();

#endif // TERRAIN3D_DEBUG_H
