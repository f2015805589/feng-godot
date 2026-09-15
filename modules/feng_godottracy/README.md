# Feng Godot Tracy

Tracy Profiler support for this engine, adapted from
[GodotTracy](https://github.com/Pineapple/GodotTracy) (MIT, Pineapple Works).

The [Tracy profiler](https://github.com/wolfpld/tracy) samples the running
process and shows a frame timeline, per-zone timings, plots, messages and,
optionally, memory and call stacks. This module bundles the Tracy client and
selects the engine's Tracy backend, so the `GodotProfileZone` instrumentation
that already exists throughout the engine turns into real Tracy zones, and the
platform main loop already marks every frame.

In the original module the client had to be added as a git submodule and the
Tracy backend had to be wired up by hand; here the module vendors the client in
`thirdparty/tracy`, drives `core/profiling` itself, and adds a script-facing API
plus a Debug menu entry that starts the profiler
(`misc/feng-addons/feng-godottracy`).

## Building

The module is **built by default**: a plain build of this engine keeps the Tracy
client and the profiler available, and the client discards events until a
profiler attaches (see `profiler_record_on_demand`).

```powershell
python misc/scripts/install_tracy.py   # only needed if thirdparty/tracy is missing
scons platform=windows target=editor arch=x86_64
```

Use `module_feng_godottracy_enabled=no` to leave the profiler out of a build, and
remember that a build without the module has no Tracy client for the profiler to
connect to.

Optional flags:

| Flag | Effect |
| --- | --- |
| `module_feng_godottracy_enabled=no` | Leave the Tracy backend out of this build. |
| `feng_godottracy_callstack=yes` | Sample call stacks for every zone (`TRACY_CALLSTACK=62`). |
| `feng_godottracy_track_memory=yes` | Report engine allocations (`GODOT_PROFILER_TRACK_MEMORY`). |
| `tracy_on_demand=yes` / `=no` | Flag of the original module, kept working; maps to `profiler_record_on_demand`. |

The engine option `profiler_record_on_demand` (default `yes`) selects
`TRACY_ON_DEMAND`: the client only records while a profiler is connected. Build
with `profiler_record_on_demand=no` to record from the first frame instead.

`profiler=tracy profiler_path=<checkout>` still selects a different Tracy
checkout; an explicitly configured `profiler_path` wins over the vendored copy,
and selecting another profiler (`profiler=perfetto`) leaves that backend alone.

Rebuilds after the first one stay incremental. Turning the module off again
rebuilds the same files, since the profiler configuration changes back.

## Using it

1. Build the engine as above and start the editor.
2. Download the profiler GUI (`tracy-profiler.exe`) from the
   [Tracy releases page](https://github.com/wolfpld/tracy/releases) - it is a
   separate program and is not part of this repository.
3. Use **Debug > Tracy Profiler**. The profiler ships in the addon's `bin`
   folder and starts from there; a fresh checkout downloads it once.
   Editor Settings > Tracy > Profiler > Executable Path overrides the lookup.
4. In the profiler window press **Connect**, and pick the running editor. The
   client listens on `127.0.0.1:8086` (override with the `TRACY_PORT`
   environment variable), and a frame timeline appears as soon as it attaches.

`TRACY_NO_EXIT=1` keeps the client alive until the profiler disconnects, which
is useful when a short-lived tool exits before the GUI can attach.

## Instrumenting code

### C++

```cpp
#include "modules/feng_godottracy/profiler.h"

void TerrainUpdate::_update() {
	FENG_PROFILE_ZONE("Terrain update");          // any backend, no-op otherwise
	FENG_PROFILE_PLOT("terrain/vt_ms", peak_ms);  // Tracy only
	FENG_PROFILE_MESSAGE("vt cache rebuilt");
}
```

The macros from the original GodotTracy headers (`FrameMark`, `ZoneScopedN`,
`TracyPlot`, `TracyMessage`, ...) are available too when the Tracy backend is
built in, because `profiler.h` includes the Tracy API in that case. Prefer the
`FENG_PROFILE_*` spellings and `FENG_PROFILE_ZONE` / `FENG_PROFILE_FRAME`,
since those also compile without a profiler.

### GDScript

The module registers the `FengGodotTracy` class and singleton, so scripts can
send markers and open zones for code that cannot use a scope:

```gdscript
FengGodotTracy.message("streaming a new sector")
FengGodotTracy.plot("terrain/cdlod_ms", peak_ms)
FengGodotTracy.begin_zone("terrain_rebuild")
# ... work ...
FengGodotTracy.end_zone()
```

Every `begin_zone()` must be paired with an `end_zone()` on the same thread;
`end_all_zones()` closes whatever is still open. In scripts that must also run
on an engine built without the module, look the singleton up at runtime:

```gdscript
if Engine.has_singleton("FengGodotTracy"):
	Engine.get_singleton("FengGodotTracy").call("message", "hello")
```

## Files

- `config.py` - enables the engine's Tracy backend, maps the module options.
- `SCsub` - compiles the module; the client itself is built by
  `core/profiling/SCsub` from `thirdparty/tracy/public/TracyClient.cpp`.
- `profiler.h` - backend-independent instrumentation macros.
- `feng_godottracy.{h,cpp}` - the `FengGodotTracy` singleton API.
- `register_types.{h,cpp}` - class and singleton registration.
- `../../thirdparty/tracy` - vendored client (`v0.11.1`, protocol 69, BSD 3-Clause).
- `../../misc/scripts/install_tracy.py` - installs or updates the vendored client.
- `../../misc/feng-addons/feng-godottracy` - Debug menu entry that starts the profiler.

## Notes

- `FrameMark` is already emitted by the platform main loop
  (`GodotProfileFrameMark`), so frames appear without extra work.
- The client is compiled once, into the engine binary, and needs no extra
  library on Windows (Tracy links `ws2_32`, `dbghelp`, `advapi32` and `user32`
  itself through `#pragma comment`).
- Zone and marker calls are cheap when nothing is connected: with the default
  `profiler_record_on_demand=yes` the client discards events until a profiler
  attaches.

## Engine fix this module depends on

The Tracy client starts its worker threads while its translation unit is being
statically initialized. Godot handed out thread IDs from
`core/os/thread.cpp`'s `Thread::id_counter`, a plain `SafeNumeric` that is
initialized *dynamically*, so those early threads incremented a counter that was
still zero and were given IDs starting at 1 - including `MAIN_ID`. The real main
thread then got a low ID as well, `Thread::make_main_thread()` concluded it was
already the main thread and left `is_main_thread_assigned` unset, and
`Thread::release_main_thread()` aborted the process on shutdown.

`Thread::id_counter` is now replaced by `Thread::next_id()` with a function-local
counter, which is initialized on first use and therefore immune to the order of
static initialization. Any library that starts a thread during static
initialization would have hit the same problem.

