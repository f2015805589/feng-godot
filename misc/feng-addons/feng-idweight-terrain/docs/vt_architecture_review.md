# Surface VT architecture

## Module map

The native side is a `Terrain3D` node plus the subsystems it owns. `Terrain3D`
itself is the façade: the properties the editor and scripts see, region
streaming, geometry, collision, instancing and the physics-tick scheduler. Its
definitions live in eight files, one per concern -- `terrain_3d.cpp` (lifecycle,
the physics tick, the render-geometry invalidation and the notifications),
`terrain_3d_wiring.cpp` (the subsystem nodes and GPU objects the node creates and
releases), `terrain_3d_monitors.cpp` (its custom `Performance` monitors),
`terrain_3d_surface_views.cpp` with `terrain_3d_surface_views_far.cpp` and `terrain_3d_surface_views_near.cpp`
(the virtual texture service: its views and settings, the far field's demand pass,
and the near field's demand pass with its sector machinery),
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
| `terrain_3d_virtual_texture.{h,cpp}` | One view's indirection texture, the mip-chain walk and its virtual blocks. No terrain data, no demand, and no residency: the atlas it publishes into belongs to the pool below. One of three files defining the view; `terrain_3d_virtual_texture_sector.cpp` owns the near field's `VirtualImageAtlas` blocks (register / resize / unregister, the block origin, and moving resident pages a whole mip per doubling so a page keeps its world footprint), and `terrain_3d_virtual_texture_lookup.cpp` owns addressing (`_request_virtual()`, the sector-local and world-grid entry points, the walk, and the releases). |
| `terrain_3d_vt_page_pool.{h,cpp}` | The physical side both views share: the `Texture2DArray` atlas, the global slot allocator (reserve / commit / abort), LRU and protection, the reverse owner index, and page read/write. |
| `terrain_3d_avt.h` | Plain records of the near-field demand: page requests, the asynchronous plan result, cached addresses, sectors and the working set. No algorithms. |
| `terrain_3d_sector_avt.cpp` | The near field's demand entry point and its configuration: `_update_sector_avt()` (the driver: predict, key, reuse-or-rebuild, submit), the plan key and the install-or-reuse decision, and the tier settings the sector size is derived from. One of three files owning the near field's planning; `terrain_3d_sector_avt_motion.cpp` owns the lead — the eye and the gaze — and the quantized plan key, `terrain_3d_sector_avt_hierarchy.cpp` the 64 m sector scan, the coarse hierarchy, the address directory and its publication, and `terrain_3d_sector_avt_internal.h` the three prologue names two of them read. |
| `terrain_3d_vt_demand.cpp` | The far field's demand pass over the world page grid, with the shared capacity floor. |
| `terrain_3d_page_pipeline.{h,cpp}` | The worker and planner threads, the immutable region snapshot they read, raw-ID page payload production, and `.vtcell` reads. |
| `terrain_vt_cell.h` | The `.vtcell` on-disk contract: format version, file name and the source signature. Shared by the baker that writes the files and the runtime reader that consumes them, because the two must agree exactly. |
| `terrain_3d_vt_cells.{h,cpp}` | The resident far-field cell sources: three GPU arrays (one layer per cell, full mip chain), the cell registry, the memory budget with its LRU eviction, and the per-(channel, layer, mip) views the page copy shader binds. A cell published here is what makes far-field page assembly a device-to-device copy with no file and no CPU work. |
| `terrain_3d_vt_service.cpp` | The VT service's settings and lifetime: page size, border, count, workers, the motion lead, the resolution preset, both tiers' storage format, the feedback toggles and the editor preview, plus `_configure_vt_service()` / `_update_vt_service()` / `_destroy_vt_service()`. One of four files defining the service. |
| `terrain_3d_vt_service_pages.cpp` | Page plumbing: invalidation of one slot, one region or every material; the queue that turns a produced payload into a material page; the resident far-field cell store; and the two helpers that decide whether a far page can be assembled from cells at all. |
| `terrain_3d_vt_service_report.cpp` | The diagnostics the dock, the inspector and the tests read: `get_vt_settings()` (the telemetry every performance test in `native/tests` is written against), `get_vt_pages()`, the page and material previews, and the compression probe. Read-only. |
| `terrain_3d_vt_service_bake.cpp` | The far field's bake and its cell files: `bake_svt()`, the automatic pass behind it, the queue that serializes the two, the `.vtcell` signature and reader, and the browser of what is baked. The only half of the service that touches the filesystem. |
| `terrain_3d_vt_service_internal.h` | The prologue the four service halves share: `baker()`, the one way the stored `Ref` becomes the producer, and `bake_source_grid()`, so a bake and a runtime page built from the same payload agree on where its corners are. |
| `terrain_3d_surface_views.cpp` | Both views' setup and teardown and every setting the dock, the inspector and scripts write, plus `invalidate_surface_pages()`. One of three files defining the two views and their demand passes. |
| `terrain_3d_surface_views_far.cpp` | The far field's demand pass: `update_surface_svt()` in both of its modes, with the distance -> level rule it walks (`get_surface_svt_mip_for_distance()`, `get_surface_svt_mip_reach()`) and the diagnostic page writer. |
| `terrain_3d_surface_views_near.cpp` | The near field's demand pass: `update_surface_vt()`, the GPU projection feedback pass, the camera-visible region query and the sector machinery (`_prepare_vt_sector()`, `_compute_adaptive_sector_sizes()`, `_vt_page_requests_for_sector()`, `_produce_missing_vt_pages()`, `_publish_vt_block_tables()`). |
| `terrain_3d_surface_views_internal.h` | The one prologue symbol the service's halves share: `SourceWakeFlush`, the guard that wakes the page pipeline's workers once a demand pass is over rather than in the middle of it. |
| `terrain_3d_surface_baker.cpp` | The device and the objects on it: the RenderingDevice lookup, texture and sampler creation, the resident-resource check and the material table upload. One of six files defining `Terrain3DSurfaceBaker`. |
| `terrain_3d_surface_baker_bundle.cpp` | The `ResourceBundle`'s lifetime: the inventory `_collect_bundle_rids()` every path uses, creation, growth, adoption as the live bundle, and the free (at once, or deferred until the renderer has stopped drawing the old one). |
| `terrain_3d_surface_baker_pipelines.cpp` | The two GPU programs: the bake pipeline and the block encoder, the GLSL both are compiled from, and the uniform sets they read. |
| `terrain_3d_surface_baker_storage.cpp` | What a page is stored in and the block encoder: the per-tier codec resolver and the formats it applies, the ring of in-flight encode pages, the encoder dispatches, and the readbacks that publish them as sampled layers. |
| `terrain_3d_surface_baker_queue.cpp` | The caller-facing queue: capacity, budget and the material snapshot, `queue_page()` / `queue_cached_page()` / `queue_cell_page()`, and the uploads that drain them. None of it runs on the render thread. |
| `terrain_3d_surface_baker_frame.cpp` | One frame of production: `render_pending()`, the job list it builds, dispatch, the retirement of bundles the material stopped sampling, and the read-only state and bindings the caller and the editor read. |
| `terrain_3d_surface_baker_internal.h` | The prologue the six halves share — the codec vocabulary, the shared constants and the small helpers — because each is read by two or three of them and a second copy would be a second vocabulary. No class member lives here. |
| `terrain_3d_data_surface.cpp` | The region payload -> page resampler both tiers call: `produce_surface_page_set` for a sector block at one local mip, `produce_surface_rect_page` for a world-space page rectangle. One of five files defining `Terrain3DData`. |
| `terrain_3d_data.cpp` | The stable layer slots, the chunk -> layer directory texture, the per-map-type blank layers and the slot-map upload. One of five files defining `Terrain3DData`. |
| `terrain_3d_data_regions.cpp` | Region lifecycle and the region table: `add_region*()` / `remove_region*()` / `unload_region()`, `change_region_size()`, `change_surface_density()`, the modified and deleted flags, and `do_for_regions()`. It never touches a slot index directly; it goes through `_acquire_slot()` / `_release_slot()`. |
| `terrain_3d_data_maps.cpp` | The map arrays, their GPU upload and their read side: `get_maps()`, `update_maps()`, `update_surface_region()`, `set_pixel()` and the height / normal / blend / slope / texture-id queries. |
| `terrain_3d_data_edit.cpp` | `add_edited_area()` (what an edit tells the data so the virtual texture republishes the regions it touched), `calc_height_range()` and the master height range the mesher reads, `dump()`, and `_bind_methods()` — the whole script-facing surface of the class. |
| `terrain_3d_vt_indirection.{h,cpp}` | Render-thread upload of the CPU-authored page table, coalesced into 16x16 tile patches. |
| `terrain_3d_vt_visibility.h` | Camera-visible terrain footprint queries shared by both fields. Header-only, camera-only dependency. |
| `main.glsl` | Sampling: the shader resolves a fragment's payload texel to a virtual page and walks up the mip chain. Address arithmetic here must match the C++ side exactly. |

The same one-file-one-job convention now covers two classes outside the VT machinery.
`Terrain3DEditor` is four files: `terrain_3d_editor.cpp` (the object's state and public API, and the
region tool), `terrain_3d_editor_paint.cpp` (the map brush loop and what runs after it),
`terrain_3d_editor_texel.cpp` (one brush texel: the three map handlers, the two neighbourhood samples
and the R16 surface path) and `terrain_3d_editor_undo.cpp` (the undo and redo snapshots).
`Terrain3DMaterial` is four as well: `terrain_3d_material_shader.cpp` (the GLSL assembly),
`terrain_3d_material.cpp` (the shader and its uniforms), `terrain_3d_material_resource.cpp` (the
lifecycle, the setters and `save()`) and `terrain_3d_material_reflect.cpp` (the property list and the
ClassDB bindings).

Three rules keep the split honest, and all three are load-bearing:

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
4. **A class split across files shares its prologue through one header, never by
   copying it.** `terrain_3d_surface_baker_internal.h` holds the codec vocabulary,
   the shared constants and the small helpers of the surface baker's four halves;
   `terrain_3d_vt_service_internal.h` holds the two helpers the VT service's four
   halves share. A helper that two halves need becomes an `inline` one there —
   including one that used to sit in an anonymous namespace, which carries internal
   linkage with no keyword to convert, so leaving it as it was makes the linker
   report one definition per half. A second definition of the page-codec list would
   be a second vocabulary, and the two `static_assert`s that keep the page list
   inside the array list would stop constraining anything.

On the GDScript side the same rule applies to the VT window: `vt_editor.gd` owns
the widgets and the selection state, `vt_terrain_bridge.gd` owns the VT window's
duck-typed calls into the extension (a missing native method must read as
"unavailable", not break the editor - `vt_editor.gd` keeps one-line delegations to it
so the window's data layer is the only place that knows the native API), and
`vt_overview_image.gd` owns the world/image maths and the per-pixel stitching, as pure
functions over data passed in. Two other scripts guard their own native calls rather
than going through the bridge: `terrain_vt_inspector.gd` (`has_method` + `call` around
`get_vt_settings` and `bake_svt`) and `editor_plugin.gd` (around the VT window's
`open_vt_page_view` and the dock's `_open_vt_editor`); the bridge is where the *VT
window* talks to the extension, not the only place in the addon that duck-types. The asset dock's list
and tile widgets are shared by both dock versions in `asset_dock_list_*.gd`, and the
dock's own half - signals, controls, search, list switching, pin, highlight and
window-focus handling - is `asset_dock_common.gd`, which `asset_dock.gd` (4.6+, hosted
in an `EditorDock`) and `asset_dock_45.gd` (pre-4.6, its own slot and window) both
extend; each keeps only its hosting, its editor-settings keys and its own extras. The
editor cursor decal is `ui_decal.gd`: the tool bar (`ui.gd`) keeps tool, brush
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

- `terrain_3d_vt_service.cpp` (settings and lifetime), `terrain_3d_vt_service_pages.cpp` (invalidation, the material page queue and the cell store), `terrain_3d_vt_service_report.cpp` (the diagnostics) and `terrain_3d_vt_service_bake.cpp` (the `.vtcell` bake) configure the shared services, invalidate them and own their source lifetime. `Terrain3DVTPagePool` (`terrain_3d_vt_page_pool.{h,cpp}`) owns physical allocation, LRU, protection and reverse ownership; the view that published an evicted slot is called back so its indirection entry goes with it.
- `terrain_3d_sector_avt.cpp` (the driver), `terrain_3d_sector_avt_motion.cpp` (the lead and the plan key) and `terrain_3d_sector_avt_hierarchy.cpp` (the scan, the hierarchy and the address directory) build visible and idle sector demand and retain address blocks. `terrain_3d_vt_demand.cpp` schedules visible SVT footprints with a common capacity floor. Both tiers point into the shared physical arrays.
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

For the built-in material, preview or both VT tiers disabled generates a shader without VT samplers/uniform resources and lookup/filter functions. Eight VT samplers disappear in preview and return on resume. A dedicated uniform helper also skips constructing VT state for this variant. Custom shader overrides retain the full interface; generated overrides are not frozen into preview mode. Displacement still uses its required material snippets. The assembly that decides this lives in `terrain_3d_material_shader.cpp` (insert loading, editor/debug injection, comment stripping, `_needs_vt_shader`), while `terrain_3d_material.cpp` owns the shader and its uniforms and `terrain_3d_material_resource.cpp` / `terrain_3d_material_reflect.cpp` the resource's properties, save, property list and bindings.

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
