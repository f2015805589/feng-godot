# Surface VT architecture

## Ownership and frame flow

`Terrain3D` exposes one **VT Setting** configuration for page dimensions, borders,
physical capacity, production budget and diagnostics. `terrain_3d_surface_vt.cpp`
coordinates the producers; `Terrain3DVTPagePool` owns global physical slots, LRU,
protected pages and reverse ownership. AVT and SVT have separate addressing tables
pointing into the same physical ID/weight and material arrays.

1. Main-thread demand allocates virtual addresses and queues immutable CPU sources.
2. Native **VT Pass** (id 16), before GBuffer, runs the registered render-thread baker.
3. AVT evaluates material pages on the main RenderingDevice. SVT uploads validated
   persisted pages; dirty-page automatic baking or a manual full bake runs the SVT producer.
4. The terrain fragment samples albedo/height, world-normal/roughness and
   normal-depth/AO/AO-affect/valid arrays. The selected AVT region uses only AVT;
   all other regions use SVT. Ancestors are allowed only within the selected view.
   Missing material pages show an emissive magenta checkerboard and never evaluate
   original terrain materials. Lighting, colour-map wetness and macro variation
   remain in the draw for valid pages.

Original material evaluation is available only with material VT disabled or explicit
`vt_debug_direct_material` diagnostics. Its accumulators reset after the cache query
because GLSL `out` values are undefined on a miss. Distant single-point evaluation
replicates the fetched ID instead of blending unfetched material-zero corners.
Material pages use camera-independent full slope blending.

Custom terrain vertex displacement runs in GBuffer. The callback registry does not
replace a camera or world compositor. Callback snapshots retain the baker until an
in-flight call finishes. Runtime production never uses a local RenderingDevice,
`submit()`, `sync()` or material-page readback.

## AVT and SVT

AVT performs runtime material baking over a configurable region grid. **Visible
Terrain** (default) clips loaded region footprints against the camera frustum and
prefers the nearest visible region, with a small distance hysteresis to avoid
focus jitter. It does not use a downward ray or the camera's ground cell. **Target
Grid** follows the clipmap target (or camera) for character-centred workflows.
Grid dimensions, world-grid offset and forward offset (in region units) are editable.
Only eligible regions inside that grid publish AVT blocks; other terrain uses SVT. Metric distance does not select the AVT/SVT boundary.

Adaptive allocation reduces virtual resolution to fit the shared physical capacity.
Resizing changes both virtual address and mip to preserve each cached page's world
footprint. Fine pages that cannot cover a coarser footprint are discarded. Automatic
demand retains pages used in the previous pass, so oversubscription retains valid ancestors or exposes missing pages
instead of continuous eviction and rebaking. Explicit offline bake retains normal LRU.
The old distance/feedback APIs are compatibility diagnostics, not normal AVT selection.

SVT uses world-aligned addresses. **Bake SVT** queues tiles covering resident terrain
and their parent mip hierarchy, protects in-flight output, exports the three material
channels, and saves `.vtpage` records under the terrain data directory's `svt/` folder.
Runtime reuse checks source ID/height bytes, page configuration and material identity.
Missing or stale baked tiles show the diagnostic checkerboard until automatically or manually rebaked.
VT Page distinguishes Missing bake, Stale/invalid bake and Pending upload. These files are
uncompressed development caches; disk I/O currently runs within the page-count budget
on the main thread, not a background streaming worker.

The native Terrain3D inspector orders **VT Setting / AVT / SVT / VT Page** under
**Surface VT**. VT Page is an actual collapsible inspector subgroup with an overview
entry; the same hierarchy is available in the dedicated Surface VT window.
VT Page displays baked SVT colours in world positions (default mip 0), independently
of physical-cache eviction. Selecting a tile locates the corresponding region data.
**Auto Bake** is enabled by default for saved terrain. Editing waits for a 500 ms
quiet interval, then batches only pages whose footprints (including borders and
parent mips) intersect dirty regions. A stable frame does not create another job.
Automatic maintenance queues and exports at most one page per frame, within the
shared production budget. Unchanged persisted pages are reused without rewriting
their files. **Bake All SVT
Pages** explicitly regenerates every page, even when cache files already exist.
Explicit preview/export and changed-page persistence may read back GPU output;
idle editor refresh does not.

## Editing and invalidation

Paint and height edits invalidate affected pages including their borders. Material
changes invalidate material results. Invalid AVT pages show diagnostics until runtime
production completes; invalid SVT pages queue a debounced incremental rebake when Auto Bake is enabled.
The `vt_debug_direct_material` setting isolates the legacy ID/weight cache for
regression tests and diagnosis, bypassing material baking and adaptive allocation.

## Performance and shader structure

- Sparse source production caches only loaded regions intersecting a page, rather
  than allocating temporary storage proportional to a huge, mostly empty world.
- Page-table initialization copies encoded invalid values without per-texel extension
  calls. Unchanged region block maps do not cause material rebinding.
- The automatic scheduler splits one page production budget across both producers.
  Explicit offline baking also proceeds in batches; this is not a millisecond cap.
- Updating page bindings no longer incorrectly triggers a full shader rebuild.
- Release extension builds exclude `debug_views.glsl` using `DEBUG_ENABLED`.
  Debug/editor builds insert only enabled debug views and remove their uniforms when
  disabled. Normal rendering samples baked materials before the expensive evaluator.
- Optional legacy GPU demand feedback still uses a local-device synchronous readback;
  it is restricted to explicit direct-material diagnostic mode. It is a diagnostic/compatibility path.

## Validation and scale

`vt_material_runner.py` exercises real material production, cache-hit rendering after
poisoning source texture bindings, editing/rebaking, adaptive resizing, SVT export and
SVT-only terrain rendering. `vt_runtime_runner.py` tests shared eviction/remapping;
`vt_render_runner.py` independently checks the raw ID/weight shader contract.

A new native Terrain3D and the editor's Initialize Terrain workflow both default to
512 samples at 1 metre spacing (512 x 512 metres per region). Existing region files
keep their dimensions. World size is `region_size * vertex_spacing`; page resolution
is separate. The editor starts with **None** selected, with no brush or region action.

## Removed inactive code

The unused dual-scaling shader and its preload/exclusion plumbing were removed;
the old property remains storage-only for scene compatibility and no longer triggers
a pointless shader rebuild. Shared allocation/eviction counters now live only in the
physical page pool. An unused eviction forwarding helper and an inert commented
editor-injection loop were deleted. VT-disabled material evaluation, raw diagnostics, offline export,
and custom shader APIs remain because they have active callers or recovery roles.

`vt_pressure_runner.py` reproduces the small-cache regression with 512-texel pages,
eight physical slots and six terrain regions. Both adaptive and fixed resolution
settle without further allocations/evictions/bakes over 36 physics ticks, while
movement and painting still produce fresh pages. `vt_runtime_runner.py` verifies
that grow/shrink remapping preserves world footprints and clears released protection.

`vt_auto_bake_runner.py` verifies initial automatic production, stroke debouncing,
no idle baking, incremental parent-page updates, unchanged distant file hashes,
forced manual full regeneration, cross-process reuse, and live AVT production
during a full SVT bake with only eight shared slots. `vt_fallback_runner.py` verifies visible
missing-page diagnostics, valid SVT rendering, and no AVT-to-SVT fallback.

Persistent material identity uses the existing texture-content SHA256 keys and
baking parameters. These identities survive source-asset release and process restarts;
transient resource instance IDs are not included in persisted cache validation.

## Visible demand and concurrent baking

`terrain_3d_vt_visibility.h` shares frustum-clipped footprint queries between AVT
focus and normal SVT demand. It samples the region height bounds and midpoint;
it is a conservative CPU visibility approximation, not occlusion testing.
`terrain_3d_vt_demand.cpp` prioritizes the closest visible pages, deriving relative
mips from their projected density and coarsening when the working set exceeds the
physical budget. It excludes AVT-owned regions and does not request pages by map
row order or a ray beneath the camera. The nearest visible footprint establishes
the finest level even when the ground below the camera is outside the view.

Offline SVT generation runs after live AVT demand in the same protection epoch.
It uses the remaining allocation budget and waits for temporarily protected slots;
it does not pause AVT or fail a job merely because the cache is currently busy.
The native Inspector SVT subsection exposes **Bake All SVT Pages** alongside
**Auto Bake**, with CPU-only progress status.

Clipmap trim, edge and fill meshes intentionally have thin rectangular shapes.
The renderer instances identical meshes across LOD rings. VT material production
uses compute dispatches and does not generate these terrain mesh shapes.
