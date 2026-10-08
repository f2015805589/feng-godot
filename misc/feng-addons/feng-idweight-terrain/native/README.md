# Native terrain build

This directory contains the terrain C++ and embedded shaders maintained in the
`feng-godot` repository.

`godot-cpp/` is vendored from Godot's `godot-4.5-stable` tag, revision
`e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`. Its license is retained in that directory.
Generated bindings and compiler products are not source dependencies.

From this directory, build the Windows debug extension:

    scons platform=windows target=template_debug arch=x86_64 -j2

The output goes to the parent addon's `bin/` directory. The editor automatically
links project addons directly to `misc/feng-addons/` when opening a project.
Restart the editor after rebuilding a loaded DLL. The `native/.gdignore` file excludes
compiler sources from project resource scanning.

Validate R16 rendering and editor integration before release using the relevant
checks in [`tests/README.md`](tests/README.md).
