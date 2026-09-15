#include "feng_godottracy.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"
#include "core/os/mutex.h"
#include "core/os/os.h"
#include "core/os/thread.h"
#include "core/profiling/profiling.h"
#include "core/templates/hash_map.h"

#if defined(GODOT_USE_TRACY)
#include <common/TracyProtocol.hpp>
#include <common/TracyVersion.hpp>
#include <tracy/TracyC.h>
#endif

FengGodotTracy *FengGodotTracy::singleton = nullptr;

#if defined(GODOT_USE_TRACY)
// Script zones are kept per thread, because Tracy ends a zone on the thread
// that began it and scripts can open zones on worker threads.
static Mutex _zone_mutex;
static HashMap<uint64_t, Vector<TracyCZoneCtx>> _zone_stacks;
// A source location is allocated by the client and stays valid for the lifetime
// of the process, so one is allocated per distinct zone name.
static HashMap<String, uint64_t> _zone_source_locations;

static uint32_t _to_tracy_color(const Color &p_color) {
	const uint32_t red = (uint32_t)CLAMP(int(p_color.r * 255.0f + 0.5f), 0, 255);
	const uint32_t green = (uint32_t)CLAMP(int(p_color.g * 255.0f + 0.5f), 0, 255);
	const uint32_t blue = (uint32_t)CLAMP(int(p_color.b * 255.0f + 0.5f), 0, 255);
	return (red << 16) | (green << 8) | blue;
}
#endif

FengGodotTracy::FengGodotTracy() {
	singleton = this;
}

FengGodotTracy::~FengGodotTracy() {
	if (singleton == this) {
		singleton = nullptr;
	}
#if defined(GODOT_USE_TRACY)
	MutexLock lock(_zone_mutex);
	_zone_stacks.clear();
	_zone_source_locations.clear();
#endif
}

bool FengGodotTracy::is_available() const {
#if defined(GODOT_USE_TRACY)
	return true;
#else
	return false;
#endif
}

bool FengGodotTracy::is_started() const {
#if defined(GODOT_USE_TRACY)
	// The client is started with the process unless TRACY_MANUAL_LIFETIME asks
	// for explicit control, which this module never does.
	return TracyCIsStarted != 0;
#else
	return false;
#endif
}

bool FengGodotTracy::is_profiler_connected() const {
#if defined(GODOT_USE_TRACY)
	return ___tracy_connected() != 0;
#else
	return false;
#endif
}

bool FengGodotTracy::is_on_demand() const {
#ifdef TRACY_ON_DEMAND
	return true;
#else
	return false;
#endif
}

String FengGodotTracy::get_version() const {
#if defined(GODOT_USE_TRACY)
	return vformat("%d.%d.%d", (int)tracy::Version::Major, (int)tracy::Version::Minor, (int)tracy::Version::Patch);
#else
	return String();
#endif
}

int FengGodotTracy::get_protocol_version() const {
#if defined(GODOT_USE_TRACY)
	return (int)tracy::ProtocolVersion;
#else
	return 0;
#endif
}

int FengGodotTracy::get_port() const {
	// The client honours TRACY_PORT; 8086 is the value it falls back to.
	const OS *os = OS::get_singleton();
	if (os != nullptr) {
		const String configured = os->get_environment("TRACY_PORT");
		if (configured.is_valid_int()) {
			return configured.to_int();
		}
	}
#ifdef TRACY_PORT
	return TRACY_PORT;
#else
	return 8086;
#endif
}

Dictionary FengGodotTracy::get_status() const {
	Dictionary status;
	status["available"] = is_available();
	status["started"] = is_started();
	status["connected"] = is_profiler_connected();
	status["on_demand"] = is_on_demand();
	status["version"] = get_version();
	status["protocol"] = get_protocol_version();
	status["port"] = get_port();
	status["zone_depth"] = get_zone_depth();
	return status;
}

void FengGodotTracy::message(const String &p_text) {
#if defined(GODOT_USE_TRACY)
	const CharString text = p_text.utf8();
	___tracy_emit_messageL(text.get_data(), 0);
#endif
}

void FengGodotTracy::message_colored(const String &p_text, const Color &p_color) {
#if defined(GODOT_USE_TRACY)
	const CharString text = p_text.utf8();
	___tracy_emit_messageLC(text.get_data(), _to_tracy_color(p_color), 0);
#endif
}

void FengGodotTracy::plot(const String &p_name, double p_value) {
#if defined(GODOT_USE_TRACY)
	const CharString name = p_name.utf8();
	___tracy_emit_plot(name.get_data(), p_value);
#endif
}

void FengGodotTracy::frame_mark(const String &p_name) {
#if defined(GODOT_USE_TRACY)
	if (p_name.is_empty()) {
		___tracy_emit_frame_mark(nullptr);
		return;
	}
	const CharString name = p_name.utf8();
	___tracy_emit_frame_mark(name.get_data());
#endif
}

void FengGodotTracy::set_thread_name(const String &p_name) {
#if defined(GODOT_USE_TRACY)
	const CharString name = p_name.utf8();
	// The client copies the name before it returns.
	___tracy_set_thread_name(name.get_data());
#endif
}

void FengGodotTracy::begin_zone(const String &p_name) {
#if defined(GODOT_USE_TRACY)
	if (p_name.is_empty()) {
		return;
	}
	const CharString name = p_name.utf8();
	MutexLock lock(_zone_mutex);
	uint64_t *source_location = _zone_source_locations.getptr(p_name);
	if (source_location == nullptr) {
		_zone_source_locations.insert(p_name, ___tracy_alloc_srcloc_name(0, __FILE__, strlen(__FILE__), __func__, strlen(__func__), name.get_data(), name.length(), 0));
		source_location = _zone_source_locations.getptr(p_name);
	}
	const TracyCZoneCtx zone = ___tracy_emit_zone_begin_alloc(*source_location, 1);
	_zone_stacks[(uint64_t)Thread::get_caller_id()].push_back(zone);
#endif
}

void FengGodotTracy::end_zone() {
#if defined(GODOT_USE_TRACY)
	MutexLock lock(_zone_mutex);
	Vector<TracyCZoneCtx> *stack = _zone_stacks.getptr((uint64_t)Thread::get_caller_id());
	if (stack == nullptr || stack->is_empty()) {
		return;
	}
	const TracyCZoneCtx zone = stack->ptr()[stack->size() - 1];
	stack->remove_at(stack->size() - 1);
	___tracy_emit_zone_end(zone);
#endif
}

int FengGodotTracy::get_zone_depth() const {
#if defined(GODOT_USE_TRACY)
	MutexLock lock(_zone_mutex);
	const Vector<TracyCZoneCtx> *stack = _zone_stacks.getptr((uint64_t)Thread::get_caller_id());
	return stack != nullptr ? stack->size() : 0;
#else
	return 0;
#endif
}

void FengGodotTracy::end_all_zones() {
#if defined(GODOT_USE_TRACY)
	MutexLock lock(_zone_mutex);
	Vector<TracyCZoneCtx> *stack = _zone_stacks.getptr((uint64_t)Thread::get_caller_id());
	if (stack == nullptr) {
		return;
	}
	while (!stack->is_empty()) {
		const TracyCZoneCtx zone = stack->ptr()[stack->size() - 1];
		stack->remove_at(stack->size() - 1);
		___tracy_emit_zone_end(zone);
	}
#endif
}

void FengGodotTracy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_available"), &FengGodotTracy::is_available);
	ClassDB::bind_method(D_METHOD("is_started"), &FengGodotTracy::is_started);
	ClassDB::bind_method(D_METHOD("is_profiler_connected"), &FengGodotTracy::is_profiler_connected);
	ClassDB::bind_method(D_METHOD("is_on_demand"), &FengGodotTracy::is_on_demand);
	ClassDB::bind_method(D_METHOD("get_version"), &FengGodotTracy::get_version);
	ClassDB::bind_method(D_METHOD("get_protocol_version"), &FengGodotTracy::get_protocol_version);
	ClassDB::bind_method(D_METHOD("get_port"), &FengGodotTracy::get_port);
	ClassDB::bind_method(D_METHOD("get_status"), &FengGodotTracy::get_status);

	ClassDB::bind_method(D_METHOD("message", "text"), &FengGodotTracy::message);
	ClassDB::bind_method(D_METHOD("message_colored", "text", "color"), &FengGodotTracy::message_colored);
	ClassDB::bind_method(D_METHOD("plot", "name", "value"), &FengGodotTracy::plot);
	ClassDB::bind_method(D_METHOD("frame_mark", "name"), &FengGodotTracy::frame_mark, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("set_thread_name", "name"), &FengGodotTracy::set_thread_name);

	ClassDB::bind_method(D_METHOD("begin_zone", "name"), &FengGodotTracy::begin_zone);
	ClassDB::bind_method(D_METHOD("end_zone"), &FengGodotTracy::end_zone);
	ClassDB::bind_method(D_METHOD("get_zone_depth"), &FengGodotTracy::get_zone_depth);
	ClassDB::bind_method(D_METHOD("end_all_zones"), &FengGodotTracy::end_all_zones);
}
