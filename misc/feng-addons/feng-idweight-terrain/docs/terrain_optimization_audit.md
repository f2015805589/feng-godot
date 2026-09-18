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
- [x] native/src/terrain_3d_assets_meshes.cpp
- [x] native/src/terrain_3d_assets_textures.cpp
- [x] native/src/terrain_3d_avt_plan.cpp
- [x] native/src/terrain_3d_avt_plan.h
- [x] native/src/terrain_3d_avt_produce.cpp
- [x] native/src/terrain_3d_collision.cpp
- [x] native/src/terrain_3d_collision.h
- [x] native/src/terrain_3d_data.cpp
- [x] native/src/terrain_3d_data_edit.cpp
- [x] native/src/terrain_3d_data.h
- [x] native/src/terrain_3d_data_maps.cpp
- [x] native/src/terrain_3d_data_regions.cpp
- [x] native/src/terrain_3d_editor.cpp
- [x] native/src/terrain_3d_editor.h
- [x] native/src/terrain_3d_editor_paint.cpp
- [x] native/src/terrain_3d_editor_texel.cpp
- [x] native/src/terrain_3d_editor_undo.cpp
- [x] native/src/terrain_3d_instancer.cpp
- [x] native/src/terrain_3d_instancer.h
- [x] native/src/terrain_3d_instancer_place.cpp
- [x] native/src/terrain_3d_instancer_transfer.cpp
- [x] native/src/terrain_3d_material.cpp
- [x] native/src/terrain_3d_material.h
- [x] native/src/terrain_3d_material_reflect.cpp
- [x] native/src/terrain_3d_material_resource.cpp
- [x] native/src/terrain_3d_material_shader.cpp
- [x] native/src/terrain_3d_mesh_asset.cpp
- [x] native/src/terrain_3d_mesh_asset.h
- [x] native/src/terrain_3d_mesher.cpp
- [x] native/src/terrain_3d_mesher.h
- [x] native/src/terrain_3d_monitors.cpp
- [x] native/src/terrain_3d_region.cpp
- [x] native/src/terrain_3d_region.h
- [x] native/src/terrain_3d_region_io.cpp
- [x] native/src/terrain_3d_region_surface.cpp
- [x] native/src/terrain_3d_sector_avt.cpp
- [x] native/src/terrain_3d_sector_avt_hierarchy.cpp
- [x] native/src/terrain_3d_sector_avt_internal.h
- [x] native/src/terrain_3d_sector_avt_motion.cpp
- [x] native/src/terrain_3d_streamer.cpp
- [x] native/src/terrain_3d_streamer.h
- [x] native/src/terrain_3d_surface_baker.cpp
- [x] native/src/terrain_3d_surface_baker_bundle.cpp
- [x] native/src/terrain_3d_surface_baker_frame.cpp
- [x] native/src/terrain_3d_surface_baker.h
- [x] native/src/terrain_3d_surface_baker_internal.h
- [x] native/src/terrain_3d_surface_baker_pipelines.cpp
- [x] native/src/terrain_3d_surface_baker_queue.cpp
- [x] native/src/terrain_3d_surface_baker_storage.cpp
- [x] native/src/terrain_3d_surface_source.cpp
- [x] native/src/terrain_3d_vt_service.cpp
- [x] native/src/terrain_3d_vt_service_bake.cpp
- [x] native/src/terrain_3d_vt_service_internal.h
- [x] native/src/terrain_3d_vt_service_pages.cpp
- [x] native/src/terrain_3d_vt_service_report.cpp
- [x] native/src/terrain_3d_texture_asset.cpp
- [x] native/src/terrain_3d_texture_asset.h
- [x] native/src/terrain_3d_util.cpp
- [x] native/src/terrain_3d_util.h
- [x] native/src/terrain_3d_virtual_texture.cpp
- [x] native/src/terrain_3d_virtual_texture.h
- [x] native/src/terrain_3d_virtual_texture_lookup.cpp
- [x] native/src/terrain_3d_virtual_texture_sector.cpp
- [x] native/src/terrain_3d_surface_views_near.cpp
- [x] native/src/terrain_3d_vt_demand.cpp
- [x] native/src/terrain_3d_vt_fade.cpp
- [x] native/src/terrain_3d_vt_feedback.cpp
- [x] native/src/terrain_3d_vt_feedback.h
- [x] native/src/terrain_3d_vt_indirection.cpp
- [x] native/src/terrain_3d_vt_indirection.h
- [x] native/src/terrain_3d_vt_page_pool.cpp
- [x] native/src/terrain_3d_vt_page_pool.h
- [x] native/src/terrain_3d_surface_views.cpp
- [x] native/src/terrain_3d_surface_views_internal.h
- [x] native/src/terrain_3d_surface_views_far.cpp
- [x] native/src/terrain_3d_vt_visibility.h
- [x] native/src/terrain_3d_wiring.cpp
- [x] native/src/terrain_surface_idweight.h
- [x] native/src/terrain_vt.h
- [x] native/audit_code.py
- [x] native/audit_gd.py
- [x] native/check_scripts.py
- [x] extras/particle_example/terrain_3D_particles.gd
- [x] menu/bake_lod_dialog.gd
- [x] menu/baker.gd
- [x] menu/channel_packer.gd
- [x] menu/channel_packer_dragdrop.gd
- [x] menu/directory_setup.gd
- [x] menu/terrain_menu.gd
- [x] src/asset_dock.gd
- [x] src/asset_dock_45.gd
- [x] src/asset_dock_common.gd
- [x] src/asset_dock_list_container.gd
- [x] src/asset_dock_list_entry.gd
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
- [x] src/ui_decal.gd
- [x] src/vt_editor.gd
- [x] src/vt_overview_image.gd
- [x] src/vt_terrain_bridge.gd
- [x] src/vt_world_overview.gd
- [x] tools/importer.gd
- [x] tools/region_mover.gd
- [x] utils/terrain_3d_objects.gd
- [x] utils/transform_changed_notifier.gd

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

Completed the tool settings, brush UI, VT window and optional lightweight/ocean shaders. A filesystem inventory also identified the following menu/object helpers outside the original native/src and src lists; all were read in full. This is the list that phase read, in the order it recorded them; the live inventory - which also covers everything read since, the split halves included - is the Reading Ledger at the top of this document.

- [x] extras/particle_example/terrain_3D_particles.gd
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
  definitions moved -- no logic changed -- into `terrain_3d_surface_views.cpp`,
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
  kept the widgets and the selection state; `vt_terrain_bridge.gd` owns the VT window's
  duck-typed native calls and `vt_overview_image.gd` owns the world/image maths and the
  per-pixel stitch as pure functions. Call sites were left alone -- the window keeps
  one-line delegations -- so the move could not change behaviour. Two other scripts
  (`terrain_vt_inspector.gd`, `editor_plugin.gd`) guard their own native calls instead;
  the architecture review now says so rather than claiming the bridge owns all of them.
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
  deleted earlier in this pass, and no definition appears twice. (The 1475-line remainder was
  split again later; see "The data class: 1,487 lines and four jobs" below.)
- **`terrain_3d_material.cpp` is two files.** The first 520 lines were the GLSL pipeline --
  loading the shader inserts (including the `shaders/*.glsl` files behind `DEBUG_ENABLED`),
  insert selection and exclusion, debug/editor code injection, comment stripping and the
  decision whether the generated shader needs VT samplers -- and the rest was the material
  resource: uniforms, noise/gradient textures, the property setters, save and bindings. The
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
  defined inline in `_operate_map()`, including the `IDWEIGHT_IMAGE_FORMAT` re-decode on write-back and the
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

## The surface baker: 2,798 lines and four jobs in one translation unit

`terrain_3d_surface_baker.cpp` was the largest file in the addon and held the largest definition in it
(`_request_encodes()`, 206 lines). Its six banners were already an honest statement of what it did, and
they were four jobs, not six: create and free GPU objects, decide what a page is stored in and run the
block encoder, take the caller's queued pages and upload them, and drive one frame. Only the last two
are ever changed for the same reason.

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_surface_baker.cpp` | 785 | The GPU objects: the `ResourceBundle`, the two shader sources, compile/adopt/free, and the growth path. |
| `terrain_3d_surface_baker_storage.cpp` | 740 | What a page is stored in — the codec resolver, the per-tier formats — the ring of in-flight encode pages, the block-encoder dispatches and the readbacks. |
| `terrain_3d_surface_baker_queue.cpp` | 467 | The caller-facing queue: budget, capacity, the material snapshot, `queue_page()`/`queue_cached_page()`/`queue_cell_page()` and the uploads that drain them. |
| `terrain_3d_surface_baker_frame.cpp` | 770 | `render_pending()`, the job list it builds, dispatch, bundle retirement, the read-only state and the bindings. |
| `terrain_3d_surface_baker_internal.h` | 175 | The prologue the four share. |

The cut is at the banners rather than at some tidier boundary because the banners were the file's own
claim about its sections, and because the four groups have no shared local state: each half reaches the
object through the class header and nothing else. The two exceptions are named in the internal header:

* The codec vocabulary (`GPU_CODEC_NONE`, `AtlasCodec`, `ATLAS_CODECS`, `PAGE_CODEC_ATLAS`,
  `page_codec()`) decides both what a tier may be stored in — the storage half — and what
  `get_stats()` reports — the frame half. A second copy would be a second vocabulary, and the two
  `static_assert`s that keep the page list inside the shared list are the reason it has to be one.
* `MATERIAL_COUNT`, `MATERIAL_STRIDE`, `JOB_STRIDE`, `IDWEIGHT_FORMAT_VALUE`, `RETIRE_FRAME_MARGIN`,
  `SurfaceVTLabel`, `append_uniform()`, `encode_vec4()` and `resolve_main_texture()` are each read by
  two or three halves. `RETIRE_FRAME_MARGIN` is the clearest case: the comment that explains it is
  about the queue's bundle lifetime, and the code that reads it is in the frame half.

Everything in the header is `inline`; the halves add `using namespace terrain_surface_baker;` so their
bodies read exactly as the single file they were, which is also what let the move be verified as a move
rather than reviewed as a rewrite. **Not one function body changed**: the only edits inside the moved
text are `static` → `inline` on the ten prologue definitions.

### How it was verified

* A migration script asserts all 29 slice boundaries by content before writing anything, asserts that
  the eight slices cover every line of the original but the three separator blanks, and keeps a backup
  (`bin/perf_probe/split_surface_baker.py`; `bin/` is gitignored).
* A second script asserts that each slice is present **byte-identical** in the file that should now hold
  it, prologue rewrites aside (`bin/perf_probe/verify_surface_baker_split.py`). This is the check that
  makes "it is a move" a fact rather than a claim: 696 lines into the GPU half, 706 into storage, 436
  into the queue half, 743 into the frame half.
* Build: `scons target=template_debug` with **zero warnings**, which matters here — an unused `inline`
  function in a header, or a helper left behind after its only caller moved, is exactly what /W4 says.
* Targeted: `vt_compression`, `vt_codec_colors`, `vt_cells` and `vt_demand` all PASS.
* The audit group is green on the new files: `dead`, `undefined`, `sections`, `params`, `dupes` (537
  definitions, none written twice), `indent`, `comments`.

### What the audit caught in the new code

`comments` reported two names the addon does not define — `_queue` and `_storage` — in the four new file
headers, because each one listed the other halves as `_queue.cpp` and `_frame.cpp` after spelling the
first name out in full. The tool was right: those are the identifiers a reader would grep for, and a
grep for `_queue` finds nothing. The repair replaced the shorthand with the full names, and then had to
be repaired itself: replacing `_storage.cpp` also rewrote the tail of
`terrain_3d_surface_baker_storage.cpp`, producing `terrain_3d_surface_bakerterrain_3d_surface_baker_storage.cpp`.
The line is now rebuilt whole from a table (`bin/perf_probe/repair_halves_line.py`) instead of by
substitution — a substitution that can nest inside its own output is not a substitution.

## The `indent` mode's second check, and the false positives that were the tool's

`audit_code.py indent` has two halves. The first finds runs of three or more lines at the wrong depth,
and it cannot see a whole body indented one level too deep: every line of such a body sits at
`expected + 1`, which is also where a wrapped continuation line sits, so the defect reads as a wrap.
The second half exists for exactly that case — it looks at the one line with a unique expected depth,
the body's first statement. It was added while fixing `_svt_walk_visible_pages()` and shipped as a
half-finished tool: it reported nine-odd files, and every report was a single-line body.

The mechanism was not "the check does not understand one-line bodies". It was an off-by-one that walks
into the next definition. `body_line` is the line after the one carrying `{`, so for
`int default_worker_count() { return default_page_workers(); }` it is the line after the function's
*last* line. The scan then skips blanks until it finds a statement, and the next statement it meets is
the *following* definition's column-0 signature — which is one level shallower than a body, so it is
reported. `terrain_3d_page_pipeline.cpp` reported "line 132, tabs=0, expected=1" and printed the
constructor's signature: line 132 is the next function.

Two skips fix it, and both are about what a body is:

* If the line carrying `{` has any code after it, the first statement shares that line. There is no line
  to measure, and it is a style choice, not a defect.
* A `}` is not a statement. An empty body written across two lines used to report its closing brace.

Verification, in three parts:

* The current tree reports `(none)` in both halves.
* A synthetic over-indented body is still caught. Adding one tab to the first statement of
  `Terrain3D::set_surface_vt_texels_per_meter()` reports `line 83 tabs=2 expected=1`, so the check was
  narrowed, not disabled.
* The real defect is reproduced. `git show 0e79973a49:…/terrain_3d_vt_demand.cpp` — the revision that
  introduced `_svt_walk_visible_pages()` before the dedent landed — reports `line 379 tabs=2 expected=1`.

The handover plan said to check this by feeding `git show HEAD:…` back through the tool and expecting
line 313. That recipe cannot work: by the time it was written the fix was already in `HEAD`, and the
line it named is a comment, which the run check cannot see because comments are blanked before it runs.
The revision to feed is the one that carried the defect, which is the commit *before* the dedent.

## A deleted line in the commit that only changed comments

`native/tests/vt_turn_budget.gd` had no `extends SceneTree`. The runners load these scripts with
`--script`, which runs the file as the main loop, so without that line Godot parses it as a
`RefCounted`: `root`, `process_frame` and `quit()` do not exist, and it refuses the whole file with
nine parse errors. The test that measures the per-phase budget — the one the 0.1 ms question is about —
has not run since `ae8be269b7`.

The commit's diff for that file shows how it happened. The author inserted an eighteen-line comment
block *over* the line:

```
 # most of the frame is the far field and a far-field miss cannot hide behind the near one.
-extends SceneTree
+#
+# What the wall-clock phase means can and cannot say, measured. Nine runs of this test on one
```

The comment is the valuable part of that commit and it is still true; the line under it was collateral
damage. The line is restored, in the same place: after the comment block, before the constants.

**How it was found, and how to find the next one.** The test reported a parse error, which no C++
change can produce, so the script was read instead of the build. The general form is worth keeping:
for a commit whose message says it only touched comments, list the lines it *removed* that are not
comments. `bin/perf_probe/removed_code_lines.py <rev> [paths]` does that (untracked, like the other
probes):

```
python bin/perf_probe/removed_code_lines.py ae8be269b7 misc/feng-addons/feng-idweight-terrain/native/tests misc/feng-addons/feng-idweight-terrain/src
  4 file(s), 20 code line(s) removed by ae8be269b7
```

Run over that commit's tests and scripts, the scan returns removed code lines in exactly four files:
`vt_turn_budget.gd` (the `extends`, restored), `vt_page_fade.gd` (five lines of a loop body, replaced
by the arrival-tracking rewrite in the same commit, which is deliberate and which passes),
`tool_settings.gd` (the `°`, `±` and `×` mojibake repairs) and one prose line of the audit tool's own
docstring. So the accident happened once, and this is the check that says so rather than the check that
hopes so.

## Fixes the file audits produced

Three files were read line by line by separate auditors with no shared context — `terrain_3d_material.cpp`,
`terrain_3d_surface_views.cpp` and `terrain_3d_instancer.cpp` — and every finding below was re-verified
here before it was applied. Two were rejected at that step.

* `terrain_3d_material.cpp`, `save()`: the failure log passed `ERROR` — the *log level* — where the
  save's `Error` belonged, so every failed save reported "Error code: 0". It is `int(err)` now.
* `terrain_3d_material.cpp`, `_update_vt_uniforms()`: `padded_blocks` is `resize()`d to `_max_regions`,
  which zero-fills, while the producer's own table fills every entry it does not write with
  `(-1, -1)` (see `_prepare_vt_block_tables()`). The comment claimed the padding was `(-1, -1)` and
  the code made it `(0, 0)` — which the shader's `block.x < 0.0` test reads as *block (0, 0)*: a real
  block, for a layer that has none. **The comment was the defect and the comment is what was fixed.**
  The fill was written, measured and reverted; see "The block table's padding" below, which the
  comment in the code now points at.
* `terrain_3d_material.cpp`, `_update_shader()`: the `List<PropertyInfo>` handed to
  `_get_property_list()` is never read — the call is there for its `_active_params` side effect — and
  the function dereferences the pointer it is given, so it cannot become `nullptr`. The local is named
  `discarded` and the comment says why it exists.
* `terrain_3d_material.cpp` header: "the ~70 property setters". The file defines 42 `set_*` methods and
  42 `ADD_PROPERTY` entries. The count is gone; a number in a header comment is a number that will be
  wrong.
* `terrain_3d_surface_views.cpp`, `_prepare_vt_block_tables()`: "Sectors are never unregistered" — the
  same file's `_retire_stale_vt_sectors()` calls `unregister_sector()`.
* `terrain_3d_surface_views.cpp`, `_collect_eligible_vt_regions()`: "Regions the far field may publish" —
  its only caller is `update_surface_vt()`, the near-field pass.
* `terrain_3d_surface_views.cpp`, the diagnostic far-field scan: "measures from the clipmap target rather
  than the camera" — it measures from `reference`, which *is* the camera whenever one is inside the
  tree, and the comment fourteen lines above says that measuring from the target is the bug being
  avoided.
* `terrain_3d_instancer.cpp`: "Set all LOD mmi AABB to match LOD0" — the code copies the *master* LOD,
  which is the shadow impostor for a shadows-only asset, where there is no LOD0. And in
  `update_transforms()`, "the bounds of brush size" — that function takes an `AABB`, and the brush
  wording is a leftover from the `remove_instances()` block it was copied from, which keeps that
  wording because it really does work on a brush.

**Rejected at verification.** `update_surface_svt()` (the far field's demand pass) was reported as
having a dead initializer
(`int mip = first_root;` immediately before a `for` that assigns `mip` before its first test). The loop
assigns `root_max_mip` in its *init* clause, so the initializer is unread only while the loop runs at
least once; when `root_max_mip < first_root` it is what keeps the `mip` read eight lines later defined.
It stays. This is the finding that justifies re-verifying all of them: "assigned and never read" and
"reachable" are different questions.

**Left open, deliberately.** The same three audits reported defects that are behaviour changes rather
than readability ones, and none of them is in this pass: a `_set()` NIL branch that clears a texture
parameter on `_material` but not on `_buffer_material` (`terrain_3d_material.cpp`), the buffer override
setters logging `_shader_override` (fixed since — the log was the defect and nothing else was),
an unguarded `get_mesh_asset()` dereference on a null `mesh_list` slot
(the three placement entry points in `terrain_3d_instancer_place.cpp`). Three entries have left this list,
each in the round that wrote a test for it: the instancer's teardown walked the data's regions ("An
instance that outlives its region"), the instance counter could not follow a setting that moved the master
LOD ("The count that described the wrong LOD"), and `set_surface_svt_root_mips()` rebuilt the shared pool
for a demand-side setting ("A demand setting that rebuilt the pool").
Added by the script half: `menu/channel_packer.gd`'s
`last_opened_directory` is read once and assigned nowhere, so the only thing its one use can do is reset
the open dialog's path; the luminance-to-height branch there reports `"Height Texture Generation error"`
and then falls through to the same success message it prints when the conversion worked (a missing
`return`); and `menu/baker.gd`'s `_bake_mesh()` and `_bake_occluder()` share a ~20-line
"get-or-create the child node, then register a resource-swap undo action" pattern whose two copies differ
only in the node type, the property name and how the resource is built. Added by the `tools/` and
`utils/` reading: `region_mover.gd` prints a variable it has just cleared and returns without restoring
`data_directory`, and its mid-pass bounds abort leaves earlier files named `tmp_terrain3d_*.res`;
`importer.gd`'s `start_import()` dereferences `assets` and `material`, which its own `reset_settings()`
nulls; `terrain_3d_objects.gd` uses `_undo_redo` before `editor_setup()` has necessarily run, and
`get_terrain()` dereferences a possibly-null edited scene root. Added by the material split:
`_get_property_list()` and `save()`
assemble overlapping parameter lists by *different* rules — the inspector's list requires
`_shader_override_enabled` and *replaces* the default shader's parameters with the override's, while
`save()` ignores the flag and *appends* a valid override's parameters to the default ones. Two
consumers of one override disagree about what it contributes. Each needs a test that can see it before
it is touched; they are recorded here so the next pass starts from them rather than from a cold read.
Line numbers are gone from this list on purpose: the splits move them every round, and a stale number
is a lie of the kind this pass exists to remove.

## The full suite on this machine

54 tests, driver vulkan, one run: **40 pass, 14 fail**.

| failing | note |
| --- | --- |
| `vt_adaptive`: scale, metric, ownership, filtering, navigation, blend, sectors | The seven the handover plan already records as red on the previous machine, all in the adaptive/ownership cluster. |
| `editor_dock:setup` | Recorded as permanently red in that plan's known-fail list. |
| `vt_turn_budget` | The parse error above, not a budget result. Restored, then re-run on its own. |
| `vt_compression` | The plan's documented flake (`a replaced page array must be released`). |
| `vt_visibility`, `vt_material`, `vt_render` | In the previous machine's red set as recorded in the handover plan, though not in the list it repeats in its own §2.3. Re-run on their own and reproduced. |
| `vt_recovery` | Not in either red set. Passed when re-run on its own. |

Two of the plan's documented failures pass here (`vt_format`), so the red set is not portable between
machines and the previous machine's 41/54 cannot be used as this machine's baseline. The suite ran
against the build made from the baker split and *before* the fixes above, which is what rules the
`padded_blocks` change out as a cause of any of them.

### Re-running the reds

Each failing test was run again on its own, against the build that carries this round's fixes:

| test | re-run |
| --- | --- |
| `vt_turn_budget` | **pass**, 16.0 s — the first run of it since `ae8be269b7` |
| `vt_recovery` | **pass**, 10.1 s |
| `vt_compression` | fail, the plan's documented flake |
| `vt_material` | fail, same assertion (`stationary AVT does not rebake unchanged pages`) |
| `vt_render` | fail, same assertion (`disabling the virtual texture should restore the array path`) |
| `vt_visibility` | fail, the same three assertions |

So the deterministic red set here is the previous machine's set minus `vt_format` — eleven tests, none
of them in the surface baker and none of them touched by this pass. Nothing this round added a failure.

### What the budget test says now

With the script loadable again, `vt_turn_budget` passes on this machine, and its report is the first
measurement of the phase budgets since the test broke. Means in ms, against the 0.10 ms budget the test
asserts on:

| sweep | service | **avt** | **svt** | topup_or_bake | fade |
| --- | --- | --- | --- | --- | --- |
| warm, 6°/frame | 0.0075 | **0.0750** | **0.0326** | 0.0002 | 0.0160 |
| slow, 1.5°/frame | 0.0080 | **0.0751** | **0.0327** | 0.0002 | 0.0122 |
| far field only | 0.0079 | **0.0010** | **0.0406** | 0.0002 | 0.0007 |
| cold, pool rebuilt | 0.0071 | **0.0650** | **0.0336** | 0.0003 | 0.0135 |

Every phase the user named is under the budget on the mean, in every sweep. `topup` is the removed
phase and reads 0.0002–0.0003 ms, which is the far-field bake residue the test prints together with it
— it cannot be over any budget. The peaks are another matter and are unchanged: the AVT peak is
0.269–0.315 ms while its mean is 0.065–0.075, which is the shape the handover plan already describes
(a phase is wall time on one thread, so one descheduling stall in sixty frames is worth tens of
microseconds of the mean). The warm sweep's paint bands are all zero — no magenta fragments at all —
and the cold sweep's first frame is `near 6, far 9` out of 15 samples, both recorded rather than
asserted.

## The service file: 1,634 lines and five jobs in one translation unit

`terrain_3d_vt_service.cpp` was, by its own admission in its header, "the oldest of the VT files and
the largest" — and it listed its five groups in that header: the settings, the service's setup and
teardown, the page plumbing, the far field's bake and the diagnostics. That list is the cut:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_vt_service.cpp` | 573 | The settings and the service's lifetime: page size, border, count, workers, the motion lead, the resolution preset, both tiers' storage format, the feedback toggles, the editor preview; `_configure_vt_service()` / `_vt_has_pending_upload()` / `_vt_has_streaming_work()` / `_update_vt_service()` / `_destroy_vt_service()`; and the bindings. |
| `terrain_3d_vt_service_pages.cpp` | 501 | Page plumbing: invalidation of a slot, a region or every material, the material page queue, the resident far-field cell store, and the two helpers that decide whether a far page can be assembled from cells. |
| `terrain_3d_vt_service_report.cpp` | 237 | The diagnostics: `get_vt_settings()`, `get_vt_pages()`, the page and material previews, and the compression probe. Read-only. |
| `terrain_3d_vt_service_bake.cpp` | 376 | The far field's bake and its cell files: `bake_svt()`, the automatic pass, the bake queue, the `.vtcell` signature and reader, and the browser of what is baked. |
| `terrain_3d_vt_service_internal.h` | 61 | The two helpers the four share. |

Unlike the surface baker's split, this one is **not** four contiguous slices. `_destroy_vt_service()`
was filed between the cell store and the invalidation helpers and belongs with the service's lifetime;
`_cancel_svt_bake()` and the codec probe sat among the settings and belong to the bake and the
diagnostics. So the migration assembles each file from a list of ranges — sixteen blocks across five
outputs — and its gate is a set equality rather than a range check: every non-blank line of the
original must be assigned to exactly one block, and the only unassigned lines may be the three blanks
that separated the blocks and the two lines of the anonymous namespace that the internal header
replaces. That is a stronger statement than "the files add up to the same length", because a duplicated
block would break it.

### What the compiler caught, twice

Two things the baker's split did not have to face:

* **`terrain_vt_cell.h` was needed by a half the original include list did not have to name.**
  `_svt_page_path()` builds a `.vtcell` file name from `TerrainVTCell`, and it moved to the pages half
  while the include went to the bake half. The build said so in one line (C2653) and the include moved
  to both.
* **An anonymous namespace carries internal linkage with no keyword to convert.** The baker's prologue
  was `static`, so `static` → `inline` was the whole conversion. Here `baker()` and
  `bake_source_grid()` were inside `namespace { }`: moving them into a named namespace in a header gave
  them external linkage, and the link failed with `LNK2005` for both symbols across all four objects.
  They are `inline` now, and the rule in `docs/vt_architecture_review.md` says so, because the next
  person to move a helper out of an anonymous namespace will hit exactly this.

`<cstring>` was in the original include list and **nothing in the file used it** — no `memcpy`,
`memcmp`, `memset`, `strlen`, `strcmp` or any other `<cstring>` name appears in 1,634 lines. It is
carried into none of the halves.

### How it was verified

* The migration asserts all sixteen block boundaries by content and the set-equality gate above
  (`bin/perf_probe/split_surface_vt.py`, idempotent: it re-reads its own backup).
* `--verify` reads the backup and asserts every block is present **byte-identical** in the file that
  should hold it — all sixteen, so the non-contiguous move is a move and not a retype.
* Build: `template_debug`, zero warnings.
* Targeted: `vt_auto_bake`, `vt_cells`, `vt_monitors` and `vt_sparse` pass (one per new half plus the
  service); `vt_compression` fails as its documented flake.

## The block table's padding: a comment defect that is not a code defect

`_update_vt_uniforms()` pads `_surface_vt_blocks` to `_max_regions` with a bare `resize()`. The
comment said the padding was `(-1, -1)`, "the state while the virtual texture is disabled". Both halves
of that are wrong: `resize()` zero-fills, and the shader does not read the table at all while the
virtual texture is off (`main.glsl:270` tests `_surface_vt_enabled` first). What *is* true, and worth
knowing, is that `(0, 0)` fails the shader's no-block test (`block.x < 0.0`) and passes its valid-block
test (`block.x >= 0`), and that `_max_regions` — a material setting clamped to 64..1024 — is
independent of the map capacity that sizes the producer's table, so the two lengths can differ and the
tail is reachable.

The obvious fix is one line, `padded_blocks.fill(Vector2(-1.f, -1.f))` before the copy. It was written
and then reverted, for two reasons:

* **No test fails without it.** The suite's VT tests pass on the padding as it is, and a change that
  no test can see is a change that no test can protect.
* **The one measurement there is pointed the other way.** `vt_format` is flaky on this machine (see
  below). Five runs with the fill: 2 pass, 3 fail. Five runs immediately after removing it: 4 pass,
  1 fail. Six more without it: 4 pass, 2 fail — 8 of 11 with the fill absent against 2 of 5 with it
  present. Both samples are far too small to conclude anything, which is the point: an unmeasured
  behaviour change was traded for a flake whose rate nobody had established.

So the code keeps its `(0, 0)` padding and the comment now says what the code does, what the shader
does with it, when it is reachable, and where the one measurement is. That is the honest form of the
finding the audit produced: the *comment* was the defect.

## The uniform-set flake, and the tests it hits here

`vt_format` passes and fails on the same binary, alternating within one session, with one engine line
either way:

    ERROR: Uniforms were never supplied for set (3) at the time of drawing, which are required by the pipeline.

and its own assertion passing in both cases (`PASS virtual texture format change keeps the page pool`).
The runner counts any `ERROR:` line as a failure, so the test reports fail. Observed rates on this
machine: 2/5 with a block-table fill in the uniform, 8/11 without it, and the sequence is
pass-fail-pass-fail rather than a warm-up effect.

This is the same family as the flake the handover plan records for `vt_compression`
(`a replaced page array must be released`) and the class the producer's own `_retired` /
`_acknowledged_generation` machinery exists for: a format change rebuilds the arrays, and a draw
prepared with the previous pair reports a missing uniform set once. It is a rendering-timing flake,
not a logic failure, and it was in the previous machine's red set as a hard failure (`vt_format` is one
of the thirteen the handover plan lists) — which is worth knowing when reading that list, because here
it is a coin flip rather than a defect.

**It has a second victim here.** `vt_compressed_render` failed in the suite with the same engine line
and its own assertion passing (`PASS compressed material pages render an ...`), and passed on a re-run
19.4 s later. So the line is a property of the engine's material/uniform-set update path under a page
array rebuild, and any test that changes a format or a compression tier can be hit by it. When one of
those two is red, read the assertion lines before the `ERROR:` line.

**And more than two.** The next suite run produced the same engine line in `vt_compression`, whose
documented flake is a *different* message (`a replaced page array must be released`) — that test
changes a tier's codec, which is the same rebuild. The same run had `vt_recovery` red on its own
assertion (`the repaired view must report no missing page (codec 1, got 1)`, where earlier runs read
codec 0), so that one is state-dependent rather than part of this family. Four tests have now been
seen to flake on this machine, and the only reliable reading of a red one is its assertion lines.

### The suite after the service split

54 tests, driver vulkan, one run on the build that carries the service split: **42 pass, 12 fail**,
against 40/54 before it. The two that moved are not the split's doing:

| | |
| --- | --- |
| passing now | `vt_compression` (its documented flake), `vt_format` and `vt_recovery` (both state-dependent, see above). |
| failing now | the same eleven as before — seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`, `vt_visibility` — plus `vt_compressed_render`, which is the uniform-set flake above and passes on a re-run. |

So the split added no failure and the count moved by three flakes landing differently. Every VT test
that exercises a new half passes: `vt_auto_bake` (bake), `vt_cells` (cell store), `vt_monitors`
(diagnostics), `vt_sparse`, `vt_pressure`, `vt_page_fade`, `vt_turn_budget`.

## The data class: 1,487 lines and four jobs

`terrain_3d_data.cpp` was the largest file left after the service split, and its own header already
listed what was in it: the slot allocator and the region directory, the map arrays and their GPU
synchronization, region lifecycle, painting, the height/normal/texture queries and the ClassDB
bindings. Those are four jobs, not six:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_data.cpp` | 483 | The stable layer slots (`_grow_slot_capacity()`, `_acquire_slot()`, `_release_slot()`), the chunk -> layer directory texture, the blank layer per map type, and the slot-map upload and dirty tracking. |
| `terrain_3d_data_regions.cpp` | 345 | Region lifecycle and the region table: `add_region*()`, `remove_region*()`, `unload_region()`, `change_region_size()`, `change_surface_density()`, the modified/deleted flags and `do_for_regions()`. It never writes a slot index; it goes through the allocator above. |
| `terrain_3d_data_maps.cpp` | 478 | The map arrays, `update_maps()` and its mipmap pass, `update_surface_region()`, and the read side: `set_pixel()`, `get_pixel_descaled()`, the height, normal, blend, slope and texture-id queries, and the mesh-vertex decimation they feed. |
| `terrain_3d_data_edit.cpp` | 218 | `add_edited_area()`, `calc_height_range()` and the master height range, `dump()`, and `_bind_methods()`. |

This is the only one of the three splits that needed no internal header. The file has no file-scope
function at all — not a `static`, not an anonymous namespace — only `Terrain3DData` members, which
every half reaches through `terrain_3d_data.h`. It is also the only one whose blocks are contiguous
and in file order, so the migration is four slices rather than a partition.

### The include block that was mostly dead

The family declared a house rule in every one of its headers — "every file carries the same include
block so each one compiles and reads on its own" — and in this file that block was largely unused:
`DirAccess`, `EditorFileSystem`, `EditorInterface`, `FileAccess`, `ResourceSaver`, `Engine`,
`terrain_surface_idweight.h` and `<unordered_map>` appear nowhere in its 1,487 lines. Each of the four
halves now includes what it uses, the two siblings were trimmed to match, and the rule is gone from
all five files, whose headers now say what they include and why.

**Two of the removals were wrong, and the compiler is what said so.** Both are lessons about how an
include can be load-bearing:

* `terrain_3d_data_surface.cpp` needs `terrain_vt.h` for `TerrainVT::log2_power_of_two()`. It used to
  compile because the shared block reached it transitively — an include that a *different* header
  happened to pull in.
* `terrain_3d_data_io.cpp` needs `engine.hpp`, and not for any use of `Engine`: a grep for the type
  confirms there is none. It is needed for the addon's own `IS_EDITOR` macro (in `constants.h`), which
  expands to `Engine::get_singleton()->is_editor_hint()`. **No grep for a type name can find a macro
  dependency.** This is the second time in this pass that an include turned out to be load-bearing for
  something other than the name it carries — the first was `terrain_vt_cell.h` in the service split —
  so the rule is: trim by grep, then trust only the build.

Net: 8 includes dropped from the data half, 5 from the surface half and 3 from the io half; 2 put back
as the direct dependency they always were; all five headers rewritten.

### How it was verified

* `bin/perf_probe/split_data.py` asserts the four boundaries and that every non-blank line is assigned
  once, and `--verify` asserts each block is **byte-identical** in the file that holds it.
* Build: `template_debug` zero warnings (after the two include fixes above).
* Targeted: `region_slots` (the slot allocator), `region_streaming` (region lifecycle), `editor_paint`
  and `texture_layers` (the map arrays and `set_pixel`), `texture_compression` (the io half with the
  trimmed includes) and `vt_cells` (the resampler) — all pass.
* Full suite: **41 pass, 13 fail**, against 42/54 after the service split and 40/54 before it. The
  deterministic red set is unchanged — seven `vt_adaptive`, `editor_dock:setup`, `vt_material`,
  `vt_render`, `vt_visibility` — and the two extra are flakes from the section above
  (`vt_compression` and `vt_recovery` in this run, `vt_compressed_render` in the one before). Nothing
  in this split added a failure.

## The instancer: 1,395 lines and three jobs

`terrain_3d_instancer.cpp` was the largest file left, and what was in it is not one thing:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_instancer.cpp` | 741 | The MMI table: `_queued_updates`, `_process_updates()`, `_update_mmi_by_region()` and the per-cell create / configure / destroy pair, plus the lifetime entry points (`initialize()`, `destroy()`, `clear_by_*()`, `set_mode()`), `update_mmis()` and `_release_orphaned_regions()`. Every MMI and MultiMesh RID in the addon lives in `_mmi_rids`, and this half owns all of it - which is why every teardown path walks that map rather than the data's regions. |
| `terrain_3d_instancer_place.cpp` | 649 | The placement data API: `add_instances()`, `remove_instances()`, `add_multimesh()`, `add_transforms()`, `append_location()`, `append_region()`, `update_transforms()` and `get_closest_mesh_id()`. It writes a region's `mesh_id -> cell -> [transforms, colours, modified]` dictionary and *queues* the MMI work rather than doing it. |
| `terrain_3d_instancer_transfer.cpp` | 128 | The two transfers that move that dictionary around: `copy_paste_dfr()` (the editor's copy/paste) and `swap_ids()` (mesh-id reindexing). Both leave the MMI table stale, and both document that the caller must `update_mmis()` afterwards. |

`_get_cell()` and `_get_usable_height()` went with the placement half because it is the only half that
calls them; `_backup_region()` stayed with the table it backs up. The blocks are not contiguous -
`update_mmis()` sits seven hundred lines from `_process_updates()`, which is why this is a partition
and not a set of slices - so the gate is the same set equality the service split used: every non-blank
line assigned exactly once, and `--verify` proving each block byte-identical in the file that holds it.
`<godot_cpp/classes/resource_saver.hpp>` was in the original include list and nothing used it;
`world3d.hpp` went to the table half alone (`_terrain->get_world_3d()->get_scenario()`) and
`terrain_3d_util.h` to the placement half alone (`v2iv3()`).

## A sentinel that nothing queues

The instancer's update queue has a documented vocabulary in `terrain_3d_instancer.h`:

```
// <V2I_MAX, -2> means destroy first, then update everything
// <V2I_MAX, -1> means update everything
// <reg_loc, -1> means update all meshes in that region
// <V2I_MAX, N> means update mesh ID N in all regions
```

`(V2I_MAX, -1)` is written **nowhere in the addon**. `_queued_updates` is private, and both of its
writers are in `update_mmis()`: `emplace(V2I_MAX, -2)` for a rebuild, and
`emplace(p_region_loc, mesh_id)` with the id clamped to `[-1, MAX_MESHES - 1]` otherwise. So the second
line of that comment described a state no caller could produce, and three pieces of code existed to
handle it:

* the `else if` branch in `_process_updates()` that set `update_all` from it — unreachable, because a
  set containing the pair is consumed and returns six lines earlier;
* the `find({ V2I_MAX, -1 })` early-out in `update_mmis()` — always false;
* the first half of the disjunction that skips queued pairs,
  `queued_loc == V2I_MAX && queued_mesh < 0` — unreachable for the same reason.

All three are gone, and the comment's second line with them. What survives is
`queued_mesh >= mesh_count`, the real skip: a mesh deleted after its update was queued.

This is the strongest kind of finding this pass can produce. It is not "assigned and never read",
which a single A/B run can overturn, but **written nowhere**, and the proof is the complete reference
list: one declaration, six reads and two writes, every one of them in the file that was being read.

### How it was verified

* Greps over every `.cpp` and `.h`: `_queued_updates` (the list above) and `V2I_MAX, -1` (three
  references, all reads).
* The deletion was built and tested **before** the split, so a red test could not be blamed on the
  wrong change: `vt_adaptive:instancer`, `region_slots`, `region_streaming`, `editor_paint` and
  `vt_density` all pass with it, and both templates build with zero warnings.
* The split was then verified on its own: `--verify` byte-identical blocks, then the same targeted
  set again, then the full suite: **41 pass, 13 fail** — the same count and the same deterministic red
  set as the run before the split (seven `vt_adaptive`, `editor_dock:setup`, `vt_material`,
  `vt_render`, `vt_visibility`), with the two extras again being the flakes above
  (`vt_compressed_render` and `vt_recovery` in this run). Neither the deletion nor the split moved a
  single test.
* The audit group caught one thing in the new prose: the file header wrote `_destroy_mmi_by_*()`, and
  `comments` was right that `_destroy_mmi_by_` is not an identifier — the three teardown paths are now
  spelled out. A wildcard in a comment is a name a reader cannot grep.

## The service file: three entry points, and code for a state nothing produces

`terrain_3d_surface_views.cpp` was the second-largest file left, and its own header said what was in it:
"the two views' enable setters and their page settings, the two demand passes with all their stages,
and the feedback pass". Three jobs:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_surface_views.cpp` | 351 | Both views' setup and teardown, and every setting the dock, the inspector and scripts write, plus `invalidate_surface_pages()`. |
| `terrain_3d_surface_views_far.cpp` | 331 | The far field's demand pass, in both of its modes, with the distance -> level rule it walks. |
| `terrain_3d_surface_views_near.cpp` | 512 | The near field's pass, its GPU projection feedback pass, the camera-visible region query and the whole sector machinery. |
| `terrain_3d_surface_views_internal.h` | 30 | `SourceWakeFlush`, the one prologue symbol two halves need. |

The first layout put `get_surface_vt_region_rect()` with the settings, and the link failed: it calls
`terrain_region_in_frustum()`, which is a file-scope `static` and therefore belongs to the one
translation unit that calls it — the AVT half. Both moved there. This is the second time in this pass
that the compiler, not the plan, decided where a helper lives (the first was `terrain_vt_cell.h`),
and the third time an internal header was needed for exactly one symbol.

### Seventeen includes that outlived their code

The file carried twenty includes. Each half now starts with three — `terrain_3d.h`, `logger.h` and
`terrain_3d_surface_views_internal.h` — and the build added nothing back, which is the proof that the
other seventeen were dispensable. Fifteen of them were engine headers:

    compositor  directional_light3d  editor_interface  engine  environment  label3d  os
    physics_direct_space_state3d  physics_ray_query_parameters3d  project_settings
    quad_mesh  shader_material  surface_tool  viewport_texture  world3d

None has a case-sensitive use anywhere in the 1,178 lines. The feedback pass used to build its own
quad, depth texture and projection; it now hands every one of those to `Terrain3DVTFeedback`, which
owns them in its own file, and the includes stayed behind. `terrain_3d_util.h` and
`terrain_3d_vt_visibility.h` went the same way, and the second is worth naming: the file defines its
own `terrain_region_in_frustum()`, so the header whose name suggests it would be needed was not.

Two traps were checked by name before the trim, because this pass has been caught by both: no macro
from a removed header is used (the data split's `IS_EDITOR`/`engine.hpp` case), and no type from one is
named without its header (the service split's `TerrainVT::log2_power_of_two`/`terrain_vt.h` case). The
build agreeing is what makes the claim.

### Three pieces of code for a state nothing produces

`update_surface_svt()` has two modes. With the material pipeline on it returns at its fourth statement
and hands its pages to `_update_visible_svt()`; the scan below that point runs **only** when
`vt_debug_direct_material` is set. In that mode, three things were dead:

* The two `_queue_vt_material_page(...)` calls inside the scan. That function's own first statement is
  `if (_vt.vt_debug_direct_material || !producer || ...) { return; }`, so both calls could not do
  anything — and each passed a `Ref<Image> page` declared two lines above it and never filled.
* The `_vt.vt_debug_direct_material &&` conjunct on both `_write_diagnostic_sparse_page()` guards: the
  mode is already known true there, 150 lines after the early return.
* Four locals that existed only to feed those calls (`page`, and the `span`/`address` pair each call
  built its rectangle from). `address` survives at the first site, where the failure path releases the
  page through it.

What is left is the check that matters: `if (!_write_diagnostic_sparse_page(...)) { release; continue; }`
in both places, which is the whole point of the diagnostic mode — nothing else can fill those slots.

The helper's *own* mode guard (`_write_diagnostic_sparse_page()` line 2) stays. A precondition at a
function's boundary is not the same as a condition the caller has already established, and deleting it
would make the helper's contract depend on where it happens to be called from today.

### One duplicate removed, one left on purpose

`struct FlushWakes` was declared identically at the top of both demand passes. It is now
`SourceWakeFlush` at file scope, in the internal header: one definition, both passes, and the reason
the two have to agree is written next to it. It sits in an **anonymous namespace** there, unlike the
two earlier internal headers whose symbols a half calls by name from a named namespace — that keeps
each unit's copy internal, exactly as the local struct it replaces was, and leaves both call sites
byte-identical.

The six page setters (`set_surface_{svt,vt}_page_{size,border,count}`) are near-identical and were
**left alone**. Unifying them needs an enum and a switch over three different setter names, because
the view's method differs with the setting: `set_page_size` / `set_page_border` / `set_page_count`.
That trades thirty lines of obvious repetition for a level of indirection and a switch a reader has to
follow. The duplication is real and recorded here rather than silently traded for cleverness.

### How it was verified

* `bin/perf_probe/split_vtsvc.py` asserts the six ranges, that every non-blank line is assigned once
  bar five separators, and `--verify` proves all three blocks byte-identical in their files.
* The deletions were verified *before* the split: `_queue_vt_material_page` still has six callers in
  other files, so the function is not dead; build clean; and `vt_svt_coverage`, `vt_page_fade`,
  `vt_demand`, `vt_monitors` and `vt_turn_budget` pass, with `vt_pressure` doing its documented
  fail-once-pass-once.
* After the split: build clean (zero warnings), audit group green, and `vt_demand`, `vt_svt_coverage`,
  `vt_page_fade`, `vt_monitors`, `vt_root_coverage` and `vt_density` all pass.
* Full suite: **42 pass, 12 fail**. The deterministic red set is the same eleven as every run since the
  service split — seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`,
  `vt_visibility` — plus `vt_recovery`, which is state-dependent and has now been seen on both sides.
  `vt_compression`, `vt_format` and `vt_compressed_render` (the three known flakes) all passed here.
  Neither the deletions nor the split added a failure.

## The material: 1,181 lines and three jobs in one translation unit

`terrain_3d_material.cpp` was the largest file left in the addon, and its own header named its jobs: the
property setters, the shader and its uniforms, and the property list the inspector reads. Three, with
the GLSL assembly already in its own file:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_material.cpp` | 409 | The shader and the uniforms it is filled with: `_update_shader()` with the noise and gradient textures it builds, and the three uniform passes. |
| `terrain_3d_material_resource.cpp` | 432 | The lifecycle (`initialize()`, `uninitialize()`, `destroy()`, `update()`), the setters with their getters, and `save()`. |
| `terrain_3d_material_reflect.cpp` | 384 | `_get_property_list()`, the revert hooks, `_set`/`_get` and `_bind_methods()`. |
| `terrain_3d_material_shader.cpp` | 548 | Unchanged by the split and now the fourth: the GLSL assembly (insert loading, editor/debug injection, comment stripping, `_needs_vt_shader`). |

The three ranges are 27-411, 412-822 and 823-1181 - contiguous, and the first split in this pass that
partitioned its file end to end with nothing interleaved.

### The shared include block, and the four headers in it nobody used

The family's old house rule was that every file carries the same include block "so each compiles and
reads on its own". The 1,181-line file's block carried `<godot_cpp/classes/engine.hpp>`,
`image_texture.hpp`, `reg_ex.hpp` and `reg_ex_match.hpp`, and case-sensitive counting finds **zero** of
the four anywhere in it: `Engine` 0, `ImageTexture` 0, `RegEx` 0, `RegExMatch` 0. (`FastNoiseLite` 5,
`Gradient` 1, `NoiseTexture2D` 1, `RenderingServer` 1, `ResourceSaver` 2 and `Terrain3DVirtualTexture` 2
are real uses and stayed.) `RegEx` and `RegExMatch` belong to the shader sibling, which uses them four
and one times; `Engine` and `ImageTexture` belong to nobody in this family.

Each of the four files now includes what it uses, and the build added nothing back - which is the proof.
The shader sibling's own trim is the same test: nine headers dropped, and the only textual occurrences
of any of them left in the file are in the comment that records the trim.

The rule survives as a rule: an include can be load-bearing for something other than a type name. This
pass has been caught twice by a macro (`IS_EDITOR` in `constants.h` needs `engine.hpp`) and once by a
transitively-provided type (`TerrainVT::log2_power_of_two` needs `terrain_vt.h`), so every candidate was
grep'd case-sensitively and then the build was trusted over the grep.

### Two consumers of one override flag that disagree

`_get_property_list()` and `save()` assemble overlapping parameter lists by **different** rules, and
neither file said so:

* `_get_property_list()` requires `_shader_override_enabled` and, when the override is valid,
  **replaces** the default shader's parameters with the override's. It drops private `_`-prefixed
  uniforms, de-duplicates the displacement buffer's entries and rebuilds `_active_params`, which is the
  set of names `_set`/`_get` will accept.
* `save()` ignores the flag and **appends** a valid override's parameters to the default ones, skipping
  a name only when it no longer names a real uniform.

So with the flag off the inspector shows no override parameters while a save writes them; with the flag
on the inspector shows *only* the override's, while the save writes both. The two are recorded here and
in `terrain_3d_material_reflect.cpp`'s header rather than changed: choosing one rule is a behaviour
decision for the owner, and no test in `native/tests` can see the difference today.

### How it was verified

* `bin/perf_probe/split_material.py` asserts each range starts on the access banner and ends on `}`,
  that the three ranges plus the 26-line prologue cover all 1,181 lines with none twice, and `--verify`
  proves each block byte-identical in its file.
* Debug and Release builds clean, zero warnings; the eight code audits green, including `comments`
  (which is what caught two pieces of the new prose naming identifiers the addon does not define).
* Targeted: `editor_dock:slider`, `editor_dock:svt_inspector`, `vt_monitors`, `texture_layers`,
  `vt_codec_colors` and `vt_format` all pass.
* Full suite: **40 pass, 14 fail**, against **42 pass, 12 fail** for the run before the split. The
  difference is entirely the documented flakes. The deterministic red set is the same eleven in both
  runs - seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`, `vt_visibility` - and the
  two runs swapped `vt_recovery` for `vt_compression` + `vt_format` + `vt_pressure`. Neither number is
  evidence about the split beyond "no new failure", which is the whole claim.

## The editor: 1,147 lines and four jobs in one translation unit

`terrain_3d_editor.cpp` was the last file over a thousand lines in the addon. Four jobs:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_editor.cpp` | 340 | The object's state and public API: the brush dictionary `set_brush_data()` sanitizes, `set_tool()` / `set_operation()`, the start -> operate -> stop sequence one stroke is bracketed by, the region tool (`_operate_region()`, `_send_region_aabb()`) and `_bind_methods()`. |
| `terrain_3d_editor_paint.cpp` | 309 | The map brush loop: `_operate_map()`, everything after it in `_finish_map_operation()`, and `_sample_brush_mask()`, whose only caller the loop is. |
| `terrain_3d_editor_texel.cpp` | 415 | One brush texel: the three `_paint_*_texel()` handlers, the R16 surface path (`SurfaceByteCache`, `_paint_surface_pair()`) and the two `_average*()` neighbourhood samples. |
| `terrain_3d_editor_undo.cpp` | 174 | `_store_undo()` and `_apply_undo()`: the two dictionaries the plugin's UndoRedo holds and the restore path that runs from its callables. |

The two `_average*()` functions sat under the file's "Private Functions" banner next to functions they
have nothing to do with; their only callers are the height and color texel handlers, so they moved with
them. `_send_region_aabb()` went the other way: `_apply_undo()` needs it, but so does every region
change, so it stays with the region tool.

### The invariant the split script asserts

Every definition in the file is declared in `terrain_3d_editor.h`, and the script proves each landed in
exactly one of the four files: it matches every definition head, asserts there are 23 of them, asserts
none appears in two halves, and asserts each name is declared in the header. Four files' worth of moving
is exactly the situation where a reader otherwise has to check that by eye, and a class method that
landed in two files would link and only fail at runtime.

### Includes: one header out of all four, two into one each

The original block carried `<godot_cpp/classes/engine.hpp>` and `terrain_surface_idweight.h`.
`Engine` and `IS_EDITOR` occur **zero** times in the 1,147 lines, so `engine.hpp` is gone from all four.
`TerrainSurfaceIdWeight` occurs three times and `Callable` twice, so the surface-format header went to
the texel half and `callable.hpp` to the undo half, where they are used. `<godot_cpp/classes/time.hpp>`
stayed in the two halves that call `Time::get_singleton()` (three call sites in total, two files).

The split also fixed a formatting defect for free: in the original, `_operate_map()`'s closing brace at
line 352 was immediately followed by `_paint_height_texel()`'s signature at line 353 with no blank line
between them. Joining blocks with one blank line removed the only place in the file where two
definitions touched.

### How it was verified

* `bin/perf_probe/split_editor.py` asserts all 23 boundaries by content, that the lines no block claims
  are exactly the copyright header, the include block and 23 blank separators, the
  23-definitions-in-one-file-and-in-the-header invariant above, and `--verify` proves every block
  byte-identical in the file that should hold it.
* Debug and Release builds clean, zero warnings; all eight code audits green (`dead`, `undefined`,
  `sections`, `comments`, `params`, `dupes`, `indent`, `shape`).
* Targeted, all pass: `editor_paint` (its own assertion is that it drives *every* tool through
  `_operate_map`), `editor_dock:input` (live array painting and the brush's GPU miss -> CPU fallback ->
  R16 ID round trip), `editor_dock:grid` (region creation, cancellation, limits), `editor_dock:pairroles`
  (the IdWeight pair fields), `vt_surface`, `region_slots` and `vt_adaptive:instancer`.
* Full suite: **40 pass, 14 fail** - the same eleven deterministic failures as the two runs before it,
  plus `vt_compressed_render`, `vt_format` and `vt_pressure`, all three documented flakes.

## One format, three names

The IdWeight payload is stored in a 16-bit unsigned normalized channel: Godot's `Image::FORMAT_R16`,
value 39. That one format was spelled three ways across ten files.

| spelling | where | sites |
| --- | --- | --- |
| `Image::Format(39)`, four of them with a comment beside them saying what 39 meant | `terrain_3d_data.cpp`, `terrain_3d_data_surface.cpp`, `terrain_3d_editor_texel.cpp`, `terrain_3d_page_pipeline.cpp`, `terrain_3d_region.cpp`, `terrain_3d_vt_page_pool.cpp`, `terrain_3d_surface_views.cpp`, `terrain_3d_virtual_texture.h` | 16 |
| `inline constexpr int IDWEIGHT_FORMAT_VALUE = 39;` "Godot's extension R16_UNORM surface format" | the surface baker's internal header, used once in `terrain_3d_surface_baker_queue.cpp` | 1 definition, 1 use |
| `static constexpr Image::Format FORMAT_R16_UNORM = Image::Format(39);` | `terrain_3d_vt_page_pool.cpp` | 1 definition, 1 use |

The three did not agree on the format's *name*. The engine calls 39 `FORMAT_R16`; two of the three local
spellings called it `R16_UNORM`, which is the name the unrelated `RenderingDevice` enum uses
(`terrain_3d_surface_baker.cpp`). A reader had to take a comment's word for the number, and there were
four comments to keep in step - one of which had already drifted into saying the format "is not named in
this godot-cpp binding" without ever saying which name it would have had.

`constants.h` now defines it once:

    inline constexpr Image::Format IDWEIGHT_IMAGE_FORMAT = Image::Format(39);

and its comment carries the two facts a reader needs: the engine's name for 39 is `FORMAT_R16`, and the
binding this addon builds against stops at `FORMAT_ASTC_8x8_HDR = 38` - its own `FORMAT_MAX` *is* 39 -
which is why that name is not available here. Seventeen call sites use the constant; the two local
aliases and the four local explanations are gone. `Terrain3DRegion::set_surface_map()` keeps the half of
its comment that is not about 39 ("R16 UNORM is the only format that preserves the packed 16-bit IDs
bit-exactly: a numeric conversion would re-quantise them"), and its error message is unchanged.

`RenderingDevice::DATA_FORMAT_R16_UNORM` in `terrain_3d_surface_baker.cpp` is a different enum, is
correctly named, and was **not** touched. "Replace every `FORMAT_R16_UNORM`" would have been the wrong
instruction, so the script asserts that site survives.

### `constants.h` gains one engine include, and why there

The constant needs `Image::Format`, so `<godot_cpp/classes/image.hpp>` moved into `constants.h`. That
header is included by every translation unit in the addon, so this is a real compile cost - visible as a
full rebuild - and it was chosen over the alternative: `terrain_3d_util.h` already includes `image.hpp`
and would have cost nothing, but eight of the ten files do not name that header today, so the constant
would have put an implicit dependency in eight files or forced eight new `#include` lines for one
symbol. `constants.h` is the one header all ten already reach, directly or through `logger.h` /
`terrain_3d.h` / `terrain_3d_region.h`. `terrain_vt.h`, whose header-only and engine-free contract the
architecture review documents, does not include `constants.h` and is unaffected.

### The scratch scripts were writing CRLF

Writing the ten files exposed a defect in this pass's own tooling rather than in the addon. The probe
scripts under `bin/perf_probe/` write with `Path.write_text(...)`, whose default newline translation
turns `\n` into `\r\n` on Windows, while the repository's `.gitattributes` declares
`* text=auto eol=lf`. Every file the split scripts produced - 33 of them - therefore ended its lines
with CRLF while its untouched siblings used LF.

Git hides this almost completely: `eol=lf` normalizes the working copy before comparing, so the files
show up as modified (they are) and the only symptom is a warning that "CRLF will be replaced by LF the
next time Git touches it". The committed content would have been correct either way. The working tree
now matches the rule again: `bin/perf_probe/normalize_eol.py` reports 33 files converted and 0 left, and
it touches only the paths `git status` reports for this addon, so the few unrelated CRLF files in the
repository (for instance `native/src/gen/doc_data.gen.cpp`) are left alone. The scripts themselves pass
`newline="\n"` now. This is recorded because it is not obvious from the outside: a byte comparison of a
generated file against a sibling has to know the endings can differ, and `bin/perf_probe/backup_round*/`
holds pre-change copies as they were on disk.

### How it was verified

* `bin/perf_probe/consolidate_r16.py` asserts, per file, how many literals it will replace and how many
  uses the result must hold; that neither local alias nor any of the four local comments survives; and
  that `constants.h` holds the definition exactly once. `--verify` re-reads all 97 sources and asserts
  no `Image::Format(39)` remains outside that definition, 18 uses in total (one declaration plus 17 call
  sites), and that the `RenderingDevice` format constant is still there.
* `bin/perf_probe/check_blank_runs.py` compares the count of runs of two or more blank lines against the
  pre-change copies, which is how the one double blank line the deletion left in
  `terrain_3d_vt_page_pool.cpp` was found and removed.
* Debug and Release builds clean, zero warnings, both after a full rebuild of every file that includes
  `constants.h`. All eight code audits green.
* Targeted, all pass: `region_slots`, `editor_paint`, `editor_dock:input`, `vt_surface`,
  `vt_codec_colors`, `texture_layers`, `vt_format`, `vt_density`. Between them they exercise the region
  surface map, the page payload, the editor's R16 byte path and the codec colours, so each changed site
  has a test that reads it back.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as the three runs before it
  (seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`, `vt_visibility`) plus
  `vt_recovery`, which has been seen on both sides of that line. A first run of the same suite reported
  41/54 with `vt_turn_budget` exiting in 0.2 s and producing no log at all; that entry is an artefact of
  rebuilding the extension *while* the run was in flight, not a test result - re-run alone it takes
  16.9 s and passes, and the re-run quoted here has it passing in 17.0 s. The lesson is cheap and worth
  keeping: a suite that loads the extension must not have the extension replaced under it. In the first
  run `vt_format` also failed as its documented uniform-set flake - its own assertion passes, and it is
  the engine's missing-uniform `ERROR:` line that the harness scores.

## The virtual texture view: 982 lines and three jobs in one translation unit

`terrain_3d_virtual_texture.cpp` was the largest file left after the editor split. The class it defines
is the per-view half of the virtual texture runtime: 58 methods, none longer than `initialize()`'s 94
lines, so the file is not one oversized function but three jobs sharing a class. Its own header named
them - "the indirection image, whose mip chain is built by hand ..., the sector block bookkeeping, and
the request / lookup / release entry points the demand passes call" - and the split follows it:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_virtual_texture.cpp` | 531 | The view object: the indirection table and its hand-built mip chain (`_read_level()` / `_write_level()` and the dirty-tile set they feed), the slot reservation the pool hands out (`_acquire_slot()`, and `_invalidate_pool_owner()`, which the pool calls back into), the settings with `initialize()` / `clear()` and the shared-pool binding, the upload `commit()` performs, page I/O and the slot queries, the counters `get_stats()` reports, and the ClassDB bindings. |
| `terrain_3d_virtual_texture_sector.cpp` | 268 | The near field's sector blocks: register / resize / unregister a sector, its block origin and size, `_virtual_to_physical()`, and the two maintenance passes `_release_sector_pages()` / `_remap_sector_pages()`. |
| `terrain_3d_virtual_texture_lookup.cpp` | 250 | Addressing: `_request_virtual()`, the sector-local and world-grid request / lookup / release entry points, and `lookup_virtual()`'s mip-chain walk. |

Two of the boundaries are the file's own text rather than a judgement made here. The two invariants it
already stated as comments - `_release_sector_pages()` walking resident owners "not the potentially
millions of virtual addresses", and `_remap_sector_pages()` moving a page a whole mip per doubling
because it "represents a fixed world footprint, not a fixed mip number" - are now the header of the file
that owns them. `set_world_max_mip()` and `world_page_to_virtual()` went to the addressing half instead
of staying with the other setters, because they *are* the shader's formula: the comment above
`world_page_to_virtual()` says "the shader uses this exact formula", and whoever changes it has to see it
next to the walk that consumes it.

### No internal header, and why that is the interesting part

All 58 definitions are member functions declared in `terrain_3d_virtual_texture.h`, and the original had
no file-scope helper and no namespace at all - the script asserts both, so the absence is checked rather
than assumed. That is why this split needs no `_internal.h`: the four earlier class splits needed one
because a helper or a type was shared by two halves, which is the case architecture-review rule 4 exists
for. Here the shared prologue is the header the class already had.

`terrain_3d_virtual_texture_lookup.cpp` is also the first file in this pass that includes neither
`logger.h` nor any engine header: it reads and writes the table through the view's own members, so
nothing in it logs and nothing in it names a Godot type. Its whole include block is the class header and
`using namespace TerrainVT;`.

### The invariant the split script asserts

As in the editor split, the script matches every definition head in every block, asserts there are
exactly 58, asserts no name lands in two files, and asserts each name is declared in
`terrain_3d_virtual_texture.h`. It also asserts that the lines no block claims are only the prologue, the
three access banners and blank separators, and that the banner text it writes into the two new files is
byte-identical to the banners it is replacing - a split that retypes a banner by hand is a split that can
silently change which section a function appears to belong to.

### How it was verified

* `bin/perf_probe/split_vtview.py` asserts all 53 block boundaries by content, the partition and
  banner/prologue rule above, and `--verify` proves every block byte-identical in its new file.
* Debug and Release builds clean, zero warnings; all eight code audits green.
* Targeted, all pass: `vt_cells`, `vt_demand`, `vt_root_coverage`, `vt_sparse`, `vt_fallback`,
  `vt_density`, `vt_page_fade`, `vt_monitors`. Between them they cover the far field's world-page path,
  the near field's sector-local path, a sector resize (`vt_density`), the page I/O and the diagnostics.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split, plus `vt_pressure`, the documented fail-once/pass-once flake. No new failure.

## The GDScript half: 31 files, 8,721 lines, and no way to check any of it

The pass read `native/src` mechanically and the addon's scripts only by eye, and the scripts are half the
source: 31 files and 8,721 lines across `src/`, `menu/`, `tools/`, `utils/` and the particle example, of
which 15 were in the ledger and 16 - the menu, the tools, the utils and the shared dock widgets - had
never been opened. Two tools close that gap.

`native/audit_gd.py` answers the same questions `audit_code.py` answers, in the form GDScript needs:

| mode | question | what GDScript makes hard about it |
| --- | --- | --- |
| `dead` | which `func` / `signal` nothing references | The engine calls `_ready`, `_process` and every `_on_*` a scene connects; `call("name")`, `has_method("name")` and `connect("name", ...)` reach a method through a *string*; a property's accessor is named by the `var x: set = set_x` that declares it. So string literals, the addon's `.tscn`/`.tres`, the C++ half and the test suite all count as references, and anything starting with `_` is skipped. |
| `params` | which parameters a body never reads | A signal handler is *required* to take the arguments its signal carries, and GDScript has no unused-parameter warning. The leading underscore is the only signal that separates "unused because the signature says so" from "unused because nobody checked", so only non-`_` parameters are reported. |
| `dupes` | function bodies written more than once | Nothing - and that is the point: GDScript has no `#include`, so a copy is the only way to share code and the only way to drift. |
| `comments` | comments naming something that does not exist | Comments are prose, so only three forms are unambiguous: a backticked name, a `name()` call, and an `_private_name`. Two rules came out of running it: a backticked token ending in a file extension is a file (`Terrain3DParticles.tscn` is not a name called `tscn`), and a token ending in `_` is emphasis, not an identifier. |
| `indent` | indentation mixing tabs and spaces, or skipping a level | - |
| `shape`, `outline` | what each file holds, and what outgrew it | - |

`native/check_scripts.py` is the second tool and the more valuable one: it runs the engine with
`--check-only --script` over every script *from the test project*, which parses the file and everything
it preloads or extends. It earned its place immediately. The dock extraction below first shipped a base
script that had lost its three constants, and the parse said
`Identifier "ES_DOCK_TILE_SIZE" not declared in the current scope` - which is also the answer to a
question the pass would otherwise have guessed at: a base script's constants *are* inherited (the
`ListContainer` preload resolved), while a missing one is a hard parse error. Script changes are now
checkable in seconds instead of a sixteen-minute suite.

### What the two tools found

* **The two docks were 40% the same file.** `asset_dock.gd` (4.6+, hosted in an `EditorDock`) and
  `asset_dock_45.gd` (pre-4.6, its own slot and window) shared twelve functions byte for byte - the
  search box, the list switching, the pin and size handlers, the highlight sweep, the asset refresh and
  the window-focus handler - plus three signals, three constants and eighteen fields. They now share
  `src/asset_dock_common.gd` and keep only what differs: how the dock is hosted, which editor settings
  survive a session, and their own extras. 1,010 lines became 882 in three files, and `dupes` is empty
  for the whole script half.
* **Two comments named something that no longer exists.** `editor_plugin.gd` said "`_input_apply`
  released, save undo data" in the branch that closes a stroke; there is no `_input_apply`. And
  `asset_dock.gd` carried a commented-out `class EdDock extends EditorDock` whose only content was a
  debug print; the layout enumeration it documented (1 vertical, 2 horizontal, 4 window) is prose now,
  and the class it named is already named at its call sites.
* **Four unreferenced public accessors, left alone**: `DoubleSlider.get_min()` / `get_max()` /
  `get_step()` and `Terrain3DAssetDockContainer.get_entry_width()`. Each is the read half of a setter the
  addon does call, on a `class_name`d widget that ships to users - `double_slider.gd`'s own header says
  it "Should work for other UIs". That is API surface rather than dead code, which is the same verdict the
  C++ half reaches for a `Terrain3D` method only its binding names.
* **Nothing else**: no duplicate bodies outside the docks, no unread parameters, no mixed indentation,
  and no comment naming something that does not exist.

### What it did not do

`shape` lists the long functions, and they are mostly UI builders where the length *is* the structure:
`ui_decal.update_decal()` 206 lines, `vt_editor._build_ui()` 200, `tool_settings._ready()` 165 and
`_create_setting_control()` 136, `ui._on_tool_changed()` 136, `editor_plugin._forward_3d_gui_input()`
130, `channel_packer._init_texture_picker()` 128, `asset_dock.initialize()` 119. Splitting a UI builder
means extracting the widgets it creates into named builders, which is a different change from the file
splits this pass has been doing and has no oracle beyond the dock tests already run. Recorded, not
touched.

The ledger still marks 16 scripts as unread line by line, and it should stay that way until they are:
this round checked them *mechanically* - parse, references, duplicates, parameters, comments,
indentation - which is a weaker claim than having read them.

### How it was verified

* `native/check_scripts.py`: **34/34 scripts parse** (33 addon scripts plus the new base class), from the
  test project, so every `preload`, `extends` and cross-script reference resolves.
* `native/audit_gd.py`: every mode green except the four accessors above and `shape`'s long-function
  list.
* `bin/perf_probe/dedup_docks.py` asserts each of the twelve moved functions byte-identical in *both*
  docks before deleting either copy, asserts each of the 26 declarations appears exactly once in each,
  asserts neither file contained a run of three blank lines before the deletions - which is what makes
  the post-deletion collapse provably touch only its own artefacts - and asserts each dock still defines
  exactly the functions it should.
* Targeted, all pass: `editor_dock:dock` (which loads *both* dock scripts and asserts the dock layout and
  management-menu behaviour), `editor_dock:input`, `editor_dock:grid`, `editor_dock:pairroles`,
  `editor_dock:slider` and `editor_paint`.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split (seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`, `vt_visibility`)
  plus `vt_recovery`, seen on both sides of that line before. That run was taken on the dock extraction
  *before* the last step of it: the script had left three section comments whose functions had moved
  (`## Dock Button handlers`, `## Update Dock contents`, and the floating-window note), which the
  original had attached to the functions rather than to the base. Removing them is comment-only, and the
  editor tests above were re-run on the final scripts.

## The menu subsystem: the first third of the unread scripts

The sixteen scripts the ledger still marks unread are the addon's editor tooling. This round read the six
in `menu/` end to end - 1,122 lines, none of which had been opened by this pass before:
`terrain_menu.gd` (101, the editor's Terrain3D menu bar), `baker.gd` (398, the bake and navigation
actions), `channel_packer.gd` (497, the Pack Textures window), `directory_setup.gd` (79, the data
directory wizard), the drag-drop button (`channel_packer_dragdrop.gd`, 17) and the LOD dialog
(`bake_lod_dialog.gd`, 30).

`dupes`, `params`, `indent` and `comments` were already clean here before the round, and the mode that
had something to say is the new one below. What the reading itself produced was four deletions and the
documentation the files were missing.

### `state`: the mode that was missing

The C++ half has always reported member fields nothing reads. The script half could not, and the first
run of the new mode found what it is for: `menu/channel_packer.gd` declares `last_opened_directory`, reads
it once to set a file dialog's path, and assigns it **nowhere**. That line cannot do anything except
reset the dialog, and the variable beside it (`last_saved_directory`) *is* written - so the plausible
readings are a lost writer or a leftover, and either way the assignment does not do what it looks like.

Three rules keep the mode honest, each suppressing a false-positive class rather than a real finding:
only column-0 `var`s are members (a local's assignment is its own declaration, which the walk skips); the
search is over the whole corpus (a member declared in a base script is written by the subclass that
extends it - `asset_dock_common.gd` declares `_confirmed` and only the two docks assign it); and a name
followed by `.` or appearing inside a string literal counts as used (`entries.push_back()` fills a list;
`tween_property(self, "editor_decal_fade", ...)` reaches a property by path). An `@export` is skipped
because the inspector assigns it. Getting to those rules took the first run reporting every local
variable in the addon and `editor_decal_fade` as one-sided; both were the tool's fault, not the code's.

### Four deletions

* `editor_plugin.gd`'s `current_region_position` and `ui.gd`'s `setting_has_changed`: declared, and
  referenced nowhere in the addon, the test suite or the test project.
* Six lines of commented-out property assignments in `channel_packer.gd`'s file-dialog setup
  (`#save_file_dialog.transient = false` and its two neighbours, and the same three for the open dialog).
* A pointless local in `_create_import_file()`: `template_content` was copied into `import_content`, and
  only the copy was ever used.
* User-visible typos that no test asserts: "generated sucsessfully", "Not Orthoganol to UV plane ... For
  Compatability with Detiling and Rotation, Select Orthoganolize Normals", and the comment's "to alow the
  dialog to clear".

### The documentation the files were missing

`baker.gd` is four jobs behind a one-line header, `channel_packer.gd` is five, and `terrain_menu.gd` had
a header that did not mention the invariant its enum depends on. Each now names its jobs, and three
contracts that existed only in the author's head are written down:

* `channel_packer.gd`: the accepted image extensions are shared by three places - the open dialog's
  filter list, `_can_drop_data()` in the drag-drop script, and what `load_image_fn` can actually read.
* `terrain_menu.gd`: the enum is the menu's item IDs *including the separators*, so its order has to stay
  in step with the `add_item()` calls; and why only two of the three tools are added as children
  (`packer` is RefCounted and adds its own window to the plugin).
* `baker.gd`: both dialogs are handed to `EditorInterface.popup_dialog_centered()`, which parents a
  window that has no parent and unparents it again on hide, which is why neither is in the tree. That was
  checked in the engine (`popup_exclusive_centered()` -> `Window::_popup()`) rather than assumed, because
  a window that is never parented would never be shown.

Documented in place as well: `_pack_textures()`'s ten positional parameters with the six bools at its two
call sites (the order *is* the interface), `_alignment_basis()` as Rodrigues' rotation onto +Z, and
`directory_setup.gd`'s file-mode filter, which is inert because the wizard only ever opens the dialog in
directory mode.

### How it was verified

* `native/check_scripts.py`: 34/34 scripts parse.
* `native/audit_gd.py`: `dupes`, `params`, `indent` and `comments` green, `state` down to the one
  recorded finding, `dead` unchanged (the four widget accessors).
* Targeted, all pass: `editor_dock:dock`, `editor_dock:input`, `editor_dock:slider` and `editor_paint` -
  the four tests that instantiate the production plugin and therefore load every script changed here.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split, plus `vt_compressed_render`, one of the documented uniform-set flakes. No new failure.

## The bridge, the image maths, the objects parent and the two manual tools

The rest of the unread `src/`, all of `tools/` and all of `utils/` - 645 lines - read end to end:
`src/vt_terrain_bridge.gd` (103), `src/vt_overview_image.gd` (156), `utils/terrain_3d_objects.gd` (191),
`utils/transform_changed_notifier.gd` (16), `tools/importer.gd` (127), `tools/region_mover.gd` (52).

Three of them carry contracts the architecture review names, and all three hold up:

* **The bridge is what it says it is.** Every accessor returns a typed empty value when the native side
  is missing - `{}`, `[]`, `null`, or `true` for the auto-bake default - so a build without the method
  reads as "unavailable" rather than breaking the editor. One check went past the document: the review
  claimed the bridge owns *every* duck-typed call into the extension, and it owns the VT window's.
  `terrain_vt_inspector.gd` and `editor_plugin.gd` guard their own (`has_method` + `call` around
  `get_vt_settings`, `bake_svt`, `open_vt_page_view` and the dock's `_open_vt_editor`). Both documents
  say that now instead of the broader claim.
* **The image maths is pure over its arguments,** including the one callback it takes (`p_get_region`),
  which is what lets the stitch be reasoned about without a window, a live terrain or a tree.
* **`Terrain3DObjects` states its invariant** in the header now: `_offsets` maps a node's instance id to
  (X, height above the terrain, Z), and a child transform change re-derives that offset rather than
  storing a position - which is why an edit that raises the ground carries the child with it.

### One duplication removed

`vt_overview_image.gd` had the same per-pixel loop written twice - `linear_to_srgb()`, force alpha to
1.0, write back - in `display_texture()` and `blit_material_preview()`, identical but for the variable
name. `dupes` cannot see it: that mode compares whole function bodies, and this is a five-line block
inside two longer ones. It is `to_display_image()` now, called by both, with the reason for the
conversion (alpha stores height, RGB is linear GPU output) written once beside it. No test calls either
display path directly, so this one is verified by the parse check and by reading both call sites - the
mutation is on a duplicate in each case, which is why passing the image in cannot reach the serialized
payload.

### What the reading found and did not change

`tools/region_mover.gd` is a manual rename tool, and its error path is where the defects are:

* It saves `data_directory`, clears it deliberately so the rename cannot re-save regions, and on a
  failed `DirAccess.open()` it prints the *cleared* variable (an empty string) and returns **without
  restoring it** - the user's data directory is gone from the node.
* The bounds check aborts in the middle of the first rename pass, so files already renamed to
  `tmp_terrain3d_*.res` keep those names: the second pass, which would give them their final names,
  never runs. Those files are not loadable, and nothing in the tool warns about it.

`tools/importer.gd`'s `start_import()` dereferences `assets` and `material` without a null check, and
`reset_settings()` in the same file is what sets both to `null` - so importing a colour file after a
Clear All is a null dereference. `utils/terrain_3d_objects.gd` calls `_undo_redo.create_action()`
unguarded (`editor_setup()` is what fills it), and `get_terrain()` dereferences
`EditorInterface.get_edited_scene_root()` unguarded, which is null when no scene is open. All of these
are behaviour or robustness changes on paths no test in `native/tests` reaches - the two tools are manual
editor scripts, and the objects parent is only exercised indirectly - so they are recorded, not touched.

Documentation added where a contract was implicit: `importer.gd` now says it is a manual tool you attach
to a Terrain3D node whose buttons run immediately and without undo (matching `region_mover.gd`'s
header), and `Terrain3DObjects` documents `editor_setup()`'s caller and `get_terrain()`'s fallback.

### The `comments` mode needed a string vocabulary

Adding a header that names the hidden helper node (`TransformChangedSignaller`) made `comments` report
it: the name exists, but as the *value* of a `StringName` constant rather than as an identifier. The fix
is the rule `dead` already had - a name the code reaches by string is still a name the addon contains -
applied to the vocabulary: string literal contents are collected too, while comments are still excluded
from it, because a comment naming a dead identifier must not teach the check that the identifier exists.
`code_only()` grew a `strings=False` mode for that.

### How it was verified

* `native/check_scripts.py`: 34/34 scripts parse.
* `native/audit_gd.py`: every mode green except the two recorded candidate lists - `dead`'s four widget
  accessors and `state`'s `last_opened_directory`.
* Targeted, all pass: `editor_dock:svt_inspector`, `editor_dock:vt_idle` and `editor_dock:dock`, the
  three tests that exercise the VT inspector and the window that calls the bridge and the image maths.
* Full suite: **39 pass, 15 fail** - the eleven deterministic failures that have been constant since the
  service split, plus *four* of the documented flakes in one run (`vt_compression`,
  `vt_compressed_render`, `vt_pressure`, `vt_recovery`; `vt_format` passed). Re-run one at a time, all
  four pass. That is a run of an unusually flaky machine state rather than a regression, and the
  deterministic set is what the claim rests on.

## The dock's two widgets, and the cursor decal

Three files, 1,120 lines, read end to end: `src/asset_dock_list_container.gd` (320, the tile grid, its
search filter and the selection model), `src/asset_dock_list_entry.gd` (448, one tile) and
`src/ui_decal.gd` (352, the editor's cursor decal). The reading produced one piece of dead code, two
small duplications, three enum spellings, and two engine questions that were answered by experiment
rather than by opinion.

### Two experiments instead of two guesses

Both code findings looked like a bug for a reason other than the real one, and both were settled by
running the pattern in the engine:

* **`destroy_buttons()` looked like a double free.** It freed `button_row` - whose children are all the
  buttons, since `setup_buttons()` adds each of them to it - and then freed each button as well. The
  engine says a node freed with its parent reads as **false**, so `if button_enabled:` never passes and
  those five guarded `free()` calls were unreachable. The experiment also showed what the pattern really
  cost: the member references were left holding freed objects instead of the `null` the guards were
  supposed to assign. The row is now the only thing freed and every reference is cleared, with the
  invariant (the row owns the controls) written down.
* **`ui_decal.gd`'s setter assigns to itself** (`editor_decal_fade = value` inside `set(value)`), which
  reads like infinite recursion and was documented as a hazard in older Godot versions. In this engine
  the setter body runs exactly **once** and the assignment writes the property's storage, so both callers
  - `update_decal()` seeding the fade from the cursor colour and the timer's tween fading it to 0 - do
  what they look like. That is a comment on the setter now, not a backer variable and not a shrug.

Neither experiment is a test in `native/tests`; both were one-off scripts under `bin/perf_probe/`, which
is where a question that needs the engine but not the addon belongs.

### Two duplications `dupes` could not see

`dupes` compares whole function bodies, so neither of these was reported:

* `asset_dock_list_entry.gd` styled its two labels with the same seven lines (size flags, font size,
  colours, shadow). They are `_make_label()` now; what differs - alignment, autowrap, overrun behaviour
  and the count label's initial text - is what the two setup functions still say.
* `asset_dock_list_container.gd` computed the last selectable entry id twice with the same comment
  ("Add new is the final entry only when search box is blank"), once to clamp the selection and once to
  read it back. It is `_max_selectable_id()`, and the comment now says why the two have to agree.

### Names and spellings that disagreed

* The tile's name label was called `"MeshLabel"` while serving textures as well as meshes. Nothing looks
  it up by name; it is `"NameLabel"`, beside `"CountLabel"`.
* Three enums were spelled two ways: `Terrain3DAssets.AssetType.TYPE_MESH` (2 sites) against
  `Terrain3DAssets.TYPE_MESH` (the rest), `Terrain3DEditor.Tool.INSTANCER` (1) against
  `Terrain3DEditor.INSTANCER`, and `Terrain3DMaterial.WorldBackground.NONE` (1) against
  `Terrain3DMaterial.NONE`. Both forms resolve to the same constant, so this is consistency rather than
  correctness - but a reader who meets two spellings has to check whether they mean two things.

### The interface between the widgets and their host

Two hard-coded ancestry walks *are* the contract between these files and the dock, and neither was
documented. The container reaches the dock with `get_parent().get_parent().get_parent()` to raise the
confirmation dialog (list -> ScrollContainer -> Box -> dock); the entry reaches the ScrollContainer with
`get_parent().get_parent()` to scroll a selected tile into view. Both now name the chain they assume and
say that nothing checks it; the container's comment also records that `plugin.asset_dock` is the same
node, for whoever makes the host shape explicit.

### How it was verified

* `native/check_scripts.py`: 34/34 scripts parse.
* `native/audit_gd.py`: every mode green except the two recorded candidate lists.
* Targeted, all pass: `editor_dock:dock`, `editor_dock:input`, `editor_dock:pairroles` (which asserts the
  role readout this widget computes), `editor_dock:slider` (the entry-width path) and `editor_paint`.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split, plus `vt_pressure`, the documented fail-once/pass-once flake. No new failure.

## The asset library: 916 lines and three jobs in one translation unit

`terrain_3d_assets.cpp` was the largest file left. It defines the library that holds a terrain's texture
and mesh assets: two parallel lists with the same ID rules, and two type-specific pipelines hanging off
them.

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_assets.cpp` | 357 | The resource object and the list engine both kinds share: `_set_asset_list()` (refill a list from a resource file, reconnect its `id_changed` notifications), `_set_asset()` and `_swap_ids()` (keep a saved ID or move the asset to the next free slot), the lifecycle, `save()` and the ClassDB bindings. |
| `terrain_3d_assets_textures.cpp` | 402 | The texture array: `_update_texture_files()` (the albedo and normal layers, with `_texture_layer_cache` reusing any layer whose identity - size, compression, mipmaps, layer kind, working format and a SHA-256 of the source bytes - has not changed), `_update_texture_settings()` (the per-layer shader parameters, always 32 of them), the array settings and the texture list's setters. |
| `terrain_3d_assets_meshes.cpp` | 229 | The mesh list and the thumbnail renderer: `update_mesh_list()`, `set_mesh_asset()`, `load_pending_meshes()`, and the offline renderer (`_setup_thumbnail_creation()` builds one scenario, viewport, orthographic camera and two lights; `create_mesh_thumbnails()` reuses them for every capture). |

The lifecycle is what makes the split legible rather than arbitrary: `initialize()` is the fan-out (it
sets up the thumbnail viewports and then asks both halves to build their lists) and `destroy()` is the
collection point (it releases the shared GPU objects and every cache either half filled). Both stay with
the resource object.

The codec table at the top of the original - `ArrayCodec` and sixteen `ARRAY_CODECS` rows, with a
`static_assert` tying the count to `ARRAY_COMPRESSION_MAX` - is used by `_update_texture_files()` alone,
so it moved into the texture half and no internal header was needed. That is the second class split in
this pass with no prologue to share (after the editor's), and the same check decided it: the script
asserts that no file-scope symbol outside those sixteen rows exists.

### An unused include, and the audit gap the split exposed

`#include <godot_cpp/classes/environment.hpp>` was in the original, and `Environment` appears nowhere in
its 916 lines. The include is gone; the build is the proof.

More interesting is what the split did to `audit_code.py`. Its `sections` mode pairs a `.cpp` with the
`.h` of the same name, so **every split half in this pass had been skipped by it** - eight files that
declared a banner and were never checked against the header. It now resolves the class header from the
file's own includes (the include that declares the class its definitions belong to, which is not simply
the first one: that is `logger.h` in most of these files). The mode went from 16 checked files to 24, and
both new halves are clean - as are the six earlier ones, which is now a verified claim rather than an
assumed one.

### How it was verified

* `bin/perf_probe/split_assets.py` derives each block's boundaries from the source rather than taking
  typed line numbers: it finds all 24 definitions in file order, asserts that order against the
  assignment table, extends each block up over the comment lines that document it (stopping at a
  `/////` banner), trims the separators between blocks, and asserts the result is a partition whose only
  unassigned lines are the prologue, the three banners and blanks. `--verify` proves every block
  byte-identical in its new file.
* Debug and Release builds clean, zero warnings. All eight code audits green, `sections` now covering 24
  files.
* Targeted, all pass: `texture_layers` (the texture array this split moved), `vt_adaptive:instancer`
  (mesh assets and their instancer path), `editor_dock:dock` (the asset dock that edits both lists),
  `editor_dock:input` and `vt_cells`.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split, plus `vt_format`, the documented uniform-set flake. No new failure.

## The node: 904 lines, and one of its jobs had never been named

`terrain_3d.cpp` was one of two files left over 900 lines. Its own header said what it owned - "the node
itself: lifecycle, notifications, the container nodes it creates, mesh/collision/instancer wiring, and
the physics-tick scheduler" - and that list is three jobs, not one:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d.cpp` | 596 | The node: `_initialize()`, the physics tick (`__physics_process()` and the two helpers it drives), the render-geometry invalidation the VT service and the mesher ask for, and `_notification()` / `_validate_property()`. |
| `terrain_3d_wiring.cpp` | 244 | Every `_setup_*` / `_destroy_*` that creates or releases a subsystem node or GPU object: the terrain and ocean meshers, the displacement buffer and its SubViewport, the collision body, the mouse-picking state, the label containers, the instancer and the streamer. All idempotent, because the notification they answer can arrive more than once. |
| `terrain_3d_monitors.cpp` | 123 | This node's custom `Performance` monitors: registration (ids under the `terrain/` group, or under the instance id for a second terrain in the scene), unregistration before the node is freed, and the four callbacks that read this node's own members. |

The node file stays the largest of the three, and the honest reason is that two of its functions are
long: `__physics_process()` (211 lines) and `_notification()` (201). Neither moved, because both *are*
the frame schedule and the lifecycle - the two things this file is for. `shape` still lists
`__physics_process()` over the function ceiling; making it a pass over named phases is the same change
this pass made to `_produce_sector_avt_pages()` and `_update_visible_svt()`, and it is not obviously worth
doing on the per-frame path that `vt_turn_budget` asserts a 0.10 ms budget for. Recorded, not done.

### A doc comment that described a function 110 lines away

The four lines at the top of the monitors section -

    /**
     * This is a proxy for _process(delta) called by _notification() due to
     * https://github.com/godotengine/godot-cpp/issues/1022
     */

- sat above `_register_debug_monitors()`, which has nothing to do with `_process`. They describe
  `__physics_process()`, which `_notification()` calls 500 lines later, and they are now attached to it.
  The split script moves them explicitly and asserts their text first, because a boundary rule cannot
  know which function a comment is about: it only knows the comment is contiguous with the definition
  below it.

### Two things the split taught the script

* **A prologue is not automatically dispensable.** The script treats the lines above the first definition
  as the file's prologue and writes its own includes in each new file - but this prologue also contained
  `Terrain3D::DebugLevel Terrain3D::debug_level{ ERROR };`, the static member's definition. The first
  build linked every object and then failed with `LNK2001` on that member. The definition is a block now,
  owned by the node half, and the free-line assertion no longer accepts it as prologue.
* **The include sets took three build cycles to settle**, and the compiler, not the grep, was right each
  time: the node half needs `shader_material.hpp`, `terrain_3d_profile.h` and
  `terrain_3d_surface_baker.h` for the tick's own body, plus `editor_interface.hpp` for `_grab_camera()`
  and `compositor.hpp` for the `Ref<Compositor>` member it touches; the wiring half needs
  `compositor.hpp` for the picking compositor. This is the third time in this pass that a half's includes
  were only knowable from a build.

### How it was verified

* `bin/perf_probe/split_terrain3d.py` derives the 29 blocks from the source, asserts their order against
  the ownership table, moves the proxy comment, and asserts the result is a partition (the static
  definition, the two banners and blank lines are the only non-function lines). `--verify` proves every
  block byte-identical in its new file.
* Debug and Release builds clean, zero warnings. All eight code audits green, `sections` now covering 26
  files.
* Targeted, all pass: `vt_monitors` (the monitors this split moved), `vt_turn_budget` (the frame path,
  including its 0.10 ms assertion), `editor_dock:dock` (the picking setup), `region_slots` and
  `vt_adaptive:instancer`.
* Full suite: **43 pass, 11 fail** - the eleven deterministic failures alone; none of the documented
  flakes fired this run. No new failure.

## The near field's planning: 904 lines, and a prologue shared three ways

`terrain_3d_sector_avt.cpp` was the largest file left. Its own header named its jobs, and its call graph
says where they divide, because `_update_sector_avt()` is a driver over named stages:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_sector_avt.cpp` | 432 | The demand entry point and its configuration: the tier settings the sector size is derived from, `_avt_logical_ratio()` and `get_avt_base_block_size()`, the driver `_update_sector_avt()`, `_avt_plan_state()`, the install-or-reuse decision and `_avt_submit_plan()`. |
| `terrain_3d_sector_avt_hierarchy.cpp` | 365 | The world model's build: `_avt_scan_sectors()`, `_avt_build_hierarchy()`, `_avt_sync_address_directory()`, and the two functions that publish the directory texture the shader reads. |
| `terrain_3d_sector_avt_motion.cpp` | 207 | Motion prediction: the smoothed velocity and turn rate and the slewed leads a plan is aimed at — where the camera will be and where it will be looking — and the quantization that keeps the plan key stable while the camera moves inside a cell. |
| `terrain_3d_sector_avt_internal.h` | 38 | The three prologue names two of the halves read: the sector's world size, the `Sector` alias and `avt_owner_key()`. |

### The prologue is the interesting part

The original opened with an 80-line anonymous namespace, and its contents divide three ways - which is
rule 4 of the architecture review in its purest form:

* **Read by two halves, so they move to the header**: `SECTOR_WORLD` (the driver, the scan, the
  directory sync and the submit), the `Sector` alias (the scan, the hierarchy, the sync, the submit and
  the publish) and `avt_owner_key()` (the sync and the submit). The helper is `inline` there rather than
  file-scope `static`, because a header definition two translation units include has to be one they are
  both allowed to have - the same conversion rule 4 records from the surface-baker split.
* **Read by one half each, so they stay**: every `MOTION_*` constant (motion), and `DEMAND_DENSITY_MARGIN`,
  `SectorKey`, `sector_hash()` and `floor_div()` (the hierarchy). A constant with one reader is part of
  that file's arithmetic, not a shared vocabulary, and the script proves the split: for each prologue
  symbol it counts the halves that read it.

The split was decided by that count rather than by taste: `prologue_use.py` reports, per definition,
which prologue symbol it reads, and it is what showed that the motion constants never leave the motion
half.

### The include trap this file had been hiding

Three build cycles, and the third one is a lesson the earlier splits had not taught. The internal header
included `terrain_3d_avt.h` and the variant headers its records need (`Vector2i`, `Rect2`) - and still
failed, because the records write `Vector2i` **unqualified**: they need `using namespace godot;`, which
`constants.h` establishes and which the original file got only because it included `terrain_3d.h` first.
So the header now includes `constants.h` before `terrain_3d_avt.h`, and says why. "Which types does this
header name" was the wrong question; the right one was "which of its declarations depend on a namespace
opened by another header".

### How it was verified

* `bin/perf_probe/split_sector_avt.py` derives the 19 blocks from the source, asserts their order against
  the ownership table, asserts the eight prologue sub-blocks by content, asserts the three header symbols
  are the original lines (with `inline` added), and asserts the result partitions the body - the prologue,
  the two namespace braces and blanks are the only non-definition lines. `--verify` proves every
  definition verbatim in its new file.
* Debug and Release builds clean, zero warnings. All eight code audits green.
* Targeted, all pass: `vt_demand`, `vt_cells`, `vt_monitors`, `vt_turn_budget` (including its 0.10 ms
  frame-budget assertion), `vt_page_fade` and `vt_root_coverage`.
* Full suite: **42 pass, 12 fail** - the same eleven deterministic failures as every run since the
  service split, plus `vt_compressed_render`, one of the documented uniform-set flakes. No new failure.

## The region: 773 lines, three jobs, and a comment this pass had broken

`terrain_3d_region.cpp` was the second-largest file left, and its layout already separated two of its
three jobs:

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_region.cpp` | 394 | The record: the four maps and their accessors, the validation that keeps them consistent (`sanitize_map()`, `validate_map_size()`), the height range, the location and instance count, and the ClassDB bindings. |
| `terrain_3d_region_surface.cpp` | 263 | The R16 IdWeight surface map: its accessors, the density it is stored at, the lazy creation, the legacy control conversion, and the nearest resample all of it goes through. |
| `terrain_3d_region_io.cpp` | 164 | Serialization and introspection: `save()`, the map dictionary `set_data()` / `get_data()`, `duplicate()` and `dump()`. |

The file-scope `_resample_surface_map()` went with the surface half, because those five functions are
its only callers - the same rule that put `terrain_region_in_frustum()` in the AVT half of the VT
service, and the reason no internal header was needed here.

### A defect this pass introduced, and the audit that could not see it

The split started with a reading, and the reading found this at `set_surface_map()`:

    	if (p_map.is_valid()) {
    // R16 UNORM is the only format that preserves the packed 16-bit IDs
    		// bit-exactly: a numeric conversion would re-quantise them.

The first comment line is at column 0 inside an indented body. It is this pass's own damage: the format
consolidation replaced a three-line comment with a two-line one through a script whose replacement text
carried the original indentation only for its second line. It compiled, because comments do not.

`indent` did not report it, and could not: both of its checks read `code_only()`, where every comment is
blank. The mode has a third check now - a column-0 `//` line whose nearest neighbour above *and* below is
indented - and the reason it needs both sides is that its first version, requiring only the line above,
reported thirteen sites: nine of them were the embedded-shader files, where a column-0 comment between a
column-0 `#include "shaders/....glsl"` and a column-0 `static const char *SHADER_SOURCE =` is exactly
where it belongs. With both sides required it reports the one real site, and the comment is indented
again.

### How it was verified

* `bin/perf_probe/split_region.py` derives the 32 blocks from the source, asserts their order against the
  ownership table, asserts the resample helper's text, and asserts the result partitions the body (the
  prologue, the two banners, the helper and blanks are the only non-definition lines). `--verify` proves
  every definition and the helper verbatim in their new files.
* Debug and Release builds clean on the first attempt, zero warnings. All eight code audits green,
  including the new comment check.
* Targeted, all pass: `region_slots`, `region_streaming` (the region lifecycle), `texture_layers` (the
  surface map into the texture array), `vt_surface` and `editor_paint`.
* Full suite: **40 pass, 14 fail** - the same eleven deterministic failures, plus three of the
  documented flakes in one run (`vt_compression`, `vt_format`, `vt_pressure`; `vt_recovery` and
  `vt_compressed_render` passed). No new failure.

## The last unread script, and what "read everything" now covers

`extras/particle_example/terrain_3D_particles.gd` (241 lines) was the last addon script the ledger did
not mark read. With it, the ledger's script half is complete: 34 shipped GDScript files, from
`vt_editor.gd`'s 1,446 lines down to `transform_changed_notifier.gd`'s 16.

What the reading found in the example:

* **A duplicated AABB computation.** The `cell_width` setter and `_create_grid()` each built the same
  particle-node AABB from the terrain's height range, six lines apiece. It is `_custom_aabb()` now, with
  `_update_custom_aabb()` applying it to the nodes that already exist and `_create_grid()` using the
  value directly for the nodes it is about to create - the two callers need different things from it, so
  the computation and its application are separate functions.
* **One of the two copies was unguarded.** The setter checked `terrain and terrain.data` before reading
  the height range; `_create_grid()` did not. The helper checks, so both are covered.
* **Two exported properties whose setters ignore their argument.** `calculated_distance` and
  `particle_count` are marked read-only for the inspector, their setters recompute them from the inputs
  that decide them, and the value written to them is discarded - the code writes `1.0` and `1` to ask for
  that recomputation. That is a real contract and a confusing one, so it is now written down in the file
  header, and each setter's parameter is named `_value` to say the value is deliberately unused. The
  alternative - a method instead of a setter - would change the property shape of a shipped example.

The example is not loaded by any test in `native/tests` (nothing there mentions `Terrain3DParticles`), so
the oracle for this round is `check_scripts.py` rather than a test run: 34/34 scripts parse. That is the
honest limit of the verification, and it is why the changes here are a deduplication, a guard and
comments rather than anything that could change what the particles draw.

### The ledger's scope, stated

The reading ledger is now complete for what the addon ships. `native/tests` (56 scripts) is not part of
it and will not be: that directory is this pass's verification instrument, its assertions and thresholds
are frozen, and it is read where a change needs it (`editor_dock.gd`, `editor_paint.gd`,
`editor_slider.gd`, `vt_turn_budget.gd` and the runners were read that way). The later "Final source
inventory" section is a record of what one earlier phase read, and now says so instead of reading like a
second, stale copy of the ledger.

## An instance that outlives its region

Every round since the instancer was read carried the same entry in the left-open list: `destroy()`
enumerates the data's *current* regions, so the instances of an unloaded region are never freed. This
round turned it into a fixed defect, because writing the test first is what that list said the entry was
waiting for - and the test needed a way to see the leak.

### What the defect was

`Terrain3DInstancer` keeps its MMI and multimesh RIDs in `_mmi_rids`, keyed by region location. Every
teardown path walked `_terrain->get_data()->get_region_locations()` - the regions the data has *now*:

* `destroy()` (and the destructor that calls it) looped over meshes and called `_destroy_mmi_by_mesh()`,
  which looped over the data's regions.
* `clear_by_mesh()` did the same.
* The update pass skipped a queued pair whose region was gone with "Errant null region found".

A region that is removed (`remove_region()`, which the region tool's SUBTRACT and the editor's deletions
call) or unloaded (`unload_region()`, what the streamer does outside the active range) is **gone from the
data before** the update it triggers runs: both functions drop it from `_region_locations` and only then
ask for an update, which reaches the instancer as the rebuild sentinel. So the MMI was never visited. Its
RenderingServer instance and multimesh RIDs stayed allocated for the lifetime of the process, and the mesh
asset's instance count - raised when a multimesh is created and lowered in `_destroy_mmi_by_cell()` -
stayed inflated for a region that no longer existed.

### The test, written first

`native/tests/terrain_instancer_release.gd` (with its 28-line `*_runner.py`, which `discover()` picks up
directly) drives both removal paths and asserts the count returns to zero. The count is the observable
because it is lowered only where an MMI is freed, so it is zero exactly when every MMI was reached.

Against the unfixed library the test failed with two `REGRESSION:` lines - and the engine said the same
thing independently at exit:

    ERROR: 1 RID allocations of type '...MultiMesh' were leaked at exit.
    ERROR: 1 RID allocations of type '...RendererSceneCull::Instance' were leaked at exit.

That is the strongest evidence this pass has produced for a defect: a leak reported by the engine's own
teardown rather than inferred from a counter.

### The fix

Every teardown path now walks `_mmi_rids`, its own state, and a new `_release_orphaned_regions()` runs at
the end of both update paths to enforce the invariant that the map only holds regions the data still has:

* `destroy()` iterates the map through `_mesh_ids_at()` - which copies the ids, because freeing one erases
  entries from the map being walked - and resets every mesh asset's count afterwards. The destructor calls
  it, which is why the leak surfaced at exit.
* `clear_by_mesh()` calls `_release_orphaned_regions()` after its per-region pass.
* `_release_orphaned_regions()` frees what the map holds for the locations `get_region_ptr()` no longer
  finds.

`_destroy_mmi_by_mesh()` had no other caller, so it is gone; the file header that listed it as one of
"three teardown paths" was corrected with it. `comments` reported the stale name the moment the function
was deleted, which is what that mode is for.

### What the fixture had to learn

The test's first version placed its second batch at `x = 64 + 4`, assuming a 64 m region because it set
`terrain.region_size = 64`. A terrain does not take that before it enters the tree and the real span is
512, so `get_region_location(x = 68)` answered `(0, 0)`: the batch was grouped into the region the first
scenario had just removed, `append_location()` returned early for a null region, and nothing was added.
The fixture now reads the span from the terrain and asserts that each batch lands in the region it means -
a check that turns a confusing "the count is 0" into "the fixture places the second batch inside the second
region". That is the third time in this pass that a test's own fixture, not the library, was the thing to
fix.

### How it was verified

* The new test: red before the fix (two `REGRESSION:` lines and the engine's leaked-RID errors), green
  after it, with `EXIT=0 ERRORS=0`.
* `vt_adaptive:instancer` (the existing instancer test, whose `clear_by_mesh()` call and count assertions
  run through the changed code), `region_streaming` (the streamer's unload path), `region_slots` and
  `vt_monitors`.
* Debug and Release builds clean, zero warnings. All eight code audits green.
* Full suite, now **55 tests** because the new runner is discovered automatically: **42 pass, 13 fail** -
  the same eleven deterministic failures, plus `vt_pressure` and `vt_recovery` from the documented flake
  set. The new test reports `PASS unloaded or removed regions release their instances` inside the suite,
  not only on its own.

## The count that described the wrong LOD

The second entry to leave the left-open list was inherited from the early audits and had never been
verified: "the instance counter doubling when a setting moves the master LOD". It is real, and this time
the test that shows it was written before anything was changed.

### What the counter describes, and why moving it broke

`Terrain3DMeshAsset::get_instance_count()` is the number the asset dock shows and the instancer tests
assert. `_get_master_lod()` decides which LOD it counts: lod 0 for an ordinary asset, `shadow_impostor`
for a shadows-only one. The counter was maintained incrementally, per cell, only where the LOD being
touched was the master *at that moment*:

* `_update_mmi_by_region()` subtracts the replaced multimesh's count and adds the new one when
  `lod == _get_master_lod(ma)`.
* `_destroy_mmi_by_cell()` subtracts when the same test passes.

That cannot follow the master: a LOD's multimesh is created and destroyed while it is *not* the master.
The shadows-only filter skips every LOD but the impostor, so switching a three-LOD asset ON ->
SHADOWS_ONLY -> ON leaves lod 0's multimesh freed while its instances are still in the count, and the
switch back adds a second LOD's worth: **4 placed instances read as 8**.

### The test

`native/tests/terrain_instancer_master_lod.gd` needed an asset with more than one LOD, which a generated
mesh cannot express - it is one card - so the fixture packs a scene whose meshes are named `TreeLOD0..2`,
the naming `set_scene_file()` sorts by. It then asserts the count stays at the number of placed instances
through ON -> SHADOWS_ONLY -> ON and one more move to a different impostor.

Against the unfixed library it reported

    INSTANCER: count is 4 with the master LOD at lod 0
    INSTANCER: count is 4 in shadows-only, master LOD is the impostor
    INSTANCER: count is 8 back with the master LOD at lod 0

and two `REGRESSION:` lines.

### The fix

`_recount_master_lods()` recomputes the counter of every mesh the pass touched from the master LOD's
multimeshes, at the end of both update paths. It replaces transition arithmetic with an invariant: the
count *is* the sum of the master LOD's resident multimeshes, whatever moved and in whatever order -
`_release_orphaned_regions()` (the round before this one) already guarantees the map holds only resident
regions, so the sum is the whole truth. The incremental adjustments stay where they are, because
`clear_by_region()` and `clear_by_mesh()` reach the teardown path outside any update pass; inside a pass
the recount simply overwrites whatever they accumulated.

### Two fixture lessons, and one thing that cannot be a suite test

* The test's first run also reported `3 RID allocations of type '...Mesh' were leaked at exit` and three
  `Leaked instance dependency` warnings. Isolating it in `bin/perf_probe/scene_file_leak.gd` - the same
  asset and scene file, no instances at all - showed the leak survived, and freeing the *builder* node
  after `pack()` removed every one of them: `packed.pack(root)` serialises the tree and does not take the
  node, so the fixture owned a three-mesh orphan. A one-off engine experiment settled the other
  candidate - `queue_free()` on a node outside the tree does free it - so `set_scene_file()`'s
  `node->queue_free()` is not at fault.
* The next defect on the list, the unguarded `get_mesh_asset()` dereference on a null `mesh_list` slot,
  **cannot be covered by a test in this suite**. A null slot is a state the library makes itself
  (`_set_asset_list()` logs `Asset ID: i is null` and skips the entry), but `update_mesh_list()` logs
  `Null Terrain3DMeshAsset found at index N` at ERROR level for the same state, and the harness fails any
  run whose log contains `ERROR:`. A test that drives the crash would therefore fail for the log line even
  after the crash is fixed. It stays on the list with that reason recorded, which is more useful than a
  test that can never pass.

### How it was verified

* The new test: red before the fix (count 8 and two `REGRESSION:` lines), green after it, with
  `EXIT=0 ERRORS=0` - the leak lines are gone with the fixture fix.
* `vt_adaptive:instancer` - the existing instancer test asserts exact counts (36, 35, 0) through
  `add_transforms()`, `remove_instances()` and `clear_by_mesh()`, so it is the regression oracle for this
  change - plus `terrain_instancer_release`, `region_slots`, `vt_monitors` and `vt_cells`.
* Debug and Release builds clean, zero warnings. All eight code audits green.
* Full suite, now **56 tests**: **42 pass, 14 fail** - the same eleven deterministic failures, plus
  `vt_compression`, `vt_format` and `vt_pressure` from the documented flake set. Both new instancer tests
  pass inside the suite, not only on their own.

## A demand setting that rebuilt the pool

The third entry to leave the left-open list was also inherited and unverified: "`set_surface_svt_root_mips()`
releasing the pool for a demand-side setting". It is real, and the fix is three lines.

### What the setting is, and what it was doing

`surface_svt_root_mips` decides how many root mips the far field protects. Reading its four users shows it
is purely demand-side: `_update_visible_svt()` clamps a root level by it and **mixes it into the plan
hash** (`scan_hash = mix_i64(scan_hash, _vt.surface_svt_root_mips)`), so a changed count invalidates the
plan by itself; `is_svt_startup_ready()` reads it to gate the material's strict sampling. It appears in no
address, no page size and no atlas dimension.

Its setter nevertheless called `_reset_vt_configuration()`, the function the page-geometry settings use
(`set_vt_page_size()`, `set_vt_page_border()`, `set_vt_page_count()`, a compression change), which:

* clears `_vt.vt_shared_ready`, so the next update rebuilds the shared pool - the pool the *near field*
  also samples, whose pages are then gone;
* sets `_vt.svt_startup_ready = false`;
* cancels a bake in flight with "VT configuration changed; run Bake SVT again", although baked cells are
  indexed by level and this count does not name a level.

Only the middle item is warranted. `set_surface_svt_enabled()` is the precedent for it, a few lines away
in the same file, and it reopens exactly that one flag.

### The test

`native/tests/vt_svt_root_mips.gd` reads `get_vt_settings()["shared_pool"]` *immediately* after each
setter, so no frame can re-establish the pool in between, and asserts **both halves** of the distinction:
`surface_svt_root_mips` leaves the flag alone, `vt_page_size` clears it - a fix that merely stopped
resetting would break the second half, and the test says so. It finishes by letting the pool come back
after the real reconfiguration, so the flag is shown to be transient rather than sticky.

Against the unfixed library, one assertion failed:

    INSTANCER: shared pool is up, page size 256
    ERROR: REGRESSION: a demand-side setting leaves the shared pool alone
    INSTANCER: after surface_svt_root_mips the shared pool is false

### The fix

    if (!_vt.vt_debug_direct_material) { _vt.svt_startup_ready = false; }

The startup flag stays - the root pyramid does have to be proven again - and the pool, the pages and a
bake in flight are left alone. The comment on the setter now records the reasoning and the precedent.

### What the fixture had to learn (again)

The test's first two runs could not attribute anything: the pool was not up at all before the setting, so
every assertion was red for the wrong reason. Two fixture errors, in sequence:

* The service configures its pool only with a camera to demand for, so the fixture needed one.
* **The physics tick is what drives `_update_vt_service()`**, and this fixture had copied the instancer
  tests' `terrain.set_physics_process(false)` to keep things deterministic - which switched the service off
  entirely. The instancer tests can do that because they drive `update_mmis()` by hand; a test about the
  VT service cannot. The fixture now says so in a comment where the call used to be.

That is the fourth time in this pass that the thing to fix was the test's own fixture, and the reason the
first run of each new test is read carefully rather than trusted: a red assertion is only evidence when the
fixture is known green elsewhere.

### How it was verified

* The new test: one red assertion before the fix, `EXIT=0 ERRORS=0` after it.
* `vt_root_coverage`, `vt_root_budget`, `vt_svt_coverage`, `vt_demand`, `vt_surface`, `vt_turn_budget`
  (the frame-budget assertion) and `editor_dock:svt_inspector` all pass. `vt_pressure` - which asserts
  that AVT and SVT share one physical pool, the closest existing oracle for this change - failed once and
  then passed twice on its own, its documented fail-once/pass-once pattern.
* Debug and Release builds clean, zero warnings. All eight code audits green.
* Full suite, now **57 tests**: **45 pass, 12 fail** - the same eleven deterministic failures, plus
  `vt_format` alone from the documented flake set. The new test passes inside the suite, and this is the
  cleanest full run of the pass so far.

## A regression this pass introduced, and the report that found it

The pass has to record its own damage, and this one was not found by the audits or by the suite: it came
back as a user report of a warning flood in a live editor session.

    W 0:00:09:700 VariantUtilityFunctions::push_warning: Terrain3DInstancer#6741:_process_updates:119:
    Errant null region found at: (2147483647, 2147483647)

### What was broken

`Terrain3DInstancer::initialize()` calls `update_mmis()` with its default arguments,
`(-1, V2I_MAX, false)`, which queues the pair `(V2I_MAX, -1)` - "every mesh in every region, without
destroying first". That is also how instances are materialised after a scene loads.

Round 8 of this pass deleted the code that recognises that pair: the `else if` arm in `_process_updates()`,
the guard that skips a sentinel in the pair loop, and the "already set to build all, quit" check in
`update_mmis()`. The reading behind the deletion was in the header: "`<V2I_MAX, -1>` ... nothing ever
queued it - `update_mmis()` writes `(V2I_MAX, -2)` for a rebuild and `(p_region_loc, mesh_id)`
otherwise". The first half is true only of a *rebuild* (`p_rebuild == true`); with the default
`p_rebuild == false` the same function writes exactly that pair.

With the arm gone, the pair fell through to the "all mesh ids for this region" expansion, where
`V2I_MAX` is not a region location: `get_region_ptr()` answered null, one `WARN` was logged **per mesh
id**, and nothing was refreshed at all - so a loaded scene's instances never appeared.

### Why the suite could not see it

`terrain_instancer.gd` does drive that call - `update_mmis(-1, Vector2i(2147483647, 2147483647), true)` -
but it asserts that the *rendered output is unchanged* afterwards, which is trivially true when nothing
happens. A test that asserts "nothing broke" cannot see "nothing ran". `native/tests/README.md` records
the same blind spot under the new test.

### The test, and the fix

`terrain_instancer_refresh.gd` edits a region's stored transforms directly - the state a restored or
hand-edited region is in - and then calls `update_mmis()` with no arguments. The observable is the
instance count, because `_recount_master_lods()` derives it from the resident multimeshes, so a refresh
that never ran leaves the count at the old value:

    INSTANCER: count is 4 after placing four instances
    INSTANCER: count is 8 after update_mmis() with no arguments      <- 4 before the fix

The fix restores the three pieces. The header now says what the pair means and who queues it, and why the
deletion that removed it was wrong; the arm in `_process_updates()` carries the same note. Verified: the
new test red then green, `Errant null region` **0 occurrences** in the fixture log (it was one per mesh id
before), `vt_adaptive:instancer`, `terrain_instancer_release`, `terrain_instancer_master_lod`,
`region_streaming` all pass, Debug and Release builds clean with zero warnings and the audits green.

The lesson is not "check harder": it is that removing a *sentinel* is removing a contract, and a contract
is only unreachable when every caller has been enumerated - `update_mmis()`'s default arguments are one of
those callers, and grepping for the pair itself finds nothing, because the pair is written by a `CLAMP`
and a default.

## The page producer's first half, three ways

`terrain_3d_surface_baker.cpp` was the largest file left at 788 lines, and its own header described three
jobs in one breath: "the ResourceBundle ... and the two shader sources the pipelines are compiled from".

| file | lines | owns |
| --- | --- | --- |
| `terrain_3d_surface_baker.cpp` | 205 | The device and the objects on it: the RenderingDevice lookup, texture and sampler creation, `_ensure_resources()` and the material table upload. |
| `terrain_3d_surface_baker_bundle.cpp` | 398 | The `ResourceBundle`'s lifetime: `_collect_bundle_rids()` (the inventory every path uses), `_create_bundle_resources()`, `_adopt_bundle()`, `_adopt_grown_pages()`, `_free_*()`, `_take_resources()` and `clear()`. |
| `terrain_3d_surface_baker_pipelines.cpp` | 235 | The two GPU programs: the bake pipeline, the block encoder, the GLSL both are concatenated from, and `_rebuild_uniform_set()`. |

The class is six files now, and the three halves it did not split were renumbered with it
("part 2 of 4" became "part 4 of 6" and so on) - the headers are the module map a reader actually meets,
so the script rewrites them and asserts each block it replaces. `terrain_3d_surface_baker_internal.h`
says "the six translation units" and lists the six jobs, which is where a reader looks first.

### Two boundary rules the script had to learn

The split script derives each definition's block by extending it up over its doc comment and trimming
trailing separators, and this file needed two refinements over the version that had split ten files before:

* **A banner's label line is a separator.** The file has `/////` / `// GPU setup` / `/////` between
  sections; the old rule trimmed the rules but stopped on `// GPU setup`, so the previous definition came
  out ending with a banner label. The rule is now a *separator set*: blanks, rules, bare `//` lines, and a
  `// X` line with a rule directly above or below it.
* **A bare `//` is a paragraph break inside a doc block, not its end.** `_adopt_grown_pages()`'s comment
  has a `//` line separating two paragraphs; the walk-up treated it as the boundary and cut the comment in
  half. Accepting any `//` line in the walk-up, and classifying the bare one as a separator, keeps both
  properties.

Neither rule changes any earlier split: each was applied to a file already split, in a script that is
new. Both are recorded here because the technique is reused, and the third refinement will be as small.

### How it was verified

* `bin/perf_probe/split_baker.py` derives the 17 blocks, asserts their order against the ownership table,
  asserts the shader-source block and the two banners by content, and asserts the three halves partition
  the body (the prologue, the banners, the shader sources and blanks are the only non-definition lines).
  `--verify` proves every definition, the shader sources and both banners verbatim in their new files, and
  asserts each renumbered header.
* Debug and Release builds clean on the first attempt, zero warnings - the include set of each half was
  assigned from a per-definition symbol scan (`RDShaderSource`/`RDShaderSPIRV` to the pipelines, `RDSamplerState`/
  `RDTextureFormat`/`RDTextureView` to the device half, `callable_mp` to the bundle) rather than copied
  wholesale, and it was right the first time.
* All eight code audits green.
* Targeted: `vt_auto_bake` (the bake path these files implement), `vt_cells`, `vt_compression` and
  `vt_turn_budget` (the frame-budget assertion) all pass.
* Full suite: SUITE_NUMBER








