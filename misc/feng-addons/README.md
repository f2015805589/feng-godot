# Source addons

Run the source-built editor from this checkout's `bin/` directory. Before the
project resource scan, it links each addon directory containing `plugin.cfg`
into the project's `addons/`: directory junctions on Windows, symbolic links on
other platforms. Windows junctions use the Windows API and need no administrator
rights or setup script.

## Project setup

New and existing projects receive missing addons. Newly linked plugins are
added to the enabled-plugin list; later launches preserve enabled/disabled
choices. Recovery mode skips link creation.

Existing directories and links to other locations are preserved with a warning.
To replace a conflicting local copy, first save any local changes, then remove
the conflict yourself and reopen the project. Links previously created into
this checkout's `bin/addons/` are migrated automatically, preserving plugin state.

Scripts and assets update immediately through the links. Projects using them
depend on the source checkout. For standalone distribution, include real copies
of runtime addons and native libraries for the destination platform.

## Native builds

On Windows, `build-feng-godot.bat` in the repository root builds the x86_64 D3D12
editor and both native debug extensions. Double-clicking keeps the result window
open; use `--no-pause` from a terminal. To build the extensions separately:

```powershell
scons -C misc/feng-addons/feng-idweight-terrain/native platform=windows target=template_debug arch=x86_64
scons -C misc/feng-addons/feng-renderdoc-capture/native platform=windows target=template_debug arch=x86_64
```

Close editors using a DLL before rebuilding, then restart to load it.
`native/.gdignore` keeps compiler sources out of the resource scan. Release
exports also need `target=template_release` libraries for their target platform.

## Verification

After building the Windows editor and both debug extensions, run
`python misc/scripts/test_feng_addons.py`. It checks startup links, existing addon
and disabled-plugin preservation, recovery mode, legacy link migration, and
editor import with both native classes. Fixtures and logs stay in
`bin/feng-addons-test-*`; editor settings are isolated from the user profile.
