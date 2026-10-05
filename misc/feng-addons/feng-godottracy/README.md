# Tracy Profiler (editor addon)

Starts the Tracy profiler from the editor, for the `feng_godottracy` engine
module, which compiles the Tracy client into the engine and routes the engine's
own profiling zones to it.

## The menu item

**Debug > Tracy Profiler** starts the profiler. On Windows, a missing profiler is
downloaded from the release matching the compiled-in client and installed in
this addon's `bin/tracy-profiler.exe` (an untracked build artifact). On Linux and
macOS, configure a compatible native executable.

Executable selection checks, in order:

1. **Editor Settings > Tracy > Profiler > Executable Path**, for anyone who keeps
   a specific build somewhere else.
2. This addon's `bin/tracy-profiler.exe`.
3. `FENG_TRACY_PATH` (a folder or a file).
4. Next to the editor.
5. The downloads folder, including the versioned folder a Tracy release unpacks
   into.

On Linux and macOS, use the executable setting or a full file path in
`FENG_TRACY_PATH`. Automatic installation is Windows-only.

The menu item and its separator have separate owned IDs. Disabling or reloading
the plugin removes only those items, even if another addon rearranges the menu.

Everything else happens inside the profiler: it lists the running editors, and
**Connect** attaches to the one you pick.

The plugin loads with or without the engine module. Without it, launching the
profiler warns that the editor has no Tracy client. If the Debug menu is
unavailable, the action appears as a **Tracy** toolbar button.

## Enabling it

The plugin is picked up like every other source addon in `misc/feng-addons`, so
it is linked into a project on the next editor start and enabled with the other
source addons. The engine module it drives is part of a default build:

```powershell
python misc/scripts/install_tracy.py   # only needed if thirdparty/tracy is missing
scons platform=windows target=editor arch=x86_64
```

## Using it

1. Use **Debug > Tracy Profiler**.
2. Press **Connect** in that window and pick the editor. The engine already marks
   every frame, so a timeline appears as soon as it attaches.

## Script API

The module registers the `FengGodotTracy` singleton, which is how scripts feed
markers and plots into the profiler:

```gdscript
if Engine.has_singleton("FengGodotTracy"):
	var tracy := Engine.get_singleton("FengGodotTracy")
	tracy.message("streaming a new sector")
	tracy.plot("terrain/vt_ms", peak_ms)
	tracy.begin_zone("terrain_rebuild")
	# ... work ...
	tracy.end_zone()
```

`get_status()` returns `available`, `started`, `connected`, `on_demand`,
`version`, `protocol`, `port` and `zone_depth`.

## Verification

`python misc/scripts/test_feng_godottracy.py` checks the extension API, the
script API, the menu item (including which menu it landed in, and that the
profiler is installed in the addon) and the Tracy protocol handshake
against a running editor. It needs an editor built with the module and never
starts the profiler itself.
