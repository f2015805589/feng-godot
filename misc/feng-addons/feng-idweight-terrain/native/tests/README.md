# Terrain integration tests

## Stopped TAA camera regression

`python misc/feng-addons/feng-idweight-terrain/native/tests/vt_motion_decay_runner.py`
turns a real terrain camera with TAA enabled, then renders 400 stationary frames.
The native VT turn predictor used to decay into float subnormals: its squared length
lost precision, so dividing the vector by that length supplied a non-unit axis to
`Basis`. The baseline produced 33 axis-normalization errors. Ignoring predicted
turns below 1e-6 radians removes the invalid rotation; the same regression reports
zero errors and verifies that an ordinary turn still produces a nonzero lead.
This is an addon-side numerical fix; the engine's axis validation remains intact.

## Full regression

Every runner, one command:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/run_all.py
```

It builds each test's isolated fixture, prints one `PASS`/`FAIL` line per test
with the runner's own `PASS`/`REGRESSION`/`ERROR:` lines under it, deletes the
fixture afterwards, and ends with a summary table plus
`n/53 passed (driver ...)`. Add `--json bin/out.json` to keep the result for a
before/after comparison, `--only vt_` to run a subset, `--keep` to keep the
fixtures for inspection, and `--prune-only` to delete fixtures leaked by earlier
runs (they are full addon copies, about 27 MB each).

**Discovery has to name a multi-mode runner's modes.** `discover()` picks up every `*_runner.py`,
but a runner that takes a flag per scenario only runs its *default* scenario when it is invoked
without one — and `vt_adaptive_runner.py` is one entry point for fourteen. Running it bare therefore
ran `vt_adaptive.gd` and nothing else, which left thirteen scripts with no way to be run at all:
camera rotation, source blending, 10 km sectors, metric density, region ownership, strict filtering,
async pages, navigation, residency, instancer, CDLOD, profile and full sectors. The suite was 39
tests where it should have been 52. One more was unreachable for a second reason: editor_slider.gd was not among editor_dock_runner.py --test choices and had no marker in its table, so nothing could run it either; both now name it, and the suite is 53. `run_all.py`'s `ADAPTIVE_TESTS` table now lists them, and
`EDITOR_DOCK_TESTS` does the same for the editor dock's seven. `editor_paint.gd` was added later and
brings the suite to 54; it is a plain `*_runner.py`, so `discover()` picks it up directly.
`terrain_instancer_release.gd` was added after that, bringing the suite to 55, and it is also a plain
`*_runner.py`. It is the test for a defect the architecture pass found by reading and could not otherwise
prove: a region that leaves the data keeps its MMIs, so `remove_region(region, true)` and
`unload_region(location, true)` each used to leave a leaked instance and multimesh RID behind. Before the
fix the run reported both `REGRESSION:` lines and the engine reported `1 RID allocations of type
'...MultiMesh' ... leaked at exit`; after it, neither. See "An instance that outlives its region" in
`docs/terrain_optimization_audit.md`.

`terrain_instancer_master_lod.gd` brings the suite to 56 and is the same shape. It packs a three-LOD
scene, because `set_scene_file()` needs `*LOD?` meshes and a generated asset is a single card, and it
asserts the instance counter follows the master LOD across `cast_shadows` ON -> SHADOWS_ONLY -> ON. That
count used to double (4 placed instances read as 8). See "The count that described the wrong LOD".

**A test that asserts "nothing broke" cannot see "nothing ran".** `terrain_instancer.gd` drives
`update_mmis(-1, Vector2i(2147483647, 2147483647), true)` and then requires the rendered output to be
unchanged - which holds when the call does nothing at all. That is how a deleted sentinel arm
(`(V2I_MAX, -1)`, the pair `initialize()` queues to materialise instances after a load) survived a green
suite while logging `Errant null region found at: (2147483647, 2147483647)` once per mesh id in a live
session. `terrain_instancer_refresh.gd` is the missing direction: it edits a region's stored transforms
directly and requires the *instance count* to follow, which is derived state that only a refresh
corrects. See "A regression this pass introduced, and the report that found it" in
`docs/terrain_optimization_audit.md`.

`terrain_instancer_refresh.gd` brings the suite to 58.

**One class of defect cannot be a test here**: the harness fails any run whose log contains `ERROR:`, so a
test cannot drive a path the library itself logs as an error - the null `mesh_list` slot that
`update_mesh_list()` reports at ERROR level is the example, and it stays recorded rather than tested.

`vt_svt_root_mips.gd` brings the suite to 57. It is a *differential* test: it asserts that a demand-side
setting (`surface_svt_root_mips`) leaves `get_vt_settings()["shared_pool"]` alone while a page-footprint
setting (`vt_page_size`) clears it, read immediately after each setter. Its fixture needs two things the
instancer tests deliberately turn off - a camera, and the physics tick that drives `_update_vt_service()`
and thereby configures the pool. See "A demand setting that rebuilt the pool".

**`editor_paint.gd`, and why it exists.** `region_slots.gd`, `texture_layers.gd`, `vt_density.gd` and
`vt_render.gd` all drive `start_operation() → operate() → stop_operation()`, but every one of them
paints with the `TEXTURE` tool only. `Terrain3DEditor::_operate_map()` dispatches on the map type and
writes four different representations — RF height floats, the packed control word, the IdWeight R16
surface bytes, and the RGBA colour map — so those four tests left the height, colour and legacy-control
branches with no headless coverage at all. This test drives all twelve tool/operation pairs the toolbar
can emit, each on its own region, asserts the visible effect of each (an exact height, the set or
cleared control bit, the written material pair), and pins the region's height + control + colour +
surface bytes with an MD5 digest; the digest is what makes it a gate for refactoring rather than just a
smoke test.

Two configurations matter more than the others, and both were found the hard way. `AUTOSHADER + ADD`
proves nothing, because a blank region's control map is `COLOR_CONTROL` and the autoshader bit already
starts set — the phase has to clear it. And a digest at the default `surface_density` of 1 cannot see
the density-replication loop, which is guarded by `density > 1`, so a phase at `surface_density = 2`
reads the painted region texel's whole block back and requires all of it to match.

**Known flakes, with their history in `bin/`.** `vt_pressure` asserts `settings.shared_pool`
and flips on the unmodified binary. `editor_dock:setup` — `Add Region did not expand into empty
space with background disabled` — is recorded as `fail` in `terrain-regression.json`,
`terrain-regression-final.json` and `terrain-avt-after.json`, and as `pass` in
`terrain-avt-final-suite.json` and `terrain-avt-targeted-reruns.json`. Neither is a signal about
a library change; both are worth re-reading from the recorded runs before they are believed.
`vt_compression` joined them once, on 09-17: `a replaced page array must be released once the material
rebinds, got 8` fired on one run and passed on the next run of the same binary (11.5 s, matching its
recorded time), whose only change was the deletion of two unreferenced header aliases. It reads a
refcount one frame early, so a failure of it is worth a re-run before it is believed.

**`vt_turn_budget` is a pre-existing, deterministic failure — and its cost is one phase, not three.**
It has failed in *every* recorded run in `bin/`, from `terrain-regression.json` (09-15 02:51) through
`vt-suite-srgb-idle.json` (09-17 00:49), including runs taken before this pass touched anything. It is
not a flake and not a regression; it is an unmet budget that has been unmet the whole time.
*(Its verdict is superseded in part by "the noise is the scheduler, and the work counters prove it"
below: runs of the same binary with byte-identical work counters measure the near field inside the
budget, so the failure is machine state and not a constant. The history above is what the file
recorded before those counters were read, and its reading that the cold sweep is the real failure
still holds.)*

Read from one run, the four sweeps separate cleanly:

| sweep | `avt` mean | `avt` peak | `svt` mean | `topup`/`bake` mean | fade mean |
| --- | --- | --- | --- | --- | --- |
| warm | 0.1226 | 0.8930 | 0.0272 | 0.0001 | 0.0146 |
| slow | 0.1299 | 0.6350 | 0.0249 | 0.0001 | 0.0146 |
| faronly | 0.0010 | 0.0030 | 0.0425 | 0.0003 | 0.0007 |
| cold | 0.6654 | 2.0760 | 0.0338 | 0.0003 | 0.0145 |

All figures are milliseconds, from the debug template, which runs about 1.5x the release one. So:

* **Only the near field (`avt`) is over budget in steady state.** 0.12–0.13 ms warm/slow is ~0.08–0.09
  in release, which is inside 0.10; the cold sweep at 0.67 ms (≈0.44 release) is the real failure, and
  it is the one a fast camera turn actually hits.
* **`svt` does not exceed 0.1 ms per sweep.** Its means are 0.025–0.043 ms. The alarming number that
  looks like it does — `svt_stats.pass_ms`, 8.0 ms — is the far field's worst pass *since startup*, and
  it is only rewritten when a pass beats the record, so it is byte-identical in all four reports and in
  every run that follows. `svt_worst_frames_ago` is printed beside it for exactly this reason: it reads
  420–901, i.e. the 8 ms pass happened during the settle phase, hundreds of frames before the sweep
  being reported. `report()` now prints that age; without it the number reads as the sweep's cost.
* **`topup` is a reported zero.** The phase was removed and its key kept so consumers do not break, so
  `phases["topup"]` is always 0. It cannot be over any budget. The test prints the column as
  `topup_or_bake = max(topup, bake)` because both phases used to be one number a reader compares against
  the same budget — so a **non-zero value in that column is the far-field bake, never a top-up**: the
  measured column reads 0.0001–0.0003 ms mean and 0.001–0.003 ms peak, and the bake is what holds the
  value up. `vt_topup_ms` is the residual between the far-field pass and the bake, i.e. the cost of the
  phase bookkeeping itself, and it is why the column is a few microseconds and not exactly zero.

Where the cold-turn near-field cost goes, from the same run's `avt_sector_stats`: `produce_ms` 0.637,
`cpu_update_ms` 0.916, `retain_ms` 0.512, against 0.001 for `retain_ms` warm. `_avt_retain_visible()`
early-outs unless the plan was reinstalled or the prefetch switch flipped, so a 500x jump is the plan
changing on every tick, and the stage is then dominated by `_lock_queue()`, the wait for the source
queue's mutex, rather than by its own 250 lookups. The workers are *not* holding that mutex while
assembling payloads — `run()` releases it before `produce()` — so the wait is contention on a queue
being hammered by 154 dispatches, not one long critical section.

The same run also shows the near field never converging even warm: `visible_plan_pages` 249 against
`avt_slots` 128, with `visible_missing_pages` 239, `visible_late_pages` 214 and `visible_late_worst_ms`
2219. The plan is roughly twice the atlas, so half of what the view asks for can never be resident, and
that is why `a settled view kept missing-page diagnostics` (172 pixels) and `a rebuilt pool never
recovered` (269) fail alongside the budget.

**The far field's protection walk is the bounded way in, and it is deliberately uncut today.** The
detail loop in `_update_visible_svt()` carries a comment saying it is *not* cut on the phase deadline,
because visiting a page is what re-marks it as demanded: a page the loop skips keeps its slot but loses
the mark, the pool evicts it, and the next tick pays to request, invalidate and re-queue it. That loop is
what reaches `detail_ms` 6.38 of the 7.98 ms worst pass. The demand mark already has a grace window —
`slot_demand_epoch` protects a slot demanded within one epoch of the current one
(`terrain_3d_virtual_texture.cpp`) — so the amortisation is reachable, but it needs a *resumable* walk
cursor to go with it: widening the grace alone does nothing while the walk still completes every tick,
and cutting the walk without a cursor starves whichever slice sorts last. That is a design change to the
pool's eviction policy and it needs the whole VT suite behind it, so it is recorded here as the next step
rather than attempted blind.

**The plan is sized by the distance rule and the atlas by the page budget, and they do not reconcile.**
This is why the near field never converges, warm or cold, and it is measurable in one run without
reading any planner code:

| sweep | `visible_plan_pages` | `avt_slots` | `visible_missing_pages` | `avt_ready_slots` |
| --- | --- | --- | --- | --- |
| warm | 249 | 128 | 239 | 128 |
| cold | 270 | 624 | 147 | 624 |

The atlas grows 128 → 624 (the cold phase raises `vt_page_border`, which grows `page_count` to 1024
and the near field's share to 624) and the plan barely moves, 249 → 270. So the plan is a function of
`surface_vt_distance` and the sector geometry, the atlas is a function of `vt_pages_per_update` and the
border, and nothing makes the first fit inside the second. At the test's settings — `page_count` 256,
`avt_share = vt_remaining / 2` = 128 slots against a 256 m near radius in a 768 m world — roughly half
of everything the view asks for can never be resident at once.

`_avt_classify_plan()` walks the whole plan every pass: `lookup_page_exact`, `protect_page`,
`_vt_note_page_readiness`, `_vt_page_production_stale` and `pool->mark_demanded()` per entry. That walk
is O(plan), and so is `r_pass.missing`, so the classify/retain/prime stages all inherit the mismatch
directly. A plan bounded by atlas capacity would shrink every one of them at the same time as it made
the resident set able to settle.

It is deliberately **not** changed here, because the three ways out are a product decision and they
trade against each other:

* give the near field more of the pool (the far field uses 27 of its 128 in this scene, so there is
  room) — but the far field's share is what keeps a not-yet-baked far page from being re-requested and
  re-assembled on the main thread, which is the failure the comment above `avt_share` records;
* shorten `surface_vt_distance` so the plan fits — fewer near-field metres, more far field;
* bound the plan to capacity and let the coarse pyramid cover the remainder — the least invasive, and
  the only one that needs no new tuning constant, but it changes which level a fragment falls back to.

Whichever is picked, the settled-view assertions (`a settled view kept missing-page diagnostics`,
`a rebuilt pool never recovered`) are the ones that should start passing, and they are the same failure
the reported flicker is: a view that keeps re-requesting pages it cannot hold shows blocks that never
resolve, however long the fade is.

**And wiring them up exposed a baseline that cannot be compared with.** Six of the modes fail here —
`metric`, `filtering`, `ownership`, `sectors`, `scale` and `blend` — and the obvious reading, that
this pass regressed them, is **wrong**. Three different libraries fail them identically — the recorded
baseline's commit, `HEAD`, and this pass's working tree. Same tests, same runner, same engine, only
the library differs:

| mode | `1f98bf6` library | `HEAD` library | current library |
| --- | --- | --- | --- |
| `metric` | `ready physical page must have exact target texels/metre` | same | same |
| `filtering` | `exercise multiple ready material pages` | same | same |
| `ownership` | `far edge approaches SVT smoothly` | same | same |
| `sectors` | `AVT coverage at negative/positive world coordinate` | same | same |
| `scale` | `moving camera recomputes demand` | same | same |
| `blend` | `AVT matches direct triangle gradient` | same | same |
| `navigation` | assertions pass | assertions pass | assertions pass; the engine prints one `_grab_camera` warning that the runner counts as an error |
| `rotation`, `residency` | pass | pass | pass |

`async-pages`, `cdlod`, `instancer` and `profile` pass with the current library; they were not re-run
against the other two, so the table claims nothing about them.

The baseline those six were compared against — `bin/terrain-avt-supplemental-final-results.json`,
where all ten pass — was recorded at **2026-09-16 23:24** with the repository at `1f98bf645b`. The
timeline around it is the whole explanation:

| when | what |
| --- | --- |
| 2026-09-16 18:03 | `72e12bab69 更新压缩、引擎侧内容` — touches `servers/rendering/rendering_device*` |
| 2026-09-16 19:33 | `1f98bf645b terrain更新` — the commit the baseline was recorded at |
| 2026-09-16 23:24 | the baseline run |
| 2026-09-17 **00:02** | **the engine binary is rebuilt** |
| 2026-09-17 01:12 | `df74a1cbaf 优化` — addon files only, no engine file |

The addon library is not the variable: `df74a1c` touches no engine file, and the *oldest* library
tried (`1f98bf6`) fails exactly what the newest does. The engine binary is: it was rebuilt half an
hour after the baseline was recorded, and the engine's own last change before that touched the
rendering device — where the virtual-texture API the addon is built against lives. The six modes
measure an engine/adapter contract that moved, and **no addon change can move them**; the recorded
results are not a gate for anything built with the current engine.

Building a comparison library is a copy of `native/` in a sibling directory (with `godot-cpp`
junctioned) whose `src/` is written from `git show <commit>:…`, so the working tree is never touched.
That is what distinguishes "the suite never ran this" from "this pass broke it", and it is why the
table above is a measurement rather than a reading of one JSON file.

`bin/terrain-adaptive-baseline.json` is the same thirteen modes re-recorded on the current engine, so
that the next pass has something comparable to diff. Its six failures are the expected state of this
environment, not a target: a diff against it reports **changes**, which is what a gate needs.

Two hypotheses were tested and **eliminated** on the way, both cheap and neither kept:

* that the page-arrival fade leaves the view mid-ramp when these tests take their shot, so that
  "settled" (production stopped, nothing pending) no longer means "showing the pages". Turning the
  fade off from the test side (`terrain.vt_page_fade_frames = 0`, which makes
  `surface_vt_page_fade()` return 1.0 immediately) changed none of the failures; making
  `vt_metric_density`'s and `vt_sectors`' `settle()` wait for `vt_page_fade_active_slots == 0` changed
  none either.
* that the prime-skip policy (`SOURCE_QUEUE_REFILL_ABOVE`) keeps coarse requests out of the queue.
  Setting it to 0 changed none of the failures.

**One real deviation from `HEAD` came out of the bisect**, in the tick's budget split:

```cpp
// HEAD
avt_produced = update_surface_vt(_vt.surface_svt_enabled ? MAX(1, vt_remaining / 2) : vt_remaining);
// this pass, before the fix
const int avt_share = MAX(1, vt_remaining / 2);
```

With the far field disabled the near field is the only consumer of the page budget, and `HEAD` gave it
the whole of it. Losing the conditional halved how many pages a view filled in per tick whenever SVT
was off — which is the configuration four of these six modes run in. The conditional is restored; the
tick's comment now says why it is load-bearing.

To compare two runs:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/compare_runs.py bin/before.json bin/after.json
```

It prints one line per test with both statuses and the failing markers, and
flags the ones whose status changed.

`--driver` defaults to **vulkan**. Use it on any machine where the D3D12 device
is unstable: `CreateResource failed with error 0x887a0005`
(`DXGI_ERROR_DEVICE_REMOVED`) reproduces at the `--headless --editor --import`
step, before any terrain code runs, so it is an environment fault rather than a
regression.

A test only passes when its process exits 0, its required `PASS` marker is
present **and** its log contains no `ERROR:` line at all. That last rule is why
a run can print every assertion as passing and still be reported as a failure:
read the `ERROR:` lines under it.

Comparing runs: keep the `--json` output of the run before your change and diff
the statuses. Several tests are red in this checkout (legacy region-AVT page
production, the setup dock's paint timing, and the far-field page ordering the
`vt_visibility` fixture pins), so the useful signal is a *change* in status or in
the `REGRESSION` text, not the pass count alone. A/B it against `HEAD` before
calling any of them a regression: `git stash push -- misc/feng-addons`, rebuild,
run the same runner, then `git stash pop`. Every red test listed in
`docs/terrain_vt_and_streaming.md` §6 was confirmed to fail identically with the
addon reverted.

## Running one test

Build the debug terrain extension, then run `texture_layers.gd` with this
engine from a project that has the terrain extension installed and imported.
Use a real rendering driver; `--headless` uses dummy textures and cannot test
GPU uploads or the rendered result.

## Adding a test

`fixture.py` owns the shared harness: it copies the addon into a throwaway
project under `bin/`, redirects `APPDATA`/`LOCALAPPDATA` there, and runs the
engine twice (headless import, then a real-driver run of one script). A script
test is a thin wrapper around `fixture.run_script_test()`; only the script, the
log name, the project name and the required `PASS` marker differ:

```python
from fixture import ROOT, run_script_test

def main() -> int:
    ...
    return run_script_test(editor=args.editor, driver=args.driver,
        fixture_prefix="terrain-vtnew-", project_name="VT new tests", log_name="vtnew.log",
        script="vt_new.gd", marker="PASS virtual texture new behaviour")
```

Two rules the harness enforces, both learned the hard way: a test only passes
when the log has **no `ERROR:` line at all** (an engine error fails the run even
if every assertion printed PASS), and a `.gd` that other tests extend must stay a
`SceneTree` script, because the runner writes it into the fixture as
`res://vt_adaptive_base.gd` or `res://vt_render_base.gd` (pass
`extra_scripts=(("vt_render.gd", "vt_render_base.gd"),)` to `run_script_test()`
so the base exists inside the fixture).

Three optional arguments cover the rest of what a runner needs to say:

* `prefixes=("VTSVT",)` prints extra log lines that start with those strings.
* `forbidden=("resident pages were released",)` fails the run when that text
  appears anywhere in the log. This is for a warning that must never be emitted,
  which an assertion inside the script cannot see: the engine writes
  `WARNING:`/`ERROR:` to the process output, not to the script.
* `extra_scripts` copies further test scripts into the fixture, see above.

A runner whose marker never matches the script's `PASS` line can never pass.
`vt_material_runner.py` did that for a while (it ran `vt_render.gd` while
requiring `vt_material.gd`'s marker), which hid four real failures; if a test
fails with "marker missing" but every assertion printed PASS, check that pairing
first.

For example, from the engine checkout on Windows (replace PROJECT):

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path PROJECT --rendering-method frp --rendering-driver d3d12 --resolution 320x240 --script F:/godot/feng-godot/misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd
```

The default test constructs two RGB8/RGBA8 materials. Optional user arguments
`-- res://node_3d.tscn OUTPUT_DIRECTORY` load the same two-material regression
case from an existing scene instead. The scene must contain a child named
`Terrain3D`, with an RGBA8 asset at ID 0 and an RGB8 asset at ID 1. Changes are
made in memory only; the test does not save project scenes or texture assets.

The test checks matching GPU array layers, size/mipmap conversion, original
asset preservation, adding an empty third layer and assigning its texture,
brush CPU writes and GPU readback, red-to-green rendered output, and undo/redo.
Before/after PNGs are saved in OUTPUT_DIRECTORY (default: `user://`).

It is normally run through its runner, which builds an isolated copied addon fixture and
rejects engine errors even if the script prints PASS:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers_runner.py --driver d3d12
```

Each terrain manages its own array settings. Defaults are auto size, mipmaps
and BC7. Tests also exercise uncompressed storage, fixed resolution, disabling
mipmaps, owner isolation, slope mixing on a ramp, and height/ID/weight/slope views.
HDR sources support uncompressed, BC6H, and HDR ASTC arrays. Originals are never modified.

## Graphical editor asset dock

After building the editor and the debug terrain extension, run the asset-dock
layout and menu regression with a real graphics driver:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --driver d3d12
```

The runner creates a disposable copied addon fixture under `bin/`, excluding
compiler sources and stale temporary DLLs. It launches the graphical editor
off-screen with `--rendering-method frp` (without `--headless`), measures the
real dock at widths 900 and 500, and exercises Texture Array, Terrain Maps,
and all five Debug Views menu actions. The command succeeds only when the log
reports `ERROR_LINES=0` and `PASS graphical Terrain3D asset dock layout and
management menu actions`; the absolute fixture log path is printed in the
result.

## Editor brush input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test input --driver d3d12
```

This graphical FRP test sends mouse-button events through the production
terrain editor callback with an oblique camera. It requires an empty first
GPU pick, then checks that the same press paints overlay ID 1 through the CPU
fallback, verifies the packed R16 map on CPU and GPU, and checks release
outside the terrain and right-button navigation. It exercises the input
callback directly; it does not simulate OS mouse delivery.

The dock regression also routes mouse motion, press, and release through the
editor viewport for Textures/Meshes, asset highlight/edit/clear, mesh visibility,
and opening the Terrain menu. Icon clicks must not bubble into tile selection
and rebuild the clicked button before release.

## New terrain setup and Scene input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test setup --driver d3d12
```

Creates an empty saved scene, verifies the folder chooser, chooses a temporary
data directory, and checks the initial 64x64 region and disabled background.
Texture-role clicks, mesh selection, painting, and Add Region are delivered
through Input.parse_input_event and the actual Scene editor event routing.
The test also saves/reloads regions and checks cancellation and existing data
folders. It never edits a user project.

## Region chunk streaming

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_streaming_runner.py --driver d3d12
```

Build the debug extension first. The runner uses an isolated copied addon and a real
graphics driver, saves a 5x5 grid of 64 m regions to a temporary data directory, drops
them from memory and then drives `Terrain3DStreamer` around it. It checks ring residency,
the per-update load/unload budgets, the missing-file cache (probed once, re-probed only
after `reset_missing()`), modified-region protection, save-on-unload, that unloading never
deletes a file, out-of-bounds rejection, and that a `Terrain3D::set_data_directory()`
rebuild does not leave the streamer on a freed `Terrain3DData`.

Each update touches only the layer slots that changed (see "Region layer slots" below), so
the budgets cost one layer upload per map type rather than a full array rebuild.

## Region layer slots

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_slots_runner.py --driver d3d12
```

Build the debug extension first. Renders a 2x2 grid of 64 m regions, each painted with its own
material, then unloads one region and adds another elsewhere. The re-rendered frame is sampled
per region, which proves the region map, the four texture arrays and the layer -> location
table the shader reads as `_region_locations` all still agree after a swap. `get_map_stats()`
additionally proves the swap reallocated zero texture arrays (`map_create_count == 0`), cost
exactly one layer upload per map (4), and that a region keeps its slot while unrelated regions
come and go. The last phase places a region at (40, -40) — outside the 32x32 grid the shader's
old `uniform int _region_map[1024]` forced — and asserts it renders through the directory
texture. Three PNGs are written to the fixture directory.

## Virtual texture runtime

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_runtime_runner.py --driver d3d12
```

Build the debug extension first. Exercises `Terrain3DVirtualTexture`: the physical page atlas,
the indirection mip chain and the LRU/protected slot allocator, built on the addressing core in
`src/terrain_vt.h`. The atlas is configured small (32 texel pages, 8 physical pages, 64x64
indirection) so every assertion can be checked against **GPU readback** rather than the CPU
mirror: the indirection texel a request published, the invalidation after an eviction, and a
full page-content round trip through the atlas.

It also pins sector block allocation (disjoint, aligned, idempotent re-register), the mip-chain
walk (a coarse page serves the finer pages it covers, and pages past the block edge do not
resolve), LRU eviction order, that protected pages survive and that a fully protected atlas
fails instead of stealing a page, and that `unregister_sector` frees the block.

Note the indirection writes are batched: `request_page()` only marks the CPU chain dirty and
`commit()` uploads it, so anything inspecting GPU state has to commit first.

## Surface virtual texture page production

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_surface_runner.py --driver d3d12
```

Build the debug extension first. Drives `Terrain3D::update_surface_vt()`: the demand pass picks a
mip per sector from its distance to the clipmap target, asks the virtual texture for that mip's
pages, and fills only the ones it actually allocated by resampling the region's surface map.

The region surface maps are filled with a pattern where every texel is distinguishable, so each
page read back from the GPU atlas can be compared texel by texel against an independently
restated version of the crop rule — at mip 0 (a 1:1 crop) and mip 1 (a 2x downsample), border
included. A border texel whose region coordinate falls outside the region belongs to a
neighbouring region, so the expectation is that region's pattern (or material 0 when no region
covers the position) rather than a clamped copy. It also pins the distance rule and that a
settled pass writes no pages and does not re-upload the indirection.

The atlas must be at least `sectors * pages_per_axis^2` pages or the LRU will evict pages the
test is about to look for; the test asserts that sizing up front.

## Surface virtual texture render integration

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_render_runner.py --driver d3d12
```

Build the debug extension first. Renders the same scene three ways — array path, virtual texture
on, and virtual texture on with the four atlas pages covering the probe point blanked — and
checks three things:

* The virtual texture path is **pixel identical** to the region texture array path. The pages
  come from the same surface map, so this catches any addressing slip in the indirection walk,
  the page grid or the border.
* Blanking the atlas pages **changes** the rendered colour. That is what proves the shader is
  reading the physical atlas rather than quietly falling back to the array.
* Turning the toggle back off restores the array path unchanged.

PNGs of all three frames are written to the fixture directory.

Note `src/shaders/*.glsl` are `#include`d into the extension's C++ sources, so a shader edit
needs a rebuild before any test can see it.

## Surface virtual texture GPU page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_feedback_runner.py --driver d3d12
```

Build the debug extension first. Exercises `Terrain3DVTFeedback`: a compute pass on its own local
RenderingDevice that projects every candidate page, measures its screen extent and writes the
local mip that would put about one page texel on one screen pixel into an `R32_UINT` storage
image, read back asynchronously with `texture_get_data_async`.

All 9216 cells of a 96x96 page grid are compared against an independently restated version of the
rule computed in GDScript, so the projection, the off-screen cull and the mip maths are pinned
together. It also checks the readback is genuinely deferred (no result at request time, result
after `sync()`), and that a camera pointing away requests nothing.

Two things to know before changing this code:

* The call order is `dispatch()` -> `request_readback()` -> `sync()`. `texture_get_data_async`
  registers the texture copy as a draw graph node, and a node only runs in `_execute_frame`, so
  the submit has to happen *after* the request. A local device has no frame advance of its own,
  which is why `sync()` is the only place the callback fires.
* The shader writes diagnostic sentinels for each early-out (`0xFFFFFFFE` behind, `0xFFFFFFFD`
  off screen, `0xFFFFFFFC` too small) and the test histograms them. When a run reports nothing
  requested, that histogram says which branch fired.

This pass is consumed by `Terrain3D::update_surface_vt()` when `surface_vt_feedback_enabled`
is on: the mip is then chosen per mip 0 page instead of per sector. See the per-page demand test
below. The readback stalls the frame, so `surface_vt_feedback_interval` (default 4) amortises it
and the demand pass keeps using the last result in between.

## Surface virtual texture per-page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_demand_runner.py --driver d3d12
```

Build the debug extension first. Drives `Terrain3D::update_surface_vt()` with the GPU feedback on
and checks the demand it arrives at, page by page, through the indirection texture:

* The mip the runtime reads for every page matches an independently restated projection rule,
  computed in GDScript through the same window origin the runtime derived. That pins the wiring —
  feedback window origin, page coordinates, level grouping — not just the shader.
* Exactly the demanded pages are resident, each at its own level, and nothing else is. The check
  uses the exact level entry rather than `lookup_page()`, which walks the mip chain and therefore
  cannot tell "this level is resident" from "a finer level covers it".
* A sector behind the camera that is inside both the feedback window and `surface_vt_distance`
  gets no pages at all. A distance rule cannot do that, so this is the check that the cull is
  genuinely honoured rather than treated as a failure.
* Page contents are read back and compared texel by texel, so a resident page filled from the
  wrong region texel still fails.
* A second pass with nothing changed produces nothing, even though the feedback runs again.
* With the feedback off, the forced-mip path still produces its 16 pages per sector.

The test asserts that its own configuration puts at least two levels inside one sector (11 of 25
sectors in the current setup) and culls at least one page, because otherwise it would pass on the
old per-sector rule too.

Two things to know before changing this code:

* `surface_vt_feedback_min_extent` (default 8 px) is the floor below which a page is culled
  instead of requested, and the viewport size comes from the camera's real viewport, so the
  window size matters: the runners pass `--resolution 320x240`.
* A culled page is not a failure. The shader walks mips fine to coarse and falls back to the
  region texture array when no page covers a texel, so a culled page simply renders through the
  array path.

## Surface density

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_density_runner.py --driver d3d12
```

Build the debug extension first. `surface_density` (terrain-wide, 1..8 texels per region texel)
makes the stored surface payload finer than the region texture array, which stays at
`region_size` and only ever carries the block-origin reduction. The test pins:

* the two sizes (`region_size * density` squared for the payload, `region_size` squared for the
  array layer), and that the region adopts the terrain's density;
* that the brush writes whole `density²` blocks and leaves blocks outside the brush untouched;
* that a 4 → 1 → 4 density round trip is **byte exact** for block-uniform data, i.e. resampling
  is a nearest block reduction and not a re-derivation from the legacy control map;
* the `add_region()` migration: a `region_size` squared payload with no density (what a file
  written before `surface_density` existed carries) is resampled to the terrain's density on
  entry and keeps its painted material;
* a real region file round trip at density 4: the payload bytes and the stored density both
  survive save → unload → load;
* that mip 0 pages are 1:1 crops of the dense payload at `page_size == span0`;
* the render: with the array path the probe shows the block-origin material, with the virtual
  texture on it shows the finer material, and the two frames differ. That last check is what
  proves the shader evaluates the idweight cell on the payload's grid — before it did, a denser
  payload rendered identically to density 1.

## Far-field sparse virtual texture

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_sparse_runner.py --driver d3d12
```

Build the debug extension first. The far field is a **world-space** page grid that spans regions,
which is the tier the region-aligned near field cannot express (its mip chain is capped at "one
page = one region"). The test pins:

* world addressing: a page is a fixed world square, and a page may span several regions;
* page content texel by texel, border included: a border texel must read the **neighbouring**
  region's payload, not a clamped copy of this page's own edge (a producer property — the shader
  point-samples corners and never reads the border today);
* the world-space mip chain: the page under the camera is published at mip 0 while a page about
  185 m away is published at mip 1, and that page holds no mip 0 entry (the bands are measured
  from the camera, which is the reference the shader uses);
* the root pyramid: every texel of the coarsest `surface_svt_root_mips` levels is resident and
  protected, and a page 6.4 km away (far outside the 256 m distance window) resolves through it;
* invalidating a region's pages re-produces them from the payload and restores the frame;
* array-free mode (`surface_array_enabled = false`): the frame stays **pixel identical** to the
  array-backed one, the array layers hold no payload, and an edit still reaches the screen
  because `invalidate_surface_pages()` drops the pages that carry it;
* the safety gate: with both virtual texture tiers off the array must carry the channel again,
  or every texel would render as material 0.

Root pages are protected because they are the fallback of last resort: if one is evicted, a miss
has nothing to show. Size `surface_svt_page_count` for the distance window **plus** the root
pyramid, or the LRU will evict the near pages the test is about to look for.

## Far-field root pyramid coverage

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_root_coverage_runner.py --driver vulkan
```

The pyramid has to answer *any* world position the shader can address, so its candidate set is the
whole SVT domain, not the visible part of it. At the level the view selects that set is thousands
of pages, and the protection cap used to truncate it in row-major order — every pinned root then
sat in one corner of the map and the fallback answered nowhere near the camera. The level window
now slides coarser until the whole domain fits the budget, and the coarsest level it reaches is
published as the world mip cap so the shader's walk can reach it. The test pins:

* `svt_root_coverage` covers the camera, the visible far field, and both far corners of the domain
  (`surface_svt_page_world * indirection_size`), with the pinned count inside the protection budget;
* the window slide itself: with `surface_svt_max_mip = 3` the planned window starts at 4 and the
  pinned levels are coarser than that;
* every pinned root is reported `ready` by the producer, so the fallback has content and not just
  an indirection entry;
* a settled view stops producing: `svt_requeues` does not grow over 60 further passes, and
  `svt_root_skips` stays far ahead of `svt_root_passes`.

Demand treats a published page with no content as a miss (`Terrain3D::_vt_page_production_stale`):
the indirection entry survives an invalidation, so a production that was dropped, refused, or lost
to a failed cell copy used to be sampled as an empty layer for the rest of the session — the far
field that loads on one run and not the next. A page is re-produced at most once every
`SVT_PAGE_RETRY_FRAMES` (30) frames while it stays empty.

## A lost page under a still view

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_recovery_runner.py --driver d3d12
```

The near field reuses its last plan while the camera does not move and the pool's residency is
unchanged, which is what keeps a settled view free of main-thread work. That shortcut used to infer
completeness from "the last pass produced nothing and listed nothing as missing", so a page whose
content was lost after that point kept its indirection entry over an empty layer *and* kept being
reported as part of a complete plan: the retry window was never reached, and the hole stayed until
the camera moved or the pool's residency changed for an unrelated reason. That is the difference
between "the hole filled in while I stood still" and "it never filled in".

The shortcut now verifies with the producer that every page it is about to call resident is still
ready, and classifies for real when one is not; `avt_sector_stats["idle_ready_lost"]` reports how
many pages that was. The test drives the sector planner with a camera that never moves, waits for
the view to settle (`plan_reused`, `visible_missing_pages == 0`, something resident), then calls
`debug_lose_vt_page_readiness(slot)` — which clears one ready page's content and nothing else, the
state a failed encode leaves behind — and requires the page to be ready again within a bounded
number of ticks, once per codec (BC7 and uncompressed). Before the fix the page never came back
(`recovered_ticks = -1` over 240 ticks) and the pass kept reporting `missing=0`; it now recovers in
~23 ticks in both.

## Compressed material page arrays

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_compressed_render_runner.py --driver vulkan
```

`surface_vt_compression` (AVT) and `surface_svt_compression` (SVT) decide the storage format of the
material page arrays, one setting per tier, over the one shared physical pool. They are separate
because the two tiers produce at very different rates: an AVT page is rewritten by every edit that
invalidates it, while an SVT page is assembled once from a baked cell and then never rewritten, so
compressing the far field is paid once and the memory is saved for the rest of the session. The
inspector shows both as `Compression` inside their `AVT` / `SVT` groups; `vt_atlas_compression`
remains as the near field's pre-split name.

Compression runs on the GPU. A compressed format cannot be a storage image, so a produced page is
encoded by the compute pass in `shaders/bc_encode.glsl`: it reads the RGBA16F staging layer through
a sampler and writes that layer's block words into one region per channel of a ring buffer, and
those blocks are copied into the tier's sampling array — by the engine-side
`texture_copy_from_buffer` in the same submission, so the page is resident in the frame it was
produced in, or by the `.buffer_get_data_async` + `texture_update` fallback on an engine without
that method. Either way the CPU never runs a block encoder, so the per-frame page budget stays at
the caller's setting.

Only the codecs that shader implements *and* that keep the alpha the shader reads can store a page,
which leaves three settings and no more: Uncompressed, BC7 and BC3 RGBA. The asset inspector's
`texture_array_compression` is the longer, CPU-encoder list — BC1, BC4, BC5, BC6H, ETC2, EAC and
ASTC included — and the two are deliberately separate lists. A value is translated rather than
reinterpreted by position: 1 is BC7 in both, 2 is BC3 here and BC1 RGB there while 3 is BC3 there
(both mean BC3, since a page cannot be stored in BC1 at all), and every other entry resolves to
uncompressed, which is what it resolved to while the settings still listed it.
`vt_compression.gd` pins that list and the translation; a page codec this device refuses is
reported with its reason.

**A page's colour is stored in sRGB.** The albedo array is the codec's sRGB format and the encoder
writes the sRGB encoding of the staging texel for that channel (the normal and parameter pages stay
linear — they are not colours). Both colour channels of a BC1/BC3 endpoint are five bits wide, so in
linear space they step by `8/255` and a channel below that has no representation other than zero:
the linear value of an authored dark colour is its sRGB value raised to roughly 2.2, so a blue
authored at `0.04` is `0.003` linear and collapsed to black. BC3 pages therefore changed hue — the
blue channel of the test's patch moved by `0.047`, the whole of it — while BC7 only lost `0.013`.
The renderer samples an array through its sRGB view only when the shader uniform carries the
`source_color` hint, so `_surface_material_albedo` and `_surface_svt_material_albedo` are declared
with it; a tier left uncompressed is bound the RGBA16F staging array, which has no sRGB twin, so the
hint costs nothing there. `vt_compressed_render.gd` now compares the rendered patch **per channel**
and fails above `0.02` — a luminance-only comparison saw a seventh of the blue error and passed it.

`vt_codec_colors.gd` is the storage-level companion: it reads a page back out of the arrays and
decodes it, so a codec that writes the wrong channel order is visible per texel without a renderer
in the way. It runs in seconds and needs no screenshots.

The ring depth is derived from the page budget, not fixed: a page holds its regions until its
readbacks land, about two frames later, so the ring admits `page_budget × 2` (8 to 64, bounded by
a byte ceiling and by half the slot count). With the earlier fixed depth of eight under a sixteen
page budget the ring was the page rate — four ready pages per frame, eight every two frames — and
the surplus queued in `pending`. `encode_ring_capacity` / `encode_ring_allocated` / `encode_ring_pages`
report the admitted depth, the allocated depth and the regions in flight, and the test asserts the
admitted depth covers the whole budget and that a burst really holds more than the old eight.

The upload has to happen from a recording point: the readback callback runs inside the frame stall,
after the frame's draw graph was ended and immediately before the next one begins, so an upload
issued from there was recorded into the finished graph and discarded — every upload reported
success while the arrays stayed empty and the whole viewport showed the missing-page diagnostic.
The test renders real material through BC7 and BC3 in both tiers (patch means within 0.01 of the
uncompressed frame and every channel within 0.02, no magenta), measures that one demand pass hands
the producer the same number of pages with and without compression, and asserts that a settled far
field stops encoding: with the view still, `encode_requests`, `ready_pages` and `svt_requeues` must
not move, so a produced far-field page is compressed exactly once.

## What a settled view costs

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_idle_cost_runner.py --driver vulkan
```

Every other VT test measures a moving camera, so the cost it reports is production. This one holds
the camera still for 400 ticks until both tiers have produced everything in view, then measures the
next 150 and asserts the phases: the near field, the far field, the top-up and the whole section. It
requires that a settled tick produces nothing (`produced == 0`), that all 150 are recognised as
idle, and that each phase stays under a stated mean budget.

The costs it exists for:

* **The top-up repeated the near field's whole pass.** `_produce_sector_avt_pages()` used to run
  twice per tick — the near field's share, then a `vt_topup` phase with the budget the far field did
  not use. The second call re-derived the same classification, re-retained the same source queue,
  re-primed the same workers and republished the same statistics to buy at most one more page, and on
  a moving view that was about half a millisecond a tick — more than all the page production it paid
  for. The tick now runs the near field once with half the page budget and the far field with
  whatever the near field did not spend, so `vt_topup` exists as a reported phase that is always
  zero. The tiers keep that order: the near field's pass publishes the near-field addressing state
  the material reads, and running the far field first was measured to turn the missing-page
  diagnostic on before the source array had stopped serving the far range (`vt_adaptive`).
* **Readiness was asked one page at a time.** The near field verifies every resident page before it
  calls itself settled, and the far field verifies its protected roots and its chosen detail set;
  each of those asked the producer per slot, which is a mutex per page. Both now ask once for the
  whole set (`count_unready_pages()` / `query_page_readiness()`). The far field's detail loop keeps
  requesting and acting page by page — batching its verification was tried and reverted, because the
  allocator can hand out the slot an earlier request evicted.
* **An idle pass republished constant statistics.** The values a settled pass publishes (nothing
  produced, nothing missing, nothing late) are constants of the settled state, and a String-keyed
  dictionary write per value per frame is the largest thing a still view had left. A run of idle
  ticks now publishes them once.

Measured with 99 resident near pages and 20 protected far roots: near field 0.020 ms, far field
0.033 ms, top-up 0.0001 ms, service 0.005 ms, whole section 0.058 ms per tick (near-field peak
0.045 ms, far-field peak 0.054 ms). The budgets are means (`0.05` / `0.08` / `0.005` / `0.15` ms)
rather than peaks, because a peak on this machine carries engine noise. The per-slot form of the
near-field loop was measured against the batched one at 0.0233 against 0.0214 ms, so on a small
resident set that batch is a shape fix rather than a large win — the single production pass is what
moves the number.

## What a moving view costs, per phase

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_turn_budget_runner.py --driver vulkan
```

`vt_turn_budget.gd` sweeps the camera a full revolution at 6° per frame and reports each phase of the
VT section as a **peak and a mean**, because a phase is what a profiler attributes a peak to and the
mean is what a budget should be argued from. On this machine a peak can be the wall-clock reading of a
phase the main thread was descheduled in, which says nothing about what the phase costs: the near
field's peak and mean differ by 6×. `vt_frame_budget_ms` is re-armed at the start of every phase, so
it bounds one pass rather than the whole section.

**The numbers below are from the debug template, and it measures about 1.5× the release one.** The
same test run against the release library — by pointing a fixture's `windows.debug.x86_64` entry at
`libfeng-idweight-terrain.windows.release.x86_64.dll` — reads:

| phase mean | debug template | release template |
| --- | --- | --- |
| service | 0.0065 | 0.0073 |
| **near field (`vt_avt`)** | **0.122** | **0.080** |
| far field (`vt_svt`) | 0.026 | 0.031 |
| top-up (`vt_topup`) | 0.0002 | 0.0002 |
| page fade (`vt_fade`) | 0.015 | 0.017 |
| whole section | — | 0.645 peak |

So in the template a session ships, every phase averages inside the 0.1 ms budget. The debug numbers
are recorded because they are what the suite reports, and because the debug/release gap is the reason
its mean assertion for the near field cannot pass here. The release run also has no leftover
diagnostic pixels after a warm *or* a cold sweep, where the debug runs leave 172–247 and 269.

**The peak is a scheduling outlier, and the source worker count does not move it.** The obvious
reading — that the near field's 0.7 ms peak is contention with its own page workers — is testable: run
the sweep with one worker instead of four. Measured on the warm sweep, same scene:

| `vt_page_workers` | near-field peak | near-field mean |
| --- | --- | --- |
| 1 | 0.744 ms | 0.116 ms |
| 2 | 0.729 ms | 0.127 ms |
| 4 (default) | 0.691 ms | 0.118 ms |

One worker peaks *no lower* than four, so the peak is not the addon's own threads: it is the main
thread not being on a core for part of one frame, with the engine's render thread and everything else
on the machine for company. `wrapper_ms` says the same from the other side — everything the demand
pass does before the sector planner measures 0.000 ms, so the phase-minus-`cpu_update_ms` gap is not a
call.

**But the peak is also one re-plan tick, and that is not scheduling.** The two are separable because
the peak's own stages are kept in `avt_peak_stats`. A tick that re-plans costs, attributed:

| stage | ms |
| --- | --- |
| planning chain — `scan` + `hierarchy` + `sync` + `publish` + `submit` | 0.126 |
| `classify_ms` + `retain_ms` | 0.036 |
| `prime_ms` + `refill_ms` (the source queue) | 0.15 – 0.27 |
| `upload_ms` + `finish_ms` + `commit_ms` | 0.09 – 0.21 |
| `wrapper_ms` | 0.000 |
| **total** | **0.40 – 0.55** |

That is what `cpu_update_ms` reports from inside the pass (0.44–0.58), and the phase peak is it plus
the scheduler gap above. Most ticks reuse the plan and cost a tenth of it, which is why the *mean* is
0.08 ms with the release library.

So the 0.1 ms budget is met as a mean and **cannot be met by a re-plan tick in one frame**: 0.40 ms of
attributed work is not removable, only movable. Staging the planning chain across frames — the part of
it that *can* be staged is `scan` and `hierarchy`, because `sync`, `publish` and `submit` have to stay
in one tick or the directory is published before the plan that fills it — would take the tick to about
0.30 ms. Even taking the whole chain and the whole source queue out of the tick leaves the production
and publish stages at 0.09–0.21 ms, at or over the budget. Meeting 0.1 ms per tick therefore means
amortising a re-plan over several frames, which trades page-arrival latency for peak: a decision about
the feature, not an optimisation of it. The mean is the number this phase can be held to.

Measured on the warm sweep (every page the first view needs already resident), before and after:

| phase | before (peak) | after (peak) | after (mean, debug) |
| --- | --- | --- | --- |
| service | 0.010 ms | 0.010 ms | 0.007 ms |
| near field (`vt_avt`) | 1.132 ms | 0.69 ms | **0.122 ms** |
| far field (`vt_svt`) | 0.072 ms | 0.039 ms | 0.028 ms |
| top-up (`vt_topup`) | 0.800 ms | 0.001 ms | 0.0003 ms |
| page fade (`vt_fade`) | — | 0.020 ms | 0.016 ms |
| whole section | 1.616 ms peak / 0.763 ms mean | 0.738 ms peak | — |

The test also sweeps the same revolution at **1.5°/frame** (90°/s, a rate a session actually runs at)
and reports it as `slow`, because `TURN_STEP`'s 6°/frame is a stress: at 2160°/s the plan key changes
on every frame by construction, so that sweep measures the re-plan chain rather than the streaming a
player sees. The slow sweep reads `avt_mean 0.144`, `svt_mean 0.027`, `topup 0.0002` — the near field
is *higher* there, not lower, so the plan-tick rate is not what sets it. It also converges better
(172 leftover diagnostic pixels against 247).

The near field is the one phase still over the 0.1 ms budget, and it is 0.12–0.14 ms by mean — the
peak is an outlier. What is left of it is attributed, not guessed, because the peak's own stages are
kept in `avt_peak_stats` — a peak read from the live `avt_sector_stats` would describe whatever ran
last, which is never the peak:

| near-field stage | ms | note |
| --- | --- | --- |
| planning chain (`scan`/`hierarchy`/`sync`/`publish`/`submit`) | 0.126 | only on a re-plan tick |
| `classify_ms` | 0.023 | the plan's pages against the pool |
| `retain_ms` | 0.016 | |
| `prime_ms` | 0.10 – 0.20 | the source queue's first fill |
| `refill_ms` | 0.05 – 0.07 | its second fill, when the queue is low |
| `upload_ms` + `finish_ms` | 0.14 | publishing, and the pass's own statistics |
| `commit_ms` | 0.043 | |
| `wrapper_ms` | 0.000 | everything around the sector planner |

`wrapper_ms` is there because the difference between the phase a profiler shows and the planner's own
`cpu_update_ms` had no attribution at all. It measured zero, which rules out the three checks
`update_surface_vt()` makes before calling the planner — so the gap is the scheduler, not a call.

**The source queue is where the remaining cost is, and it does not respond to the obvious fixes.** It
was measured four ways, and three of them are recorded here so they are not tried again:

* `prime_insert_ms` does **not scale with the number of inserts**: 4 inserts measured 0.093 ms and 12
  measured 0.191 ms in one run, and the same 12 measured 0.117 in another. So the window is dominated
  by the queue's acquisition and by being scheduled, not by the insert loop.
* **The containers are not it.** Replacing `std::map<Key, Entry>` + `std::set<pair<token, Key>>` with a
  flat `std::vector<Entry>` + a flat FIFO of keys removed both node allocations per insert and
  measured neutral on every phase. It is kept because it is simpler — two flat containers instead of
  two node containers with paired bookkeeping — not because it is faster.
* **A spin-then-block acquisition is not it either.** Spinning 2000 `try_lock` calls before blocking
  was tried against the reading that motivated it and made it no better: the spin does not shorten the
  wait, it *is* the wait, of the same magnitude as the wake latency it was meant to avoid. It was
  removed, and `_lock_queue()` now says so.
* **Fewer workers is not it.** With `vt_page_workers = 1` — one worker instead of four, so no worker
  contention at all — the same seven inserts still measured 0.059 ms (8 µs each).

The honest conclusion is that the remaining gap is now smaller than this machine's measurement noise:
identical code measured `avt_mean` 0.113, 0.115, 0.122, 0.126 and 0.144 across runs while four source
workers, the engine and a shell shared the CPU. Closing it needs a quieter measurement first — the
release template rather than the debug one, or a pinned process — and the two structural candidates
are recorded above the noise floor rather than chased through it: stop sharing one mutex between the
demand pass and the workers' claim/complete path, and stage the planning chain.

**The noise is the scheduler, and the work counters prove it.** `vt_turn_budget` was run nine times
across five revisions of the near field, and *every one* of those runs reports byte-identical work at
the warm report — `sector_ticks` 421, `reuse_ticks` 402, `chain_ticks` 19, `plan_refresh_skips` 108,
`plan_refresh_frames` 7, `requested_physical_pages` 157, `retained_requests` 93, `visible_plan_pages`
64, `refinement_requests_denied` 116 — while the phase means are:

| run | `avt` mean (warm) | `avt` mean (slow) | `avt` mean (cold) | `svt` mean (warm) | `service` mean (warm) |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.1299 | 0.1056 | 0.0873 | 0.0453 | 0.0137 |
| 2 | 0.1142 | 0.0799 | 0.0611 | 0.0450 | 0.0126 |
| 3 | 0.0863 | 0.0774 | 0.0657 | 0.0379 | 0.0098 |
| 4 | 0.0874 | 0.0801 | 0.0619 | 0.0372 | 0.0096 |
| 5 | 0.1432 | 0.0833 | 0.0691 | 0.0517 | 0.0150 |
| 6 | 0.1068 | 0.0871 | 0.0808 | 0.0440 | 0.0110 |
| 7 | 0.1189 | 0.0938 | 0.0702 | 0.0436 | 0.0128 |
| 8 | 0.1213 | 0.1275 | 0.0785 | 0.0494 | 0.0143 |
| 9 | 0.0912 | 0.1098 | 0.0739 | 0.0423 | 0.0127 |

The same sweep on the same binary spans 0.0863–0.1432 ms, and the `service` mean — whose entire work
is a few microseconds of cache checks — moves by 46% with it. One 3 ms deschedule inside a 60 frame
sweep is worth 0.05 ms of its mean, which is the whole of the spread. The drift is also monotone
within a session (runs 3–4 were taken an hour before 5–9, and every phase moved up together while
the counters did not), so a run is only comparable to another taken under the same machine state. The
warm and slow sweeps even swap sides: run 8 has the slow one over budget and the warm one at 0.1213,
run 9 the reverse (warm 0.0912, slow 0.1098), with `chain_ticks` 19 and `sector_ticks` 421 in both. A
threshold on either mean is a coin flip on a loaded machine, in both directions, and a red
`vt_turn_budget` is not by itself evidence about the code: read the counters and the stage sums
first.

**The phase's cost was mostly the main thread being descheduled, not work.** `prime` inserts seven
requests and measured 0.14–0.25 ms for it — 20–35 µs per insert — while the same seven inserts cost
0.05 ms once the wake moved out of the pass. The demand pass woke the source workers *inside* the
phase it was being timed in, so the phase read as its own cost when what it actually contained was a
partially descheduled main thread. `Terrain3DPagePipeline::flush_wakes()` is now called when the
producing pass is over, so the workers start against the render rather than against the tick that
submitted their work. Nothing is lost: work submitted this pass cannot be assembled within it, and the
previous pass's work has had a whole frame. Measured effect of that one change on the near field:
peak 0.84 → 0.62 ms, `produce_ms` 0.54 → 0.31, `finish_ms` 0.31 → 0.05, `prime_insert_ms` 0.136 →
0.050, with the painted result unchanged.

Three more things had to be true for the near field to get there, and each is its own regression risk:

* **One production pass per tick.** See above.
* **A phase gets its own deadline.** With one deadline for the whole section, the service check, the
  far field's walk and the near field's planning chain spent it before the near field produced
  anything, so production found it expired on every tick of a moving view, emitted its one-page floor
  and stopped. That is what made a turn refine in blocks: one page every other tick.
* **The far field's detail loop must not be cut by that deadline.** Visiting a detail page is what
  re-marks it as demanded. A page the loop skips keeps its slot but loses the mark, the pool evicts
  it, and the next tick has to re-request, invalidate and re-queue it — and the queue is the
  expensive half, since a far page with no baked cell assembles its source on this thread. Cutting
  this loop measured *worse* on every number (far field 0.092 ms mean and 1.18 ms peak against
  0.037 ms and 0.052 ms). The same is true of the visible-footprint walk, which feeds the far
  field's level window and so its root plan's identity: a walk cut in a different place each tick
  makes the selected level oscillate and the root pyramid is thrown away and rebuilt every tick.
* **A prime leaves a half-full source queue alone** (`SOURCE_QUEUE_REFILL_ABOVE`, applied to both of
  the tick's primes). A queue the workers have not reached yet is not something to re-scan and
  re-insert into, and the decision is made from a lock-free count so it does not cost the queue mutex
  to answer. It measures as neutral on the warm sweep, where the queue is usually shallow by the time
  the pass primes, and it is what keeps a cold pass from re-scanning a queue it just filled.

Still over the phase budget, and where to look next:

* **`prime_ms`** — the source queue's first fill, the largest single stage at 0.125 ms, and the mean is
  where the remaining budget pressure is: 0.114 ms against a 0.1 ms budget. Its own inserts and wakes
  are cheap (`prime_insert_ms` 0.046, `prime_wake_ms` 0.000), so what is left is the queue mutex and
  being scheduled behind the workers that hold it. Fewer workers (`vt_page_workers`) is the lever that
  remains, and the structural fix is to stop sharing one mutex between the demand pass and the
  workers' claim/complete path.
* **The planning chain** (`scan_ms` 0.058 + `hierarchy_ms` 0.037) is 0.095 ms of the re-plan tick.
  Staging it across ticks is the fix, and only the scan and the hierarchy may be staged: `sync` +
  `publish` + `submit` have to stay in one tick, because a directory that has been synced but not
  published sends whole sectors to the missing-page diagnostic. That is what the previous attempt at
  staging got wrong.
* A far-field **root plan rebuild**, attributed by `svt_stats` to `rootreq_ms`: a far page with no
  baked cell crops its source from the density-scaled region data on the main thread (~2 ms for a
  page as coarse as a root). Moving that crop to the source worker is the fix; it is gated by the
  phase deadline in the meantime so a rebuilt pyramid arrives as a ramp instead of one 8 ms hitch.
* A **cold** sweep (a VT settings change destroys the shared pool, so every page in view is produced
  while the camera moves) peaks the near field at ~1.2 ms. That is a reconfiguration — the address
  directory is rebuilt and the material republished — not steady-state streaming, and
  `avt_sector_stats` attributes it (`scan_ms` / `hierarchy_ms` / `sync_ms` / `publish_ms` /
  `material_ms`).

Two variations of the tick's split were tried and both changed behaviour a test pins, so both were
reverted: running the far field *first* flipped `_surface_material_required` on before the source
array had stopped serving the far range (`vt_adaptive` failed its pre-VT baseline), and resizing the
far field's share changed when the far field's startup grace ends. Keeping the tiers in their
original order and deriving the far field's share from the near field's own production count is what
keeps the painted result at the value it had before all of this (`vt_turn_budget`'s settled-view
diagnostic count is 528 before and after, and its isolated-turn count is 906/14 before and after).

## A page arrival is a ramp, not a step

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_page_fade_runner.py --driver vulkan
```

A finer page resolves its texels at full weight the frame its content lands, so the view switches
from the level it replaced to the page itself in one frame — block by block, in the rectangular grid
the pages are. A turning camera makes that obvious, because the working set moves and pages land
continuously. `vt_page_fade_frames` (default 12, 0 disables) makes that switch a ramp: a page that
has just arrived is blended against the coarser level it replaced.

The test drops one resident page's content — the state a lost block encode, a rebuild that discards
a page, or a page re-produced after an edit leaves behind — and counts the ticks the engine publishes
a fading slot for:

| `vt_page_fade_frames` | active ticks | fading slots |
| --- | --- | --- |
| 0 | 0 | 0 |
| 20 | 8 – 16 | published |
| 40 | 23 – 31 | published |

The assertion is on that ordering rather than on the exact count: how many frames one tick is spread
over belongs to the engine's frame pacing, not to the fade. What is pinned is that the fade is absent
when it is off, runs over several frames when it is on, is *longer* when it is asked to be, and
leaves the view exactly where it started. A measurement whose arrival did not happen inside the
observation window at all — the page's re-production is what has to land, and how long that takes
depends on how loaded the machine is — is retried rather than asserted on.

`vt_turn_budget`'s transient counts are the evidence that it is the artifact the complaint was about,
and they were stable across runs before the fade existed:

| `vt_turn_budget` reading | before | with the fade (default 12) |
| --- | --- | --- |
| settled-view diagnostic pixels after a warm turn | 528 | 247 |
| isolated 180° turn, middle/bottom screen bands | 906 / 14 | 627 / 0 |
| diagnostic pixels after a rebuilt pool recovers | 560 | 269 |

The bottom band of the isolated turn — the near field, which is what the camera is looking at —
goes to zero, and the two remaining counts halve.

**The image half is asserted, and what makes it measurable is the camera's orthographic size.** The
test searches a row of thirty-three samples for the one a dropped page's fallback moves most, and
requires: with the fade off, an arrival is a **single step** (0 frames between the two ends); with the
fade on it passes through intermediate frames (5–6 at 20 ticks); and a longer fade spends more of them
(17–19 at 40 ticks). Measured, twice, on the same scene:

| | frames between the ends | fading ticks |
| --- | --- | --- |
| fade off | 0 | 0 |
| fade on, 20 ticks | 5 – 6 | 7 – 9 |
| fade on, 40 ticks | 17 – 19 | 22 – 24 |

The orthographic size decides it, because it decides which mip of a page the shader selects and
therefore whether the page draws anything the source array does not:

| `camera.size` | one screen pixel covers | the page mip vs the array | result |
| --- | --- | --- | --- |
| 192 m | ~0.6 m | averages the checkerboard to nearly what the array draws: 0.0039 in red | not measurable |
| 4 m | ~0.013 m | shows the checkerboard; the level behind differs by 0.15 in red | measured, `sample=18` |

**The shape of the ramp is asserted, not only its ends.** Where each observed frame sits between the
level that was there and the page that arrived is printed, and required to be monotonic and to reach
the page — a ramp that leaves one end and reaches the other in a single frame is a step with extra
bookkeeping, and one that goes backwards is the flicker the feature exists to remove. Measured, two
runs, 20-tick fade:

```
0.067  0.223  0.310  0.399  0.577  0.666  0.889  1.0  1.0 …
0.071  0.262  0.357  0.452  0.643  0.762  0.881  1.0  1.0 …
```

Seven intermediate values, evenly spaced, in order, then the page. (The ramp is set in *ticks* and
sampled in *frames*, and one awaited frame spans about two engine ticks here, which is why a 20-tick
fade resolves in eight samples.)

**Three earlier explanations for this half being unmeasurable were tested and are wrong**, recorded so
they are not re-derived from the source:

* *that a page's mip levels cannot differ here*, because a payload texel is an exact multiple of a page
  texel on aligned grids, so every level resolves the payload texel containing its centre. Raising the
  density until a payload texel *is* one page texel wide, so the level above spans two of them, changes
  which pages the plan holds and still moved no sample.
* *that the fade leaves the view mid-ramp when the shot is taken*, so that "settled" (production
  stopped, nothing pending) no longer means the view is showing the pages. Turning the fade off from
  the test side changed none of the failures.
* *that the sampled row is not virtual-texture resolved at all.* It is — by a four-thousandth, which is
  the whole point: at 192 m across, the two paths agree to within a threshold.

The test also needs the right scene to be measurable at all, and three of its settings are load
bearing: the resolution preset rather than `surface_vt_pages_per_axis` (they set the page count per
axis and the texel density together, and setting one alone leaves the planner's block size disagreeing
with the density), `surface_density` high enough that the stored payload is at page-texel scale, and a
pool large enough for the plan to hold a sector's whole mip chain — the planner leaves 128 pages of
the pool for its retained tail and walks with the rest, so a 128-page pool leaves a 32-page walk,
barely one level per sector, and a dropped page then has no level behind it at all.
`debug_invalidate_vt_page()` is what drops a page's *content*, as opposed to
`debug_lose_vt_page_readiness()`, which drops only the CPU-side readiness the demand pass acts on and
which the shader never sees.

Each measurement builds its own scene. Dropping a page reshapes the pool, so a second measurement in
the same scene does not start from the state the first one did — which is what made an earlier
version of this test pass one configuration and fail the next.

Root pages and detail pages are still assembled on the GPU: a baked cell is a device-to-device
copy. A tier left uncompressed samples the staging arrays directly and costs nothing extra; a
compressed tier adds its own `page_count` layers beside the pool. Once **both** tiers are
compressed nothing samples the staging arrays by slot, so the half-float pool shrinks to the
encoder ring: a produced page writes into a ring layer, the encoder reads that same layer, and the
layer is held until the page's block readbacks arrive. At 256 pages and a 264² stored page that is
~535 MB of resident staging becoming ~67 MB (32 ring layers). A capacity growth then re-produces
the resident pages instead of migrating them, and `export_page()` / the dock preview read a page's
block words and decode them, because the layer it was produced in has been reused.

What the arrays cost is reported, and the per-tier figures are what a codec comparison reads:
`get_vt_settings()` answers `physical_cache_bytes` with the real layout (staging pool plus one
compressed copy per tier that resolved), keeps the old slot-count formula as
`physical_cache_bytes_uncompressed`, and adds `material_staging_bytes` / `material_compressed_bytes`
and `surface_vt_compression_bytes` / `surface_svt_compression_bytes` with each tier's pool
occupancy (`*_slots`, `*_ready_slots`). `get_stats()` reports `staging_layers` / `staging_scratch` /
`staging_bytes` / `compressed_bytes` / `material_bytes` / `avt_bytes` / `svt_bytes`,
`encode_requests` / `encode_readbacks` / `encode_updates` / `encode_failures` and
`encode_ring_pages`, which is how a page that is ready in staging but never reaches the sampled
arrays is told apart from one that was never produced.

## Terrain monitors and profiler zones

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_monitors_runner.py --driver d3d12
```

The node's own cost is published under a `terrain/` keyword, because a GDExtension method is
invisible to the engine's profiler and an unattributed spike cannot be told apart from engine work.
`get_vt_settings()`-style readings become custom monitors — `terrain/vt_cpu`, `terrain/vt_cpu_peak`,
`terrain/avt_cpu`, `terrain/svt_cpu`, `terrain/cdlod_cpu`, `terrain/material_bytes`,
`terrain/pages_ready`, `terrain/pages_pending` — with the monitor types the editor formats as
milliseconds, bytes and counts, and the same phases are emitted as profiler zones and plots while a
profiler client is connected. The zones cover the tick's phases (`terrain/vt`, `terrain/vt_service`,
`terrain/vt_avt`, `terrain/vt_svt`, `terrain/vt_topup`, `terrain/vt_bake`) and the geometry backend,
which the rendering server drives from `frame_pre_draw` instead of from the tick: `terrain/cdlod`,
`terrain/cdlod_select`, `terrain/cdlod_cull`, `terrain/cdlod_pack` and `terrain/cdlod_upload`, with
plots `terrain/cdlod_ms` / `terrain/cdlod_patches` / `terrain/cdlod_visible`. A second terrain in
one scene publishes under `terrain/<instance id>/...` so the plain names never collide, and the
monitors are withdrawn when the node exits the tree and again before it is deleted, because they
hold callables into it. The test checks the names, the types, a live reading — including that
`terrain/cdlod_cpu` is the backend's own `cpu_update_ms` — the two-terrain split and the withdrawal.

## Far-field distance -> mip bands

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_mip_bands_runner.py --driver d3d12
```

The production far field picks a page's level from its distance, through one table that the page
producer (`Terrain3D::get_surface_svt_mip_for_distance`) and the shader
(`surface_svt_mip_for_distance` in `main.glsl`) both read: `surface_svt_mip_distances` holds one
entry per level, in metres, the furthest camera distance that level is sampled at, and an empty
table reproduces the automatic rule exactly (one level per doubling of `surface_svt_page_world`).
The shader starts its walk at that level and only walks coarser, which is what stops the rendered
mip from following page residency — the regression this covers:

* the band edges, including that a band edge belongs to its own level and that distances past the
  last entry keep the coarsest listed level;
* for probes spanning levels 0..3, that the level the shader starts at is the level that was
  produced (the indirection publishes a slot there), so the shader never has to fall back;
* a settled view moves no level and does not keep allocating/evicting, and a small camera move
  that stays inside every band moves no level either;
* an over-subscribed pool (8 slots) raises a coarseness floor rather than rewriting levels:
  every probe still resolves (its own level or a coarser ancestor), the nearest ones first, and
  the pool stops allocating/evicting once the view settles.

`vt_svt_coverage_runner.py` keeps covering the persisted-material side (auto-bake repair of newly
required levels over 144 regions with an eight-slot pool).

## AVT material pages and persisted SVT

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_material_runner.py --editor bin/godot.vt-test.exe
```

Runs the actual VT Pass on D3D12: verifies material-cache sampling independently
of source texture bindings, terrain painting/rebaking, adaptive virtual image
resizing, offline SVT mip generation, disk reload and SVT-only rendering.
Use an engine containing the VT callback registry and rebuild the native addon.
The older `vt_surface`, `vt_render`, `vt_sparse`, `vt_density`, `vt_demand` and
`vt_perf` scripts explicitly select the diagnostic raw ID/weight mode to test
that lower-level contract separately.

## Terrain virtual texture addressing contract

```powershell
cd misc/feng-addons/feng-idweight-terrain/native/tests/vt
scons && ./terrain_vt_contract_test.exe
./terrain_vt_request_priority_test.exe
```

Standalone C++ test for `src/terrain_vt.h`, the shared AVT/SVT addressing core,
and `src/terrain_vt_arrival_queue.h`, the bounded per-slot arrival FIFO. The FIFO
checks include duplicate-slot replacement, pool resizing and 100,000 churn operations.
No engine and no GPU. It pins the indirection mip-chain walk (which level and local
coordinate a request resolves to) and the POT `VirtualImageAtlas` allocator: block
alignment, the full 65,536-leaf capacity, non-overlap, and resize rollback with refill.
The address-profile descriptor tables, page-id packing, LRU key encoding and feedback
dither it used to cover were deleted from the header as unused production code, and
their checks went with them. See `docs/terrain_vt_and_streaming.md` for the design.

## Grazing views and camera cuts

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_anisotropy_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_snap_turn_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_project_lifetime_probe.py --project F:/godot/project/test-1 --motion snap
```

The anisotropy test checks native fine-page demand and distinct rendered mip
colors at grazing, diagonal and rolled angles. The snap test checks exact forward
reversal, obsolete-lead removal, immediate planning and ordinary-turn reuse.
The project probe copies the source project and records sparse post-cut images;
orbit mode also records full-viewport GPU time alongside the terrain CPU phases.
See `docs/vt_sampling_review.md` for the sampling and scheduling contracts.

## Texture array codecs

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_compression_runner.py --driver d3d12
```

Build the editor and debug extension first. This uses an isolated copied addon
and real GPU upload/readback for every exposed compression choice, two layers,
both channel arrays, mipmaps on/off, packed alpha and HDR values above 1.
It checks ASTC 8x8 HDR block sizing, source preservation, and uploaded format,
and rejects engine errors even if the script prints PASS. Unsupported GPU
formats use explicit decoded uploads; this does not test native mobile GPU
support on a desktop adapter. Logs remain in the printed fixture directory.

## Strict material VT and incremental SVT

For the real-project feedback-off coverage regression:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_strict_coverage_runner.py --project F:/godot/project/test-1
```

This copies the project and uses the current addon build. At 1920x1080 it checks
a static view and four yaw/position changes, then requires zero missing, pending
and sampled magenta pixels after settling. JSON traces and PNGs stay in the
temporary fixture. Per-frame readback is diagnostic; use the separate project
lifetime probe for timing comparisons.
Add `--pages 64` to disable automatic capacity in the copied runtime and exercise
the explicit capacity LOD under pressure; the default preserves the scene's pool.

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_fallback_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_auto_bake_runner.py
```

The strict GPU test checks missing SVT with original materials still present,
valid baked SVT output, and a selected AVT miss above otherwise valid SVT.
The automatic bake test checks 500 ms stroke coalescing, affected region/parent
updates, unchanged distant file hashes, zero idle bakes, and forced full regeneration.
A second process then releases authoring texture resources and verifies that it
uploads the saved SVT pages without generating replacements.

Unified page compression and camera-cut regressions:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_block_codec_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_bc3_alpha_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_normal_compression_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_snap_turn_runner.py
```

Run GPU tests serially. The block test dispatches the real encoder and uses the engine's
independent decompressor to check negative normals, BC3 alpha tail indices, independent
color/alpha, roughness and validity. The rendering matrix compares AVT/SVT raw baselines with unified BC7/BC3 compression,
asserts all three physical formats match, and includes normal strength above one.

## The delivery matrix and the clipmap ring

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_delivery_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_debug_views_runner.py --driver d3d12
```

`vt_delivery` is the assembly test: it writes the four (tier, group) cells before a terrain enters
the tree and asserts the configuration owns **nothing** - no view object, no page pool, no material
array, no VT uniform and no shader arm - then takes a live terrain through all-direct, the
undeliverable writes, the mechanism's entry and restored, asserting what each stopped or built. It
reads the live service pointers, the material's own verdict on the shader it generated
(`is_shader_using_vt()`) and the published booleans (`avt_service`/`svt_service`/`clipmap_service`,
`clipmap_ring`, `delivery_supported`/`delivery_unsupported`), never a frame time, because the claim
is about what *exists*. The acceptance rule is the matrix's other half here: `near/height = Clipmap`,
`far/height = AVT` and `far/material = Clipmap` are written in one step and every cell keeps the
method it had, because a method this build cannot deliver for that group is refused rather than
stored (the height channel's choices are `Direct` and the ring; the material channel has no clipmap
source yet).

`vt_clipmap` is the ring's own test, and it **no cell selects anything**: this build refuses
`Clipmap` for the height group, so the ring is built and stepped by
`Terrain3D::debug_update_vt_clipmap()` - the same `Terrain3DClipmap::update()`, focus and budget the
tick's clipmap phase runs - on a one-level ring of 16 texels an axis over 16 m, i.e. one texel a
metre, so every production number is exact. It pins the shape and snap from the level reports, the
strip cost (a one-texel move produces exactly `size` texels of CPU production and one whole-layer
upload; a diagonal produces both bands; a stationary focus produces nothing and is counted idle), the
budget (with `vt_clipmap_budget_texels = 4` one tick produces exactly 4 and queues the job, 63 more
drain the level, and the level uploads once), the content (every texel centre is read back through
`Terrain3D::sample_vt_clipmap()` and compared against `Terrain3DData.get_pixel()` at the same world
position, plus a level built out of eight strips versus the same level rebuilt whole), and the
refusal itself (a terrain whose only `Clipmap` write was refused owns no ring, produces nothing and
answers a sample with `NAN`). See `docs/vt_delivery_assembly.md` section 8.2 for the readings.

`vt_debug_views` is the editor-facing half: the order the matrix is read in (the native `Surface VT`
subgroups straight from `get_property_list()` - `VT Setting` with the delivery matrix first inside
it, then `Clipmap`, `AVT`, `SVT`, `CDLOD`, `VT Page` - and the Surface VT window's own hierarchy),
the dock's four delivery rows (the height row disables `Clipmap`, `AVT` and `SVT`, the
diffuse+normal row disables only `Clipmap`, each with its reason as the tooltip - read from
`is_item_disabled()` rather than from a screenshot), the VT Page's clipmap view **rendered** into a
SubViewport (the pixel counts prove the level strip, the world map and the queued strips' colour are
all drawn; the screenshot is kept as `user://vt_clipmap_debug_view.png`), and the gate on both debug
Controls. The clipmap's gate is the ring *object* (`has_vt_clipmap_ring()`) rather than a matrix
cell, so no ring reports unavailable, hides itself and never calls the native preview, while a ring
the entry built makes the view appear on the same poll - read from
`clipmap_preview_calls`/`..._computed` and `avt_preview_calls`/`..._computed`, which separate an ask
that was refused from one that did the work.

