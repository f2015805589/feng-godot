# Terrain optimization audit

Goal: preserve rendered output and density while improving VT cost, camera turns, draw submission and maintainability. The reading ledger is complete for the implementation inventory below. Entries record the investigation chronologically; later evidence supersedes earlier pending notes. Completion and limitations are recorded at the end.

## Verified first phase

- Automatic AVT mip selection restored; removed distance controls remain compatibility no-ops.
- Resident-owner iteration replaces scans of entire virtual mip pyramids.
- Nearby sector addresses remain cached across turns; idle surrounding prefetch uses free slots only.
- R32F indirection updates copy dirty 16×16 tiles on the render thread instead of uploading the whole mip chain every update. No page ID precision change.
- D3D12 rotation fixture `terrain-vtadaptive-3a_ffnif`: pages [256,0,0,0,0], CPU update means [3.544,0.338,0.298,0.295,0.293] ms. Warm-turn sampled red-channel difference to settled image: 0. Initial cold frame differs. These are CPU update measurements, not total GPU frame times.
- Filtering fixture `terrain-vtadaptive-zkbfx4qy` passed parent, boundary, arrival and fractional mip checks.
- Still required: old/new identical-image comparison, broad SVT/reset/editor regressions, real scene performance and shader/draw audit.

## Structural changes under validation

Mesher: removed three duplicate mesh resources (10 → 7 unique grids); consolidated repeated instance creation into five ordered groups; preallocated vertex/index arrays and filled through native pointers. Instance counts, positions, vertex/index order, normals and tangents are unchanged. Native debug build passed. Ownership GPU regression passed (`terrain-vtadaptive-k0q5x7lq`).

## Reading ledger

The inventory below covers native and editor implementation; additional tools/extras and relevant engine interfaces must also be inventoried before completion. Files marked pending may have been partially inspected; only complete review is marked read here.

- [x] native/src/constants.h
- Generated `native/src/gen/doc_data.gen.cpp` is embedded documentation, excluded from own implementation review.
- [x] native/src/generated_texture.cpp
- [x] native/src/generated_texture.h
- [x] native/src/logger.h
- [x] native/src/register_types.cpp
- [x] native/src/register_types.h
- [x] native/src/shaders/auto_shader.glsl
- [x] native/src/shaders/backgrounds.glsl
- [x] native/src/shaders/debug_views.glsl
- [x] native/src/shaders/displacement.glsl
- [x] native/src/shaders/displacement_buffer.glsl
- [x] native/src/shaders/editor_functions.glsl
- [x] native/src/shaders/gpu_depth.glsl
- [x] native/src/shaders/idweight_r16.glsl
- [x] native/src/shaders/macro_variation.glsl
- [x] native/src/shaders/main.glsl
- [x] native/src/shaders/max_regions.glsl
- [x] native/src/shaders/overlays.glsl
- [x] native/src/shaders/pbr_views.glsl
- [x] native/src/shaders/projection.glsl
- [x] native/src/shaders/samplers.glsl
- [x] native/src/shaders/surface_bake.glsl
- [x] native/src/target_node_3d.h
- [x] native/src/terrain_3d.cpp
- [x] native/src/terrain_3d.h
- [x] native/src/terrain_3d_asset_resource.h
- [x] native/src/terrain_3d_assets.cpp
- [x] native/src/terrain_3d_assets.h
- [x] native/src/terrain_3d_avt_plan.cpp
- [x] native/src/terrain_3d_avt_plan.h
- [x] native/src/terrain_3d_avt_produce.cpp
- [x] native/src/terrain_3d_collision.cpp
- [x] native/src/terrain_3d_collision.h
- [x] native/src/terrain_3d_data.cpp
- [x] native/src/terrain_3d_data.h
- [x] native/src/terrain_3d_editor.cpp
- [x] native/src/terrain_3d_editor.h
- [x] native/src/terrain_3d_instancer.cpp
- [x] native/src/terrain_3d_instancer.h
- [x] native/src/terrain_3d_material.cpp
- [x] native/src/terrain_3d_material.h
- [x] native/src/terrain_3d_mesh_asset.cpp
- [x] native/src/terrain_3d_mesh_asset.h
- [x] native/src/terrain_3d_mesher.cpp
- [x] native/src/terrain_3d_mesher.h
- [x] native/src/terrain_3d_region.cpp
- [x] native/src/terrain_3d_region.h
- [x] native/src/terrain_3d_sector_avt.cpp
- [x] native/src/terrain_3d_streamer.cpp
- [x] native/src/terrain_3d_streamer.h
- [x] native/src/terrain_3d_surface_baker.cpp
- [x] native/src/terrain_3d_surface_baker.h
- [x] native/src/terrain_3d_surface_source.cpp
- [x] native/src/terrain_3d_surface_vt.cpp
- [x] native/src/terrain_3d_texture_asset.cpp
- [x] native/src/terrain_3d_texture_asset.h
- [x] native/src/terrain_3d_util.cpp
- [x] native/src/terrain_3d_util.h
- [x] native/src/terrain_3d_virtual_texture.cpp
- [x] native/src/terrain_3d_virtual_texture.h
- [x] native/src/terrain_3d_vt_demand.cpp
- [x] native/src/terrain_3d_vt_fade.cpp
- [x] native/src/terrain_3d_vt_feedback.cpp
- [x] native/src/terrain_3d_vt_feedback.h
- [x] native/src/terrain_3d_vt_indirection.cpp
- [x] native/src/terrain_3d_vt_indirection.h
- [x] native/src/terrain_3d_vt_page_pool.cpp
- [x] native/src/terrain_3d_vt_page_pool.h
- [x] native/src/terrain_3d_vt_visibility.h
- [x] native/src/terrain_surface_idweight.h
- [x] native/src/terrain_vt.h
- [x] src/asset_dock.gd
- [x] src/asset_dock_45.gd
- [x] src/double_slider.gd
- [x] src/editor_plugin.gd
- [x] src/gradient_operation_builder.gd
- [x] src/live_info_panel.gd
- [x] src/multi_picker.gd
- [x] src/operation_builder.gd
- [x] src/terrain_setup.gd
- [x] src/terrain_vt_inspector.gd
- [x] src/tool_settings.gd
- [x] src/toolbar.gd
- [x] src/ui.gd
- [x] src/vt_editor.gd
- [x] src/vt_world_overview.gd

## Additional evidence

- SVT cross-cell composition, bake and reload passed: `terrain-vtcells-i_6_7vd9`.
- Identical checker fixture, preserved pre-optimization DLL (`terrain-vtadaptive-tn_caows`) versus current DLL (`terrain-vtadaptive-lzgg8n07`): all five settled 320×240 RGBA PNGs are byte-equivalent at the decoded pixel level (maximum difference 0, differing pixels 0). This includes the mesher and shared shader-layout refactors. It does not establish every possible material/view configuration.
- Reference rotation pages [40,24,22,22,22], current [256,0,0,0,0]. Current spends idle initial frames on surrounding prefetch. Reference warm CPU updates 3.63–4.05 ms; current 0.29–0.38 ms. Cold means include prefetch; GPU frame time still pending.
- Material generator now shares region-layout/sampler exclusion logic between main and displacement shaders. Removed unused RegEx allocation in shader rebuild. Remaining shader audit is incomplete; no unverified shader branch has been deleted.
- Material source reviewed through `_update_uniforms` and initialization (current lines 1–887); remaining methods and header still pending. Sampler and max-region snippets read in full.

## Culling investigation (not yet changed)

- Main vertex shader read at lines 1–190 and 580–724. It geomorphs XZ, samples heights, removes holes with NaN positions, blends background heights and optionally applies vector displacement. Normals/tangents are transformed, so removing their mesh arrays without checking engine vertex defaults would not be justified.
- Global height range starts at zero in `Terrain3DData::calc_height_range`, so the mesher's suspicious `max + abs(min)` expression normally equals `max - min`. No speculative AABB change made. Tightening bounds requires accounting for background noise and vector displacement, not just region min/max.
- Existing `vt_perf.gd` explicitly tests legacy ID/weight residency with 256 m regions and direct-material debugging; its comments describe older shipped defaults. It cannot establish current material AVT GPU performance. A current draw/GPU/overdraw fixture remains required.

## Planner and mesh ownership refactor

- Visible and idle AVT plans now share one parent-preserving refinement function. Physical page generation/error cleanup/protection is also shared; allocation priorities and idle-only free-slot checks remain at the caller.
- Post-refactor rotation fixture `terrain-vtadaptive-xrkfgpiv` passed strict warm-turn zero-production and image-continuity checks. Five settled images still match the preserved old DLL exactly (maximum channel difference 0).
- Clipmap instance storage now uses `std::vector<std::array<std::vector<RID>, 5>>` instead of nested Godot Variant arrays. Meshes use `std::vector<RID>`. This removes Variant conversions/copies in snap/update/free loops without changing instance ordering or transforms. Native build passed; ownership regression passed (`terrain-vtadaptive-eoz6he3o`).

## Measured rendering scope

Current test is one flat 512 m region, camera height 4 m, 320×240 viewport, FRP/D3D12. `terrain-vtadaptive-dok7q47i` reports 23 visible draw calls at each heading and warm viewport GPU averages 0.160–0.213 ms. These viewport measurements exclude some asynchronous baking work and are not a complete frame-wide GPU profile. Current refactor fixture reports the same draw count.

FRP's built-in overdraw view replaces the terrain vertex shader (`render_frp_clustered.cpp` near 472, `scene_shader_frp_clustered.cpp` near 958). Its saved image `overdraw_flat_clipmap.png` is uniformly single-colored across the plane, with no visible overlap bands in this view. This is evidence for flat base geometry only, not an actual displaced-terrain overdraw measurement. A vertex-preserving diagnostic is still needed for that requirement.

Full material implementation and header, plus GeneratedTexture implementation/header, now read. Material serialization/property plumbing retained; GeneratedTexture create ownership and material override signal lifecycle merit follow-up (no speculative change yet).

Main shader additional complete read range: 190–409 (legacy raw-ID VT lookup, SVT material lookup, hash directory). Its remaining AVT resolve/filter and fragment body still need complete review.

## Main shader review

Main shader now read in full. Removed the initial linear contribution aggregation and three-layer selection whose outputs were unconditionally overwritten by pair-aware slope selection before use. Shared helpers remain because other shader consumers can use them. Actual AVT material/persistence integration passed (`terrain-vtmaterial-c8q6cuwp`). Direct-evaluator image comparison is pending.

Read auto/projection/macro/PBR/displacement-buffer snippets in full. Auto-shader and projection snippets are still consumed by the displacement buffer, even though the main R16 material path supersedes the old evaluator. Deleting these snippets wholesale would change displacement, so they remain. Displacement buffer also has an overwritten initial t_weights calculation, a possible subsequent cleanup requiring displacement-specific validation.

Latest reference/current pair: `terrain-vtadaptive-1wxzdm16` / `terrain-vtadaptive-saeg9je2`. Visible draws are 25 / 23 at all five headings. Warm viewport GPU times overlap in scale (reference 0.141–0.160 ms, current 0.153–0.182 ms); do not claim a measured GPU speedup. Current initial prefetch viewport mean is higher (~0.92 ms vs ~0.21 ms), trading idle warm-up work for turning reuse. Whole-frame GPU baking budget remains under investigation. IDWeight GLSL helper read in full.

## Large-world and hilly-scene profiling

- Scale fixture `terrain-vtadaptive-uhtyusxb` passed 10.24 km / 25,600-sector coverage and bounded residency. Whole-visible-world AVT moving plan ~22.10 ms; stationary ~0.253 ms. With SVT/radius512: 288 sectors, moving ~0.783 ms. This worst-case all-world plan remains expensive.
- New `--profile` fixture builds nine 512 m sinusoidal-height regions at 1280×720. Shader diagnostic preserves the original vertex function and replaces only fragment/render mode, so heights, holes and clipmap morphing survive. Depth-disabled additive output measures potential front-facing geometric overlap, not actual fragments surviving normal early-Z.
- Initial unlit profile `terrain-vtadaptive-mb_ruuzm`: AVT viewport0.710 ms, direct0.559 ms, 33 visible draws/225592 primitives, diagnostic0.182 ms/41 draws. Higher diagnostic draw count is a transparent-pass instrumentation effect. Images inspected: real hilly silhouette/overlapping hills, no flat-grid replacement. Added directional illumination and black diagnostic background for the next comparison.
- Full sector planner and visibility helper read. Visibility clipping now reserves and reuses two polygon buffers instead of allocating each frustum plane; arithmetic and point order unchanged. Debug build passed, updated lit hilly fixture running.
- First profile attempt `terrain-vtadaptive-ms0l3rvc` failed due to an unbound test-only `update_aabbs()` call; corrected to height-range calculation before `update_maps()` (which emits the normal bounds-update signal). This fixture is not a pass.

Lit hilly profile current `_tpra3g6` / reference `usostoe4`: all three decoded images (`avt`, `direct`, `overdraw_terrain`) match exactly, maximum difference0. Visible draws33 vs35, same225592 primitives. Current cold-demand mean2.676 ms vs13.802 ms; produced256 vs180 across180 updates (different warm-up scheduling, not per-page benchmark). Current settled AVT viewport0.714 ms vsreference0.588 ms: this is a measured GPU regression requiring further investigation, despite identical output and improved CPU latency. Direct0.564 vs0.606 ms is too small/noisy to attribute alone.

Vertex-preserving depth-disabled overlap diagnostic histogram: 0 layers323700 pixels; 1 layer500436; 2 layers90534; 3 layers6907; 4 layers23, based on exact sRGB encodings of additive linear0.1 per face (0,89,124,149,170). This describes potential front-facing overlap, including naturally hidden hills. Normal opaque early-Z should reject hidden fragments; do not remove real occluding geometry just to lower this diagnostic count.

## GPU regression isolation

The hilly profile previously stopped explicit VT updates during measurement. It now calls `update_surface_vt(0)` each frame while AVT is enabled, advancing readiness and the 200 ms fade without allocating pages. Fixture `terrain-vtadaptive-ve0kewkb` passes and still measures AVT0.714 ms/direct0.565 ms. Thus frozen fade state does not explain the measured GPU delta. Further isolation of directory lookup and resident-page sampling is required; the regression is not resolved.

Edge-query diagnostic fixture `terrain-vtadaptive-wrb1qygk`: runtime-only shader override removes the four neighbour-feather statements, leaving production source unchanged. AVT0.714 ms, diagnostic2.248 ms, subsequent direct0.900 ms. Diagnostic image equals ordinary AVT in this uniform-material scene, but timing is not evidence that removal helps; do not adopt it. Measurement now includes120 settling frames plus120 samples and a restored-AVT phase to distinguish shader-switch/order effects. Editor shader snippet read in full.

Longer settling profile `terrain-vtadaptive-ryp48ex8`: AVT0.726 ms, no-edge diagnostic0.619 ms, restored AVT0.880 ms, direct0.780 ms. The same AVT path differs before/after shader switching, so order/clock/compiler-state variation remains significant; do not use a single phase delta as a reliable isolated cost estimate. Neighbour queries remain a candidate for preserving-output optimization, not removal. Overlays GLSL read in full.

## Clipmap transform submission

Instances now retain their last submitted Transform3D and an initialized flag. Mesher snap only sends `instance_set_transform`/`instance_teleport` when the exact transform changes; target shader uniform still updates every tick, and changed segments still teleport as before. Debug build passed. Full moving hilly-image validation is in progress.

First moving-profile attempts `u350bpbn`/`dwtzdggf` only called public `Terrain3D::snap()`, which resets the snap threshold but does not execute mesher snap. Their 2–4 us figures measure scheduling only and are invalid evidence for transform performance. Corrected fixture enables physics after disabling AVT and waits physics frames before captures. Registration source/header read in full.

Moving hilly captures from current `rhr1vcg0` match reference `xi8kawd0` at steps1,2,64,-512 exactly (maximum difference0). Current fixture's exit had a camera-lifetime error after all captures; teardown now disables physics before freeing the scene. Clean current rerun `jxe84g42` is the subsequent validation.

Streamer implementation/header now read. Follow-up finding: `_try_unload` proceeds to unload a modified region even when save-on-unload fails or no destination exists. This can drop unsaved edits. Needs focused correction/test before closing the lifecycle audit. Also `_collect_desired` rebuilds and sorts the same square every update; ring iteration/cache can eliminate repeated sorting with identical near-first,y,x order.

## Streamer ordering and save ownership

- Replaced desired-square generation plus distance/y/x sorting with direct Chebyshev-ring enumeration. Corner/edge rejection retains the same order. Regression `terrain-streaming-7wg17i2g` passed, including new equality checks against the previous sort contract for radii0,1,3,16 at interior and world-edge centers.
- Save-on-unload now aborts unload if the destination is empty or region save returns a failure; modified data and streaming ownership remain available for retry. Failure telemetry increments. Ordinary successful saves/unloads are unchanged. Added regression for an unsaved terrain with no directory, checking data/ownership retention and failure telemetry; latest runner `terrain-streaming-wogxfzu3` validates it.
- Region::save implementation inspected: it preserves `_modified` on ResourceSaver failure and only clears it on OK; the old streamer discarded that failure result. Region file full review remains pending.

## Density and region data validation

- Updated metric regression to distinguish retained address capacity from actual visible mip demand. At larger camera footprints, `finest_requested_texel_world` increases while the cached address size stays unchanged. `terrain-vtadaptive-1j8se9w2` passes 768/1024/2048 texels/m, bounded shared residency, independent SVT density, coarse page reuse and sloped-cell normals.
- Region source/header now fully reviewed. Surface-map resampling copies the original two ID bytes through cached native pointers instead of one decode/encode API call per texel. Nearest-neighbour source coordinates are unchanged. `terrain-vtdens-dl7mr_or` passes block-exact resampling, migration, brush editing, save/reload and rendering checks.
- GPU upload queue now coalesces complete updates to the same mip/tile before the render thread consumes them. Tiles are disjoint; the latest bytes replace obsolete pending bytes. No physical-page density or filtering change. Debug build passes; rotation regression follows.
- Clean moving profile `jxe84g42` passes teardown. Reference `xi8kawd0` uses the corrected longer settling/phase sequence: AVT0.725 ms versus current0.718 ms. Earlier0.588/0.714 ms samples used a different measurement sequence and do not establish a reproducible shader regression. No GPU speedup is claimed; phase/order sensitivity still limits interpretation.
- Sparse upload failure recovery remains open: texture creation/copy failures currently discard that batch. This is a robustness limitation, not a measured cause of ordinary camera-turn stalls.

## Upload queue and editor validation

- Coalesced-upload rotation `terrain-vtadaptive-_mqkur3r`: production [256,0,0,0,0], warm CPU0.308–0.370 ms, warm-turn image error0, initial image error0.161. All automatic mip controls pass. This does not remove cold-start latency.
- Clean hilly profile `jxe84g42` versus reference `xi8kawd0`: all nine common PNGs match exactly, including four moving captures and vertex-preserving overdraw.
- Graphical editor input `feng-editor-dock-clean-brcatiw8` passes preview pause, live array painting, VT resume, brush fallback, release and navigation, with no engine errors.
- Allocator statistics now return the existing owner-map size instead of scanning every quadtree node. Insert/remove/resize transactions already maintain this map; no allocation order changes.
- Source height-page construction, GPU feedback implementation/header, IDWeight contract and VT address/allocator contract fully read. Legacy feedback still synchronously submits and reads a local RD; do not enable it on the modern sector path as a performance fix. Allocator descendant counts are int16_t and could wrap with 65,536 minimum-size allocations; follow-up robustness fix/test required. Current typical runtime residency is far smaller.

## Preview shader specialization and allocator pruning

- The generated built-in shader now preprocesses out VT uniform resources and lookup/filter functions when editor preview is active or both tiers are disabled. Material updates regenerate only when this compile-time mode changes. Custom shader overrides retain the full interface; creating an override from the default source does not freeze preview mode into its source.
- Graphical editor `feng-editor-dock-clean-7_s8v0zo` passes preview/painting/resume and asserts all eight VT samplers are absent in preview, restored on resume, and absent again when reopening preview. This proves resource declarations were removed, beyond a runtime boolean early-out.
- Address allocator now tracks occupied descendant area using uint64_t, replacing the overflowing int16_t descendant count. It skips completely occupied subtrees while preserving the traversal order of available nodes. Statistics still use the existing owner map. Standalone contract test passes 65,536 simultaneous leaf allocations with no overlap, rejects allocation into the full root, preserves ownership on failed resize, and allows released space to be refilled. Native debug build passes.
- Hilly profile `terrain-vtadaptive-53q2_6tt` passes after both changes. All nine images match old reference `xi8kawd0` exactly, including direct shading, moving clipmap and custom shader diagnostic. Visible draws33, primitives225592. AVT viewport0.728 ms; direct0.843 ms follows multiple shader switches and remains unsuitable for an isolated speedup claim.
- Collision and asset implementations/headers fully read. Candidate follow-ups: texture-asset validation retrieves Image twice; removed individual assets can retain callbacks; texture-array rebuild emits textures_changed and settings update emits it again; collision active shape indices use Variant arrays and repeated PhysicsServer queries. These are audit findings, not changes yet. Asset array uploads intentionally swap both arrays transactionally before freeing old RIDs; GeneratedTexture ownership must preserve this use.

## Data, utilities and baker audit

- Completed reading data, mesh assets, utilities, logger/constants, surface baker and its shader, and the virtual-texture page-pool implementation/header. This does not complete the remaining terrain/editor inventory.
- Direct/preview material updates now skip VT uniform construction and bindings through a dedicated helper; displacement material and custom shader interfaces remain intact. Editor input/preview switching regression `feng-editor-dock-clean-lci0bjq4` passed.
- RF height extrema scan reads base-level bytes once instead of calling `Image.get_pixel` per sample. Other formats retain decoded sampling. `terrain-slots-115jyu_p` passed RF/RGBAF/RGBA8, mip chains, NaN holes, infinities, slot rendering and layer swaps without whole-array recreation.
- Suppressed debug logging no longer recursively walks arrays/dictionaries. Release compiles out this diagnostic work.
- Removed overwritten initial ID/weight material selection from the bake shader, an unused image validator, duplicate private constants and unused resource-creation arguments. Debug and Release builds passed. D3D12 material baking/SVT persistence integration `terrain-vtmaterial-fjgwfatj` passed with zero engine errors.
- Surface-array synchronization checks whether the payload is needed before obtaining/resampling it. VT-only updates no longer create a coarse image only to discard it. Density regression `terrain-vtdens-42rrgbz4` passed paint blocks, resampling, migration, file round trip, exact crops and rendered density distinction. Debug and Release DLLs include this change.
- No quantified GPU improvement is claimed for these cleanup steps; earlier image equality evidence is scoped to its recorded fixtures.

Remaining concrete findings to resolve or document: data `add_region_blankp` ignores its update flag; region-size copy currently copies legacy map channels and needs dense surface preservation verification; data region insertion/save-deletion failure paths need transactional review; baker queue restoration/configuration generations need lifecycle tests. Full source review and broader final validation remain in progress.

## Upload failure recovery and tool inventory

- Indirection creation, RS wrapping and patch-copy failures retain their initial data/failed tiles for a later commit. Restoration uses insert-if-absent so a newer queued CPU tile wins; no recursive render-thread retry loop. Idle commit uses an atomic retry flag, avoiding a mutex on the normal clean path. Debug and Release builds passed. Actual GPU allocation/copy failure injection remains untested; normal upload behavior is covered below.
- Latest debug rotation `terrain-vtadaptive-k9vu8lyu` passed pages [256,0,0,0,0] and warm-turn image differences [0,0,0,0]. Five settled RGBA images remain pixel-identical to pre-optimization reference `terrain-vtadaptive-tn_caows`. This run overlapped compilation, so its timings are not a comparative performance benchmark.
- Read both import/region mover tools and the legacy unit-testing utility. Removed an unused full-image min/max scan from importer; data import itself still computes the actual region bounds. Region mover is a legacy manual utility: fixed 32-region bounds, early data-directory clearing and unchecked rename transactions are findings, not exercised or changed here.

Tools/extras inventory (bundled third-party scripts are listed separately from own core code; examples must also be checked for compatibility):
- [x] tools/importer.gd
- [x] tools/region_mover.gd
- [x] extras/3rd_party/import_sgt.gd
- [x] extras/3rd_party/project_on_terrain3d.gd
- [x] extras/particle_example/grass.gdshader
- [x] extras/particle_example/particles.gdshader
- [x] extras/particle_example/terrain_3D_particles.gd
- [x] extras/shaders/hex_grid.gdshaderinc
- [x] extras/shaders/lightweight.gdshader
- [x] extras/shaders/minimum.gdshader
- [x] extras/shaders/ocean_shader.gdshader

- Release runtime validation `terrain-vtadaptive-io92ael5` (no concurrent build): pages [256,0,0,0,0], warm AVT CPU update means [0.318,0.297,0.297,0.273] ms, warm viewport GPU [0.161,0.170,0.168,0.183] ms, 23 visible draws; sampled warm-turn errors all zero. The runner used `--reference-dll` to load Release into an isolated fixture; reference mode skips the strict new assertions, so recorded zero-production/error values were also inspected explicitly. No GPU failure injection was performed.
- Editor widgets read: DoubleSlider, MultiPicker, operation/gradient builders and toolbar. Findings retained for focused follow-up: DoubleSlider uses pixel/value midpoint inconsistently and assumes zero minimum; MultiPicker uses world origin as unset sentinel and adds buttons on every enter-tree; gradient operation is a synchronous brush loop. Their existing UI behavior was not changed by the performance patch.

## Instancing and editor implementation review

- Completed native instancer/editor source and headers, plus setup and VT inspector scripts. Reviewed RD MeshStorage transform/color buffer layout and buffer/AABB/motion-vector update behavior (`servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp`, especially `_multimesh_instance_set_transform`, `_multimesh_set_buffer`, `_multimesh_re_create_aabb`).
- MultiMesh construction now writes the same three transform rows plus RGBA to one float buffer and submits once, replacing per-instance transform/color server calls. No instance order, transform, color, LOD range, shadow policy or bounds formula was changed. Missing colors retain zero initialization as in the RD allocation path; normal producer inputs contain one color per instance.
- Instance removal now leaves an untouched cell's payload/dirty flag alone and queues rendering updates only if a removal occurred. Removed two unused local computations.
- Added `--instancer` mode to the existing GPU fixture runner and `terrain_instancer.gd`: 36 generated cards with nonuniform scales, rotations and colors, full rebuild, a missed brush stroke, deterministic one-instance removal and clear. The test explicitly requires visible colored pixels; the first fixture with default short LOD range rendered no foliage and was replaced before accepting image evidence.
- Before-change reference `terrain-vtadaptive-buoz7bnw` and current `terrain-vtadaptive-26o5cpq6` both passed. All five decoded RGBA PNGs (instances, rebuilt, missed_removal, removed, cleared) are pixel-identical. Current test additionally checks the missed stroke does not alter the dirty flag. Debug and Release builds passed for instancer changes. No quantified frame-rate gain is claimed from this small fixture; the reduction is in server submissions during construction/rebuild.
- Deleted the unused editor legacy blend-average branch/enum and unused state/local fields. Height and roughness share a scalar map/channel average with unchanged sampling and arithmetic. Color averaging remains separate. Debug and Release builds passed. Editor regression `feng-editor-dock-clean-t26na8lg` passed VT preview, live R16 painting, resume and input/navigation checks with zero engine errors. This UI test is not a numerical smoothing test; scalar-average equivalence is established by the unchanged sample order, channel selection and arithmetic in the refactor.

Review findings for remaining work: editor brush loops still resolve/create/check regions and maps per sample and regenerate color mips for every region touched earlier in a stroke; texture painting scans all regions twice and may form an unneeded array reduction. Instancer append copies packed color arrays repeatedly per appended transform; repeated height updates can mark unchanged cells dirty; lifecycle deletion/count paths need broader multi-LOD/shadow/region-unload checks. These are candidates requiring result-preserving validation, not claims of completed optimization.

## Batched instance append

- `append_region` now retains writable per-cell transform/color arrays for the entire incoming batch and writes back once per cell. Previously, every packed-color append detached from the Dictionary copy and copied the preceding colors. First-seen cell order, instance order, existing transforms/colors, backup timing and update scheduling are preserved.
- `terrain-vtadaptive-lvse_h58` passed the instance integration test, extended with 300 interleaved inputs across three cells appended twice. It verifies cell insertion order and every one of the 600 transform/color pairs. All five rendered phases are pixel-identical to pre-instancer-change fixture `terrain-vtadaptive-buoz7bnw`. Debug build passed; Release compilation checked separately.
- Reviewed particle example scripts/shaders, minimal terrain shader and both third-party integration samples. Particle example has a pre-existing negative height AABB (`min - max`), unconditional parameter updates and legacy control-map texture filtering; it is an optional example, not the terrain's default rendering path. No example rendering policy was changed. Scatter integration is entirely commented sample code.

- Applied the same writable-batch ownership to `add_transforms` region grouping, replacing two transient Dictionaries and per-instance packed-color writebacks. First-seen region order, local transforms, height offset and white fallback colors remain intact. Extended the test with interleaved negative/zero/positive region coordinates and a shorter color input. Final fixture `terrain-vtadaptive-kyv52ksa` passed all checks; all five rendered phases still match `terrain-vtadaptive-buoz7bnw` pixel-for-pixel. Debug and Release builds and diff whitespace checks passed. This removes the repeated array-detachment pattern at both grouping levels; no numerical performance multiplier is claimed without a larger benchmark.

## VT page source lifetime

- Completed the Terrain3D header, surface VT service and visible SVT demand source reads. SVT runtime page assembly now skips height-page generation: it copies baked cell outputs and never consumes this height input. AVT generation and offline SVT cell baking still receive their original height images.
- Removed the unread height-byte copy from every page record (and its corresponding inspector erasure). At the default 264-by-264 RF footprint this avoids 278,784 retained bytes per record, up to about 68 MiB for 256 populated records; this is a storage calculation, not a measured process-memory reduction.
- Debug and Release builds passed. `terrain-vtcells-seiywjts` passed cell baking, reload and mixed-cell composition; `terrain-vtmaterial-izfxdif6` passed AVT material and SVT persistence integration, both with zero engine errors. Diff whitespace checks passed.
- Pending focused verification: the SVT capacity coarsening loop aligns mip-0 addresses by the difference between mip levels instead of the destination mip. Already-coarse input pages can therefore fail to merge canonically under pressure. Add a mixed-mip/negative-coordinate capacity regression before changing this policy. Other service candidates include repeated settled fade uploads, unused mip argument in cell file naming, and repeated dirty-region key construction during bake queuing.

## Unreachable legacy SVT scheduling

- Read `terrain_3d.cpp` from the beginning through the first part of `get_surface_vt_region_rect` (the view-focus target assignment). Full-file review remains open.
- Confirmed `update_surface_svt` returns into `_update_visible_svt` whenever raw-ID diagnostic mode is off. Removed the unreachable non-diagnostic branches remaining below that return: loaded-region bounds, automatic root candidates, their floor-shift helper and duplicate scan-budget selections. Kept the diagnostic scan bounds, hash inputs, cursor order, root protection and allocation limits unchanged.
- Debug and Release builds passed. `terrain-vtroot-76qtko48` passed bounded root/detail scheduling for the legacy full grid and loaded terrain, with zero engine errors. This change removes dead architecture rather than claiming a runtime frame-rate gain. The destination-mip alignment issue in the separate visible scheduler is still pending a focused regression.

## SVT pressure parent addressing

- Completed the entire `terrain_3d.cpp` read and the live-info/world-overview editor scripts. The native core inventory is now fully read (generated documentation excluded as noted above); remaining editor scripts and optional shaders are still open. Core follow-up candidates include duplicated VT-service refresh in physics plus explicit AVT updates, eager mouse/displacement viewport creation, and resource replacement signal lifetimes. Legacy region AVT remains reachable through public selection modes and is not dead code.
- Fixed the visible SVT planner's pressure merge: input coordinates are already in mip-0 units, so canonicalization must use the destination mip, not the difference from the input mip. `world_page_origin` uses floor division for negative addresses without shifting negative signed values. Removed misleading selection-policy comments; the actual policy raises a shared floor when the distance-selected set exceeds capacity.
- Standalone contract tests pass exhaustive containment, idempotence and parent consistency over addresses -4096..4096 and mips 0..10, plus explicit positive/negative mip-2 siblings merging at mip 3. Existing allocator/address tests also pass. Debug and Release builds passed.
- Extended the real GPU ownership test with a 64-page, two-region SVT pressure phase starting at mip 2. Fixed fixture `terrain-vtadaptive-u6pl2qpj` passed canonical parent checks and existing AVT mip/cross-region/material grouping checks. The preserved pre-fix DLL from `terrain-vtroot-76qtko48` failed the same test in `terrain-vtadaptive-ozzdgnuz`: mip-5 records had addresses (32,8) and (24,8), yielding incorrectly offset world rectangles. This proves the regression reaches the actual planner, not only the arithmetic helper. Additional pressure-phase rendered color checks are recorded after their run completes.
- Final fixture `terrain-vtadaptive-gez9bvly` also passed actual red/green material checks on the two terrain blocks after pressure coarsening, with zero engine errors. No general GPU speedup is inferred from this correctness regression. Normal precision controls remain unchanged; under pressure the corrected deduplication avoids artificial over-coarsening and misplaced baked-page footprints.

## Editor asset filtering and review

- Completed both asset dock implementations and `editor_plugin.gd`. Both docks created a ListEntry and connected resource signals before search filtering, then returned without freeing rejected entries. They now free those unparented nodes immediately. Visible list entries and rendering are unchanged.
- Added an editor regression that rejects the same resource 100 times in each dock version and checks both orphan-node count and retained resource callbacks. The check passed in the graphical editor. Full dock validation exposed stale tests for the removed AVT resolution dropdown, automatic baking during live preview, and the old baked overview title. Updated these to verify independent AVT/SVT density controls, preview-paused guidance followed by resumed automatic controls, and exactly one baked source per cell.
- Remaining architectural candidates: list rebuilds recreate every child and repeat mesh thumbnail generation; two dock versions duplicate most list/tile behavior but differ in platform docking, sizing and hover labels; resource replacement does not explicitly disconnect old signals until node deletion; input still includes an unused region-position computation. These findings are not claims of completed fixes or measured frame-time improvements.
- Final graphical fixture `feng-editor-dock-clean-o77sn_ch` passed all dock/menu/Inspector/bake/overview assertions and both filtering-lifetime checks with zero engine errors. An earlier run passed functional checks but reported a scene-tree lookup error during shutdown; the fixture now clears selection/Inspector and drains pending UI work before quitting. The legacy dock's filtered-entry lifetime is tested on the current engine; its complete Godot 4.5 docking workflow was not exercised. Also completed the optional hex-grid snippet review (not used by the default terrain material).


## Final source inventory

Completed the tool settings, brush UI, VT window and optional lightweight/ocean shaders. A filesystem inventory also identified the following menu/object helpers outside the original native/src and src lists; all were read in full:

- [x] menu/bake_lod_dialog.gd
- [x] menu/baker.gd
- [x] menu/channel_packer.gd
- [x] menu/channel_packer_dragdrop.gd
- [x] menu/directory_setup.gd
- [x] menu/terrain_menu.gd
- [x] utils/terrain_3d_objects.gd
- [x] utils/transform_changed_notifier.gd

The inventory covers addon C++ headers/implementations, GDScript, GLSL and shader/include files, excluding vendored godot-cpp, generated embedded documentation and test harnesses. Relevant FRP culling/vertex override and RD MultiMesh interfaces were inspected as recorded above; this is not an audit of the entire engine.

Optional example shaders retain their authored algorithms. The lightweight shader uses the older control-map material contract and does not implement current R16/sector AVT; the ocean shader intentionally uses screen/depth refraction and transparent rendering. Neither is the default terrain material, so replacing them to lower default terrain cost would not help.

Editor findings retained for later focused work: repeated full shader-parameter queries during brush cursor updates; repeated settings/page snapshots during explicit VT window refresh; duplicate preview color conversion; submenu focus callback accumulation; channel-packer synchronous per-pixel normal alignment and deferred window lifetime guards; object-follow helpers' deferred node lifetime checks. These are pre-existing opportunities, not necessary prerequisites for the verified rendering/cache refactors. No speculative behavior changes were made to those tools.


## Completion and final acceptance

The requested implementation audit/refactor is complete for the recorded scope. Earlier "pending" notes are chronological observations; completed items are resolved by later sections, and unimplemented opportunities are explicitly deferred rather than claimed as fixes. Preserving output takes precedence over deleting reachable functionality or changing bounds/seam/shadow policies merely to lower counters.

- Final Debug rotation `terrain-vtadaptive-3uywsfyz`: production [256,0,0,0,0]; warm CPU AVT updates [0.312,0.317,0.314,0.265] ms; warm sampled turn errors [0,0,0,0]; 23 visible draws. All five common settled RGBA PNGs are pixel-identical to preserved baseline `terrain-vtadaptive-tn_caows`. Initial cold sampled error remains 0.161; initial prefetch creates 256 pages. Viewport GPU warm means 0.132–0.183 ms are not whole-frame baker timings.
- Final hilly profile `terrain-vtadaptive-tiukepau`: all nine common PNGs are pixel-identical to baseline `terrain-vtadaptive-xi8kawd0`, including direct material, moving clipmap and vertex-preserving overdraw. Normal phases retain 33 visible draws / 225592 primitives. Initial settled AVT viewport GPU mean is 0.715 ms; restored 0.884 ms and direct 0.838 ms illustrate why these sequential phases are not a controlled GPU speedup comparison. Diagnostic overlap has 41 draws with the same primitive count. Both final runners and density/automatic-mip controls passed with zero engine errors.
- Native Debug and Release builds passed after the final native change (SVT parent canonicalization). Subsequent edits only affected editor filtering, its fixture and documentation; the final dock fixture `feng-editor-dock-clean-o77sn_ch` passed with zero errors. The final diff whitespace check passes.
- Other focused regressions are recorded above: metric density, mip/border/arrival filtering, cross-region and negative-coordinate SVT pressure, cell source persistence/composition, material generation, instance batch ordering and exact rendered output, editor preview/painting, data/streamer contracts, and 65536-entry allocator behavior.

Remaining boundaries: cold streaming is not eliminated; all-visible 10.24 km moving demand remains expensive; SVT I/O/extraction/export remain synchronous; page-level CPU budget is soft and is not a GPU frame budget. Conservative culling bounds and required seam geometry remain unchanged. No reduction of actual early-Z overdraw, broad GPU/FPS multiplier, arbitrary third-party shader equivalence or all shadow/displacement configurations is claimed. GPU resource-failure recovery is implemented but not failure-injected. Optional legacy example/tool issues and further service/editor caching opportunities remain separate follow-up work.

The current architecture is summarized in `vt_architecture_review.md`; old contradictory distance-control and page-file descriptions there and in `doc/feng-terrain-frp.md` were replaced with the shipped behavior.


## Architecture pass: structure and deletion

A later pass attacked readability and maintainability directly rather than cost. It is
recorded here because the deletions above are listed as "read", not as "used".

- **AVT demand is no longer one 520-line function.** `_update_sector_avt` is now 42 lines
  that call seven named phases (`_avt_plan_state`, `_avt_install_or_reuse_plan`,
  `_avt_scan_sectors`, `_avt_build_hierarchy`, `_avt_sync_address_directory`,
  `_avt_submit_plan`, `_avt_publish_directory`) plus a file-local worker function
  `avt_plan_pages`. The records those phases pass around moved out of `Terrain3D`'s private
  nesting into `native/src/terrain_3d_avt.h`, so a phase can be a function with a signature
  instead of a closure over the caller's locals. No algorithm changed in the move; the one
  behavioural slip it introduced (the background plan was stamped with the key being
  replaced instead of the new one, which stopped plans from ever installing) was caught by
  the before/after regression diff and fixed.
- **`terrain_vt.h` lost the half production never called** (863 -> 384 lines): the
  `AddressProfile` descriptor tables and preset selection, the page-id packing helpers, the
  LRU key encoding, the physical-page UV/world-rect math, the feedback sizing and Bayer
  dither, and the high-coordinate allocation order SVT never used. The standalone contract
  test dropped the checks for the deleted API with it (653 -> 215 lines) and still passes.
- **Deleted outright:** `unit_testing.{h,cpp}` (only reachable through a commented-out call,
  yet compiled into every build), `Terrain3DData::produce_surface_pages` (a duplicate of
  `produce_surface_page_set`'s request enumeration with no callers),
  `Terrain3DVTPagePool::get_atlas_image`, `_vt_offline_producing`,
  `is_surface_vt_blocks_dirty`/`clear_surface_vt_blocks_dirty`, and a directory scan in
  `menu/directory_setup.gd` whose result was never read.
- **The two asset docks share one list.** `asset_dock.gd` and `asset_dock_45.gd` each
  carried the same ~740 line `ListContainer` + `ListEntry` pair; they differed in six
  places (editor-scale-aware tile metrics, the pair-role hover label, a `set_selected` tree
  guard, and comments). The Godot 4.6 copy -- the richer one -- now lives in
  `src/asset_dock_list_container.gd` and `src/asset_dock_list_entry.gd`, and each dock
  aliases them with `preload`, so `Dock.ListContainer` still resolves for the editor
  regression. 2508 lines became 1800, and the pre-4.6 dock inherits three cosmetic
  differences it cannot be tested for here: scaled tile metrics, a 16 point font cap
  instead of 18, and the role label on hover. Both dock editor tests pass; the pre-4.6
  path has no engine to run on in this checkout.
- **Two cross-file contracts became one definition each.** `terrain_vt_cell.h` now holds the
  `.vtcell` version, path and source signature that the baker and the runtime reader each
  used to spell out separately -- a reader that computes a different value reports every
  baked cell as missing. `Terrain3D::_configure_surface_view()` now applies one view's page
  dimensions, format and mode-specific addressing; the initial setup and the shared-pool
  rebuild both call it, where the rebuild previously relied on settings that happened to
  persist on the object.
- **The test runners no longer each carry their own harness.** Twelve runners were the same
  fifty lines with six values changed. `native/tests/fixture.py` owns the fixture and the
  two-phase engine invocation, `run_script_test()` takes those six values, and each runner
  is now a ~28 line wrapper that names its script, log and PASS marker.
- **`terrain_3d.cpp` is six files.** At 2900 lines it held the node's lifecycle, the VT
  service, the property setters, the queries, the warnings and every ClassDB binding. The
  definitions moved -- no logic changed -- into `terrain_3d_vt_service.cpp`,
  `terrain_3d_geometry.cpp`, `terrain_3d_properties.cpp`, `terrain_3d_queries.cpp` and
  `terrain_3d_bindings.cpp`, leaving 683 lines of node lifecycle and a comment that maps
  the rest. The compiler and the same 29 test regression check a move like this.
- **The node's VT fields are one struct.** `terrain_3d.h` declared 103 virtual texture fields
  interleaved with the mesher, ocean, CDLOD and rendering fields. They are now
  `terrain_3d_vt_state.h`'s `Terrain3DVTState _vt` -- 178 lines out of the header, which went
  from 754 to 619 -- and a reference reads `_vt.vt_page_size`, `_vt.surface_svt_page_world`
  or `_vt.avt_plan_key`: the subsystem prefix stays (it says which tier the field belongs to)
  while the leading underscore of the original member names goes, because the struct is no
  longer a class member. The move is verbatim declarations in their original order with the
  same initializers; 1030 references were rewritten across seven files, scoped to
  `Terrain3D`'s own definitions so `Terrain3DVirtualTexture::_page_size` and every other
  same-named member of another class was left alone, and never inside a string literal. The
  compiler and the full regression check a move like that.
- **The stall that made that move fail the first time got fixed, so it could land.** The first
  attempt was reverted: it flipped `editor_dock --test vt_idle` deterministically
  (`missing_pixels=1681252`, byte-identical across three runs) although the struct was
  field-for-field equivalent to the field list it replaced. The cause was a real pre-existing
  stall in the editor wakeup, not the move: `_update_vt_service()` asked for a redraw only
  while the surface baker reported render work, so an indirection upload that was already
  queued for the render thread had nothing to run it once the baker went idle, and the
  refactor's timing was enough to land in that window.
  `Terrain3DVTIndirection::has_pending_upload()` now keeps that request alive while an upload
  is outstanding (see [`history/vt_tuning_log.md`](history/vt_tuning_log.md)), and with the fix
  in place the same extraction passes: `missing_pixels=0`, and the full 29-test differential is
  29/29 unchanged (`bin/terrain-after14.json`). Frame count was incidental rather than the
  mechanism -- the passing pre-fix run made 78 indirection commits and the failing one 58, but
  the post-fix run passes at 60; what matters is that a queued upload always drains.
- **The VT window's bridge and image maths moved out of it.** `vt_editor.gd` (1579 lines)
  kept the widgets and the selection state; `vt_terrain_bridge.gd` owns the duck-typed
  native calls and `vt_overview_image.gd` owns the world/image maths and the per-pixel
  stitch as pure functions. Call sites were left alone -- the window keeps one-line
  delegations -- so the move could not change behaviour.
- **The two remaining long C++ functions became named phases.** `_produce_sector_avt_pages`
  (123 lines of locals, two lambdas and three interleaved loops) is now a 15-line pass over
  `_avt_classify_plan`, `_avt_retain_visible`, `_avt_prime_sources`, `_avt_produce_visible`,
  `_avt_produce_prefetch` and `_avt_finish_produce`, with the per-pass state in
  `Terrain3DAVTProducePass` (`terrain_3d_avt.h`) so each stage has a signature instead of a
  capture. `update_surface_vt` (246 lines) became a 60-line loop over
  `_prepare_vt_block_tables`, `_collect_eligible_vt_regions`,
  `_compute_adaptive_sector_sizes`, `_retire_stale_vt_sectors`, `_prepare_vt_sector`,
  `_vt_page_requests_for_sector`, `_produce_missing_vt_pages` and
  `_publish_vt_block_tables`. Its `requested` counter was incremented for every planned page
  and never read; it is gone. Stage order, side-effect order and every value are otherwise
  unchanged.
- **The editor's cursor decal is its own module.** `ui.gd` (839 lines) mixed the tool/menu
  wiring with ~300 lines of cursor rendering: 19 colour constants, the three decal arrays,
  the brush/reticle texture, the fade tween, the region-directory preview and a 200-line
  per-tool colour decision tree. `src/ui_decal.gd` owns all of it and `ui.gd` keeps three
  one-line forwarders, because `Terrain3DEditor` and the editor plugin reach the decal
  through the UI node (`ui.update_decal()`, `ui.hide_decal()`,
  `ui.set_decal_rotation()`). Tool, brush and pointer state stay on the UI node and the
  decal reads them, so no state was duplicated. `ui.gd` is 532 lines.
- **`tool_settings.gd`'s 180-line `add_setting` became three functions.** The parse and
  validation stayed in `add_setting`, the widget construction for every `SettingType` moved
  to `_create_setting_control` (which appends a row's companion widgets to an out array),
  and the label/separator/spacer assembly moved to `_add_setting_decorations`. The setting
  registry that `_ready` declares is untouched, and the file is a widget factory plus a
  list of settings rather than one function doing both.
- **`terrain_3d_data.cpp` is three files.** At 2263 lines it held three unrelated jobs:
  the slot allocator, region maps and every data query; the on-disk path (region files,
  map export, map import, `layered_to_image` and the `_save_export_image` helper); and the
  resampler that turns a region's R16 payload into VT pages. The on-disk path is now
  `terrain_3d_data_io.cpp` (571 lines) and the payload resampler
  `terrain_3d_data_surface.cpp` (260 lines), leaving 1475 lines of storage, lifecycle,
  painting and queries in `terrain_3d_data.cpp`, each of the three headed by a comment that
  names the other two. Definitions were counted across the three files before and after the
  move: 68 before, 67 after, the one difference being the `produce_surface_pages` duplicate
  deleted earlier in this pass, and no definition appears twice.
- **`terrain_3d_material.cpp` is two files.** The first 520 lines were the GLSL pipeline --
  loading the shader inserts (including the `shaders/*.glsl` files behind `DEBUG_ENABLED`),
  insert selection and exclusion, debug/editor code injection, comment stripping and the
  decision whether the generated shader needs VT samplers -- and the rest was the material
  resource: uniforms, noise/gradient textures, ~70 property setters, save and bindings. The
  pipeline is now `terrain_3d_material_shader.cpp` (546 lines) and the resource
  `terrain_3d_material.cpp` (1132), each headed by a comment naming the other. The 67
  definitions were counted before and after: identical sets, none duplicated.
- **Verification infrastructure.** `native/tests/run_all.py` runs every runner in one
  command, prints one `PASS`/`FAIL` line per test with its failing markers, cleans up the
  fixtures it creates (537 leaked ones, about 13 GB, were also reclaimed) and can write a
  JSON result; `native/tests/compare_runs.py` diffs two of those results and flags only the
  tests whose status changed. That diff is how the pass was verified: every intermediate
  run was compared against the pre-change baseline, and the last two report
  `29/29 unchanged` (`bin/terrain-after14.json`, the VT-state extraction as landed) and
  `28/29` (`bin/terrain-after15.json`, after the field-name cleanup). `vt_pressure` is the
  known flake: it asserts `settings.shared_pool` and flips status on the unmodified binary
  too (pass in after9, fail in after10, pass in after15).
- **What was left alone, and why.** The legacy AVT selection modes and the GPU feedback
  pass look like delete candidates from the inside, but they are the tested contract:
  ten test scripts set `surface_vt_selection_mode` (0 visible-terrain, 1 target grid,
  2 sector AVT) and four drive `surface_vt_feedback_enabled`, among them tests that are
  green in the baseline. They are diagnostic and compatibility surface, not dead code, so
  deleting them would break the regression suite and the "existing behaviour stays
  working" requirement of this pass. `tools/region_mover.gd` is likewise a manual utility
  whose issues are recorded in the tool inventory above; its references were rechecked and
  it has none, but removing a script a user may attach by hand is the owner's call, not
  this pass's.

### Removed: the experimental distance-mip controls

The one cluster that was genuinely dead, and has now been deleted:
`set_surface_vt_distance_mips()` (which forced the member it set back to `false`),
`set_surface_vt_mip_ranges()` (an empty function), `get_surface_vt_distance_lod()` (which
returned `0`), the `surface_vt_mip0/1/2_distance` accessors built on `mip_ranges`, the two
members behind them, their six `ClassDB` bindings, their five properties and the
`avt_distance_mips` / `avt_mip_ranges` keys of `get_vt_settings()`. Nothing was serialized:
every property was declared `PROPERTY_USAGE_NONE`, so no saved scene ever carried them, and
the editor dock had already dropped the `AVTMipDistance*` controls that
`vt_resolution_controls.gd` asserts are absent. The test asserted their no-op behaviour —
`terrain.surface_vt_distance_mips = true` must leave it `false` — which was the only thing
keeping them; those three assertions are gone with the surface.

The distinguishing test was the suite, not a judgement call: `vt_debug_direct_material` is
set by nine scripts, `surface_vt_selection_mode` by thirteen, `surface_vt_force_mip` by six.
Only the distance-mip cluster had no reader outside the test that pinned its no-op.

### The far field now reads in the same shape as the near field

The near field's production pass has had a named stage record since the budget work:
`Terrain3DAVTProducePass` is filled in order by `_classify_plan` → `_retain_visible` →
`_prime_sources` → `_produce_visible` → `_prefetch` → `_finish_produce`, so a reader can find one
stage without reading the pass. The far field had no such structure: `_update_visible_svt()` had
grown to **484 lines** holding six stages — the visible-region scan, the recursive footprint walk,
the shared-capacity request, the level-window publish, the root pyramid, the over-subscription floor
search — plus the detail loop and the worst-pass statistics. Every one of them was reachable only by
reading the whole function.

`_svt_plan_roots()` now owns the root pyramid (283 lines left in the pass, 213 in the new method),
with its inputs and its two outputs named instead of being locals in the middle of the pass:

```cpp
std::array<double, 4> _svt_plan_roots(const Rect2 &p_domain, int p_maximum_mip,
        int p_coverage_limit, int p_physical_page_count, int &r_produced, bool &r_cached);
```

It returns its four stage timings rather than writing them, which is what let the extraction keep the
existing `ST_ROOTLIST`..`ST_ROOTCOV` attribution: the pass fills those four slots from the array, so
`svt_stats` reports `rootlist_ms` / `rootunpin_ms` / `rootreq_ms` / `rootcov_ms` exactly as before.
The first attempt dropped the `rootreq` stamp and moved 1.5 ms of a root walk into `rootcov_ms` —
which is the whole reason the stages are reported at all, and it is why the extraction was verified
against `svt_stats` rather than only against the suite.

Verified behaviour-neutral: `vt_recovery`, `vt_pressure`, `vt_svt_coverage` and `vt_demand` pass
standalone, `vt_turn_budget`'s paint readings are unchanged (172 leftover diagnostic pixels after a
warm turn, 627 / 0 in the isolated turn's bands), and the reported `svt_stats` for the worst pass is
the same breakdown of the same pass.

### The surface baker's render callback, in its stages

`Terrain3DSurfaceBaker::render_pending()` is the render-thread callback that turns the demand queue
into a compute dispatch, and it was 272 lines of stages with nothing naming them: the lock-scoped
snapshot, the retiring of old resource bundles, the resource rebuild, the material refresh, the job
list, the per-slot invalidation and production loop under the page budget, and the dispatch. Two of
those stages are now methods, which is what the callback reads as:

* **`_retire_acknowledged_bundles()`** — frees the bundles the material has stopped sampling, from the
  frame after it acknowledged the pair it is drawn with. It needed no parameters at all: it reads
  `_retired`, `_acknowledged_frame` / `_acknowledged_generation` and writes `_retire_ready`. It was
  also indented one level too deep in the callback, a leftover from an earlier edit that the compiler
  is happy with and a reader is not — extracting it is what puts it back at the right depth.
* **`_build_frame_jobs()`** — the frame's job list: one job per slot with an invalidation standing in
  where nothing is queued, when the whole atlas is invalidated; otherwise exactly what was queued. A
  pure function of its four arguments, which is why it is `const`.

* **`_dispatch_frame_jobs()`** — the stage worth the most: the encode halves, the per-slot loop and the
  compute dispatch, 133 lines. It takes the frame's job list and reports one thing back, a `bool`:
  false when the job recording failed, which means the frame did nothing, every job is back in
  `_pending` and the whole atlas is marked for invalidation, so the caller returns. Everything else it
  works through — `compute_jobs`, the `scratch` regime test, the `cleared_all` / `cleared_layers`
  invalidation shortcut, `_frame_page_updates` — is local to it.

`render_pending()` is 116 lines, down from 272. The extraction was a scripted move rather than a
hand-paste — 126 lines relocated and ten caller-locals renamed to parameters — because renaming ten
identifiers across a hundred lines by hand is where a silent miss lives. The script asserted every
rename's occurrence count and refused to write on a mismatch, which is how it caught three
`_set_ready(..., generation, ...)` call sites where two were expected; the renames it did *not* cover
are exactly the ones the compiler then found (`cleared_layers`'s `page_count`, the three `_record_jobs`
arguments, and that the job list has to be passed by non-const reference because the loop stores the
staging layer into each job).

Two of `_ensure_resources()`'s six stages are now methods, taking it from 296 lines to 233:

* **`_adopt_grown_pages()`** — carries a grown pool's finished pages into the bundle replacing it, and
  queues the old bundle for retirement. Its doc comment is where the two reasons live: the old output
  has to stay alive until the material has bound the new arrays (so it goes through `_retired` rather
  than being freed), and under the scratch regime there is nothing to copy at all, because a page's
  half-float content only ever lives in the encoder ring and a block-compressed layer cannot carry the
  unordered-access flag `texture_copy` needs on D3D12.
* **`_adopt_bundle()`** — adopts a finished bundle and resizes everything indexed by the page count
  together, so no slot can be read at a size the arrays do not have. It is also where a grown pool's
  ready pages are marked to be encoded again: a block-compressed layer cannot be copied between
  formats, and the staging copy is what carries the content across the resize.

The stage that was worth the most is **`_create_bundle_resources()`** — every texture and sampler of a
bundle, the per-tier compressed arrays, the staging and output textures, and the validation of all of
them, 128 lines. It takes the bundle to fill plus the stored page size and the page count, and nothing
else: the per-tier loop and the ring sizing write members, so they need no plumbing. `_ensure_resources()`
is 113 lines, down from 296.

Two stages are left and are named for the next pass: the guards, and the previous bundle's capture with
the growing decision.

`vt_format` is the test that covers this path directly — it changes the page format and asserts the
page pool survives — and its `PASS virtual texture format change keeps the page pool` holds with
`ERRORS=0` after the extraction, as do `texture_layers`, `vt_compression` and `vt_codec_colors`.

The move was scripted again, and the script's own limits are worth recording: it asserted all twenty
`next` → `r_next` renames by count and refused to write on a mismatch, but it did *not* know that the
span's last line closes the moved block rather than the function, so the extracted function came out
without a closing brace, and it left the caller's own `ResourceBundle next;` in place beside the one
the call site needs. The compiler found both immediately (C2601, "local function definitions are
illegal"); a boundary is not something a rename count can check.

**And it indented the moved code one level too deep, which is the same defect this pass had already
found and fixed in someone else's edit.** Both scripted moves did it — `_dispatch_frame_jobs()` too —
because the script added a tab to code that was already inside a function body. It was fixed by
de-indenting each body by exactly one tab, over the range the brace match gives (on masked text, since
these files quote braces in comments and raw strings). The lesson is the uncomfortable one: finding a
class of defect in the code is not the same as not writing it, and the only reason this was caught is
that the *next* thing that pass did was read the same function again for an unrelated reason.

**It happened a third time, in the extraction this pass is proudest of.** `_svt_walk_visible_pages()`
was lifted out of `_update_visible_svt()` and kept the depth its body had inside the old function: all
fifty-one lines sat one tab too deep, and the run-based indentation check cannot see that, because a
uniformly over-indented body puts every line at `expected + 1` — exactly where a wrapped continuation
belongs. Narrowing the check to the one line with a unique expected depth, the *first* statement of a
body, is what finds it (`body_indent.py`): one case in the whole tree, this one. The same pass also
left four wrapped signatures in `terrain_3d_surface_baker.cpp` indented with eight spaces rather than
two tabs; the run check skips anything inside an unclosed parenthesis, which is why an earlier
space-versus-tab sweep did not see them either. Both are fixed, and the check's continuation rule now
covers a line ending on `|` or `&` as well as `+` — without that it reported the two legitimate
bitfield wraps in `terrain_3d_editor.cpp` and the baker as wrong.

The lesson generalises past this file: a tolerant check has to be paired with a strict one on the few
lines where the tolerance cannot legitimately apply, or the defect it tolerates hides behind it.

One cosmetic inconsistency is recorded and deliberately **not** fixed: the shader files are
tab-indented (main.glsl is 776 tab-indented lines against 14 space-indented ones, all of them inside
its header comment), but `backgrounds.glsl` carries a vendored noise block of about thirty 4-space
lines, and `editor_functions.glsl` four more. Whitespace in GLSL changes nothing at runtime and those
files are upstream text, so restyling them would be churn with no reader benefit beyond consistency;
it is listed here so the next pass can decide rather than rediscover it.

The three largest functions left all need the same thing before they can be split, and it is a design
step rather than a move:

* `_update_visible_svt()` (283) — **split**: the footprint walk is now `_svt_walk_visible_pages()`, and
  the pass is 235 lines. This needed the design step first, twice over: the two records it hands the
  walk (`Terrain3DSVTRegion`, `Terrain3DSVTPage`) had to leave the function for `terrain_3d_svt.h`,
  declared the way `terrain_3d_avt.h` declares the near field's plan types and for the reason that
  header's own comment gives — so a stage can be a function with a readable signature instead of a
  lambda closing over a large function's locals. The `avt_interior` predicate stays in the pass and is
  passed in, and the addressable `domain` moved *up* to the caller, because the root plan below the
  walk is bounded by it too.
* `_request_encodes()` (199) — its 137-line per-page loop carries a locally-declared `PendingStore`.
* `_operate_map()` (492) — 95 lines of brush-parameter gathering feeding a 308-line paint loop that
  caches a region image across iterations. This one wants a context struct for the loop, and it is the
  only one where the split changes how the code reads rather than only where it lives.

The scripted move produced three faults this time, and the pattern in them is worth more than the
move: the moved range *included* its end marker, so the walk came back carrying the caller's
`stamp(ST_WALK)` and its own `visible_page_count`; a local it renamed collided with the out-parameter
of the same name; and `domain`, declared inside the range, was needed on both sides. Ranges want to be
half-open and to hold only what moves — a rule both of this pass's scripted moves broke, in different
ways, and the compiler caught each one within a build.

The new header also has a gotcha worth more than the header itself: **a Godot type has to be
qualified in a header that can be included first.** `Rect2` and `Vector2` are in `namespace godot`, and
the `using namespace godot;` that makes them writable unqualified lives in `terrain_3d_vt_visibility.h`
and `constants.h` — which every other header in the addon happens to be included after. This one is
first in `terrain_3d_vt_demand.cpp`, so it needed `godot::Rect2`. Two builds were spent on that, and
the same two on including `terrain_vt.h`, which does not declare `VisiblePatch` at all — that is in
`terrain_3d_vt_visibility.h`.

### Audit helpers, kept as one tool

`native/audit_code.py dead`, `undefined`, `sections`, `comments`, `params`, `shape` and `dupes` are
what answered "what is dead", "what is declared but never written", "does the file's own banner still
describe it", "does the prose still name something that exists", "does every parameter mean something"
and "what has outgrown its file" without reading the source by eye. `dead` is what found
`get_warnings()` (nothing outside its own declaration, and no binding) and confirmed the distance-mip
cluster above; re-run over the tree as it stands it reports **no unused `Terrain3DVTState` field**, of
197 declared, and nothing else but the generated doc data's registration hook. `shape` is what found
`_update_visible_svt()`. They are reported as candidates rather than verdicts, and say so: a property
getter named only from its `ADD_PROPERTY` binding string is live, and the report names the sixteen
that look dead for exactly that reason.

**`shape` was measuring wrong, and that is worth recording because its numbers were acted on.**
A span is the distance from one definition to the next, so anything the detector misses is not
reported as missing — it is silently added to its predecessor. It missed two whole kinds of
definition:

* **Namespace-scope functions.** The detector matched `Terrain3D::name(` only, so the 194-line
  `avt_plan_pages()` in `terrain_3d_sector_avt.cpp` was attributed to whatever member function
  preceded it. That made `set_surface_vt_selection_mode()` read as **229 lines**; it is **nine**.
  Splitting a nine-line setter was the next thing on the list, and checking the number by hand first
  is the only reason it did not happen.
* **The embedded shaders.** They are raw string literals, `R"(#version 450 … )"`, and the GLSL inside
  them sits at column 0 and looks exactly like a definition — `vec4 encode_vec4(…) {`, `void main() {`.
  A first attempt at the fix reported `encode_vec4` at 1699 lines and a `main` at 877.

The detector now masks comments and raw string literals (keeping every offset, so line numbers still
mean something) and matches a column-0 line that is not a comment, a preprocessor line or one of the
scope keywords, whose name may be qualified — the initial fix failed because `[\s*&]` before the name
does not match the `:` of `Class::method(`. It reports member and namespace-scope definitions alike,
and its numbers now agree with the ones checked by hand: `_update_visible_svt` 283,
`_ensure_resources` 233, `_svt_plan_roots` 214, `render_pending` 116.

The lesson generalises past this file: a metric that is off by an attribution error looks exactly like
a metric that is right, and the only cheap defence is to check one known value by hand before acting.

### `dupes`: what is *not* there

`native/audit_code.py dupes` is the complement of `dead` — that finds code nothing reads, this finds
code written twice. Bodies are compared as line sequences with comments and indentation dropped, so a
reformatted copy still matches while one whose identifiers were renamed does not; it under-reports
rather than producing pairs a reader has to reject one by one.

It compared **541 definitions and found none written more than once**. That is a result, not a
non-event: the deletion half of this pass has no copy-paste to collect, so what is left there is
removal of things nothing calls (which `dead` answers) rather than merging.

### `undefined`: the promise no file keeps

`native/audit_code.py undefined` is the check neither the compiler nor `dead` can make. It
attributes every declaration in a header to the class that encloses it and asks for that
*qualified* definition, which is the only way to see the case it was written for:
`Terrain3DVTPagePool::get_atlas_image()` was declared beside the live
`Terrain3DVirtualTexture::get_atlas_image()`, defined nowhere and called nowhere. The compiler is
silent because nothing calls it, and `dead` counts the name as used because the other class declares
a method with it — so the entry in **Deleted outright** above was wrong until this pass, and the
declaration was still sitting in the header it names.

Two corrections were needed before the report was worth reading, and both are the same mistake: a
declaration is neither a *local variable* nor a *call*. The first version matched
`std::lock_guard<std::mutex> lock(_mutex);` and `const Vector3 center(...)` inside inline bodies and
reported a dozen methods that do not exist; gating every match on "this line's brace depth is the
enclosing class's body depth" removed all of them. The second reported free functions that are
defined in a header rather than a `.cpp`, which is most of `terrain_3d_util.h` and
`terrain_surface_idweight.h`.

Run over the tree as it stands it reports none of either kind, which is what makes the one deleted
declaration a fix rather than a coincidence.

### The section banners that were lying

`sections` is the only check here about a *file* rather than about code, and it is the one that found
a defect class nothing else can see: a definition under a "Private Functions" banner whose declaration
in the header says `public:`. The compiler does not care where in a translation unit a definition
sits, so the banner is the only place that claim is made — and thirteen of them had accumulated:

* `terrain_3d_streamer.cpp` had all nine of its private helpers (`_sync_data`, `_resolve_directory`,
  `_is_inside_world`, `_is_resident`, `_collect_desired`, `_collect_unload_candidates`, `_try_load`,
  `_try_unload`, `_notify_region_set_changed`) under "Public Functions", interleaved with the public
  ones. The file now groups them the way its header already did: private first.
* `terrain_3d_assets.cpp` defined three public property setters (`set_texture_array_size`,
  `set_texture_array_mipmaps`, `set_texture_array_compression`) inside the private block; they moved
  in beside the asset setters the header declares them with.
* `terrain_3d_vt_feedback.cpp` had `get_raw()` — the accessor the feedback test reads — under the
  private banner.
* `terrain_3d.cpp` had its only public definition, `set_streaming_enabled()`, at the end of the
  private block. It is now in `terrain_3d_properties.cpp` with every other public setter, which is
  what makes "terrain_3d.cpp is private helpers and the Node overrides" true rather than nearly true.

All thirteen were moves with no text changed. Moving the pre-fix files back in is the proof: fed
`HEAD`'s copies of the three files that were clean before this pass, `sections` reports exactly those
twelve and none on the tree as it stands. The compiler never objected to any of them, and
`region_streaming` and `vt_feedback` pass unchanged.

The check has one trap of its own, recorded because it produced eight false reports before it was
read: it first reused `undefined`'s declaration matcher, which requires the `;` to end the line, and
so could not see declarations that are inline bodies in the header (`bool is_ready() const { ... }`)
or whose default arguments push the `;` past the name. The header matcher is deliberately looser.

### Stale references in the prose

`comments` reads the comments instead of the code, which is the only way to find a name a comment
promises and the code no longer has. It collects three shapes that look like code — backticked names,
empty parameter lists, leading underscores — and reports the ones that appear nowhere in the addon's
sources, scripts, shaders or resources. Four were real:

* `terrain_3d_mesher.cpp` said "Append LOD to `_lod_rids`" directly above a
  `_clipmap_rids.push_back()`.
* `terrain_3d_vt_state.h` sent the reader to `Terrain3D::_process_physics()` for why the top-up phase
  went; the tick is `Terrain3D::__physics_process()`.
* `terrain_3d_editor.cpp` described the array rebuild "at the end of the last `_operate()` call" — the
  function is `_operate_map()`.
* `terrain_3d_editor.h` said "See `_get_undo_data` for definition" of a dictionary that
  `_store_undo()` writes and `_apply_undo()` reads.

The other twenty-five candidates were right, and naming them is part of the result: engine internals
(`Node::_process()`, `RenderingDeviceGraph::_execute_frame()`, `std::mutex::try_lock()`,
`Image::get_format_pixel_size()`), GDScript reached through `call()`, test script names, and prose
that happens to carry underscores. Two lessons are recorded in the check because each cost a pass:

* **Not masking raw string literals is the point.** Masking them the way every other mode does made
  the shaders invisible, and the report filled with shader parameters (`p_world`, `p_surface_texel`,
  `projectionAxis`, `surface_svt_sample`) that exist — sixteen of the first twenty-nine candidates.
  This check's corpus is "text with comments blanked", not "text with literals blanked".
* **The corpus has to be rooted at the addon, not at `native/`.** Rooted where the tool lives, it
  never read `src/tool_settings.gd`, so a comment pointing at `tool_settings.gd:_on_picked()` looked
  stale — and a check that reports a correct comment teaches its reader to ignore the check.

Run over the tree as it stands it reports nothing, which is the state worth keeping: the next line it
prints is either a new stale reference or a new class of legitimate one for the engine list.

One check was written for the *misattached* comment — a comment block above one declaration that names
a different declaration of the same file — and dropped rather than kept. Two versions were tried:
"the comment names any member of the file" fired on forty-odd legitimate cross-references ("see
`get_x()`", "split out of `_update_visible_svt()`"), and "only backticked names, and only when the
comment never names the declaration it sits above" still fired on twenty-three, every one of them
inspected and legitimate (the `get_prime_stats()`/`prime()` pair, the `_claim_head`/`_claim_order`
pair, a group comment introducing three stage declarations). The two real cases this pass fixed — the
fade comment that sat above `_flush_source_wakes()` and the force-mip comment above
`set_surface_vt_texels_per_pixel()` — were found by reading, while moving the members they describe,
and no mechanical rule separated them from the legitimate mentions. Recorded so the next pass does not
rebuild it.

The addon's *tests* are a different story and were left alone. `settle()` — the "wait until production
stops and nothing is pending" helper — appears in nine test files, and the first reading of that is
"nine copies, unify them". Checking each one first changed the answer twice:

* they are not one family. Two of the nine extend `vt_adaptive_base.gd`, two extend
  `vt_render_base.gd`, and five extend `SceneTree` directly with their own names and shapes
  (`settle_sectors`, `settle_views`, `settle_bundles`, `settle(max_ticks)`). One of them,
  `vt_region_ownership.settle_views()`, is not a settle predicate at all — it waits a fixed 140 frames.
  So the largest possible unification within one family is two files.
* and that unification does not work. A helper on `vt_adaptive_base.gd` cannot drive `tick()`, because
  GDScript resolves the call statically against the base and the base has no `tick()` — each scenario
  defines its own, one driving the demand pass directly and another through the physics notification.
  Passing the tick as a `Callable` would make it compile, and it was reverted rather than done: a
  `Callable` parameter plus nine rewritten call sites to delete eleven lines of predicate is not a
  trade worth making on the suite that verifies everything else.

Reverted, and the scenarios re-run to their previous state — which for `vt_metric_density` and
`vt_sectors` is the pair of engine-side failures recorded earlier, with no parse errors, so the revert
is exact. The duplication is recorded here as *deliberate* rather than as debt.

### Smaller cleanups in the same pass

* `get_warnings()` removed: a public accessor with one reference outside its declaration and no
  binding.
* The pass-timing idiom — `uint64_t start = ...; run stage; stats[key] = ms(start); start = ...`
  repeated seven times in one method and six in another — is now one `mark(key)` lambda per pass, so
  `_produce_sector_avt_pages()` and the planning chain read as the stages they run.
* Comments that described code that no longer exists: the phase list still named a "near-field
  production top-up" as a phase (removed two passes ago, kept as a reported zero), and
  `_avt_logical_ratio()` justified itself by "the staged planner publishes the directory one phase
  before it submits the plan" (there is no staged planner; the real reason is that the publish
  precedes the submit in the chain).
* `Terrain3DPagePipeline`'s queue is two flat `std::vector`s (an entry array and a FIFO of keys)
  where it was a `std::map` plus a `std::set` of `(token, key)` pairs kept in step by hand. Measured
  neutral on every phase: it is a simplification, not an optimisation, and it is recorded as such
  rather than as a win.
* `Terrain3DVirtualTexture::_request_virtual()` is declared private, but sat between
  `request_page()` and `request_page_internal()` in the `.cpp`, so the "Public Functions" banner was
  wrong about one of the three. Moved, with no text changed.
* `terrain_3d_vt_demand.cpp` carried an exact duplicate of the first line of a comment block as a
  stray line two blanks above the block it copies, and six other files plus that one separated two
  definitions with two blank lines. Both are gone, and the tree now contains no double blank line.
* `Terrain3DData::_grow_slot_capacity()`'s ceiling comment named `MAX_REGIONS`, which is a GLSL macro
  the material shader is compiled with — not a C++ identifier, and not what the line bounds against.
  The code clamps to `MAX_MAP_SLOTS`, the CPU ceiling that matches the *largest selectable*
  `max_regions`; the comment now says that, and says why a table past the ceiling could never render.
* Two literal `0xF` masks meant "every slot map" — the one `_acquire_slot()` sets on a fresh slot and
  the one a `TYPE_MAX` request resolves to. Both are now `SLOT_MAP_ALL`, derived from `SLOT_MAP_MAX`,
  because a fifth slot map would otherwise have silently kept meaning four.
* `Terrain3DData::add_region_blankp()` took `p_update`, exposed it to Godot as `update` in its
  binding, and then called the location overload **without** it: `add_region_blankp(pos, false)` — the
  bulk path that is supposed to skip the map rebuild per region — rebuilt every map anyway. This is
  the one defect here that changed behaviour rather than wording, found by reading the function while
  walking the file.
* `Terrain3D::_svt_page_path()` took a `p_mip` and hard-coded `0` into `TerrainVTCell::path()`. All
  three callers pass 0 and the cell file carries its whole mip chain, so the parameter could only ever
  mislead a future caller: it is gone, and the reason mip 0 names the cell is now on the declaration.

### The page pool left the view that shared it

`Terrain3DVTPagePool` was declared and implemented inside `terrain_3d_virtual_texture.{h,cpp}`, which
is the file of *one* view — and two views use it, because there is one physical atlas. It is now
`terrain_3d_vt_page_pool.{h,cpp}`: the atlas, the global slot allocator, LRU and protection, the
reverse owner index, and page read/write, with the three contracts a caller has to keep stated on the
header instead of implied by the code. `terrain_3d_virtual_texture.cpp` went **1375 -> 983 lines**
(and its header 349 -> 264), and what is left there is per-view: the indirection texture, the
mip-chain walk and the sector block bookkeeping.

The move is mechanical, and the two files still reach each other in exactly one place: an eviction
calls back into `Terrain3DVirtualTexture::_invalidate_pool_owner()`, through the friendship the class
already declared. Two things did not survive it unchanged, and both were errors the split exposed:
`Terrain3DVTPagePool::get_atlas_image()` (see `undefined` below), and the pixel-size helper, which was
a file-local `static` in the view and is now `vt_format_pixel_size()`, declared beside the pool
because the atlas layers and the indirection chain are both sized by it.

### `Terrain3DEditor::_operate_map()`: 490 lines to 198

`_operate_map()` was the largest definition in the addon — two and a half times the next one — and it
was one function doing six jobs: gather the brush, dispatch on map type, run four different per-texel
representations, then finish the edit. The brush loop alone was a 308-line nested body whose four
branches each ended differently: the height branch fell through to a shared `set_pixelv()`, the
surface branch `continue`d after writing bytes of its own, the colour branch could `continue` from two
places before its switch, and the gradient case `return`ed out of the whole function.

The split names those differences instead of leaving them implicit:

* `MapBrushOp` — the twenty-odd values `_operate_map()` reads out of the brush dictionary once, so the
  per-texel work can be a function. It also documents what a brush *is*: an operation is a map type, a
  shape, a strength and a payload, and nothing per-texel.
* `TexelResult { TEXEL_WRITE, TEXEL_SKIP, TEXEL_ABORT }` — the three endings the branches actually had.
  The loop now acts on the result in one place: abort, skip, or `backup_region()` + `set_pixelv()`.
  `TEXEL_ABORT` is only reachable from the gradient case, which is why it is named for the operation
  rather than for the texel.
* `_paint_height_texel()`, `_paint_control_texel()`, `_paint_color_texel()` — one per map type, chosen
  by the map type. Adding a representation is adding a handler rather than editing a loop.
* `_finish_map_operation()` — the 56 lines after the loop: mipmap regeneration, the partial-vs-full
  `update_maps()` decision, the surface array refresh, VT page invalidation, collision and `snap()`.
* `SurfaceByteCache` — the R16 payload cache that used to be four loop locals and a `[&]` lambda
  defined inline in `_operate_map()`, including the `Image::Format(39)` re-decode on write-back and the
  region-change test. It gets a type because it has an invariant worth stating: the bytes are a
  copy-on-write view, so exactly one region may be cached at a time.

Two behaviour notes, both deliberate:

* The gradient `TEXEL_ABORT` path now flushes the surface cache before returning. This is a no-op by
  construction — the surface cache is only ever populated for the `TEXTURE` tool, and `TEXEL_ABORT`
  requires `_operation == GRADIENT`, which cannot run with `TEXTURE` — but it removes a latent
  drop of pending writes if those conditions ever change.
* The block-replication `continue` in the `TEXTURE` path had to stay a `continue`: it skips the `(0,0)`
  texel, which the handler has already painted through `_paint_surface_pair()`. It is the one
  `continue` in the extracted code that is *not* a loop-level skip.

#### How it was verified

The refactor was gated on a new test, `native/tests/editor_paint.gd`, written *before* the move.
`region_slots.gd`, `texture_layers.gd`, `vt_density.gd` and `vt_render.gd` all drive
`start_operation() → operate() → stop_operation()`, but every one of them paints with the `TEXTURE`
tool only, so the height, colour and legacy-control branches had no headless coverage at all. The new
test drives all twelve tool/operation pairs the toolbar can emit — sculpt add/subtract/average, the
alt-drag trough, gradient, height, colour, roughness, holes, navigation, autoshader, texture — each on
its own region, asserts the visible effect of each (an exact height, the set/cleared control bit, the
written material pair), and pins the region's height + control + colour + surface bytes with an MD5
digest.

Every digest is byte-identical across the split, which is a much stronger statement than "the suite
still passes": it says the extracted handlers write the same bytes as the 490-line original in all
twelve branches, including the surface-cache flush points and the `edited_area` accumulation.

Three things the test found on the way:

* A blank region's control map is `COLOR_CONTROL`, so the autoshader bit starts *set*. `AUTOSHADER +
  ADD` therefore writes nothing at all, and a test that asserts the bit is set after painting passes
  vacuously. The phase had to become `AUTOSHADER + SUBTRACT`.
* `gradient_points` are world space, not brush-relative. The first version put the ramp in region 0 and
  painted in region 4, which clamps the projection weight to 1.0 and makes the phase assert nothing.
* The alt-drag trough clamps to the cursor height, so it is indistinguishable from a plain raise while
  the cursor sits at or above the surface. The phase moves the cursor 0.5 m below the surface, and the
  assertion is the clamped height.

And one thing it did *not* find. The `continue` → `TEXEL_SKIP` rewrite was applied by pattern, and the
pattern wrongly matched a `continue` inside the density-replication double loop. At the default
`surface_density` of 1 that loop is skipped entirely (it is guarded by `density > 1`), so all twelve
digests still matched. A second phase was added at `surface_density = 2` which reads the block back and
requires all four texels to equal the painted one — a check that cannot pass vacuously, because it also
requires the base texel to be non-zero. Both the fix and the coverage came from this: the test is only
as good as the configurations it drives, and a digest gate over one density is a gate over one path.

