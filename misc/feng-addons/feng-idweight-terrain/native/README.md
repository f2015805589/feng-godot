# Native terrain build

This directory is ordinary source in the `feng-godot` repository. It is not a
submodule and has no independent Git repository. Edit terrain C++ and embedded
shaders here, not in the former sibling `feng-idweight-terrain` directory.

`godot-cpp/` is vendored from Godot's `godot-4.5-stable` tag, revision
`e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`. Its license is retained in that directory.
Generated bindings and compiler products are not source dependencies.

From this directory, build the Windows debug extension:

    scons platform=windows target=template_debug arch=x86_64 -j2

The output goes to the parent addon's `bin/` directory. Build the engine afterward
to refresh `bin/addons/`. The engine packaging step excludes this `native/`
directory, so new game projects receive runtime plugin files, not compiler sources.

Repository consolidation does not complete the Hydra rendering migration.
The R16 contract and conversion code are present; rendering and editor integration
must be validated separately before release.
