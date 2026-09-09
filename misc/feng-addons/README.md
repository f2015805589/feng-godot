# Source addons

The source-built editor in `bin/` links each directory containing `plugin.cfg`
here into a project's `addons/` directory before scanning project resources.
Windows uses directory junctions through the Windows API; other platforms use
symbolic links. No administrator rights, PowerShell script, or build-time copy
is needed on Windows. Keep the editor in this checkout's `bin/` directory.

Both new and existing projects receive missing addons. Newly linked plugins
are enabled without replacing the project's existing enabled-plugin list.
Later launches preserve disabled plugins. Recovery mode does not create links.
Links made by the old editor into this checkout's `bin/addons/` are migrated.
Existing ordinary directories and links to other locations are kept, with a
warning; move any local modifications somewhere safe before removing a
conflicting addon yourself. The engine does not delete or back up these files.

Changes to scripts and assets are visible through the links immediately.
Native DLLs still need their own build; close editors using them before rebuilding:

```powershell
scons -C misc/feng-addons/feng-idweight-terrain/native platform=windows target=template_debug arch=x86_64
scons -C misc/feng-addons/feng-renderdoc-capture/native platform=windows target=template_debug arch=x86_64
```

Restart the editor to reload a rebuilt DLL. `native/.gdignore` keeps compiler
sources out of Godot's resource scan. For release exports, also build the native
extensions with `target=template_release` (and the appropriate target platform).

These projects depend on the source checkout while using links. To distribute
a project independently, include real copies of its runtime addons and the
native libraries for the destination platform. The legacy `link_plugin.ps1`
is unnecessary with this editor.

After building the Windows editor and both debug extensions, run
`python misc/scripts/test_feng_addons.py` to verify startup links, preservation
of existing addons and disabled plugins, recovery mode, legacy link migration,
and full editor import with both native classes. Fixtures and logs stay in
`bin/feng-addons-test-*`; editor settings are isolated from your user profile.
