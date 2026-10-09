# Terrain optimization audit: historical evidence

This multi-stage record describes the builds and fixtures named below. It is not a
current source inventory, a current bug list or a fresh validation result. The
[architecture guide](vt_architecture_review.md), [addressing guide](terrain_vt_and_streaming.md)
and [test guide](../native/tests/README.md) own present-day contracts and commands.
The original process narrative has been condensed to decisions, measurements and evidence.

## Scope and decisions

The historical review covered addon-owned native code, GDScript, GLSL, tools and examples,
plus the relevant FRP culling/vertex-override and RenderingDevice interfaces. Vendored
godot-cpp, generated embedded documentation and a complete engine audit were outside scope.
The recorded reading ledger is retained below; it establishes what that review read only.

The work grouped these responsibilities:

- Terrain facade: lifecycle, subsystem wiring, public properties/queries, bindings and monitors
- VT: view addressing, shared physical pool, AVT planning/production, SVT visible/root work,
  source workers, GPU baker, indirection uploads and diagnostics
- Data: stable slots, region lifecycle, map synchronization, editing, persistence and resampling
- Material: shader assembly, GPU bindings, author-resource properties and reflection
- Instancer: owned MMI table, placement data and transfers
- Editor: window state, page rows, bands/CDLOD panels, shared dock/list widgets and cursor visuals

The final ownership map lives in the current architecture document. Historical translation-unit
line counts, mechanical split scripts and successive header rewrites are not API contracts.
Shared helpers were retained only where used; legacy diagnostic/selection modes, manual tools,
serialized fields and third-party algorithms remained part of their own compatibility surface.

The recorded cleanup unified the public VT tier while keeping legacy setters side-effect-free,
centralized codec selection without changing explicit-channel APIs, named the fixed-size plan-key
layout and shared distance threshold, removed a duplicated visibility-bound condition, and added
the priority regression to the default test build. It added no per-frame callbacks, ref-counted
resources, dictionaries, dynamic policy containers or heap-backed policy objects. Current ownership
and compatibility contracts are in the architecture guide; this list describes that historical diff.

## Recorded correctness outcomes

| Area | Outcome and regression |
| --- | --- |
| Indirection | Dirty 16×16 tile uploads coalesced by mip/tile; failed creation/copy retained retry data, with newer CPU tiles winning. Stationary editor redraws continued while uploads remained pending |
| Region streaming | Chebyshev-ring enumeration matched distance/y/x ordering. Failed save-on-unload retained modified data and streamer ownership |
| Surface data | Nearest resampling preserved packed R16 bytes; RF extrema read base-level bytes; VT-only synchronization skipped unnecessary coarse payload creation |
| Geometry | Seven unique grids replaced ten resources; five ordered instance groups and cached transforms preserved vertex/index order, seams, displacement and shadow bounds |
| Instancer release | Teardown used the owned MMI map, including removed/unloaded regions. `terrain_instancer_release` changed from two failures plus an engine MultiMesh leak to a clean run |
| Instance counts | Counts were recomputed from each asset's current master LOD. `terrain_instancer_master_lod` preserved four instances across ON → SHADOWS_ONLY → ON instead of ending at eight |
| Refresh sentinel | The default `update_mmis()` all-region sentinel was restored after a cleanup removed it. `terrain_instancer_refresh` changed stored transforms and required the observable count to update |
| SVT root settings | `vt_svt_root_mips` distinguished demand changes from physical-layout changes: root-count changes retained the pool; page-size changes invalidated it |
| Shader assembly | Direct/editor variants omitted unused VT bindings. Main/bake shaders removed overwritten material-selection work while displacement consumers retained their snippets |
| Editor lifetime | Filtered entries were freed; owned callbacks and picker/UI state followed their resource/host lifetime |

The sentinel regression is an important boundary: default arguments and indirect callers
belong to reachability analysis. Tests for refresh must require a changed derived result,
not only unchanged images. File partitioning and comment-only changes also require parse/build gates.

## Recorded image and performance evidence

All times below are measurements of the named fixture, with their original scope.
They do not establish a general GPU/FPS gain or an all-frame latency bound.

| Fixture / condition | Recorded result |
| --- | --- |
| Final Debug rotation `terrain-vtadaptive-3uywsfyz`, compared with `terrain-vtadaptive-tn_caows` | Page production `[256,0,0,0,0]`; warm CPU updates `[0.312,0.317,0.314,0.265]` ms; warm sampled errors all zero; all five common settled RGBA images pixel-identical; 23 visible draws |
| Same rotation, cold / GPU scope | Initial sampled error 0.161 and 256 prefetch pages; warm viewport GPU 0.132–0.183 ms, excluding a complete frame-wide baker profile |
| Final hilly fixture `terrain-vtadaptive-tiukepau`, compared with `terrain-vtadaptive-xi8kawd0` | All nine common PNGs identical, including moving geometry and vertex-preserving overlap; normal phases 33 visible draws / 225,592 primitives |
| Same hilly sequence | AVT 0.715 ms, restored AVT 0.884 ms, Direct 0.838 ms viewport GPU. Sequential shader/order sensitivity prevents attributing these differences as a speedup |
| Vertex-preserving overlap instrument | 41 diagnostic draws with the same primitive count; histogram 0/1/2/3/4 layers = 323,700 / 500,436 / 90,534 / 6,907 / 23 pixels |
| Large-world fixture `terrain-vtadaptive-uhtyusxb` | 10.24 km / 25,600 sectors; moving whole-visible AVT plan about 22.10 ms, stationary 0.253 ms; bounded-radius AVT+SVT case about 0.783 ms |
| Release fixture `terrain-vtadaptive-io92ael5` | Warm CPU `[0.318,0.297,0.297,0.273]` ms; viewport GPU `[0.161,0.170,0.168,0.183]` ms; 23 draws, zero sampled warm errors |

The overlap instrument disables depth and preserves terrain vertex deformation. It measures
potential front-face overlap, not actual opaque fragments surviving early-Z. The built-in
FRP overdraw override cannot substitute for displaced-terrain validation.

### Sequential plan-key helper cleanup

The Windows Debug/Release change named the existing plan-key sections and shared one
distance threshold; it retained the sequential writer and added no runtime allocations.
Addressing, 100,000 arrival-queue churn operations, 20,000 Jacobian-bound samples,
priority ordering, format selection, snap/displacement refresh and anisotropic D3D12
sampling passed in the recorded fixtures. The repeated-motion comparison used the
pre-change unified-compression DLL from `terrain-project-lifetime-ke6fwkn0` and a
1920×1080 test-1 copy, with runs serialized.

| Recorded run | VT CPU mean | Viewport GPU mean |
| --- | ---: | ---: |
| First comparison, pre-change → final | 0.739 → 0.754 ms | 0.981 → 0.937 ms |
| Reverse-order intermediate/final vs. old | 0.756 vs. 0.717 ms | 0.803 vs. 0.810 ms |
| Final sequential-writer run | 0.678 ms | 1.015 ms |

The first three runs had per-window object counts `[2728, 3077, 3116, 2987, 3059, 2963]`;
the reverse-order old run differed by 24 objects in one intermediate window and settled
at 2963. The measurements vary and do not establish a general CPU or GPU improvement.
The refreshed snap/displacement fixture is `terrain-snap-turn-jr8_wphq`; copied-project
logs use `architecture_perf_*.log`.

The recorded final native Debug/Release builds passed after SVT parent canonicalization.
The subsequent graphical dock fixture `feng-editor-dock-clean-o77sn_ch` passed with zero
errors. Earlier runs that overlapped compilation, timed only `snap()` scheduling, had stale
fixtures or used mismatched shader-switch sequences were excluded from performance conclusions.

## Historical suite snapshots

The following tables preserve the original run sequence. Pass totals and known-failure
labels are historical observations; every current failure still needs a current diagnosis.
The budget table reports phase means in milliseconds, not guaranteed peak bounds.

### The full suite on this machine

| failing | note |
| --- | --- |
| `vt_adaptive`: scale, metric, ownership, filtering, navigation, blend, sectors | The seven the handover plan already records as red on the previous machine, all in the adaptive/ownership cluster. |
| `editor_dock:setup` | Recorded as permanently red in that plan's known-fail list. |
| `vt_turn_budget` | The parse error above, not a budget result. Restored, then re-run on its own. |
| `vt_compression` | The plan's documented flake (`a replaced page array must be released`). |
| `vt_visibility`, `vt_material`, `vt_render` | In the previous machine's red set as recorded in the handover plan, though not in the list it repeats in its own §2.3. Re-run on their own and reproduced. |
| `vt_recovery` | Not in either red set. Passed when re-run on its own. |

### Re-running the reds

| test | re-run |
| --- | --- |
| `vt_turn_budget` | **pass**, 16.0 s — the first run of it since `ae8be269b7` |
| `vt_recovery` | **pass**, 10.1 s |
| `vt_compression` | fail, the plan's documented flake |
| `vt_material` | fail, same assertion (`stationary AVT does not rebake unchanged pages`) |
| `vt_render` | fail, same assertion (`disabling the virtual texture should restore the array path`) |
| `vt_visibility` | fail, the same three assertions |

### What the budget test says now

| sweep | service | **avt** | **svt** | topup_or_bake | fade |
| --- | --- | --- | --- | --- | --- |
| warm, 6°/frame | 0.0075 | **0.0750** | **0.0326** | 0.0002 | 0.0160 |
| slow, 1.5°/frame | 0.0080 | **0.0751** | **0.0327** | 0.0002 | 0.0122 |
| far field only | 0.0079 | **0.0010** | **0.0406** | 0.0002 | 0.0007 |
| cold, pool rebuilt | 0.0071 | **0.0650** | **0.0336** | 0.0003 | 0.0135 |

### The suite after the service split

| | |
| --- | --- |
| passing now | `vt_compression` (its documented flake), `vt_format` and `vt_recovery` (both state-dependent, see above). |
| failing now | the same eleven as before — seven `vt_adaptive`, `editor_dock:setup`, `vt_material`, `vt_render`, `vt_visibility` — plus `vt_compressed_render`, which is the uniform-set flake above and passes on a re-run. |

## Validation methods and limits

Use `native/tests/run_all.py --json ...` and `compare_runs.py` for matched before/after
results. Keep engine and extension identities together; compare failure markers and
work counters as well as timing. Run graphics tests serially on a real driver.
`native/check_scripts.py` parses shipped scripts in an isolated engine project;
`native/audit_code.py` and `native/audit_gd.py` check structure, duplicate/dead names,
indentation, comments and declarations. These static checks supplement runtime tests.

The audit's subsequent focused tests included `texture_layers`, `region_slots`,
`region_streaming`, `vt_runtime`, `vt_material`, `vt_cells`, `vt_density`, `vt_format`,
`vt_compression`, `vt_codec_colors`, `vt_compressed_render`, `vt_recovery`,
`vt_svt_coverage`, `vt_pressure`, `vt_demand`, `vt_turn_budget`, adaptive modes and
editor-dock modes. Current invocations and harness error policy are in the test guide.

Remaining limits at the end of the original review included cold-streaming cost,
whole-world moving demand, soft CPU budgets, arbitrary custom shaders and all shadow
configurations, complete Godot 4.5 docking and GPU allocation/copy failure injection.
Runtime SVT I/O was later moved to workers; its earlier synchronous-cost notes describe
that older stage. Optional importer/region-mover, custom material setter and editor
caching findings were separate follow-up candidates, not claims about the present tree.
Conservative bounds and seam geometry were retained.

## Recorded reading ledger

Paths below are the historical ledger, including files later changed or regrouped.

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
- [x] native/src/terrain_3d_surface_views_far_walk.cpp (was terrain_3d_vt_demand.cpp)
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

## Recorded local artifacts

These are original local artifact names, usually under ignored `bin/`; their presence in a
fresh checkout is not guaranteed. They are retained to locate saved evidence.

- `_terrain->get_data()->get_region_locations()`
- `_terrain->get_world_3d()->get_scenario()`
- `bin/`
- `bin/perf_probe/`
- `bin/perf_probe/backup_round*/`
- `bin/perf_probe/check_blank_runs.py`
- `bin/perf_probe/check_editor_literals.py`
- `bin/perf_probe/consolidate_r16.py`
- `bin/perf_probe/dedup_docks.py`
- `bin/perf_probe/normalize_eol.py`
- `bin/perf_probe/removed_code_lines.py <rev> [paths]`
- `bin/perf_probe/repair_halves_line.py`
- `bin/perf_probe/scene_file_leak.gd`
- `bin/perf_probe/split_assets.py`
- `bin/perf_probe/split_baker.py`
- `bin/perf_probe/split_data.py`
- `bin/perf_probe/split_editor.py`
- `bin/perf_probe/split_material.py`
- `bin/perf_probe/split_region.py`
- `bin/perf_probe/split_sector_avt.py`
- `bin/perf_probe/split_surface_baker.py`
- `bin/perf_probe/split_surface_vt.py`
- `bin/perf_probe/split_terrain3d.py`
- `bin/perf_probe/split_vtsvc.py`
- `bin/perf_probe/split_vtview.py`
- `bin/perf_probe/verify_surface_baker_split.py`
- `bin/terrain-after14.json`
- `bin/terrain-after15.json`
- `doc/feng-terrain-frp.md`
- `feng-editor-dock-clean-7_s8v0zo`
- `feng-editor-dock-clean-brcatiw8`
- `feng-editor-dock-clean-lci0bjq4`
- `feng-editor-dock-clean-o77sn_ch`
- `feng-editor-dock-clean-t26na8lg`
- `terrain-slots-115jyu_p`
- `terrain-streaming-7wg17i2g`
- `terrain-streaming-wogxfzu3`
- `terrain-vtadaptive-1j8se9w2`
- `terrain-vtadaptive-1wxzdm16`
- `terrain-vtadaptive-26o5cpq6`
- `terrain-vtadaptive-3a_ffnif`
- `terrain-vtadaptive-3uywsfyz`
- `terrain-vtadaptive-53q2_6tt`
- `terrain-vtadaptive-_mqkur3r`
- `terrain-vtadaptive-buoz7bnw`
- `terrain-vtadaptive-dok7q47i`
- `terrain-vtadaptive-eoz6he3o`
- `terrain-vtadaptive-gez9bvly`
- `terrain-vtadaptive-io92ael5`
- `terrain-vtadaptive-k0q5x7lq`
- `terrain-vtadaptive-k9vu8lyu`
- `terrain-vtadaptive-kyv52ksa`
- `terrain-vtadaptive-lvse_h58`
- `terrain-vtadaptive-lzgg8n07`
- `terrain-vtadaptive-mb_ruuzm`
- `terrain-vtadaptive-ms0l3rvc`
- `terrain-vtadaptive-ozzdgnuz`
- `terrain-vtadaptive-ryp48ex8`
- `terrain-vtadaptive-saeg9je2`
- `terrain-vtadaptive-tiukepau`
- `terrain-vtadaptive-tn_caows`
- `terrain-vtadaptive-u6pl2qpj`
- `terrain-vtadaptive-uhtyusxb`
- `terrain-vtadaptive-ve0kewkb`
- `terrain-vtadaptive-wrb1qygk`
- `terrain-vtadaptive-xi8kawd0`
- `terrain-vtadaptive-xrkfgpiv`
- `terrain-vtadaptive-zkbfx4qy`
- `terrain-vtcells-i_6_7vd9`
- `terrain-vtcells-seiywjts`
- `terrain-vtdens-42rrgbz4`
- `terrain-vtdens-dl7mr_or`
- `terrain-vtmaterial-c8q6cuwp`
- `terrain-vtmaterial-fjgwfatj`
- `terrain-vtmaterial-izfxdif6`
- `terrain-vtroot-76qtko48`
