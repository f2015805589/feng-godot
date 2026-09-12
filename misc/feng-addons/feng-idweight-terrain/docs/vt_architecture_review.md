# Surface VT architecture

## Ownership and frame flow

`Terrain3D` exposes one **VT Setting** configuration for page dimensions, borders,
physical capacity, production budget and diagnostics. `terrain_3d_surface_vt.cpp`
coordinates the producers; `Terrain3DVTPagePool` owns global physical slots, LRU,
protected pages and reverse ownership. AVT and SVT have separate addressing tables
pointing into the same physical ID/weight and material arrays.

1. Main-thread demand allocates virtual addresses and queues immutable CPU sources.
2. Native **VT Pass** (id 16), before GBuffer, runs the registered render-thread baker.
3. AVT evaluates material pages on the main RenderingDevice. SVT copies/composites validated
   cell source mips into cache pages. Dirty-cell automatic baking or a manual full
   bake updates the offline source files.
4. The terrain fragment samples albedo/height, world-normal/roughness and
   normal-depth/AO/AO-affect/valid arrays. Sector AVT selects its near detail before SVT and coarse procedural fallback;
   legacy region mode retains its region ownership policy.
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

New terrain regions cover **512 x 512 metres**. Procedural AVT uses independent
**64 x 64 metre sectors**, 8 x 8 inside a default region. These are material-cache
partitions, not separate mesh sizes. Bulk creation accepts a region count on X/Z;
20 x 20 regions span 10.24 x 10.24 km.

The old AVT resolution dropdown is removed. `surface_vt_texels_per_meter` sets the
base virtual material density (default 1024); `surface_svt_texels_per_meter` sets
SVT density independently. SVT stores the equivalent world page span for compatibility.
Changing physical page size preserves both metric densities. These settings cannot
create detail absent from the source material textures.

The AVT indirection atlas is 2048 x 2048 entries. With 256-texel physical pages:

| AVT texels/metre | Sector virtual image | Logical pages per axis | Allocated POT block |
| --- | --- | --- | --- |
| 768 | 49152 x 49152 | 192 | 256 x 256 |
| 1024 | 65536 x 65536 | 256 | 256 x 256 |
| 2048 | 131072 x 131072 | 512 | 512 x 512 |

Logical image extent is separate from allocator padding, so 768 does not silently
become 1024. Virtual block area is budgeted against the indirection atlas, not
against physical slots. At a distance, dropping global mip 0 reduces a 256-entry
block to 128, then 64; cached compatible pages keep their world footprints and
move to corresponding local mip addresses. Atlas pressure may discard additional
fine entries. Very large target densities can therefore exceed available address
space, especially with smaller physical pages.

Sector AVT now selects mip automatically from world-position screen derivatives.
CPU allocation and refinement use projected pixel density rather than distance bands;
old `surface_vt_mip_distances` values are retained only for legacy API compatibility.
The shader blends adjacent ready mip levels at fractional LOD and falls back to
coarser ready pages when detail is pending. This is isotropic trilinear virtual mip
filtering, not Hydra's anisotropic feedback path. The UI exposes density at each
level: by default 1024, 512, 256 texels/metre. Editing a level scales the whole
standard half-density chain; independent non-halving levels are not supported.
The CPU refines only
visible page footprints within the physical residency budget, without enumerating
or baking the complete virtual mip pyramid. Coarse procedural roots cover delayed
or over-budget detail. New pages are queued to the rendering-thread producer within
`vt_pages_per_update`; valid cached ancestors remain usable during refinement.
The demand tree now retains parents when refining children, counting both against
physical capacity. A world hierarchy bridges large roots down to individual 64 m
sectors; refinement prioritizes projected error across the whole visible tree,
without a nearest-sector cutoff. Virtual atlas pressure applies a shared mip bias
instead of greedily exhausting entries on the nearest sectors.

Sampling resolves world texel size across sector and world mips. Non-power-of-two
density transitions use the next world's actual texel size. A missing/coarser
neighbour feathers into a retained parent over a small boundary strip; equal-detail
neighbours do not gain a blurred seam. New ready pages fade from their parents over
200 ms. The 1024 slot weights use 256 packed vec4 uniforms (4 KiB), avoiding scalar
array std140 padding. Parent retention uses part of the existing page budget, so a
small pool can reach a coarser maximum detail than the old leaf-only scheduler.
`vt_adaptive_runner.py --filtering` checks immediate parent residency, page-border
continuity, removal of the fade between equally detailed neighbours, arrival
blending, integer LOD transitions and non-power-of-two sector/world transitions
in actual GPU readbacks. It does not certify every scene's appearance or implement
anisotropic material-cache filtering.

This implementation uses CPU frustum/footprint demand, not Hydra's GPU PageID
feedback implementation. The local Hydra analysis is in `docs/terrain_vt_and_streaming.md`;
the referenced D:/hydra/hydra-unity source checkout was unavailable during this work.

When both views are enabled, the entire selected region grid belongs to AVT,
including its far edges and pending detail pages. The region grid/offset/forward
controls also apply to 64 m sectors. SVT supplies other regions; an AVT miss uses
AVT coarse coverage or the missing-page diagnostic, never SVT. The previous metric
AVT/SVT distance switch was removed from the UI. Both share production/residency
budgets. SVT remains a fixed centred
world grid: increasing its texels/metre decreases addressable world extent, shown
in the VT settings window. Its independent mip-distance table remains supported.
SVT traversal now descends visible footprints instead of imposing a 16-page-per-region
minimum mip, allowing sub-metre pages in large terrain regions.

Legacy region-view and target-grid AVT modes remain for compatibility. Their old
resolution API is hidden from the editor; it does not configure sector AVT density.

SVT now follows the reference's separation of offline cell sources and runtime
cache pages. **Bake SVT** queues terrain cells, not world pages. A 512 m cell at
the default 1 texel/metre produces a 512 x 512 source image for each of the
three material channels, including a complete standard mip chain. Cell source
resolution is currently limited to 8192 per axis; larger requests report a bake
failure rather than silently reducing density.

Sources live in `svt_cells/<cell_x>_<cell_z>_0.vtcell`. Each file contains
a small metadata/preview record and an offset index followed by independently
Zstandard-compressed RGBA16F mip levels for the three channels. A distant page
seeks directly to its coarse source mip without reading the full-resolution image. Writes
use a temporary file and rename after completion. Old `svt/*.vtpage` files remain
untouched but are no longer read or generated; existing projects need one rebake.
The content signature covers density, material identity, spacing, surface/control
maps and neighbouring height data. Changing physical page size or border does not
invalidate the offline source. Dirty-cell baking also considers neighbouring cells.

Runtime uses a 256 MiB / 64-entry CPU cache of selected cell mips (one oversized
fine mip may reside alone), extracts only the required mip
rectangles, and queues a GPU compute copy/composition into physical cache pages.
A coarse page may combine several cells; runtime never reevaluates their materials.
The browser reads only metadata and small previews, not full source images. Disk
reads, source mip extraction and offline readback/serialization still run on the
main thread; this is not yet a background cell streaming worker or a compressed
GPU source texture cache. Offline baking uses a separate temporary GPU baker.

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

Visible SVT demand continues during offline generation, and exhausting the frame's
production budget does not stop resident-page protection for the remaining working
set. Missing persisted pages discovered by streaming schedule automatic repair when
Auto Bake is enabled. With Auto Bake disabled, newly required but absent files remain
explicit diagnostics until Bake.

The level a far-field page is produced at comes from one distance table,
`surface_svt_mip_distances` (one entry per level, in metres), and the shader resolves
its sample level through the same table, then walks coarser only. A point's rendered
level is therefore a pure function of its distance from the camera, and the sampled mip
cannot follow page residency. When the pool cannot hold the selected set, the pass raises
a coarseness floor: it finds the smallest level that makes the visible set fit and
coarsens only the pages finer than that floor, so pages already coarser keep the level
the table gives them, every visible chunk still resolves, and the choice depends on the
visible set and the pool size rather than on eviction order. The earlier density-ratio
selection coarsened every page until the whole set fit and extended the hierarchy to do
it, which changed a page's level from frame to frame while pages published at the previous
level stayed resident. `svt_effective_max_mip` reports the effective level cap.

Both AVT and SVT page-table reads use `texelFetch` with an explicit integer mip.
The material's `filter_nearest` sampler clamps sampled LOD to zero, so using
`textureLod` here could miss resident ancestor pages and display the purple missing
page diagnostic when the view selected coarser coverage. Integer page-table reads
bypass that sampler clamp without changing physical material texture filtering.
The adaptive GPU regression verifies that cached ancestors remain visible during
block growth with a one-page production budget, including after the source
material binding is replaced with a deliberately incorrect color.

`vt_svt_coverage_runner.py` exercises persisted material SVT over 144 regions with
an eight-slot shared pool and one-page update budget. It restores baked pages from disk
with the source albedo deliberately poisoned, then moves and turns the camera. A turn
that brings nearer terrain into view must produce the finer levels the distance table
names and auto-bake the pages behind them before all 81 visible non-AVT samples match
their authored materials. `vt_mip_bands_runner.py` pins the table itself: the band
edges, that every probe's distance-selected level is published, that a settled view
moves no level, and that a crowded pool keeps the nearest pages and still settles.

`vt_adaptive_runner.py --metric` verifies exact physical page footprints at 768,
1024 and 2048 texels/metre with only 32 physical slots, 256/128/64 distance-driven
page-table blocks, cached mip reuse, and independent high-density SVT requests.
The controls test verifies serialization and removes the obsolete resolution UI.

Validation on Windows / RTX 3080 Ti / D3D12: native debug extension builds;
metric density plus combined-view residency and controls tests pass; SVT distance
bands, automatic persistence and cross-process reuse pass; 10.24 km visibility
with 25600 sectors and 32 physical slots passes. In that deliberately all-visible
scale test the CPU demand pass averages about 69 ms, so GPU feedback / further
large-world scheduling optimization is still outstanding. High-density automatic
SVT repair queues current page demand; manual baking covers the addressable domain.
Persisted-page validation includes world footprint, preventing a density change
from accepting an old page solely because its source IDs and heights are flat.


### AVT CPU scheduling correction

The earlier ~69 ms average in the all-visible 25600-sector test included repeated
planning even for an unchanged view. Demand plans now reuse exact camera/projection,
viewport, region locations/heights and configuration keys. Cached plans still request
pages every demand epoch, so material edits and eviction repair do not stop. The GPU
sector directory only rebuilds when virtual allocations change; camera movement alone
no longer repacks/uploads it. Aligned regions avoid duplicate-sector maps, registered
block sizes are cached natively, and fully visible flat footprints use an allocation-free
frustum query. Fine-page height staging reuses source cell samples across columns.

Windows / RTX 3080 Ti / D3D12 regression measurements: stable warmed CPU updates
average 0.37 ms; 20 small camera translations average 10.86 ms in the same deliberately
all-visible 25600-sector scene. The run including initialization and initial production
averages 21.57 ms. These are CPU demand timings, not GPU frame time or FPS claims;
initial population and large moving views still have costs. GPU PageID feedback remains
unimplemented. Metric-density, combined-view demand, mip reuse, slope/border persistence,
editing invalidation and SVT distance-band regressions pass after these changes.


SVT UI counts distinguish persisted cell sources from resident physical pages.
A 512 m block at 8 texels/m stores a 4096 x 4096 source with mips; the runtime
256-texel page grid is an independent cache organization, not 256 disk files.
`vt_cells_runner.py` checks actual 4096 baking, source replacement after editing,
page-size-independent reuse and cross-process reload without material baking.
Its `--mix` case checks negative coordinates and a single coarse runtime page
composited from differently coloured cells. The ownership regression also checks
AVT automatic mip selection, whole-region ownership and the source browser.
