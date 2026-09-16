// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>

// The terrain's CPU work is invisible to the engine's own profiler, because the node runs as
// a GDExtension method rather than an instrumented engine function. It is published instead
// through the profiler singleton the engine exposes, under names that all start with
// `terrain/` so a timeline can tell the terrain apart from everything else.
//
// Nothing is emitted while no profiler client is attached, and the singleton is looked up
// once per frame rather than once per zone, so a shipping build pays a frame check.
//
// The singleton keeps one last-in-first-out stack per thread, so a zone has to be closed on
// the thread that opened it: every user holds this as a scope guard and lets it close the
// zone, including from a function with several early returns. Subsystems that run outside the
// node's own tick - the geometry backend, which the rendering server drives - include this
// header and emit their own `terrain/...` zones.
class TerrainProfileZone {
public:
	explicit TerrainProfileZone(const char *p_name) {
		_profiler = profiler();
		if (_profiler) {
			_profiler->call("begin_zone", String("terrain/") + p_name);
		}
	}
	~TerrainProfileZone() {
		if (_profiler) {
			_profiler->call("end_zone");
		}
	}
	TerrainProfileZone(const TerrainProfileZone &) = delete;
	TerrainProfileZone &operator=(const TerrainProfileZone &) = delete;

	// The profiler object while a client is connected, otherwise nullptr.
	static Object *profiler() {
		// The lookup is cached per frame and per thread: the node's tick runs on the main
		// thread while the geometry backend can run on the rendering thread, and the two
		// must not share a mutable cache.
		static thread_local Object *cached = nullptr;
		static thread_local uint64_t checked_frame = UINT64_MAX;
		Engine *engine = Engine::get_singleton();
		const uint64_t frame = engine ? engine->get_process_frames() : 0;
		if (frame == checked_frame) {
			return cached;
		}
		checked_frame = frame;
		cached = nullptr;
		const StringName singleton_name("FengGodotTracy");
		if (!engine || !engine->has_singleton(singleton_name)) {
			return cached;
		}
		Object *profiler_object = engine->get_singleton(singleton_name);
		if (!profiler_object || !profiler_object->has_method("is_started") ||
				!profiler_object->has_method("begin_zone") || !profiler_object->has_method("end_zone")) {
			return cached;
		}
		if (!bool(profiler_object->call("is_started"))) {
			return cached;
		}
		// A profiler can be started in on-demand mode with nobody connected yet; emitting
		// then would cost the game for an empty timeline.
		if (profiler_object->has_method("is_profiler_connected") &&
				!bool(profiler_object->call("is_profiler_connected"))) {
			return cached;
		}
		cached = profiler_object;
		return cached;
	}

	static void plot(const char *p_name, double p_value) {
		Object *profiler_object = profiler();
		if (profiler_object && profiler_object->has_method("plot")) {
			profiler_object->call("plot", String("terrain/") + p_name, p_value);
		}
	}

private:
	Object *_profiler = nullptr;
};
