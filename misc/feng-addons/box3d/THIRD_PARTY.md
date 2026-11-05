# Third-party source provenance

All third-party code remains MIT licensed. Retain the license files when
distributing this addon, including binary-only packages.

| Component | Repository | Pinned revision | License |
| --- | --- | --- | --- |
| Box3D | https://github.com/erincatto/box3d | `3fc20f5b453ba9e14cdf54ecafa87a2a4bcdf53c` | `native/thirdparty/box3d/LICENSE` |
| Godot Box3D adapter | https://github.com/bearlikelion/godot-box3d | `c16ba7c9e30020e0616e7903622e8c2a8e31d948` (`v0.3.1`) | `native/thirdparty/godot-box3d/LICENSE` |
| godot-cpp | https://github.com/godotengine/godot-cpp | Shared checkout SDK, API 4.5 | `../feng-idweight-terrain/native/godot-cpp/LICENSE.md` |

The Box3D snapshot contains its library sources, public headers, and CMake build
files. The adapter snapshot contains its C++ sources. Upstream Godot test scripts
are in `tests/upstream/` under the adapter's MIT license. Samples, screenshots,
CI scripts, and build artifacts are not vendored.

Source audit on 2026-11-03 compared all 97 vendored Box3D files under `src/` and
`include/` with the archive at the pinned upstream commit (normalizing line
endings): all matched before the local issue fixes below. The rigid-body core is
the official library with these explicit local patches. Upstream's Soft Step
rigid-body solver is not soft-body support.

Local Box3D core changes:

- `src/shape.c`: invalidate cached contact materials and wake affected bodies on
  material edits (#209); no per-frame global material refresh.
- `src/mesh_contact.c`: preserve dense mesh/heightfield triangle candidates beyond
  the 256-entry stack fast path using the worker arena (#184).
- `src/distance.c`: retain a valid separating normal for initial contacts within
  the slop region, allowing mover callers to distinguish departure from entry
  (#32). Truly degenerate overlaps do not receive an invented normal.

`native/soft_tasks.c` is an addon-owned bridge to the pinned Box3D scheduler. It
uses private world/scheduler headers, so it must be reviewed when updating the
upstream revision. It runs synchronously after the rigid step and reuses that
world's workers; callbacks must not mutate rigid-world data.
Large soft-body iterations use one cooperative task batch: the last completed
group runs the shared tail before publishing the next iteration. No nested
dispatch is permitted inside those callbacks. Regression checks include both
asynchronous workers and an inline task scheduler.

Local changes to the adapter:

- Shape ownership is maintained across add/remove/replace/clear and owner deletion.
  Freeing a shape RID first detaches every body/area instance, including repeated
  attachments to one body. This fixes Terrain3D heightmap teardown looping forever
  while waiting for its static body's shape count to shrink.

- The three PhysicsServer/direct-state extension classes use `float` in their
  scalar overrides, matching this checkout's generated Godot 4.5 API metadata.
  No Godot engine source changes are required.
- The addon has its own CMake build and reuses the shared godot-cpp SDK. Its native
  library is `bin/box3d.dll` (Windows) or `bin/box3d.so` (Linux).
- The GDExtension manifest requires 4.5 and disables live DLL reload. Replacing a
  physics server while worlds are alive requires an engine restart.
- `backend_activation_test.gd` also checks the actual server class, so a fallback
  to Godot/Jolt cannot produce a passing activation result.
- Direct ray/point/shape queries now fill the native `collider` pointer as well
  as its ID. Previously script queries hit geometry but returned a null collider.
  Ray results also propagate Box3D's mesh triangle index (`-1` for primitives).
- Separation-ray default documentation tolerates a null RID; runtime creation
  still reports the unsupported shape.
- Added a local CPU XPBD SoftBody3D implementation and renderer update bridge,
  with welded particles, stretch/bend constraints, closed-mesh volume preservation,
  pinned points, forces, and collision against Box3D rigid shapes. Extended with
  BVH-accelerated vertex/triangle self and soft/soft contacts, swept crossing checks,
  and strain/cut-driven seam splitting. Expanded render vertices allow visible
  cracks without resizing live GPU buffers; particle splitting preserves mass.
  These are local adapter features, not upstream Box3D features.
- Reuse soft-contact query storage and broadphase rigid candidates; precompute
  constraint inverse masses. Cache rigid environment settings and use a default
  environment fast path when no areas exist. Parameter/space/mode changes and
  switching force integration invalidate the cache.
- Filter and reuse body callback snapshots, pass callable arguments on the stack,
  and use stable double-buffered area event batches. Clear sync flags before user
  callbacks to avoid accessing a body freed inside its callback. Keep awake state
  synchronization and custom integration semantics intact.
- Separate hot soft-constraint positions/masses from render/rest state; precompute
  compliance and effective mass per substep. Skip a duplicate soft-contact pass
  only when the preceding pass made no position corrections. These local changes
  reference Jolt's active-work and cache-locality design; no Jolt solver code is
  copied or linked into the extension.
- Group large soft meshes into disjoint vertex clusters; solve cross-cluster
  edges serially and rebuild groups after tears. Use aligned SIMD collision
  bounds and parallel read-only candidate generation, requerying moved particles.
- Color constraints within each cluster into independent four-lane SSE2 batches,
  with a scalar fallback retaining the same constraint order. Parallelize face
  bounds and reuse conservative swept bounds only while all vertices remain
  contained; cache candidates by target BVH revision and query containment.
  Thickness and topology changes invalidate cached bounds.
- Store four-lane constraint parameters and accumulated multipliers contiguously
  for SIMD loads/stores instead of gathering them from topology records. Run
  large-body constraint iterations cooperatively within one worker submission,
  preserving the per-iteration cross-cluster and volume tail. This references
  Jolt's staged work progression; no Jolt implementation was copied.
- Skip per-particle rigid-query setup when the body's candidate list is empty,
  and skip repeated empty soft-candidate checks only before any contact has moved
  vertices in that pass. Allocate BVH traversal scratch only on a cache miss.
- Retain vertex candidate lists per collider in a bounded four-entry LRU cache;
  eviction recomputes queries rather than discarding contacts. Cache target IDs
  and BVH revisions, not object pointers. Batch independent small soft bodies
  across the existing Box3D worker pool while keeping rigid impulses and mutual
  contact response ordered. This references Jolt's batched work architecture;
  soft/soft candidate caching remains an independent local implementation.
- Reuse contiguous topology scratch for tearing. Bucket triangle corners and
  edges by dense particle ID, then sort only each vertex's incident entries;
  retain the old lexicographic split IDs, edge order and mass partition. Build
  solver adjacency with CSR arrays and compute BVH centroids once per rebuild.
  No particle, contact, substep or iteration is removed. This follows Jolt's
  use of contiguous work arrays and preprocessing outside the iterative solve;
  the tearable topology implementation is local, and no Jolt source was copied.
- Add soft-body sleep islands and support-change wakeup (including deleted rigid
  and soft supports), without reducing substeps, iterations, or particle counts.
  Unchanged render callbacks reuse the filled mesh buffer; the engine's upload
  call remains unchanged. Contact slop no longer leaves closing velocity to
  accumulate on an otherwise resting surface.
- Separate collision depenetration from velocity changes. Apply equal/opposite
  rigid contact impulses including rotational effective mass and friction; use
  barycentric impulses for soft/soft contact. Solver statistics expose kinetic
  energy, center of mass and maximum speed for impact regression checks.
- Forward runtime friction/restitution edits to already-created rigid shapes.
- Track subscriptions for body callbacks and contact reports instead of scanning
  every body for unused notifications. Maintain subscriptions across space changes,
  callback replacement and deletion; retain RID snapshots during user callbacks.
  Disable unused native contact begin/end events; Godot monitors still read the
  complete manifolds. Enable supported Release interprocedural optimization for
  the core and adapter, with unchanged floating-point flags and solver settings.
- Add a backend-neutral PhysicsServer3D/MultiMesh stress fixture for 10k/30k/60k
  rigid bodies. Jolt and Box3D use the same fixture; test results describe the
  installed engine builds, not equivalently compiled standalone libraries.
  Use cached public typed body-state accessors and upload poses only after a
  physics step on both backends. Compare automatic worker configurations by
  default, with independent overrides; the old forced-four-thread comparison
  did not reproduce the playground's automatic Jolt worker configuration.
- Skip the zero gyroscopic correction for exactly isotropic inertia tensors and
  zero angular velocity. Retain the original Newton solver for all asymmetric
  tensors, including nearly isotropic and compound bodies. No epsilon cutoff,
  extra body-state storage, solver-iteration reduction or floating-point flag
  change is used. Optional stress-fixture profiling exposes core phase timers.
- Ragdoll examples inherit character velocity on activation, clear stale bone
  velocities on reset, and disable redundant character physics callbacks while
  the native bones are simulating.
- Runtime body/area collision-layer changes now update existing Box3D shape
  filters. This is required when PhysicalBone3D switches from standing to ragdoll.
- Pin/Hinge default parameters without a Box3D equivalent only warn for nondefault
  values that change requested behavior, rather than every default ragdoll setup.
- Pin joints no longer map Godot's linear bias/damping onto the spherical joint's
  angular spring. Pin joints must allow free rotation; the old mapping made
  ragdolls artificially retain their rest pose. Nondefault unsupported tuning is
  reported explicitly rather than silently modifying angular behavior.
