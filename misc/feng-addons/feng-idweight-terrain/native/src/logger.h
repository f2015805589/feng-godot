// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef LOGGER_CLASS_H
#define LOGGER_CLASS_H

#include <godot_cpp/variant/utility_functions.hpp>

#include "constants.h"
#include "terrain_3d_debug.h"

/**
 * Prints warnings, errors, and messages to the console.
 * Regular messages are filtered based on the user specified debug level.
 * Warnings and errors always print except in release builds.
 * EXTREME is for continuously called prints like inside snapping.
 * See `Terrain3DDebug::Level` and `Terrain3D::debug_level`.
 *
 * The level is read through `terrain3d_debug_level()` rather than through `Terrain3D` itself: this
 * header is included by nearly every translation unit, and reaching the class from here dragged the
 * node, its VT state and the clipmap headers into all of them.
 *
 * Note that in DEBUG mode Godot will crash on quit due to an
 * access violation in editor_log.cpp EditorLog::_process_message().
 * This is most likely caused by us printing messages as Godot is
 * attempting to quit.
 */

#ifdef DEBUG_ENABLED
#define LOG_ENABLED(level) ((level) == ERROR || (level) == WARN || (level) <= terrain3d_debug_level())
#define LOG(level, ...) \
	do { \
		if (level == ERROR) \
			UtilityFunctions::push_error(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__); \
		else if (level == WARN) \
			UtilityFunctions::push_warning(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__); \
		else if (level <= terrain3d_debug_level()) \
			UtilityFunctions::print(__class__, ":", __func__, ":", __LINE__, ": ", __VA_ARGS__); \
	} while (false); // Macro safety
#else
#define LOG_ENABLED(level) false
#define LOG(...)
#endif

#endif // LOGGER_CLASS_H
