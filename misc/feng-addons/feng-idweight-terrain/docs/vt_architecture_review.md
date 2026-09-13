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


## Optional geometry backend and capture

The CDLOD foldout after SVT enables a quadtree/MultiMesh backend for finite built-in terrain. See [CDLOD and capture](cdlod_and_capture.md) for controls, compatibility, measured draw scope and the removal of forced all-page work from normal RenderDoc capture.


### 2026-09-13: persistent missing-page investigation (not fully resolved)

Implemented: clamp filtering at the actual last AVT mip without attempting a nonexistent next mip; share physical capacity according to visible producer demand instead of reserving half the pool unconditionally; remove SVT CPU-only mip coarsening; route visible SVT source payload construction through the existing source worker. Missing required pages still render the diagnostic checker, with no producer or ancestor substitution.

Height min/max pyramids are generated once on the source worker and published with release/acquire synchronization. AVT queries local footprint bounds rather than using the whole region height range for every page. Source invalidation replaces the snapshot. Frustum clipping uses stack buffers; farthest distances use polygon vertices and include all tested height planes. A volume intersecting the frustum is no longer rejected merely because its three horizontal slices miss it. The AVT statistics now expose `height_bounds_ready` and `refinement_requests_denied` (rejected child requests, not a pixel miss counter).

Debug and Release builds and the strict filtering, async invalidation, source blending, and ordinary flat rotation regressions were checked. A separate 1280x720 hill probe uses 256 physical pages, 1024 texels/m, a 90 m Gaussian hill centered at (300,210), camera (256,55,256), pitch -35 degrees, yaw alternating 0/90 degrees, and 240 update frames per view. The previous half-pool planner left approximately 283339 diagnostic pixels; corrected sharing and bounds eliminate those holes on the first view, but repeated turns still leave 25615 diagnostic pixels (2.78% of the frame). This unresolved case is consistent with a CPU demand / fragment footprint mismatch after sector allocation growth. It is not a successful zero-miss regression. Probe and logs: `bin/terrain-vtadaptive-qujlebic/vt_hill_probe.gd`, `hill-volume.log`, `hill-hit.log`.

Final ordinary rotation CPU averages were 0.369 ms while filling, then 0.061–0.070 ms when warm; peaks were 1.467 ms during a view change and 0.227–0.243 ms on repeated warm turns. These are CPU update measurements, not GPU timestamps. The 0.1 ms maximum target remains unmet. No precision reduction or expanded physical pool was retained; a trial demand multiplier was discarded because it increased work without eliminating the residual holes.


### 2026-09-13: repeated-turn hill residency fixed; CPU peak target remains open

This supersedes the residual hill-miss result above. Demand now samples source-triangle slope projection, including points outside the frustum on already-visible pages. The previous bounds-only estimate could under-request a visible slope after virtual allocation growth. Ready AVT pages are marked demanded so that SVT cannot evict them during the same update.

Refinement and prefetch planning run on the persistent source worker using immutable snapshots. Main-thread sector allocation remains. Camera keys avoid Variant serialization; unchanged residency reuses cached demand slots. Prefetch advances with a persistent cursor, and production uses a soft 40 microsecond CPU slice while retaining the hard 16 physical-page GPU-operation limit. This is not a hard total-update time bound.

Material-cache rendering no longer uploads redundant raw ID atlas layers; explicit inspection still uploads and reads the authored layer. Page-table patches use a reusable storage buffer and one compute scatter dispatch instead of temporary texture creation/copy/destruction per patch. Render-thread callbacks may execute on the main thread under the engine default thread-safe mode; they are not claimed as independent worker execution.

The new vt_residency.gd regression checks every pixel after 300 frames at each of five alternating hill views, at 1280x720, 256 physical pages and unchanged 1024 texels/m. All five settled views contain zero diagnostic pixels. This does not guarantee zero transient misses or coverage for every terrain. Strict absent-page diagnostics remain; no AVT-to-SVT, VT-to-editor, or missing-page ancestor substitution was added.

Latest D3D12 hill CPU update averages: 0.053-0.071 ms; peaks: 0.243-0.303 ms. Ordinary rotation averages: 0.031-0.100 ms; peaks include 0.801 ms for a new direction and 0.113-0.132 ms for repeated warm views. The requested 0.1 ms peak is NOT achieved. Measurements cover update_surface_vt CPU wall time, excluding worker/GPU time and other terrain work. Async invalidation/GPU ID sampling (12069 samples), material blending, and strict Vulkan filtering regressions pass. Logs are under bin/terrain-vtadaptive-qujlebic/*-final-*.log.


### 2026-09-13: continuous navigation and cache-preserving growth

This supersedes the worker-sharing and 40 microsecond production-slice description above. Completed demand is retained while a new view is planned; camera movement no longer continually replaces unfinished planning. Planning and source preparation use separate persistent threads. Installing a plan can immediately submit its successor. The source queue is refilled before and after consumption, even when this frame's GPU generation budget has been spent. Unused SVT budget returns to AVT, rather than leaving AVT permanently capped at eight pages. New AVT baking and SVT page uploads still share the sixteen-page frame limit.

Visibility clips source triangles in the near field, guards the frustum by 192 pixels, and prepares a bounded finer-mip apron (larger on nearby slopes). Sampled levels precede speculative finer pages; speculative demand is limited to spare capacity and 256 requests. Up to 128 recently requested pages survive eight plan revisions so short-lived mip changes do not continually discard prepared work. Idle prefetch keeps coarse world roots instead of rebuilding a full spare-cache refinement tree on every moving view. Child traversal uses fixed four-entry arrays. AVT statistics expose planning duration and completed-plan age separately from main-thread update time.

The negative-sector boundary address is clamped below 1.0 before indexing: float rounding could otherwise select a neighbouring indirection block. SVT cell composition extends border texels only at genuinely absent outer neighbours; missing or stale existing cell bakes remain invalid. Strict selected-page diagnostics remain: no AVT-to-SVT, VT-to-editor, or absent-fine-page ancestor substitution was added.

`Auto Capacity` is enabled by default and can grow the shared physical pool to 1024 pages, retaining transition headroom. Growth preserves owners, source jobs, addresses and ready material results. The render callback copies ready output layers into the larger arrays; the old arrays stay alive until the material binds the replacement. The virtual world root does not shrink because physical capacity grew. Raw diagnostic ID layers grow lazily on explicit access. At 256 texels plus a four-texel border, the full 1024-page cache estimate is about 2.13 GiB; migration temporarily retains both allocations. This is a real video-memory tradeoff, not a reduction in rendering precision.

**Budget scope:** the sixteen-page limit counts newly generated material pages and SVT page uploads. Cache-growth copies preserve existing GPU results and are tracked separately as `migrated_pages`; a migration can copy more than sixteen existing pages in one frame. This implementation does not claim a sixteen-copy total GPU-operation limit or a 0.1 ms allocation/migration bound.

Final Debug and Release builds pass. Verification uses the custom Godot 4.7.3 FRP editor and RTX 3080 Ti. The following paths are relative to the engine repository root:

- `bin/terrain-vtadaptive-ptkrhzk7/vtadaptive.log` (D3D12) and `bin/terrain-vtadaptive-ppf6w94g/vtadaptive.log` (Vulkan): 1920x1080, sixteen settled uphill/horizon directions and all twenty-four continuous-movement checkpoints contain zero diagnostic pixels. Peak generation is sixteen pages; 147 ready pages migrate without resetting the cache generation. Inspector controls also pass.
- `bin/terrain-vtadaptive-03koy5_t/actual-final-smooth-d3d12.log`: an isolated copy of the user's 64 terrain cells, 64/64 successful SVT bakes, three surface-following movement paths, every full-frame checkpoint and final image free of diagnostic pixels. Original project terrain files were not modified.
- Strict selected-page diagnostics and normal mip interpolation pass on D3D12 (`terrain-vtadaptive-4pts2i7m`) and Vulkan (`terrain-vtadaptive-yan3eg_e`). This probe disables automatic capacity because it supplies its own fixed 64-layer atlas.
- Asynchronous edit invalidation, GPU ID payload sampling and teardown pass (89,369 samples, `terrain-vtadaptive-4ak0ery0`). Source blending and absent-producer substitution rejection pass (`terrain-vtadaptive-q3v6e0k0`). All five settled slope views pass (`terrain-vtadaptive-tketyj2z`). These last three checks preceded the final increase of the frustum guard from 128 to 192 pixels; their source/baker logic did not change afterward.

The navigation fixture now follows the actual triangle-interpolated surface. `get_height()` reads a nearest authored texel; using it directly for camera height caused metre-scale vertical jumps. The original stricter trajectory remains reproducible with `vt_adaptive_runner.py --navigation --stepped-camera`, preserving the same zero-miss assertions. Stepped-height investigation runs still exhibited transient missing pages (523 pixels in a Vulkan hill checkpoint and 41,630 in a copied-terrain checkpoint), followed by recovery; they are not claimed as passing. Cold starts, camera cuts and arbitrary unseen views still need bounded generation time. No rendering substitution masks that delay.

**The requested 0.1 ms CPU peak is not achieved.** Final smooth navigation measured AVT update peaks of 1.325 ms (D3D12) and 1.243 ms (Vulkan). Complete terrain physics-notification averages were 0.231/0.223 ms, with peaks of 4.284/4.058 ms; these exclude worker execution and GPU timing. The copied 64-cell paths measured physics-notification averages of 0.363/0.310/0.458 ms and peaks of 9.143/1.856/4.402 ms. These measurements must not be presented as whole-pipeline or GPU timings. Restart the editor to load the rebuilt native extension.


### 2026-09-13: stationary editor producer wakeup

The editor low-processor loop draws only when RenderingServer reports changes.
Background page preparation and direct RenderingDevice cache writes do not by
themselves request such a draw. The VT compositor callback can consequently wait
for user input even though its production queue is nonempty.

The main-thread VT service now checks a mutex-protected, constant-time
`Terrain3DSurfaceBaker::has_render_work()` predicate and queues a redraw on the
editor base control while GPU work remains. This uses the normal draw loop, not
`force_draw`, a GPU wait, or an always-on editor redraw. It covers queued pages,
material/invalidation work and cache growth/retirement. CPU source work continues
to be polled by terrain physics ticks and becomes eligible for this wakeup once
queued to the producer. The sixteen-new-page budget and strict missing-page
shading are unchanged.

`native/tests/editor_dock_runner.py --test vt_idle` opens a real editor, enables
low-processor mode, creates cold AVT pages and later invalidates the cells. It
waits using timers without camera movement, manual terrain ticks or forced draw
calls, then checks producer completion and the viewport image. A green fixture
material avoids mistaking the blue editor axis over red ground for magenta VT
pixels. This regression addresses stationary completion, not arbitrary camera
cuts or the still-unmet 0.1 ms CPU peak target.

Validation: Debug and Release native builds succeeded. The graphical Vulkan
editor idle regression passed with zero pending GPU pages and zero magenta
pixels (`bin/vt-editor-idle-vulkan.log`). D3D12 evidence is recorded in
`bin/vt-editor-idle-d3d12.log`. The test uses fixed observation waits, not a
measurement of page latency. Restart the editor to load the rebuilt extension.


### 2026-09-13: CPU query reuse and optional AVT coarse recovery

CPU changes preserve demand and page production budgets:
- SVT reuses the exact region visibility result when several coarse ancestors
  clip to that same complete region, rather than repeating polygon queries.
- AVT remaps existing requests only when the virtual directory or logical scale
  changes. Camera motion alone does not change their mip addresses.
- Exact AVT residency lookup resolves both block coordinates in one atlas query,
  validates the local address, and does not search ancestor mips. Temporary
  request vectors reserve their known capacity to avoid repeated growth.

Navigation baseline (`bin/vt-peak-baseline.log`) measured AVT peak 1.409 ms,
whole physics-update peak 4.291 ms and average 0.227796 ms. It also reproduced
one existing transient missing-page checkpoint. Final CPU-change runs passed
all static/moving image checks, with at most 16 new pages per frame:

| Driver | AVT peak ms | Whole physics peak ms | Whole physics average ms |
| --- | ---: | ---: | ---: |
| D3D12 | 1.472 | 7.955 | 0.184075 |
| Vulkan | 1.253 | 4.151 | 0.180674 |

Logs: `bin/vt-peak-verified-navigation-d3d12.log` and
`bin/vt-peak-verified-navigation-vulkan.log`. The average improved by about 19%,
but these results do NOT demonstrate a stable peak reduction or meet 0.1 ms.
Temporary stage instrumentation also found both dynamic collision and AVT
contributing to large whole-update peaks; the instrumentation was removed.
The async edit/content/teardown test passed 104209 sample checks, and the real
editor stationary-completion test passed (`bin/vt-peak-verified-async.log`,
`bin/vt-peak-verified-idle.log`).

The AVT Inspector now exposes `surface_vt_coarse_mip_fallback`, default false.
When true, the shader can search coarser resident AVT mips/world parents if the
selected page or directory entry is absent. Readiness still comes from the
physical page parameters. No ready AVT ancestor means the missing-page
checker remains. Demand continues requesting the original precise pages;
fine residency automatically resumes fine sampling. This does not enable
AVT-to-SVT or editor-material substitution and does not force new ancestor
bakes. When false, the previous strict behavior is preserved.

The filtering GPU regression now checks default-off behavior, coarse recovery,
rejection of unready parents, fine-page arrival, and the existing normal mip
transitions. D3D12 passed (`bin/vt-coarse-toggle-d3d12.log`).

Vulkan also passed the coarse-recovery and strict-filtering regression
(`bin/vt-coarse-toggle-vulkan.log`). Both final Debug and Release native
builds succeeded; no temporary peak logging remains in production code.
