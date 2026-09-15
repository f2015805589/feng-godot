#ifndef FENG_GODOTTRACY_H
#define FENG_GODOTTRACY_H

#include "core/math/color.h"
#include "core/object/object.h"
#include "core/string/string_name.h"
#include "core/variant/dictionary.h"

// Engine-side entry point of the Tracy profiler, registered as the
// `FengGodotTracy` singleton and usable from C++ and from scripts.
//
// The profiler backend itself is the engine's own profiling layer
// (`core/profiling`), so instrumenting engine code does not need this class:
// include "modules/feng_godottracy/profiler.h" and use FENG_PROFILE_*.
// This class is for code that cannot open a scope, such as GDScript.
class FengGodotTracy : public Object {
	GDCLASS(FengGodotTracy, Object);

	static FengGodotTracy *singleton;

protected:
	static void _bind_methods();

public:
	static FengGodotTracy *get_singleton() { return singleton; }

	FengGodotTracy();
	~FengGodotTracy();

	// Build and connection state. Safe to call when the engine was built
	// without the Tracy backend: everything then reports as unavailable.
	bool is_available() const;
	bool is_started() const;
	// Not `is_connected`: Object already uses that name for signals.
	bool is_profiler_connected() const;
	bool is_on_demand() const;
	String get_version() const;
	int get_protocol_version() const;
	int get_port() const;
	Dictionary get_status() const;

	// One-shot events on the profiler's timeline.
	void message(const String &p_text);
	void message_colored(const String &p_text, const Color &p_color);
	void plot(const String &p_name, double p_value);
	void frame_mark(const String &p_name = String());
	void set_thread_name(const String &p_name);

	// Zone pairs for code that cannot use a scope, such as GDScript. Each
	// begin_zone() must be paired with an end_zone() on the same thread.
	void begin_zone(const String &p_name);
	void end_zone();
	int get_zone_depth() const;
	void end_all_zones();
};

#endif // FENG_GODOTTRACY_H
