#ifndef FENG_GODOTTRACY_PROFILER_H
#define FENG_GODOTTRACY_PROFILER_H

// Instrumentation header for the feng_godottracy engine module.
//
// Include this from .cpp files only, as it pulls in the full profiling
// implementation of the selected backend. The FENG_PROFILE_* macros always
// compile: they become no-ops when the engine is built without a profiler, so
// instrumentation can stay in the code base and be switched on per build.
//
// When the engine is built with the Tracy backend, the raw Tracy API is
// available as well, so the original GodotTracy spellings (FrameMark,
// ZoneScopedN, TracyPlot, TracyMessage, ...) keep working unchanged.

#include "core/profiling/profiling.h"

#if defined(GODOT_USE_TRACY)
#ifndef TRACY_ENABLE
#define TRACY_ENABLE
#endif
#include <tracy/Tracy.hpp>
#endif

// Zones and frame marks, supported by every backend.
// A zone lasts until the end of the enclosing scope.
#define FENG_PROFILE_ZONE(m_name) GodotProfileZone(m_name)
// A zone group keeps a single zone open and reuses it for the whole scope.
#define FENG_PROFILE_ZONE_GROUPED_FIRST(m_group, m_name) GodotProfileZoneGroupedFirst(m_group, m_name)
#define FENG_PROFILE_ZONE_GROUPED(m_group, m_name) GodotProfileZoneGrouped(m_group, m_name)
#define FENG_PROFILE_ZONE_GROUPED_END_EARLY(m_group, m_name) GodotProfileZoneGroupedEndEarly(m_group, m_name)
// Mark the start of a new frame on the profiler's timeline.
#define FENG_PROFILE_FRAME() GodotProfileFrameMark

#if defined(GODOT_USE_TRACY)
// Messages and numbers shown in the profiler's log and plot views.
// Arguments are not evaluated when Tracy is disabled.
#define FENG_PROFILE_MESSAGE(m_text) TracyMessageL(m_text)
#define FENG_PROFILE_PLOT(m_name, m_value) TracyPlot(m_name, m_value)
#define FENG_PROFILE_PLOT_CONFIG(m_name, m_type, m_step, m_fill, m_color) TracyPlotConfig(m_name, m_type, m_step, m_fill, m_color)
// Name the calling thread in the profiler; the name is copied by Tracy.
#define FENG_PROFILE_THREAD(m_name) tracy::SetThreadName(m_name)
#else
#define FENG_PROFILE_MESSAGE(m_text)
#define FENG_PROFILE_PLOT(m_name, m_value)
#define FENG_PROFILE_PLOT_CONFIG(m_name, m_type, m_step, m_fill, m_color)
#define FENG_PROFILE_THREAD(m_name)
#endif

#endif // FENG_GODOTTRACY_PROFILER_H
