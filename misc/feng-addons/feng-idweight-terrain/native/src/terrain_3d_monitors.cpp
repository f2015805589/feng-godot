// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D, part 3 of 3: this node's custom Performance monitors.

// One of three files that define the node. `_register_debug_monitors()` publishes the terrain's
// own cost beside the engine's, under ids that all start with `terrain/` because the editor's
// monitor graph uses that prefix as the group name; a second terrain in a scene publishes under
// its instance id instead. `_unregister_debug_monitors()` has to run before the node is freed,
// since every monitor calls back into it.
//
// The four callbacks here read the values that live in this node's own members; the other
// monitor callbacks the table names are defined beside the data they read (the VT service and the
// terrain mesher).
//
// The other two: `terrain_3d.cpp` (the node and its frame schedule) and
// `terrain_3d_wiring.cpp` (the subsystem nodes and GPU objects).

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_surface_baker.h"

#include <godot_cpp/classes/performance.hpp>

///////////////////////////
// Private Functions
///////////////////////////

// Publishes this node's cost as custom monitors. Every id starts with `terrain/`, which the
// editor's monitor graph uses as the group name, so a graph can show the terrain's own CPU
// and memory beside the engine's numbers instead of an unattributed spike. Units are the ones
// the editor formats: seconds for MONITOR_TYPE_TIME, bytes for MONITOR_TYPE_MEMORY.
void Terrain3D::_register_debug_monitors() {
	if (_monitors_registered) {
		return;
	}
	Performance *performance = Performance::get_singleton();
	if (!performance) {
		return;
	}
	// A second terrain in the same scene would collide on the plain names, so everything after
	// the first publishes under its instance id - still inside the `terrain` group.
	_monitor_prefix = performance->has_custom_monitor(StringName("terrain/vt_cpu"))
			? "terrain/" + String::num_int64(get_instance_id()) + "/"
			: "terrain/";
	// `Performance::MONITOR_TYPE_*` is not in the generated binding, so the ids the engine
	// binds are spelled out here; they decide how the editor formats a value.
	constexpr int MONITOR_TYPE_QUANTITY = 0;
	constexpr int MONITOR_TYPE_MEMORY = 1;
	constexpr int MONITOR_TYPE_TIME = 2;
	struct MonitorEntry {
		const char *name;
		Callable callable;
		int type;
	};
	const MonitorEntry entries[] = {
		{ "vt_cpu", callable_mp(this, &Terrain3D::_monitor_vt_cpu_ms), MONITOR_TYPE_TIME },
		{ "vt_cpu_peak", callable_mp(this, &Terrain3D::_monitor_vt_peak_ms), MONITOR_TYPE_TIME },
		{ "avt_cpu", callable_mp(this, &Terrain3D::_monitor_avt_cpu_ms), MONITOR_TYPE_TIME },
		{ "svt_cpu", callable_mp(this, &Terrain3D::_monitor_svt_cpu_ms), MONITOR_TYPE_TIME },
		{ "cdlod_cpu", callable_mp(this, &Terrain3D::_monitor_cdlod_cpu_ms), MONITOR_TYPE_TIME },
		{ "material_bytes", callable_mp(this, &Terrain3D::_monitor_material_bytes), MONITOR_TYPE_MEMORY },
		{ "pages_ready", callable_mp(this, &Terrain3D::_monitor_pages_ready), MONITOR_TYPE_QUANTITY },
		{ "pages_pending", callable_mp(this, &Terrain3D::_monitor_pages_pending), MONITOR_TYPE_QUANTITY },
		{ "pages_late", callable_mp(this, &Terrain3D::_monitor_pages_late), MONITOR_TYPE_QUANTITY },
	};
	for (const MonitorEntry &entry : entries) {
		// The generated binding exposes three arguments, so the monitor type is passed through
		// a dynamic call; without it the editor shows every value as a bare number.
		const StringName id(_monitor_prefix + entry.name);
		if (performance->has_custom_monitor(id)) {
			continue;
		}
		const Variant arguments[4] = { id, entry.callable, Array(), entry.type };
		const Variant *argv[4] = { &arguments[0], &arguments[1], &arguments[2], &arguments[3] };
		Variant target(performance);
		Variant result;
		GDExtensionCallError error;
		target.callp("add_custom_monitor", argv, 4, result, error);
		if (error.error != GDEXTENSION_CALL_OK) {
			LOG(WARN, "Could not publish the ", String(entry.name), " terrain monitor");
		}
	}
	_monitors_registered = true;
}

void Terrain3D::_unregister_debug_monitors() {
	if (!_monitors_registered) {
		return;
	}
	_monitors_registered = false;
	Performance *performance = Performance::get_singleton();
	if (!performance) {
		return;
	}
	// The monitors call back into this node, so they have to be gone before it is freed.
	for (const char *name : { "vt_cpu", "vt_cpu_peak", "avt_cpu", "svt_cpu", "cdlod_cpu",
				 "material_bytes", "pages_ready", "pages_pending", "pages_late" }) {
		const StringName id(_monitor_prefix + name);
		if (performance->has_custom_monitor(id)) {
			performance->remove_custom_monitor(id);
		}
	}
}

double Terrain3D::_monitor_cdlod_cpu_ms() const {
	return _terrain_mesher ? _terrain_mesher->get_cdlod_cpu_ms() : 0.0;
}

int64_t Terrain3D::_monitor_material_bytes() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_material_bytes() : 0;
}

int64_t Terrain3D::_monitor_pages_ready() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_ready_page_count() : 0;
}

int64_t Terrain3D::_monitor_pages_pending() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_pending_page_count() : 0;
}
