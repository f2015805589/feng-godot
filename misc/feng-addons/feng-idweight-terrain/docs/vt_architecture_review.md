# Surface VT architecture

This is the current ownership and frame-flow guide. Addressing and streaming are in
[terrain_vt_and_streaming.md](terrain_vt_and_streaming.md); channel selection and
Clipmap configuration are in [vt_delivery_assembly.md](vt_delivery_assembly.md).
Historical measurements are indexed separately in [README.md](README.md).

## Ownership

`Terrain3D` owns authoring settings, subsystem lifetime and scheduling. Each subsystem
owns the state transitions behind its public operations. The source is grouped by concern:

| Owner | Responsibility |
| --- | --- |
| `terrain_3d.cpp`, `_wiring`, `_properties`, `_queries`, `_bindings`, `_monitors` | Node lifecycle, subsystem wiring, public API and monitor lifetime |
| `terrain_3d_vt_state.h` | Node-owned VT configuration and coordinated state: pool generation, plans, fades, bake jobs and Clipmap layers |
| `terrain_vt.h` | Engine-independent page coordinates, mip lookup and POT virtual-block allocation |
| `terrain_3d_virtual_texture*`, `terrain_3d_vt_indirection*` | Per-view addressing, virtual blocks and dirty page-table uploads |
| `terrain_3d_vt_page_pool*` | Shared physical slots, synchronous allocation, LRU, pin counts and reverse ownership |
| `terrain_3d_sector_avt*`, `terrain_3d_avt_plan*`, `terrain_3d_avt_produce.cpp` | Near-field motion prediction, sector hierarchy, immutable planning input and page production schedule |
| `terrain_3d_surface_views*` | Delivery selection, view configuration, near/far demand and SVT root/visible-page planning |
| `terrain_3d_page_pipeline*`, `terrain_3d_surface_source.cpp` | Bounded worker requests and immutable source snapshots |
| `terrain_3d_vt_service*` | Shared service lifetime, invalidation, source routing, diagnostics and offline cell baking |
| `terrain_3d_vt_cells*`, `terrain_vt_cell.h` | GPU-resident SVT cell sources and the versioned `.vtcell` format |
| `terrain_3d_surface_baker*` | GPU resources, candidate/live/retired bundles, queues, material bake/copy and block encoding |
| `terrain_3d_clipmap*`, `terrain_3d_material_clipmap_detail*` | Per-channel Clipmap storage/source interfaces and material detail residency |
| `terrain_3d_data*`, `terrain_3d_region*`, `terrain_3d_streamer*` | Region persistence, stable GPU slots, map edits and chunk residency |
| `terrain_3d_material*`, `native/src/shaders/` | Resource properties, selected shader variants, bindings and sampling |
| `terrain_3d_mesher*`, `terrain_3d_cdlod*`, `terrain_3d_instancer*` | Geometry, optional CDLOD and mesh-instance lifetime |

Multi-file implementations share constants/helpers through their internal headers.
CPU and shader addressing change together. `_configure_surface_view()` applies the
same complete configuration on initial setup and pool rebuild.

On the editor side, `vt_editor.gd` owns the window and selection; `vt_terrain_bridge.gd`
performs its guarded native calls. Overview/image math and page rows are data helpers;
SVT bands and CDLOD controls own their panels. Inspector and plugin callers guard their
own optional native methods. `asset_dock.gd` owns EditorDock hosting, asset-source
bindings and list selection; list containers and entries own their resource subscriptions.
`ui_decal.gd` owns cursor visuals. Signals and temporary resources are released by the object that registered them.
Node resource replacement disconnects the old material/assets graph before uninitializing it;
asset-list membership owns each asset subscription. Bulk and single sector remaps use the
same ownership transitions; public nearest-surface queries share the region-boundary sampler.
The asset list derives its selectable limit from the actual trailing empty tile. Channel
packing cancellation/closure clears queued follow-on work.

`vt_layout_preview.gd` owns the weak terrain reference, availability polling and stale-layout
cleanup; AVT and Clipmap subclasses own their native gate, layout read and drawing.
Inspector blocks follow the preview's initial availability and change signal, so hidden
views keep checking availability without duplicate native queries or layout reads.

## Defaults and units

| Setting | Default / meaning |
| --- | --- |
| Region geometry | 512 samples at 1 m spacing; existing region files retain their dimensions |
| Delivery | Near Material AVT, Far Material SVT, both Height cells Direct |
| AVT sector | Fixed 64 × 64 m world cell, independent of region and virtual-image size |
| AVT density / reach | 1024 texels/m / 384 m; projected demand chooses resolution and local mip |
| SVT density | 1 texel/m; distance bands choose world-page mips |
| Shared pool | 256 slots, 256-texel core, 5-texel border; automatic growth up to 1024 slots |
| Material compression | Uncompressed per tier; BC7 and BC3 are optional |
| Coarse recovery | AVT and SVT feedback enabled |
| Arrival ramp | `vt_page_fade_frames = 12` ticks; zero disables it |
| AVT batch | Default 16, maximum 64; the motion/unserved-view governor selects the live allowance |
| Editor preview | Enabled; direct live material display with runtime VT and auto-bake paused |

A 64 m sector at 1024 texels/m names a 65,536² virtual image, not a resident texture.
Physical slots, virtual-address capacity, screen footprint and source detail bound output.
Changing physical page dimensions preserves the metric density settings.
The anisotropy limit is shared by CPU/shader footprint selection and bounded by the
viewport sampler and `2 * border - 1`; the default border supports the requested 8×.

## Frame flow

1. Main-thread region updates publish immutable source bytes. Delivery selection chooses
   active services and shader arms. A never-selected service allocates no runtime resources;
   a deselected service can retain its cache while its work and bindings are stopped.
2. AVT predicts eye/gaze motion, derives or reuses a bounded sector plan, retains useful
   ready pages and submits source requests. SVT plans protected roots and visible footprints.
3. Separate bounded AVT/SVT worker queues prepare source payloads. Workers use snapshots,
   with tokens/generations rejecting cancelled or superseded results. Teardown joins them
   before destroying their owners; normal demand updates do not wait for worker completion.
4. Main-thread publication owns slots and page-table state. Dirty 16×16 table tiles are
   queued to the render thread; failed submissions remain retryable. Pending work keeps
   the editor drawing even if the page baker itself is idle.
5. The native FRP **VT Pass** (ID 1) executes the registered main-RenderingDevice producer
   before GBuffer. It evaluates material pages, copies/composes SVT cells and encodes blocks.
   The render graph orders direct buffer-to-texture copies before sampling.
6. Readiness and bindings publish coherently. Replaced GPU bundles retire after the material
   acknowledges newer outputs. Reused slots clear readiness; lost content is retried.

The live AVT allowance feeds production, worker-window sizing and encoding capacity.
`vt_pages_per_update` is positive; CPU deadlines are soft and checked between work units.
Pool size is residency capacity, not work per frame. Cold views, edits and capacity changes
can require several frames; no fixed all-frame CPU latency is guaranteed.

## Sampling and missing pages

AVT samples a flat sector directory plus a mip-carrying page table. CPU projected demand
and shader derivatives use matching footprints. The explicit plan distinguishes an
unrequested level from a planned page whose content is late. SVT uses a world grid and
its distance-selected mip/coarseness floor. Each field's feedback toggle permits coarser
resident recovery within that field; disabling it exposes selected-page misses.

The outer 25% of AVT reach blends to SVT. In that transition band a ready side can serve
while the other arrives; outside it the selected tier owns the sample. Arrival ramps
blend ready detail against available ancestors. A complete material-cache miss uses the
diagnostic path. Direct author-material evaluation is selected explicitly by delivery,
editor preview or the direct-material diagnostic mode. Legacy raw-ID tests have their
own source-sampling path.

## Source and editor lifetime

SVT material sources come from GPU-resident cells, valid `.vtcell` files or resident
region payloads. Runtime disk read/decompression/cropping runs on its worker queue;
offline bake/export and editor previews are separate operations. The decoded mip cache
is bounded at 256 MiB / 64 entries, allowing one oversized mip alone.

A default 512 m cell at 1 texel/m stores three 512² material sources and complete mips;
source resolution is capped at 8192. Signatures include density, material/source revisions
and neighboring height data. Save-terrain and bake-SVT are separate operations.
Auto Bake debounces edits by 500 ms; explicit Bake regenerates all cells. Old `.vtpage`
files require rebaking to `.vtcell` and are left untouched.

Editor preview combines dirty invalidations until it closes; manual Bake remains available.
Built-in shader variants include only selected delivery resources. Custom shader overrides
retain their declared interface. Height stays RF; region Surface Maps stay packed R16.
Geometry displacement and lighting remain draw-time work, separate from cached materials.

## Diagnostics and verification

`get_vt_settings()` is a flat compatibility API assembled by subsystem owners. Read actual
capacity, formats, live services, producer readiness, source queues and phase times together.
Peak snapshots include their age; they are distinct from the latest pass. The detailed
Clipmap report separates resolved settings from allocated runtime layers.

Use [native/tests/README.md](../native/tests/README.md) for current commands and assertion
scope. CPU contracts, native lifecycle tests, GPU images and editor integration are
separate gates. Historical D3D12 timings and preserved-image comparisons in the
[optimization audit](terrain_optimization_audit.md) apply only to their recorded builds.
