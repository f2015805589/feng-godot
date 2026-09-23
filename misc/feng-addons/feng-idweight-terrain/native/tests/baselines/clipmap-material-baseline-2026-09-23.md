# Clipmap material baseline — 2026-09-23 (worktree `auto-density-tests`)

Pre-fix baseline for the 1024 texels/m clipmap-material acceptance test
(`native/tests/vt_clipmap_density.gd` / `vt_clipmap_density_runner.py`), recorded on the
pre-merge binary so the fix's effect can be read against a known state.

* Worktree: `F:\godot\feng-godot-wt-density-tests` (branch `auto-density-tests`)
* Commit: `2dee1c57ec` — "更新" (`2dee1c57ec54380d258a2b5fff38b565cef6bab7`, 2026-09-23 08:24:35 +0800)
* Debug extension: `misc/feng-addons/feng-idweight-terrain/bin/libfeng-idweight-terrain.windows.debug.x86_64.dll`
  (2026-09-23 07:40:09, used as prepared — no rebuild)
* Engine: `bin/godot.windows.editor.x86_64.exe` (2026-09-19 23:53:13)
* Driver: `d3d12`, `--rendering-method frp`, 1920x1080 for the density runner
* All raw logs: `bin/density-baseline-logs/*.txt` (fixtures under `bin/terrain-*`)

## 1. Existing regressions — all green on this binary

Commands (run serially, GPU tests):

```powershell
python misc\feng-addons\feng-idweight-terrain\native\tests\vt_clipmap_render_runner.py --driver d3d12
python misc\feng-addons\feng-idweight-terrain\native\tests\vt_clipmap_runner.py --driver d3d12
python misc\feng-addons\feng-idweight-terrain\native\tests\vt_delivery_runner.py --driver d3d12
```

| runner | result | `ERRORS` | marker |
| --- | --- | --- | --- |
| `vt_clipmap_render` | EXIT=0 | 0 | `PASS clipmap height arm and material arm` |
| `vt_clipmap` | EXIT=0 | 0 | `PASS clipmap ring` |
| `vt_delivery` | EXIT=0 | 0 | `PASS delivery matrix assembly` |

Key numbers, quoted from the logs:

* `vt_clipmap_render`: all eight PASS lines present, including
  `PASS clipmap material bake: the ring serves its own baked layers, and they are the material the pages hold`
  and `PASS clipmap material bake: a strip bake keeps the rest of the level's material in place`.
  Fixture `bin/terrain-vtclipmap-render-d7zyyrk9`.
* `vt_clipmap`: `VT_CLIPMAP_FIRST_FILL ... size=16 levels=1 valid=1 pending=0|produced=256 full=1 upload=1024 layers=1|center=(8.0, 8.0) ring=(0, 0) texel_world=1.000 world_size=16.0`;
  `VT_CLIPMAP_BUDGET budget=4 first=4 total=256 ticks=63 upload=1024 error=0.000000`;
  `VT_CLIPMAP_INCREMENTAL moves=8 strip_error=0.000000 full_error=0.000000 mismatch=0 size=256`;
  `VT_CLIPMAP_INVALIDATE rect=4x4 queued=1 texels=16 produced=16 error=0.000000`.
  Fixture `bin/terrain-vtclipmap-tqrommon`.
* `vt_delivery`: `VT_DELIVERY_MATERIAL_CLIPMAP cells near/material=2 near/height=0 far/material=0 far/height=0 | services avt=false svt=false clipmap=true | objects avt=true svt=true ring=true | shader_arms=true | array_needed=true`;
  `VT_DELIVERY_CLIPMAP_ENTRY ... services ... clipmap=false | objects ... ring=true` (the mechanism's
  own entry builds a ring with no cell selecting it); `VT_DELIVERY_PREVIEW_GATE ... clipmap_computed=3 ring=true`.
  Fixture `bin/terrain-vtdelivery-goasw0jb`.

So the clipmap ring and its material bake are **not** broken in general: with the far field `SVT` up
(the shared producer's bake runs), the material ring's baked layers serve, and `vt_clipmap_render`
measures it. What no existing test measures is the **delivered density** at a gameplay pose — all of
them stop at the ring's source grid (1 texel/m) or a density matched to the far field.

## 2. The new acceptance test — expected failure, and what it says

```powershell
python misc\feng-addons\feng-idweight-terrain\native\tests\vt_clipmap_density_runner.py --driver d3d12 --resolution 1920x1080
```

`RUNNER_EXIT=1`, `EXIT=1 ERRORS=9`, marker absent. All nine `ERROR:` lines are this test's own
`REGRESSION:` assertions — there is **no** engine error, script parse error or interface error.
Fixture `bin/terrain-vtclipmapdensity-r_0_z11a`, log `.../vtclipmapdensity.log`.

### 2.1 The density is the coarse ring's 1 texel/m, never 1024

`CLIPMAP_DENSITY` readings at the probe point (the ground 1.6 m in front of the camera) and over the
visible near field (on-screen ground within 8 m, 55 sample points):

| configuration | requested | delivered | coarse ring | detail | array | hit rate |
| --- | --- | --- | --- | --- | --- | --- |
| A `near/material=Clipmap`, `far/material=Direct`, cold | 0.0 | **0.0** | 0.0 | 0.0 | 1.0 | **0.000** |
| A, after a camera move | 0.0 | **0.0** | 0.0 | 0.0 | 1.0 | **0.000** |
| B `near/material=Clipmap`, `far/material=SVT`, cold | 0.0 | **1.0** | 1.0 | 0.0 | 1.0 | **0.000** |

The assertions that fired:

```
ERROR: REGRESSION: 密度未达标：config_a_cold 目标点 (32.0, 30.4) 的实际采样密度 0.0 texels/m < 1024（粗环 0.0，细层 0.0，区域数组 1.0）
ERROR: REGRESSION: 密度未达标：config_a_cold 可见近场 8 m 内达到 1024 texels/m 的命中率 0.000 < 0.90（55 个采样点）
ERROR: REGRESSION: 密度未达标：config_a_moved 目标点 (35.0, 26.4) 的实际采样密度 0.0 texels/m < 1024（粗环 0.0，细层 0.0，区域数组 1.0）
ERROR: REGRESSION: 密度未达标：config_a_moved 可见近场 8 m 内达到 1024 texels/m 的命中率 0.000 < 0.90（55 个采样点）
ERROR: REGRESSION: 密度未达标：config_b_cold 目标点 (35.0, 26.4) 的实际采样密度 1.0 texels/m < 1024（粗环 1.0，细层 0.0，区域数组 1.0）
ERROR: REGRESSION: 密度未达标：config_b_cold 可见近场 8 m 内达到 1024 texels/m 的命中率 0.000 < 0.90（55 个采样点）
```

`requested=0.0` is itself a finding: the build publishes no requested detail density at all
(`detail_settings applied=[]` — none of `vt_clipmap_detail_enabled`,
`vt_clipmap_material_detail_density`, `vt_clipmap_detail_budget_bytes` … exist in the property
list), and `detail_report()` is empty in both configurations.

### 2.2 Evidence for "the material ring alone does not bake / falls back to the region array"

This is the plan's stage 1 gap, reproduced by the test's configuration A
(`near/material=Clipmap`, `far/material=Direct`, the ring standing alone):

```
CLIPMAP_DENSITY config_a_cold ... baked_levels=0 valid=4 pending_jobs=0 pending_bake=4 ... texture_layers=8
CLIPMAP_DENSITY uniform config_a_cold band=[1, 0] levels=[4, 0] \
    outstanding=[1, 1, 1, 1, 0, 0, ...] center0=(32.0, 32.0) baked_binding=array arm=true \
    delivery=near/material=Clipmap near/height=Direct far/material=Direct far/height=Direct
CLIPMAP_DENSITY source ring=array color=(0.0471, 0.0471, 0.9216, 1.0)
```

Read together: the ring produced **all four levels** (`valid=4`, `pending_jobs=0`) but **nothing
baked them** (`baked_levels=0`, `pending_bake_rects=4`). The shader's own readiness table
(`_clipmap_outstanding_count`) holds a whole-level rect for each of the four levels, so
`clipmap_baked_material()` refuses every fragment and `evaluate_idweight_material()` reads the
region array. The source probe paints the payload fallback blue and the fragment at the probe point
reads **blue** (`source ring=array`) — exactly the "仅材质环时未烘焙、回退区域数组" state the plan's
section 2 records.

Configuration B shows the contrast, and locates the missing half precisely: with the far field
`SVT` up the *shared producer* exists, so the same ring bakes
(`baked_levels=4 pending_bake=0 outstanding=[0, 0, ...]`) and the fragment reads the ring's baked
layers (`source ring=coarse`, the real material colour `(0.8196, 0.7255, 0.1451)`). What is missing
there is not the bake path but the **detail layer**: `detail_enabled=false`, `texture_layers=8`
(four levels x two channels), no `_clipmap_detail_albedo` sampler, and the finest source answering
the point is still the coarse ring's level 0 at **1 texel/m**.

### 2.3 The shader source probe

The probe distinguishes the three sources and its calibration half passes today:

* `source array=array` in both configurations — with the material cell deselected, the payload
  evaluation (region array / SVT page) answers, painted blue `(0.0471, 0.0471, 0.9216)`.
* `source ring=coarse` in configuration B — with the cell selected and the ring baked, the ring's own
  baked layers answer (the real material, neither poison colour).
* `source detail=array` / `source detail=coarse` — the **detail layer never answers**, and the
  assertions fire:
  ```
  ERROR: REGRESSION: 着色器探针的细层读数失败：目标点应读到细层烘焙层，读到 array（细层报告 {  }）
  ERROR: REGRESSION: 着色器探针的细层读数失败：目标点应读到细层烘焙层，读到 coarse（细层报告 {  }）
  ```
  `source ring=array` in configuration A is the stage 1 evidence above (the unbaked ring falls back).

The probe binds the payload albedos (`_texture_array_albedo`, `_surface_material_albedo`,
`_surface_svt_material_albedo`) blue and, on a build that exposes one, `_clipmap_detail_albedo`
green; the readings are taken with the terrain's tick frozen because the far field's page-arrival
fade republishes the material's textures each frame it runs. The coarse baked layers are not
repainted: `_clipmap_baked_albedo` is bound by the addon as the ring's own two-group array, and an
override was measured to sample black and force the fallback (see the note in the script header).

### 2.4 Operations (claim 4)

```
CLIPMAP_DENSITY correctness array_vs_ring=0.000000
CLIPMAP_DENSITY correctness boundary_worst=0.000000
CLIPMAP_DENSITY correctness edit_delta=0.204902
CLIPMAP_DENSITY correctness replace_asset=0 in_place=true color=(0.5804, 0.5804, 0.5804, 1.0)
CLIPMAP_DENSITY correctness array_off_delta=0.000000
ERROR: REGRESSION: 材质替换未传到环的画面：目标点颜色 (0.5804, 0.5804, 0.5804, 1.0) 不是替换后的洋红
```

* The ring and the array render the same material at the probe point and across a material
  boundary, and `surface_array_enabled=false` changes nothing at the probe point (the ring's band
  covers it) — all three pass on this binary.
* A draw edit reaches the screen (`edit_delta=0.204902` > 0.06) — passes.
* **A material replacement does not reach the ring's baked layers** — the patch stays the old grey
  `(0.5804, 0.5804, 0.5804)` after the albedo texture is updated in place. This is the plan's
  stage 3 rule ("材质资产替换使相关烘焙层失效") that is not implemented: the bake is not invalidated
  when the material's albedo changes.

The material replacement is an in-place `ImageTexture.update()` of the asset's albedo, not a
`set_texture_asset()` swap: with the far field up the swap was measured to leave the renderer
without a material uniform set for several frames
(`ERROR: Parameter "uniform_set" is null.` / `ERROR: Uniforms were never supplied for set (0) ...`),
and the harness fails any run whose log carries an engine error. The in-place update keeps the
asset identity and the claim intact.

## 3. Summary for the fix

| plan item | state on this binary | reading |
| --- | --- | --- |
| stage 1: the material ring bakes without a page pool | **missing** | config A: `valid=4`, `baked_levels=0`, `pending_bake_rects=4`, `outstanding=[1,1,1,1,...]`, `source ring=array` |
| stage 2: a 1024 detail layer | **missing** | `detail_settings applied=[]`, `detail_report()={}`, delivered `0.0`–`1.0` texels/m, hit rate `0.000` |
| shader probe distinguishes the three sources | partial | `array` and `coarse` readings proven; the `detail` reading has nothing to read yet |
| stage 3: asset replacement invalidates the bake | **missing** | patched albedo does not reach the ring's baked layers |
| edit / boundary / `surface_array_enabled=false` pictures | pass | `edit_delta=0.204902`; `array_vs_ring=0.000000`; `boundary_worst=0.000000`; `array_off_delta=0.000000` |
| existing regressions | pass | `vt_clipmap_render`, `vt_clipmap`, `vt_delivery` all `EXIT=0 ERRORS=0` |

Not covered / open questions:

* The test's density reading is CPU-side (level reports and the settings report) cross-checked by
  the source probe; there is no direct GPU readback of the fragment's texel spacing, because the
  clipmap's level table is a uniform the material already carries. If a future detail layer
  publishes its residency somewhere other than `get_vt_settings()` (a shape the test accepts as
  `clipmap.material.detail`, a top-level `clipmap_detail` dictionary, or flat `clipmap_detail_*`
  keys), the test reads it without a change.
* The test's `far/material=SVT` configuration reuses the far-field settings from
  `vt_clipmap_render`; the density result does not depend on the far field's own mip selection.
* `correctness_phase` compares ring vs array pictures at 1 texel/m, where equality is expected. Once
  the detail layer answers at 1024 texels/m the same comparison still has to hold: the detail layer
  bakes from the same 1 texel/m payload, so it should not change the material, only its sampling
  density. If the fix makes the detail layer disagree, this is the check that catches it.
