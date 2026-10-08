# Terrain integration tests

Build the editor and debug extension using [the native build instructions](../README.md).
Embedded `native/src/shaders/*.glsl` changes also require a native rebuild. GPU tests
need a real RenderingDevice driver; headless import and CPU tests do not verify images.
Run GPU measurements serially, with the same engine, extension, driver and scene for A/B runs.

This guide describes test entry points and their assertions. Recorded timings and past
failures belong to the [historical audit](../../docs/terrain_optimization_audit.md),
[VT budget record](../../docs/vt_frame_budget.md) and [baselines](baselines/).
Use a fresh run's log to establish the status of the current build.

## Full regression

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/run_all.py
python misc/feng-addons/feng-idweight-terrain/native/tests/run_all.py --list
python misc/feng-addons/feng-idweight-terrain/native/tests/compare_runs.py bin/before.json bin/after.json
```

`run_all.py` discovers `*_runner.py` and expands the adaptive and editor-dock modes
listed in its tables. `--list` is the current inventory. Options:

- `--driver vulkan` (default) or `--driver d3d12`
- `--only vt_` selects matching test names; `--timeout SECONDS` sets each runner's limit
- `--json bin/out.json` preserves status, failure markers and fixture paths
- `--keep` retains fixtures; otherwise the suite deletes the reported fixture after each run
- `--prune` / `--prune-only` delete matching disposable fixtures under `bin/`; save evidence first

Each script runner requires exit 0, its matching `PASS` marker and no test/engine
`ERROR:` lines. The shared `ENVIRONMENTAL_ERRORS` exemption covers only
`Failed to read the root certificate store.`. Inspect other errors even when assertions pass.
A driver failure during import is a blocked run. Compare failing markers and work counters
against a same-build baseline; past flakes or an old passing binary do not waive a failure.
Use a separate checkout/build for comparison so the active working tree remains intact.

## Adding a test

`fixture.py` creates a copied addon project under `bin/`, isolates `APPDATA` and
`LOCALAPPDATA`, imports headlessly, then runs the script with a real driver.
Use its common runner rather than copying process/error handling:

```python
from fixture import ROOT, run_script_test

return run_script_test(editor=args.editor, driver=args.driver,
    fixture_prefix="terrain-vtnew-", project_name="VT new tests", log_name="vtnew.log",
    script="vt_new.gd", marker="PASS virtual texture new behaviour")
```

`prefixes` prints additional diagnostic lines; `forbidden` rejects a warning/text;
`extra_scripts` copies dependencies, for example
`extra_scripts=(("vt_render.gd", "vt_render_base.gd"),)`. Shared bases remain
`SceneTree` scripts, and the runner marker must match its selected script.
Register every mode of a multi-mode runner in `run_all.py`.

Fixture conventions:

- Set `surface_vt_feedback = false` explicitly when testing strict missing-page diagnostics
- Disable physics processing after enabling delivery for manually driven demand tests;
  enabling delivery can re-enable the node tick. Stop it before freeing the camera
- Drive frame-based plan refresh through real process/physics frames when testing pose changes
- The coarse AVT owner is `Vector2i(INT32_MIN, INT32_MIN)`; its levels are mips of one owner
- Commit page-table changes before GPU readback
- Assert observable work as well as unchanged output, so a no-op cannot satisfy a refresh test
- Error-injection tests must account for the harness's fatal-error policy explicitly

## Editor helpers without the native extension

```sh
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_vt_helpers_runner.py --editor /path/to/feng-godot
```

Checks unavailable-native fallbacks, one resident-page snapshot per read, material-preview
filtering and repeated directory-picker opening. Runs in an isolated headless editor;
no terrain native library or graphics driver is required.

## Stopped TAA camera regression

`python misc/feng-addons/feng-idweight-terrain/native/tests/vt_motion_decay_runner.py`
turns a real TAA camera, then renders 400 stationary frames. It requires a nonzero
ordinary turn lead and zero axis-normalization errors as the predictor decays.

## Running one test

Run `texture_layers.gd` from an imported project with the terrain extension:

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path PROJECT --rendering-method frp --rendering-driver d3d12 --resolution 320x240 --script F:/godot/feng-godot/misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers_runner.py --driver d3d12
```

Optional script arguments `-- res://node_3d.tscn OUTPUT_DIRECTORY` select an existing
scene with a `Terrain3D` child, RGBA8 material at ID 0 and RGB8 at ID 1. Changes stay
in memory; PNGs go to the supplied directory or `user://`.
Checks array layers, size/mips, source preservation, empty-layer assignment, painting,
GPU readback, rendered color, undo/redo, owner isolation and slope/debug views.
It covers auto/fixed size, default BC7, uncompressed and HDR-compatible arrays.

## Native/editor state regressions

The full suite also discovers these focused runners:

- `terrain_instancer_release_runner.py`: region removal/unload releases owned instances and RIDs
- `terrain_instancer_master_lod_runner.py`: counts follow the current master LOD through shadow-mode changes
- `terrain_instancer_refresh_runner.py`: default all-region refresh applies changed stored transforms
- `vt_svt_root_mips_runner.py`: demand settings preserve the pool while page-layout settings invalidate it
- `editor_paint_runner.py`: height, control, color and R16 surface operations, undo bytes and density replication

Run a matching subset with `run_all.py --only NAME --driver DRIVER`, or invoke its runner
with `--editor /path/to/godot --driver DRIVER`. `--list` includes additional current
lifecycle, resize, editor helper and contract runners as they are added.

## Graphical editor asset dock

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --driver d3d12
```

Runs a real off-screen editor at widths 900 and 500, exercises Texture Array,
Terrain Maps and Debug Views, and requires its PASS marker and `ERROR_LINES=0`.
The copied fixture excludes compiler sources and stale temporary libraries.

## Editor brush input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test input --driver d3d12
```

Exercises the production editor callback with an oblique camera, an empty first GPU pick,
CPU pick recovery, packed R16 CPU/GPU output, release outside terrain and right-button navigation.
Dock event routing also covers textures/meshes, highlight/edit/clear, visibility and menus.
These are callback/viewport events, not OS mouse-delivery tests.

## New terrain setup and Scene input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test setup --driver d3d12
```

Creates a saved temporary scene, selects a temporary data directory and tests initial terrain,
disabled background, role clicks, mesh selection, painting, Add Region, save/reload,
cancellation and existing-data selection through real Scene event routing.
The fixture uses its own region-size configuration and never edits a user project.

## Region chunk streaming

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_streaming_runner.py --driver d3d12
```

Drives a saved 5×5 grid of 64 m regions through residency and load/unload budgets,
missing-file caching/reset, modified-region protection, save-on-unload, boundary rejection
and data-directory replacement. Unload preserves disk files; changed slots upload one
layer per map type rather than rebuilding every array.

## Region layer slots

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_slots_runner.py --driver d3d12
```

Renders distinct materials before and after a region swap. Requires stable unaffected slots,
four layer uploads and zero array reallocations, matching directory/layer-location tables,
and rendering at `(40, -40)`. The fixture writes three PNGs.

## Virtual texture runtime

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_runtime_runner.py --driver d3d12
```

Uses GPU readback on a 32-texel/8-slot/64²-table fixture to check page contents,
indirection, invalidation, LRU/protection, allocation alignment, re-registration,
mip-chain bounds and block release. Call `commit()` before inspecting GPU mappings.

## Surface virtual texture page production

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_surface_runner.py --driver d3d12
```

Tests the legacy raw-ID diagnostic path with distinguishable source texels, mip-0 crops,
mip-1 downsampling and neighbor-sourced borders. Checks the distance rule and settled
zero-production/zero-table-upload behavior. Size the pool for every page the test inspects.

## Surface virtual texture render integration

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_render_runner.py --driver d3d12
```

Compares direct arrays, raw-ID VT, deliberately blanked physical pages and restored direct
rendering. Equal reference pixels establish addressing; changed poisoned pages establish
that the shader consumed the atlas. Three PNGs are retained by the individual runner.

## Surface virtual texture GPU page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_feedback_runner.py --driver d3d12
```

Checks the optional projection compute pass against an independent CPU rule for all
9,216 cells of a 96² grid, including behind/offscreen/small-page sentinels and deferred
readback. Local-device ordering is `dispatch() → request_readback() → sync()`.
This is projected-page feedback for the legacy region mode, not fragment-authored demand.

## Surface virtual texture per-page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_demand_runner.py --driver d3d12
```

Checks projection-window wiring, exact requested mip entries, behind-camera culling,
page payloads, settled zero work and the forced-mip path with feedback disabled.
The fixture requires multiple levels inside a sector and at least one culled page.
`surface_vt_feedback_min_extent` is measured in pixels; use the configured 320×240 viewport.
This suite explicitly selects the raw-ID diagnostic path, whose source fallback differs
from the production material-cache miss policy.

## Surface density

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_density_runner.py --driver d3d12
```

Checks payload size `(region_size × density)²` versus the coarse array layer,
whole-block brush writes, nearest 4→1→4 resampling, legacy-file migration, disk round-trip,
dense page crops and rendered differences. A block-uniform round-trip must be byte exact.

## Far-field sparse virtual texture

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_sparse_runner.py --driver d3d12
```

Checks world pages spanning regions, neighbor borders, distance mips, protected root
coverage, invalidation, array-free rendering and the direct-array safety gate.
This suite selects raw-ID diagnostics. Budget for visible pages and protected roots.

## Far-field root pyramid coverage

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_root_coverage_runner.py --driver vulkan
```

Checks whole-domain root coverage, level-window coarsening under a protection budget,
ready content and settled zero requeues. Reports `svt_root_coverage`, `svt_root_passes`
and `svt_root_skips`. Published mappings whose content is missing must be retried.

## A lost page under a still view

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_recovery_runner.py --driver d3d12
```

Settles a stationary sector plan, clears one slot's producer readiness with
`debug_lose_vt_page_readiness(slot)`, then requires bounded recovery for BC7 and raw pages.
`idle_ready_lost` distinguishes readiness loss from ordinary plan changes.

## Compressed material page arrays

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_compressed_render_runner.py --driver vulkan
```

Compares raw/BC7/BC3 in both tiers, per-channel rendered error, producer rate and idle
zero re-encoding. `vt_codec_colors.gd` separately decodes stored blocks.
Albedo is sRGB; normals/parameters are linear. Source texture-array codecs and VT page
codecs are separate settings. Native GPU-copy and asynchronous readback fallback paths
have different latency; inspect `encode_readbacks` and readiness counters.
The ring's admitted and allocated depths are distinct: use `encode_ring_capacity`,
`encode_ring_allocated`, `encode_ring_pages` and the material-memory report.

## What a settled view costs

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_idle_cost_runner.py --driver vulkan
```

Settles for 400 ticks, then measures 150 ticks. Requires no produced pages and all
measurements classified idle. Compares per-phase means with declared budgets; record
resident counts, source readiness and build identity with timing results.

## What a moving view costs, per phase

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_turn_budget_runner.py --driver vulkan
```

Sweeps warm, slow, far-only and cold-pool configurations and reports phase mean/peak,
work counters and the worst-pass snapshot. Compare `avt_peak_stats` with the live report
and the SVT worst-pass age; a historical maximum is not the current sweep's cost.
`vt_frame_budget_ms` is a soft per-phase budget. Measure debug/release independently,
and use matched machine load; elapsed CPU time includes scheduling and lock waits.
Historical numbers and rejected experiments are in the budget/reference records.

## The near field's page budget, and the movement that raises it

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_page_budget_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_project_lifetime_probe.py --project F:/godot/project/test-1 --motion snap
```

Checks default/max batch clamps, ordering, serialization and the constant-budget case.
The project snap probe's `VT_AVT_TIMELINE` connects motion, chosen tier, allowance and
actual submitted batch. Capture arrival latency separately from timing: per-frame
readbacks alter frame cost. Larger peak budgets also enlarge staging/ring allocations.

## A page arrival is a ramp, not a step

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_page_fade_runner.py --driver vulkan
```

Checks disabled, short and long arrival ramps, monotonic intermediate image samples and
identical settled endpoints. `vt_page_fade_frames` counts ticks, not displayed frames.
Use a narrow orthographic view, adequate source density and enough pool capacity for a
parent chain. Each measurement creates a fresh scene.
`debug_invalidate_vt_page()` removes shader-visible content;
`debug_lose_vt_page_readiness()` changes producer readiness for recovery tests.
Memory reports include staging, compressed copies, tier occupancy and in-flight encoding.

## Terrain monitors and profiler zones

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_monitors_runner.py --driver d3d12
```

Checks `terrain/` monitors, millisecond/byte/count types, live readings, separate names
for a second terrain and withdrawal on exit/deletion. Includes VT phases and render-driven
CDLOD selection/cull/pack/upload zones; `terrain/cdlod_cpu` matches backend `cpu_update_ms`.

## Far-field distance -> mip bands

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_mip_bands_runner.py --driver d3d12
```

Pins band edges, CPU/shader mip agreement, stable settled levels and capacity coarsening
in an eight-slot pool. Empty `surface_svt_mip_distances` uses the automatic distance rule.
`vt_svt_coverage_runner.py` covers persisted-material auto-bake repair across 144 regions.

## Near-field delivered density

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_near_density_runner.py --driver d3d12
```

Measures selected virtual layout, plan mip histogram and ready-page world footprints at
1920×1080, 1.7 m eye height and an 8° downward pitch. Checks near/outer coverage,
complete coarse residency and no settled debt. A moved narrow orthographic view binds a
green finest page against red alternatives to prove that the resident density is sampled.
Pose changes run through real frame callbacks so the plan-refresh interval advances.

## AVT material pages and persisted SVT

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_material_runner.py --editor bin/godot.vt-test.exe
```

Runs the real VT Pass on D3D12 with the callback-enabled engine and rebuilt addon.
Covers source-independent cached-material sampling, painting/rebaking, adaptive resize,
offline mip generation, disk reload and SVT-only rendering. The older `vt_surface`,
`vt_render`, `vt_sparse`, `vt_density`, `vt_demand` and `vt_perf` scripts select the
raw-ID diagnostic contract separately.

## Terrain virtual texture addressing contract

```powershell
cd misc/feng-addons/feng-idweight-terrain/native/tests/vt
scons && ./terrain_vt_contract_test.exe
./terrain_vt_request_priority_test.exe
```

Standalone C++ tests need no engine/GPU. They cover mip coordinates, POT atlas alignment,
65,536-leaf capacity, non-overlap/resize rollback, sampled Jacobian bounds, request priority
and the bounded per-slot arrival queue, including replacement, resize and 100,000 churn operations.

## Grazing views and camera cuts

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_anisotropy_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_snap_turn_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_project_lifetime_probe.py --project F:/godot/project/test-1 --motion snap
```

Checks CPU demand and distinct rendered mip colors at grazing, diagonal and rolled angles;
exact forward reversal, obsolete-lead removal, immediate planning and ordinary-turn reuse.
The project probe copies its input project. Snap mode saves sparse post-cut images;
orbit mode also reports whole-viewport GPU and terrain CPU phases.
See [sampling](../../docs/vt_sampling_review.md).

## Texture array codecs

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_compression_runner.py --driver d3d12
```

Uses real GPU upload/readback for every exposed codec, two layers, both arrays,
mips on/off, packed alpha and HDR values above 1. Checks ASTC 8×8 HDR block sizes,
source preservation and actual upload formats. Decoded desktop fallback does not prove
native support on a mobile GPU.

## Strict material VT and incremental SVT

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_strict_coverage_runner.py --project F:/godot/project/test-1
```

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_fallback_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_auto_bake_runner.py
```

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_block_codec_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_bc3_alpha_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_normal_compression_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_snap_turn_runner.py
```

The copied-project coverage test uses 1920×1080, a static view and four yaw/position
changes. After settling it requires zero missing/pending pages and sampled magenta.
`--pages 64` fixes capacity for the pressure case; default preserves the source scene.
JSON/PNG readbacks are diagnostics; use the lifetime probe for timings.

`vt_fallback` tests explicit strict AVT/SVT misses while other sources are available.
`vt_auto_bake` checks the 500 ms debounce, affected-cell updates, distant-file hashes,
idle zero bakes, forced regeneration and second-process loading without authoring textures.
The block/alpha/normal suites use the real encoder and independent engine decompressor,
including signed normals, alpha tail indices, roughness/validity, unified tier formats
and source normal strength above one.

## The delivery matrix and the clipmap ring

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_delivery_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_debug_views_runner.py --driver d3d12
```

`vt_delivery` checks accepted/refused cells, lazy service creation, all-direct shader
specialization, deselection and restoration. Read live services separately from retained
cache objects. Material accepts Direct/AVT/Clipmap/SVT; Height accepts Direct/Clipmap.
`vt_clipmap` tests arithmetic levels, snap, strip updates, a four-texel budget,
CPU/GPU content and explicit diagnostic construction without selecting a delivery cell.
`vt_debug_views` checks native/editor group order, supported dropdowns, rendered previews
and visibility gates. `vt_clipmap_render` verifies height/material sampling, baked layers,
strip preservation and completion identities when a ring moves during queued work.
See [delivery assembly](../../docs/vt_delivery_assembly.md).

## 1024 texels/m clipmap material density acceptance

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_density_runner.py --driver d3d12 --resolution 1920x1080
```

At 1920×1080, a 1.7 m eye and 8° pitch, checks the ground 1.6 m ahead and visible
points within 8 m. Requires the reported target density and hit rate, then repeats after
movement. Poisoned source bindings distinguish direct, coarse and detail material paths.
Tests both Direct and SVT far fields, edits, in-place albedo replacement, material boundaries
and `surface_array_enabled=false`; matched patches use the 0.06 channel-difference threshold.

The companion `vt_clipmap_sharpness_runner.py` selects Clipmap with shipped defaults and
uses `sample_vt_detail()` for point-wise coverage rather than a focus-only summary.
It checks at least 1024 texels/m at the probe and detail-layer coverage of every visible
near point at 128 texels/m or higher, before/after movement, and saves on/off patches.
The [2026-09-23 baseline](baselines/clipmap-material-baseline-2026-09-23.md) records
pre-fix failures; it is not the expected result of the current implementation.
