# Native terrain build

This directory contains the terrain C++ and embedded shaders maintained in the
`feng-godot` repository.

`godot-cpp/` is vendored from Godot's `godot-4.5-stable` tag, revision
`e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77`. Its license is retained in that directory.
Generated bindings and compiler products are not source dependencies.

From this directory, build the debug extension for your platform:

    scons platform=windows target=template_debug arch=x86_64 -j2
    scons platform=linux target=template_debug arch=x86_64 -j4

The output goes to the parent addon's `bin/` directory. The editor automatically
links project addons directly to `misc/feng-addons/` when opening a project.
Restart the editor after rebuilding a loaded DLL. The `native/.gdignore` file excludes
compiler sources from project resource scanning.

Validate R16 rendering and editor integration before release using the relevant
checks in [`tests/README.md`](tests/README.md).

## Runtime boundaries

- `Terrain3DVirtualTexture` validates addresses and publishes indirection; its shared
  page pool owns allocation, LRU, pin counts and reverse owners. Allocation and
  publication are synchronous. Content production happens separately
- `Terrain3DPagePipeline` owns the bounded source queue and immutable snapshots.
  Only snapshot capture depends on `Terrain3DData`; workers do not access the scene.
  Queue removal shares one path for accounting and deferred image destruction
- Clipmap layers keep their storage leases through queued renderer work. Teardown
  drains that work before releasing its resources

Run the deterministic pool/queue lifecycle checks without Godot or a graphics driver:

    python tests/native_state/run_tests.py

The harness compiles production declarations and method bodies with engine-boundary
value doubles. Use `--source PATH_TO_NATIVE_SRC` for a same-harness baseline check;
it does not verify real worker scheduling or GPU publication.
