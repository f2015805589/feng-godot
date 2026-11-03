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

The extension descriptor uses the standard debug/release library names above.
BC7 source-array encoding includes the repository's `thirdparty/cvtt` implementation
in the addon, so it does not require the engine's optional cvtt encoder module.
Its MIT notice is retained at `../CVTT_LICENSE.txt`.

The optional `vt_neural_data` resource provides encoded evaluated pages for the
near/far `NTC (baked pages)` setting. Its implementation is supplied by `feng-ntc`:
either decode missing pages into the ordinary hardware cache, or keep compressed
features resident with an independently bounded decoded working set. The latter
injects the addon's portable sampler into the terrain material for cold misses.
No NTC SDK dependency is added to Terrain3D. See
[`feng-ntc`](../../feng-ntc/README.md) for baking, platform and memory boundaries.

Validate R16 rendering and editor integration before release using the relevant
checks in [`tests/README.md`](tests/README.md).

## Runtime boundaries

- `Terrain3DVirtualTexture` validates addresses and publishes indirection; its shared
  page pool owns allocation, LRU, pin counts and reverse owners. Allocation and
  publication are synchronous. Content production happens separately
- `Terrain3DPagePipeline` owns the bounded source queue and immutable snapshots.
  Only snapshot capture depends on `Terrain3DData`; workers do not access the scene.
  Queue removal shares one path for accounting and deferred image destruction.
  Workers claim the oldest live token; cancellation leaves no separate FIFO history
- Clipmap layers keep their storage leases through queued renderer work. Teardown
  drains that work before releasing its resources

Run the deterministic pool/queue lifecycle checks without Godot or a graphics driver:

    python tests/native_state/run_tests.py

The harness compiles production declarations and method bodies with engine-boundary
value doubles. Use `--source PATH_TO_NATIVE_SRC` for a same-harness baseline check;
it does not verify real worker scheduling or GPU publication.
