# Tracy Profiler (editor addon)

Starts the Tracy profiler from the editor, for the `feng_godottracy` engine
module, which compiles the Tracy client into the engine and routes the engine's
own profiling zones to it.

## The menu item

**Debug > Tracy Profiler** starts the profiler. One click, nothing to configure:
the profiler ships in this addon's `bin` folder (`bin/tracy-profiler.exe`), and
is started from there. When that file is missing - a fresh checkout, where the
`bin` folder is not part of the repository - it is downloaded once from the Tracy
release that matches the compiled-in client and installed in the same folder.

Other copies are only used when the addon has none, in this order:

1. **Editor Settings > Tracy > Profiler > Executable Path**, for anyone who keeps
   a specific build somewhere else.
2. `FENG_TRACY_PATH` (a folder or a file).
3. Next to the editor.
4. The downloads folder, including the versioned folder a Tracy release unpacks
   into.

Everything else happens inside the profiler: it lists the running editors, and
**Connect** attaches to the one you pick.

The plugin never refers to `FengGodotTracy` directly, so it also loads in an
editor that was built without the module; starting the profiler then warns that
this editor has no Tracy client. If the main menu is collapsed or its Debug menu
cannot be found, the same action is added as a **Tracy** toolbar button instead.

## Enabling it

The plugin is picked up like every other source addon in `misc/feng-addons`, so
it is linked into a project on the next editor start and enabled with the other
source addons. The engine module it drives is part of a default build:

```powershell
python misc/scripts/install_tracy.py   # only needed if thirdparty/tracy is missing
scons platform=windows target=editor arch=x86_64
```

An editor built with `module_feng_godottracy_enabled=no` has no Tracy client;
starting the profiler then warns about it.

## Using it

1. Use **Debug > Tracy Profiler**. The profiler window opens, downloading itself
   first if this machine has no copy yet.
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
profiler is installed next to the editor) and the Tracy protocol handshake
against a running editor. It needs an editor built with the module and never
starts the profiler itself.
