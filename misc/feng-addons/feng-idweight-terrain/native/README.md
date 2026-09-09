# Native terrain build

This directory is ordinary source in the `feng-godot` repository. It is not a
submodule and has no independent Git repository. Edit terrain C++ and embedded
shaders here, not in the former sibling `feng-idweight-terrain` directory.

`godot-cpp/` is vendored from Godot's `godot-4.5-stable` tag, revision
`e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`. Its license is retained in that directory.
Generated bindings and compiler products are not source dependencies.

From this directory, build the Windows debug extension:

    scons platform=windows target=template_debug arch=x86_64 -j2

The output goes to the parent addon's `bin/` directory. The editor automatically
links project addons directly to `misc/feng-addons/` when opening a project.
There is no `bin/addons/` copy to refresh and no linker script to run. Restart
the editor after rebuilding a loaded DLL. The `native/.gdignore` file excludes
compiler sources from project resource scanning.

Repository consolidation does not complete the Hydra rendering migration.
The R16 contract and conversion code are present; rendering and editor integration
must be validated separately before release.
