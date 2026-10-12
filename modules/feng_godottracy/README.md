# Feng Godot Tracy

Tracy profiler support for this engine, adapted from
[GodotTracy](https://github.com/Pineapple/GodotTracy) (MIT, Pineapple Works).
The module vendors Tracy, selects the engine backend, exposes a script API, and
adds the Debug menu entry in `misc/feng-addons/feng-godottracy`.

The [Tracy profiler](https://github.com/wolfpld/tracy) shows frame timelines,
zones, plots, messages and, optionally, memory and call stacks. Existing
`GodotProfileZone` instrumentation becomes Tracy zones when this backend is
enabled, and the platform main loop marks each frame.

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

The [editor addon guide](../../misc/feng-addons/feng-godottracy/README.md)
covers profiler installation, executable discovery and **Debug > Tracy Profiler**.
Connect to the running editor; the client listens on `127.0.0.1:8086` unless
`TRACY_PORT` overrides it.

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

The module registers the `FengGodotTracy` class and singleton for script markers
and plots. The VM records script functions and native calls automatically:

```gdscript
FengGodotTracy.message("streaming a new sector")
FengGodotTracy.plot("terrain/cdlod_ms", peak_ms)
```

For scripts that must also run on an engine built without the module, look the
singleton up at runtime:

```gdscript
if Engine.has_singleton("FengGodotTracy"):
	Engine.get_singleton("FengGodotTracy").call("message", "hello")
```

Dynamic message text is copied into Tracy's queue (fewer than 65,535 UTF-8 bytes
per message). An allocated zone source location transfers ownership on each
begin, including when the client is disconnected; it must never be reused.
Plot and named-frame categories use the engine profiler's persistent interner
because Tracy retains their pointers. Keep these names stable, such as
`terrain/cdlod_ms`; put per-frame values in the plot value or message text rather
than generating a new category every frame. Names stay until profiler shutdown.

Two complementary lifetime regressions are available:

```sh
python modules/feng_godottracy/tests/run_lifetime_tests.py
python misc/scripts/test_feng_tracy_lifetime.py --editor /path/to/godot
```

The first compiles the actual module against deterministic API ownership
doubles. The second requires a rebuilt editor and drains the real Tracy stream
over a private loopback connection while repeated dynamic script zones,
messages and categories are emitted. Neither launches the profiler GUI.

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

## Thread initialization

Tracy starts worker threads during static initialization. Godot's
`Thread::next_id()` uses a function-local counter so those workers receive
unique IDs regardless of translation-unit initialization order.
