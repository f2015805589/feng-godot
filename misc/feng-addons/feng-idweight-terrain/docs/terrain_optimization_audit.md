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
- [x] native/src/terrain_3d_vt_feedback.cpp
- [x] native/src/terrain_3d_vt_feedback.h
- [x] native/src/terrain_3d_vt_indirection.cpp
- [x] native/src/terrain_3d_vt_indirection.h
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

