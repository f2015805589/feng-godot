# Surface VT architecture

## Module map

The native side is a `Terrain3D` node plus the subsystems it owns. `Terrain3D`
itself is the façade: the properties the editor and scripts see, region
streaming, geometry, collision, instancing and the physics-tick scheduler. Its
definitions live in six files, one per concern -- `terrain_3d.cpp` (lifecycle,
notifications, containers, mesh/collision/instancer wiring, the tick scheduler),
`terrain_3d_vt_service.cpp` (the virtual texture service and both demand passes),
`terrain_3d_properties.cpp`, `terrain_3d_queries.cpp` and
`terrain_3d_bindings.cpp` -- so a concern can be read without the others. Its two
longest passes are written as named phases rather than locals: `update_surface_vt`
is one loop over the helpers that rebuild the block tables, decide sector sizes,
resolve each sector's pages and publish the result, and `_produce_sector_avt_pages`
is one pass over `_avt_classify_plan`, `_avt_retain_visible`, `_avt_prime_sources`,
`_avt_produce_visible`, `_avt_produce_prefetch` and `_avt_finish_produce`, whose
per-pass state is `Terrain3DAVTProducePass`. The virtual texture machinery itself
lives in these files, and each one owns one thing:

| File | Owns |
| --- | --- |
| `terrain_vt.h` | The addressing contract only: page IDs, virtual-image kinds, the block allocator. Header-only, no Godot dependency, no runtime state. |
| `terrain_3d_vt_state.h` | Every VT field `Terrain3D` owns, in one struct: the shared service, the near-field AVT and the far-field SVT, grouped in the same order as the passes that use them. No algorithms, no cross-field initializers. The node's own fields stay in `terrain_3d.h`. |
| `terrain_3d_virtual_texture.{h,cpp}` | One view's indirection texture and its virtual blocks, plus `Terrain3DVTPagePool`: the physical `Texture2DArray`, slot free list, LRU, protection and the reverse owner index. No terrain data, no demand. |
| `terrain_3d_avt.h` | Plain records of the near-field demand: page requests, the asynchronous plan result, cached addresses, sectors and the working set. No algorithms. |
| `terrain_3d_sector_avt.cpp` | The near field end to end: the camera/config plan key, the 64 m sector scan, the coarse hierarchy and address directory, the asynchronous page selection, and page production from the region payload. |
| `terrain_3d_vt_demand.cpp` | The far field's demand pass over the world page grid, with the shared capacity floor. |
| `terrain_3d_page_pipeline.{h,cpp}` | The worker and planner threads, the immutable region snapshot they read, raw-ID page payload production, and `.vtcell` reads. |
| `terrain_vt_cell.h` | The `.vtcell` on-disk contract: format version, file name and the source signature. Shared by the baker that writes the files and the runtime reader that consumes them, because the two must agree exactly. |
| `terrain_3d_vt_cells.{h,cpp}` | The resident far-field cell sources: three GPU arrays (one layer per cell, full mip chain), the cell registry, the memory budget with its LRU eviction, and the per-(channel, layer, mip) views the page copy shader binds. A cell published here is what makes far-field page assembly a device-to-device copy with no file and no CPU work. |
| `terrain_3d_surface_vt.cpp` | VT service lifecycle and configuration, capacity growth, invalidation, the `.vtcell` bake/read path, the single page-production choke point and VT telemetry. No demand planning. |
| `terrain_3d_data_surface.cpp` | The region payload -> page resampler both tiers call: `produce_surface_page_set` for a sector block at one local mip, `produce_surface_rect_page` for a world-space page rectangle. One of three files defining `Terrain3DData`; `terrain_3d_data.cpp` owns the slots, maps and queries and `terrain_3d_data_io.cpp` the region files and map import/export. |
| `terrain_3d_vt_indirection.{h,cpp}` | Render-thread upload of the CPU-authored page table, coalesced into 16x16 tile patches. |
| `terrain_3d_vt_visibility.h` | Camera-visible terrain footprint queries shared by both fields. Header-only, camera-only dependency. |
| `main.glsl` | Sampling: the shader resolves a fragment's payload texel to a virtual page and walks up the mip chain. Address arithmetic here must match the C++ side exactly. |

Two rules keep the split honest, and both are load-bearing:

1. **`Terrain3D` owns configuration and the frame schedule; the VT files own the
   algorithms.** A change to how pages are chosen belongs in the demand file for
   that field, not in `terrain_3d.cpp`.
2. **Addressing is computed in exactly one place per field.** The near field
   publishes a hashed sector directory the shader reads; the far field's page
   address is a pure function of world coordinates on both sides. Any new
   addressing rule has to be added to the C++ side and `main.glsl` together.
3. **A view is configured by one function.** `_configure_surface_view()` applies
   page dimensions, format and the mode-specific addressing; both the initial
   setup and a shared-pool rebuild call it, so neither path depends on settings a
   previous configuration happened to leave on the object.

On the GDScript side the same rule applies to the VT window: `vt_editor.gd` owns
the widgets and the selection state, `vt_terrain_bridge.gd` owns every duck-typed
call into the extension (a missing native method must read as "unavailable", not
break the editor), and `vt_overview_image.gd` owns the world/image maths and the
per-pixel stitching, as pure functions over data passed in. The asset dock's list
and tile widgets are shared by both dock versions in `asset_dock_list_*.gd`, and
the editor cursor decal is `ui_decal.gd`: the tool bar (`ui.gd`) keeps tool, brush
and pointer state and forwards `update_decal()`, while the decal module owns the
shader parameters, the decal arrays, the fade tween and the region-directory
preview.

## Dimensions and controls

A new terrain region is 512 samples at 1 metre spacing: **512 x 512 metres of geometry**. Existing region files keep their dimensions. Bulk initialization accepts X/Z region counts; 20 x 20 spans 10.24 x 10.24 km.

Procedural AVT partitions material addressing into **64 x 64 metre sectors** (8 x 8 per default region). The AVT indirection atlas has 2048 x 2048 R32F entries and a manual mip chain. The default shared pool has 256 physical slots, each with a 256 x 256 texel core and 4-texel borders (264 x 264 storage).

| Density | Virtual image per 64 m sector | Logical entries per axis | Allocator block |
| --- | --- | --- | --- |
| 768 texels/m | 49152 x 49152 | 192 | 256 x 256 |
| 1024 texels/m (default) | 65536 x 65536 | 256 | 256 x 256 |
| 2048 texels/m | 131072 x 131072 | 512 | 512 x 512 |

Allocator padding does not change logical density. These virtual images are not fully resident textures. Physical capacity, address capacity, screen footprint and original material detail all constrain visible quality. Changing physical page size preserves metric densities.

`surface_vt_texels_per_meter` and `surface_svt_texels_per_meter` are independent. The AVT resolution dropdown and fixed mip-distance controls have been removed. Fixed-distance compatibility setters are no-ops; the legacy distance array remains for legacy/diagnostic APIs. Sector AVT uses automatic screen-footprint mip selection. The UI shows three half-density levels (1024/512/256 by default); editing one scales the standard chain, which continues beyond these three levels. SVT keeps its separate distance table.

## Ownership and frame flow

- `terrain_3d_surface_vt.cpp` configures shared services, invalidation and source lifetime. `Terrain3DVTPagePool` owns physical allocation, LRU, protection and reverse ownership.
- `terrain_3d_sector_avt.cpp` builds visible and idle sector demand and retains address blocks. `terrain_3d_vt_demand.cpp` schedules visible SVT footprints with a common capacity floor. Both tiers point into the shared physical arrays.
- `terrain_3d_vt_indirection.cpp` owns RD indirection initialization and dirty-tile uploads. CPU updates coalesce by mip/tile; the render thread copies 16 x 16 tiles. Failed initial/patch submissions remain available for retry. Encoded page IDs remain exact R32F values. The upload is queued into the render thread, so it only runs while frames are drawn: while a view still owes one, `Terrain3D::_update_vt_service()` keeps asking the editor for a redraw even when the baker has nothing pending.
- The native **VT Pass** (id 16) runs the registered main-RenderingDevice baker before GBuffer. AVT evaluates material pages; SVT copies/composites baked cell source regions. Runtime production does not use a local-device submit/sync or material readback.
- Terrain shading resolves albedo/height, world-normal/roughness and normal-depth/AO/AO-affect/valid outputs. Lighting, color-map wetness and macro variation remain in the draw. Custom terrain vertex displacement remains in GBuffer.

Missing detail resolves through ready parents. A complete cache miss uses explicit diagnostics rather than evaluating original materials. Original evaluation remains available with VT disabled, editor preview or explicit direct-material diagnostics. Legacy region/target-grid AVT and raw-ID diagnostic APIs remain reachable and were not deleted as dead code.

## Coverage, mip filtering and camera turns

With both tiers enabled, AVT covers a camera-centred XZ radius of 512 m by default, requesting visible resident terrain across region boundaries. Its outer 25% blends into SVT; a sector-sized margin retains coarse coverage. SVT skips only footprints entirely inside the AVT interior. With SVT disabled, AVT supplies the whole visible world. Region Grid, Offset and Forward controls are hidden compatibility state and do not control sector coverage.

The planner retains compatible nearby sector address blocks and ready pages across turns. Visible requests have priority. Idle surrounding prefetch uses only free physical slots and cannot evict visible work. Offscreen blocks can be reclaimed under pressure; terrain beyond the active range is released when SVT provides the far field. This avoids repeatedly rebuilding warmed headings without lowering foreground target density or enlarging the default pool.

CPU refinement uses projected pixel density; the shader uses world-position derivatives and fractional mip blending. Parents remain resident during refinement, including the world hierarchy above 64 m sectors. Missing/coarser neighbours feather into a ready parent, while equal-detail neighbours stay sharp. New ready pages fade from their parent over 200 ms. Non-power-of-two densities use actual world texel sizes across sector/world transitions. Filtering is isotropic virtual trilinear filtering; it does not use anisotropic GPU page demand.

AVT page production obeys the shared page budget and an approximately 3 ms CPU soft limit checked between pages. A single page can exceed that limit. Cold starts, newly visited regions, edits and insufficient cache capacity still need generation and can expose refinement. Prefetch exchanges idle warm-up work for later reuse; it is not a zero-cost guarantee for arbitrary turns.

## Baked SVT sources

SVT defaults to **1 texel/metre**. A 512 m cell bakes three 512 x 512 RGBA16F material sources with complete mip chains. At 8 texels/m the cell source is 4096 x 4096. Source resolution is limited to 8192 per axis; unsupported larger requests fail rather than silently reduce density.

`svt_cells/<x>_<z>_0.vtcell` stores metadata, a preview and indexed, independently Zstandard-compressed channel/mip chunks. Distant requests seek directly to a coarse mip. Writes use temporary files and rename. Source signatures include density, materials, spacing, surface/control maps and neighbouring height data; physical page size/border changes do not invalidate sources. Old `.vtpage` files are not read or generated and remain untouched; old projects need a rebake.

Runtime caches selected source mips (256 MiB / 64 entries, allowing one oversized mip), extracts required rectangles, and queues GPU copy/composition into physical slots. One runtime page may combine several cells. Baking by cell does not imply one physical slot per cell. Runtime SVT assembly does not generate unused height inputs or retain height-byte copies in page records. A cell that was baked in the running session (or imported) is also published into the resident cell store, and page assembly for it reads no file at all; a page whose cell is neither resident nor persisted is produced from the resident region payloads, so the far field never depends on a bake file to render.

SVT's fixed centred world address grid has a smaller world extent at higher density; the window displays its bounds. Distance selection supplies requested mips. If they exceed capacity, a shared coarseness floor merges pages canonically in mip-0 coordinates using the destination mip, including negative coordinates. Shader page-table fetches use integer mip `texelFetch`, avoiding sampler LOD clamping.

Auto Bake is enabled by default for saved terrain, with a 500 ms edit debounce. It queues dirty cell sources and advances incremental baking/export; explicit Bake regenerates all source cells. The browser distinguishes baked cells from resident physical pages and reads small metadata/previews. Disk reads, source extraction and offline GPU readback/serialization are still main-thread work, not a background streaming worker.

## Editor and shader specialization

`vt_editor_preview` defaults on and is editor-only. It shows live material evaluation and the surface array, pauses runtime VT requests and automatic SVT baking, and combines dirty invalidation until preview closes. Manual Bake remains available. Saving terrain does not update its offline SVT sources; bake explicitly or let auto-bake finish with preview off. Direct preview may differ from coarse cached output.

For the built-in material, preview or both VT tiers disabled generates a shader without VT samplers/uniform resources and lookup/filter functions. Eight VT samplers disappear in preview and return on resume. A dedicated uniform helper also skips constructing VT state for this variant. Custom shader overrides retain the full interface; generated overrides are not frozen into preview mode. Displacement still uses its required material snippets. The assembly that decides this lives in `terrain_3d_material_shader.cpp` (insert loading, editor/debug injection, comment stripping, `_needs_vt_shader`), while `terrain_3d_material.cpp` owns the material resource and its uniforms.

The main and bake shaders no longer calculate the initial linear material selection that pair-aware slope selection overwrote. Shared layout exclusions avoid duplicated shader-generation rules. Debug/editor builds include only selected debug views; Release excludes debug-view source.

## Geometry, data and deleted work

Clipmap construction shares seven unique grids instead of ten duplicated resources. Five ordered native instance groups replace nested Variant containers, and cached transforms avoid unchanged server submissions. Vertex/index order, instance geometry, seam meshes and displacement/background bounds remain intact. MultiMesh uploads use one packed transform/color buffer; append operations retain writable arrays per cell/region and write back once.

The cleanup also removes unreachable non-diagnostic SVT scheduling branches, unused baker helpers/arguments, overwritten shader calculations, unused editor average mode/state and unconsumed VT height copies. RF height extrema scan base-level bytes directly. Array synchronization checks whether a payload is needed before resampling it. Streamer ring traversal preserves ordering and failed saves retain resident ownership. Filtered asset entries are freed immediately instead of leaking unparented nodes and callbacks.

## Evidence and limits

The [optimization audit](terrain_optimization_audit.md) records the full source inventory, preserved DLL/image fixtures, measured CPU/GPU/draw values and individual regressions. Debug and Release native builds pass. Tests cover material baking/reload, cell composition, pressure addressing, mip filtering, metric density, large worlds, editor painting/preview, instancer output and allocator contracts.

In the fixed D3D12 camera-turn fixture, warmed CPU AVT updates fell from about 3.6–4.1 ms to 0.27–0.32 ms. Four warm turns generated zero pages and sampled image differences were zero; settled images match the preserved baseline. This is not an overall FPS/GPU speedup claim. Cold output still differs until ready.

Draw calls and overdraw were measured, not reduced by deleting required seam geometry or tightening unsafe bounds. The hilly-scene diagnostic preserves terrain vertex deformation and measures potential front-face overlap, not actual early-Z fragment cost. Built-in FRP overdraw substitutes a vertex shader and cannot validate displaced terrain. Arbitrary custom shaders, all shadow configurations, GPU allocation failure injection and complete Godot 4.5 docking are outside the demonstrated regression scope. Whole-world moving demand and synchronous SVT source I/O remain performance limits.

Demand is CPU footprint based; see `terrain_vt_and_streaming.md` for the addressing contract and
`terrain_3d_vt_feedback.cpp` for the optional GPU projection pass. This is not a claim of exact
per-fragment GPU page feedback.


## Optional geometry backend and capture

The CDLOD foldout after SVT enables a quadtree/MultiMesh backend for finite built-in terrain. See [CDLOD and capture](cdlod_and_capture.md) for controls, compatibility, measured draw scope and the removal of forced all-page work from normal RenderDoc capture.



## History

The tuning passes that produced the current behaviour -- measured frame costs,
the hill-residency investigation, the cache-growth policy and the stationary
editor wakeup -- are recorded chronologically in
[`history/vt_tuning_log.md`](history/vt_tuning_log.md). They are not a
description of the code: later entries supersede earlier ones.
