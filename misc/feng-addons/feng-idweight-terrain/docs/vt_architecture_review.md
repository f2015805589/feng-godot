# Surface VT architecture

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
- `terrain_3d_vt_indirection.cpp` owns RD indirection initialization and dirty-tile uploads. CPU updates coalesce by mip/tile; the render thread copies 16 x 16 tiles. Failed initial/patch submissions remain available for retry. Encoded page IDs remain exact R32F values.
- The native **VT Pass** (id 16) runs the registered main-RenderingDevice baker before GBuffer. AVT evaluates material pages; SVT copies/composites baked cell source regions. Runtime production does not use a local-device submit/sync or material readback.
- Terrain shading resolves albedo/height, world-normal/roughness and normal-depth/AO/AO-affect/valid outputs. Lighting, color-map wetness and macro variation remain in the draw. Custom terrain vertex displacement remains in GBuffer.

Missing detail resolves through ready parents. A complete cache miss uses explicit diagnostics rather than evaluating original materials. Original evaluation remains available with VT disabled, editor preview or explicit direct-material diagnostics. Legacy region/target-grid AVT and raw-ID diagnostic APIs remain reachable and were not deleted as dead code.

## Coverage, mip filtering and camera turns

With both tiers enabled, AVT covers a camera-centred XZ radius of 512 m by default, requesting visible resident terrain across region boundaries. Its outer 25% blends into SVT; a sector-sized margin retains coarse coverage. SVT skips only footprints entirely inside the AVT interior. With SVT disabled, AVT supplies the whole visible world. Region Grid, Offset and Forward controls are hidden compatibility state and do not control sector coverage.

The planner retains compatible nearby sector address blocks and ready pages across turns. Visible requests have priority. Idle surrounding prefetch uses only free physical slots and cannot evict visible work. Offscreen blocks can be reclaimed under pressure; terrain beyond the active range is released when SVT provides the far field. This avoids repeatedly rebuilding warmed headings without lowering foreground target density or enlarging the default pool.

CPU refinement uses projected pixel density; the shader uses world-position derivatives and fractional mip blending. Parents remain resident during refinement, including the world hierarchy above 64 m sectors. Missing/coarser neighbours feather into a ready parent, while equal-detail neighbours stay sharp. New ready pages fade from their parent over 200 ms. Non-power-of-two densities use actual world texel sizes across sector/world transitions. Filtering is isotropic virtual trilinear filtering, not Hydra anisotropic GPU feedback.

AVT page production obeys the shared page budget and an approximately 3 ms CPU soft limit checked between pages. A single page can exceed that limit. Cold starts, newly visited regions, edits and insufficient cache capacity still need generation and can expose refinement. Prefetch exchanges idle warm-up work for later reuse; it is not a zero-cost guarantee for arbitrary turns.

## Baked SVT sources

SVT defaults to **1 texel/metre**. A 512 m cell bakes three 512 x 512 RGBA16F material sources with complete mip chains. At 8 texels/m the cell source is 4096 x 4096. Source resolution is limited to 8192 per axis; unsupported larger requests fail rather than silently reduce density.

`svt_cells/<x>_<z>_0.vtcell` stores metadata, a preview and indexed, independently Zstandard-compressed channel/mip chunks. Distant requests seek directly to a coarse mip. Writes use temporary files and rename. Source signatures include density, materials, spacing, surface/control maps and neighbouring height data; physical page size/border changes do not invalidate sources. Old `.vtpage` files are not read or generated and remain untouched; old projects need a rebake.

Runtime caches selected source mips (256 MiB / 64 entries, allowing one oversized mip), extracts required rectangles, and queues GPU copy/composition into physical slots. One runtime page may combine several cells. Baking by cell does not imply one physical slot per cell. Runtime SVT assembly does not generate unused height inputs or retain height-byte copies in page records.

SVT's fixed centred world address grid has a smaller world extent at higher density; the window displays its bounds. Distance selection supplies requested mips. If they exceed capacity, a shared coarseness floor merges pages canonically in mip-0 coordinates using the destination mip, including negative coordinates. Shader page-table fetches use integer mip `texelFetch`, avoiding sampler LOD clamping.

Auto Bake is enabled by default for saved terrain, with a 500 ms edit debounce. It queues dirty cell sources and advances incremental baking/export; explicit Bake regenerates all source cells. The browser distinguishes baked cells from resident physical pages and reads small metadata/previews. Disk reads, source extraction and offline GPU readback/serialization are still main-thread work, not a background streaming worker.

## Editor and shader specialization

`vt_editor_preview` defaults on and is editor-only. It shows live material evaluation and the surface array, pauses runtime VT requests and automatic SVT baking, and combines dirty invalidation until preview closes. Manual Bake remains available. Saving terrain does not update its offline SVT sources; bake explicitly or let auto-bake finish with preview off. Direct preview may differ from coarse cached output.

For the built-in material, preview or both VT tiers disabled generates a shader without VT samplers/uniform resources and lookup/filter functions. Eight VT samplers disappear in preview and return on resume. A dedicated uniform helper also skips constructing VT state for this variant. Custom shader overrides retain the full interface; generated overrides are not frozen into preview mode. Displacement still uses its required material snippets.

The main and bake shaders no longer calculate the initial linear material selection that pair-aware slope selection overwrote. Shared layout exclusions avoid duplicated shader-generation rules. Debug/editor builds include only selected debug views; Release excludes debug-view source.

## Geometry, data and deleted work

Clipmap construction shares seven unique grids instead of ten duplicated resources. Five ordered native instance groups replace nested Variant containers, and cached transforms avoid unchanged server submissions. Vertex/index order, instance geometry, seam meshes and displacement/background bounds remain intact. MultiMesh uploads use one packed transform/color buffer; append operations retain writable arrays per cell/region and write back once.

The cleanup also removes unreachable non-diagnostic SVT scheduling branches, unused baker helpers/arguments, overwritten shader calculations, unused editor average mode/state and unconsumed VT height copies. RF height extrema scan base-level bytes directly. Array synchronization checks whether a payload is needed before resampling it. Streamer ring traversal preserves ordering and failed saves retain resident ownership. Filtered asset entries are freed immediately instead of leaking unparented nodes and callbacks.

## Evidence and limits

The [optimization audit](terrain_optimization_audit.md) records the full source inventory, preserved DLL/image fixtures, measured CPU/GPU/draw values and individual regressions. Debug and Release native builds pass. Tests cover material baking/reload, cell composition, pressure addressing, mip filtering, metric density, large worlds, editor painting/preview, instancer output and allocator contracts.

In the fixed D3D12 camera-turn fixture, warmed CPU AVT updates fell from about 3.6–4.1 ms to 0.27–0.32 ms. Four warm turns generated zero pages and sampled image differences were zero; settled images match the preserved baseline. This is not an overall FPS/GPU speedup claim. Cold output still differs until ready.

Draw calls and overdraw were measured, not reduced by deleting required seam geometry or tightening unsafe bounds. The hilly-scene diagnostic preserves terrain vertex deformation and measures potential front-face overlap, not actual early-Z fragment cost. Built-in FRP overdraw substitutes a vertex shader and cannot validate displaced terrain. Arbitrary custom shaders, all shadow configurations, GPU allocation failure injection and complete Godot 4.5 docking are outside the demonstrated regression scope. Whole-world moving demand and synchronous SVT source I/O remain performance limits.

Hydra reference notes are in `terrain_vt_and_streaming.md`; the referenced D:/hydra/hydra-unity checkout was unavailable. This implementation uses CPU footprint demand and is not a claim of an exact Hydra GPU feedback port.
