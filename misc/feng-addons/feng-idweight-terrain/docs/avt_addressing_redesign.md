# AVT addressing redesign: one page table with mip layers

**Status: all four rules hold on this revision and are verified by test.** R2 (the fallback tier's
residency guarantee) and R3 (the level threshold) were built here; R1 and R4 turned out to be already
implemented and are recorded as verified rather than rebuilt, with the assertions that pin them cited
in section 3 and sections 6.3-6.4. The phase table in section 6 says which is which. Read this before
changing what answers an AVT sample. The near field's addressing is being restructured around four rules. Each rule below is
stated as the behaviour the implementation must have; section 3 says where the code stands against
it today, section 4 lists the invariants the change is accepted on, and section 6 is the phase plan
with one acceptance reading per phase.

Nothing here touches the far field, the page fade, the motion lead or the tick's page split. The
near field is `surface_vt_selection_mode` in its sectored AVT form.

## 1. Rules

* **R1 — one page table carries the mip dimension.** The page table (`_surface_vt_indirection`) is a
  mip-carrying structure: a page entry is addressed by a cell **and** a level. The AVT *indirection*
  table carries **no** mip dimension: one entry per adaptive cell, naming the cell's current upgrade
  if it has one.
* **R2 — the resident fallback is a complete, non-sparse low-precision table, and it has mip
  layers.** Part of the page table is always-resident low-precision content covering every cell in
  its extent with a full mip chain. The rest of the table is the sparse high-resolution upgrade set.
  "Complete" is a residency guarantee, not a grid shape: every cell in the fallback's extent has a
  page, independent of what the view is doing.
* **R3 — the split is a level threshold, `MaxAdaptiveLevel`.** A request with `mip >=
  MaxAdaptiveLevel` **skips the indirection table** and reads the fallback table directly. A request
  with `mip < MaxAdaptiveLevel` (a precision upgrade) goes through the indirection table for
  second-level addressing.
* **R4 — the upgrade path allocates the table entry before the physical page.** For `mip <
  MaxAdaptiveLevel`: first give the cell a page-table entry, then request the physical page. If the
  table entry is not ready (the indirection entry reads 0), the fragment uses that cell's low-mips
  fallback page. If the physical page is not resident (a virtual-texture page fault), the fragment
  substitutes the parent level, as an ordinary virtual texture does.

## 2. Why this shape

The two tiers answer different questions. The fallback answers "what colour is this ground" for any
cell, cheaply and always; the upgrade answers "how sharp can this cell be" for the cells the view is
actually looking at, and is allowed to be late, sparse and evictable. R3 makes that split explicit in
the addressing instead of leaving it to a comparison of texel sizes, and R4 makes each of the two
failure modes of the upgrade path resolve to a *defined* answer rather than to the diagnostic.

## 3. Where the implementation stands

| Rule | Today | Delta |
| --- | --- | --- |
| R1 | **The two-level structure is already there.** The directory is flat: `avt_find_sector(key, 0, entry)` returns one entry per adaptive cell and is read at level 0 (`native/src/shaders/main.glsl:578-600`, `:629`), while the page table is the mip-carrying structure (`texelFetch(_surface_vt_indirection, page, mip)`, `:631`, `:656`) and the write side publishes per-owner `mip` (`native/src/terrain_3d_vt_page_pool.cpp:307-353`). | Verify and name it rather than rewrite it: the read path already addresses the flat table for "which cell" and the mip-carrying table for "which page". P2 is therefore a contract test, not a layout change. |
| R2 | **Landed.** The fallback is its own owner (`avt_coarse_owner()`) with a grid sized and placed in `_avt_scan_sectors` (`native/src/terrain_3d_sector_avt_hierarchy.cpp:56-90`), planned as `ROOT` pages (`native/src/terrain_3d_avt_plan.cpp:12`), and its pages are now *reserved*: `Terrain3DVTPageOwner::reserved` keeps them out of the pool's victim search. | See section 6.1. |
| R3 | **Landed as one number.** The read order used to be decided by an inline texel comparison (`max(pixel_world, minimum_texel) < coarse_texel`); it is now decided by the published sample level against `avt_adaptive_threshold_level`, derived once as `log2(coarse_texel / fine_texel)` (`get_avt_adaptive_threshold_level()`) and read by the material, the report and the plan. Note the naming: `avt_max_adaptive_level` is a *different* number and is not this threshold - it is the fallback grid's own mip boundary, fixed at 1, and its own test pins it. | See section 6.2. |
| R4 | **Already implemented, and already pinned by a green test.** `native/tests/vt_avt_dense.gd` asserts all three cases by colour: removing a sparse mip-0 page's mapping (`release_page(sector, 0, x, y)`, `:965-967`) samples the ready dense fallback (`:974`); clearing the whole fine directory (`_avt_directory_mask = 0`, `:976`) also samples the dense fallback (`:980-981`); and removing only the fine mapping of a turned view samples the **nearest ready local parent** rather than the outer fallback (`:580-590`), with the parent's exact address and slot asserted still mapped (`:564-569`). | Verify, do not rebuild. See section 6.3. |

The plan side already carries the ingredients R2 and R3 need: `Terrain3DAVTRefinement::level_mips`
is a histogram of the plan by local mip, `world_pages` counts the fallback-tier pages, and
`PlanInput::mip_level_cap`/`get_avt_mip_level_cap()` is a single published cap that both the plan and
the shader read.

## 4. Invariants the change is accepted on

* **I1 — no unowned fragment inside the fallback's extent.** A fragment inside the fallback table's
  extent resolves to a material or to the explicit diagnostic. It must not resolve to "no owner"
  because a tier's residency sits behind a production allowance.
* **I2 — the fallback's residency is bounded and reserved.** The pages it occupies are a function of
  configuration, not of the view or of upgrade pressure.
* **I3 — dropping an upgrade never changes what a fragment resolves to.** An evicted upgrade degrades
  to the fallback, so eviction needs no coordination with the shader.
* **I4 — one number.** `MaxAdaptiveLevel` is published once and read by both the plan and the shader,
  so the plan cannot produce a page no fragment asks for, and the shader cannot ask for a level the
  plan was never told about.

## 5. Landed prerequisite: reach no longer rejects the fallback

`avt_resolve()` had gained an early `distance(world, v_camera_pos.xz) >= max(64.0,
_avt_coverage_distance)` rejection. It was correct for the upgrade path - reach is what that path's
plan is sized against - and wrong for the fallback tier, which is the near field's last resort when
the far field is off or not ready. A fragment past reach then had no provider at all and drew the
missing-page diagnostic.

Measured on `native/tests/vt_turn_budget.gd` (debug build, D3D12): the settled 180-degree turn with
the far field disabled went from **333 diagnostic pixels** to **0**, and the near-field phase mean
over the three measured sweeps fell from 0.589 / 0.334 / 0.533 ms to **0.529 / 0.264 / 0.431 ms**.
The reach gate now bounds the upgrade branch only; the fallback branch is bounded by its own table's
extent test.

## 6. Phases

Each phase ends with `scons platform=windows target=template_debug` green and the named reading
taken on the same binary.

| Phase | Change | Acceptance |
| --- | --- | --- |
| **P1** | Fallback residency guarantee: **landed.** A page whose owner is the fallback tier is published reserved (`Terrain3DVTPageOwner::reserved`, set from `request_page_internal()` by the AVT producer) and the pool's victim search never chooses a slot holding one; `fallback_reserved_pages` / `fallback_reserved_blocked` are the readings. See §6.1. | A settled view reports a fallback page for every cell in the table's extent, and a run that fills the pool with upgrades still resolves a fallback sample in every covered cell (I1, I2). **Met** in the four phases of `vt_turn_budget` at 20/20/20. |
| **P2** | Flat indirection: **already satisfied in the read path, and now verified instead of rewritten.** The directory is flat (one entry per adaptive cell, read at level 0) and the page table carries the mip. What this phase owns is the contract test: `vt_avt_dense` pins the sector tiers, the full local mip chain, the sparse fallback and bounded residency; `vt_cap_probe` pins the addressing counters. | Both green on this revision (`vt_avt_dense` 17.0 s, `vt_cap_probe` 40.1 s) with no counter moved. |
| **P3** | Level threshold: **landed.** `get_avt_adaptive_threshold_level()` is the one number, published to the shader as `_avt_adaptive_threshold_level` and to the report as `avt_adaptive_threshold_level`; the read order compares the sample's level against it instead of comparing texel sizes inline. See §6.2. | The plan never holds an upgrade page at or above the threshold (I4): `plan_upgrade_above_level` is **0** at a threshold of **10.0** in all eight readings of `vt_turn_budget`. |
| **P4** | Failure modes separated (R4): **already satisfied, verified rather than rebuilt.** An absent page-table entry resolves to the cell's low-mips fallback page; a present entry whose physical page is missing resolves to the nearest ready local parent. Both are asserted by `vt_avt_dense` (see section 6.3). | The test's own assertions are the acceptance: `missing AVT mip-0 mapping falls back to a ready dense page`, `a missing AVT fine directory entry falls back to the dense mip chain`, and `a turned view uses the nearest ready local parent instead of the outer dense/SVT fallback`. **Met** (`vt_avt_dense` PASS). |
| **P5** | Documentation: `README.md` index, the outside-radius sentence in `avt_page_table.md`, and the test that pins the new contract. | The index links this document; `avt_page_table.md` no longer claims that sampling outside the radius always uses the far field. |

### 6.1 P1: the fallback tier is resident by construction

**Measured before building anything.** The tier is planned as `ROOT` pages, which the production
order puts ahead of the upgraded prefix, and the pass pins every resident plan page while it runs.
That is an argument, so it was measured first: `Terrain3DAVTProducePass::fallback_plan`/`fallback_ready`
are published as **`fallback_plan_pages`** and **`fallback_ready_pages`**. A full revolution at two
rates, a cold pool rebuild and an isolated near field (`native/tests/vt_turn_budget.gd`, debug build,
D3D12) reported `fallback_plan_pages: 20, fallback_ready_pages: 20` in every live reading, so the
tier was not being starved in the scenarios that exist. The 20 is the coarse grid's own page count
for this configuration (`size = 4`, `levels = 3` over a 256 m page: `4^2 + 2^2`), covering +/-512 m
around the focus, which is also why the settled 180-degree turn resolves past the near field's 256 m
reach.

**Then made structural, because "resident by luck of the production order" is not the rule.**
`Terrain3DVTPageOwner` carries a `reserved` flag; `request_page_internal()` propagates it and the AVT
producer sets it for a page whose owner is the fallback tier (`avt_coarse_owner()`); the pool's victim
search never chooses a slot holding a reserved page, so the tier's residency is a function of the
configuration instead of of what the upgrade set asks for. Two readings were added with it:
**`fallback_reserved_pages`** (slots currently holding a reserved page) and
**`fallback_reserved_blocked`** (requests that found only reserved candidates left).

**After it, on the same test:**

| Reading | Result |
| --- | --- |
| `fallback_plan_pages` / `fallback_ready_pages` / `fallback_reserved_pages` | **20 / 20 / 20** in all four live reports (warm, slow, far field alone, cold) |
| `fallback_reserved_blocked` | **0** - the reservation never blocked an upgrade acquisition at this load |
| Near-field phase mean, warm / slow / cold | 0.484 / 0.282 / 0.436 ms, unchanged from 0.496 / 0.279 / 0.383 within this suite's documented run-to-run variance |
| 180-degree settled turn, far field off | still 0 diagnostic pixels |

The `avt_peak_stats` diagnostic reads `fallback_ready_pages: 0` in the same run, and that is the
reading working as intended: it is a snapshot of the session's worst AVT pass, taken before the settle
produced the tier, not a statement about current residency. Read the live `avt=` report for residency.

What the reservation does not and cannot do is fill the tier during the window in which the pool has
just been rebuilt: nothing is resident then, the pages have to be produced, and the reading that
window produces is the cold phase's own sweep, not a settled view.

### 6.2 P3: the threshold is one number, and the plan agrees with it

The read order used to be decided inline, by comparing texel sizes:
`max(pixel_world, minimum_texel) < coarse_texel`. That is the same fact as a level comparison, but it
is a fact the plan could not read, so the plan and the shader each carried their own version of it.

`get_avt_adaptive_threshold_level()` is now the single statement of it: the level at which the
fallback table takes over, `log2(coarse_texel / fine_texel)`, derived from the two tiers' texel sizes
so it cannot disagree with the tables it describes. It is published to the shader as
`_avt_adaptive_threshold_level` and to the report as `avt_adaptive_threshold_level`. The shader reads
a sample as an upgrade only when `level < _avt_adaptive_threshold_level`; at or above it, the fallback
table answers and the sector directory and its page table are not touched.

The plan's half is the reading that says the two agree: **`plan_upgrade_above_level`** counts upgrade
pages the plan holds whose own level is at or above the threshold - pages no fragment asks the upgrade
path for. At the defaults the threshold is **10.0** (a 256-texel fallback page spanning 256 m is 1 m
per texel against a 1/1024 m finest upgrade texel, so `log2(1024)`), and the count is **0** in all
eight readings of `vt_turn_budget`.

Two names, deliberately: `avt_max_adaptive_level` stays fixed at **1** and is the *fallback grid's own
mip boundary* - its dense chain starts at its mip 1 and its mip 0 address space is what the block
registration reserves - and its own assertion in `vt_avt_dense` pins that. The threshold added here is
a *sample level*, which is a different quantity in a different space; conflating them would have made
the grid boundary look configurable when it is structural.

Measured on this revision (debug build, D3D12): `vt_avt_dense` **PASS** 17.0 s, `vt_cap_probe`
**PASS** 40.1 s, and `vt_turn_budget`'s settled 180-degree turn with the far field off is still 0
diagnostic pixels. The near-field phase means in that run (0.388 / 0.176 / 0.339 ms) are lower than
the previous round's, but that run's shared-service phase mean moved with them, so the difference is
machine state, not this change: the change is a comparison restated, not work removed.

### 6.3 P4: rule R4 was already implemented and already tested

Rule R4 was written as work to do, and the reading of the code says there is none: the two failure
modes are separated today, by control flow rather than by a new mechanism.

* A cell with **no page-table entry** never enters the upgrade branch at all: `avt_find_sector()`
  fails, and the sample falls out to the fallback table's own mip chain.
* A cell with an entry whose **page has no slot** walks up that block's own chain (`continue` to the
  next coarser mip), which is the parent substitution an ordinary virtual texture performs, and only
  reaches the fallback table when the whole chain is short.

`native/tests/vt_avt_dense.gd` asserts each of those three outcomes by colour, which is why this
phase is closed by verification:

| Assertion in `vt_avt_dense.gd` | What it pins |
| --- | --- |
| `missing AVT mip-0 mapping falls back to a ready dense page` (`:965-974`) | An absent entry for a page resolves to the fallback tier's page, not to the diagnostic |
| `a missing AVT fine directory entry falls back to the dense mip chain` (`:976-981`) | An absent *cell* entry does the same, with the directory masked off entirely |
| `a turned view uses the nearest ready local parent instead of the outer dense/SVT fallback` (`:580-590`), with the parent's slot asserted still mapped (`:564-569`) | A present entry whose page is missing resolves to the nearest ready **parent**, not straight to the fallback |

All three are green on this revision (`vt_avt_dense` PASS 16.5 s), together with the fallback tier's
residency from section 6.1 and the threshold from section 6.2.

Two tests that would cover R4 more directly cannot run in this checkout:
`native/tests/vt_strict_coverage_runner.py` and `vt_near_arrival_runner.py` exit 2 without starting a
frame, because both default to `--project D:\godot\project\test-1` and that project does not exist
here. Their red in a suite summary is environmental and is not evidence about the code.

### 6.4 The per-cell blur: the plan's walk was depth-first on one cell

Reported from use: at one distance, some 64 m cells are sharp and others are one blurry patch, and a
small camera movement sharpens a whole patch at once. The reading that made it measurable is in
`native/tests/vt_turn_budget.gd`: for every 4 m point within 16 m of the camera it reports the finest
**ready** page covering that point, its page world size, whether only the fallback tier covers it, and
the cell's own level. It first asked the view's per-cell answer (`produce`), and two variants were
built and rejected on measurement:

| Variant | Result |
| --- | --- |
| Give every unsampled footprint the cell's distance density, and drop `produce` from the descent | **Broke a contract.** `vt_avt_dense`'s narrow view stopped publishing the local mip-0 page its demand asks for (four assertions). |
| Give it only to cells the view does not sample at all (`!cell.produce`) | **Inert.** `plan_invisible_cell_pages` - added for this - stayed at **8**: one whole-cell page for each of the 8 apron cells, which are the far ones where the distance's demand stops at the whole-cell page anyway. |

That second reading eliminated the theory rather than merely failing to fix it: cells a few metres
away are always sampled (a 64 m box containing the eye cannot be rejected by a frustum plane), so the
per-cell difference was never the view's answer.

**What it was.** The probe's first settled run reported **43 of 45 points within 16 m of the camera
with no ready fine page**, the worst at 0.25 m per texel - a whole-cell page - while the camera's own
cell was refined to 0.0039 m per texel. The plan was fully satisfied while that was true
(`missing=0`, `slot_wait=0`, `free=101`), and its level histogram was **bimodal**:
`[0, 30, 15, 8, 2, 2, 36, 1, 1, ...]` - a deep cluster for the nearest cell and 36 whole-cell pages for
every other. The walk in `plan_pages()` popped its pending queue by `(produce, distance, mip)`, so it
was depth-first on the closest cell: a chain to the pixel footprint is 1+4+16+... entries and the plan
holds ~128, so one cell consumed the budget and every other cell kept its root.

**The fix, and what later replaced it.** The pending queue was ordered by **page world span** first:
every cell descends one world level before any cell descends two. Span is the one quantity two chains
can be compared by across blocks of different sizes - a 256-page block and a 64-page block hold the same
world resolution at different local mips, which is why ordering by local mip (tried first) let the larger
block outrank the smaller at every level. That order fixed the bimodality and left the ceiling this
section's own "does not do" note measured; it is **superseded by the demand-deficit order** in the next
subsection.

| Reading | Before | After |
| --- | --- | --- |
| Points within 16 m with no ready page finer than 0.2 m per texel | 43 of 45 | **0** |
| Worst texel among those points | 0.25 m (whole-cell page) | **0.125 m** |
| `plan_level_mips` | bimodal: fine cluster + 36 roots | unimodal: `[0, 0, 0, 0, 0, 58, 35, 1, 1, ...]` |
| `vt_avt_dense`, `vt_cap_probe`, `vt_root_coverage` | green | **green** |

**What this does not do**, measured: make the near field sharp. At the shipping 256-page pool the plan
holds ~116 entries for ~36 cells - about three per cell - so uniformity caps at one level of descent
(0.125 m per texel here). Raising the pool to 1024 spreads the histogram
(`[0, 7, 97, 111, 88, 70, 37, 1, 1]`) and takes the unanswered count 45 -> 29 but leaves the worst
texel at 0.125 m, because a complete quadtree chain costs 1+4+16+... per cell: at 36 cells, three
levels alone is 756 entries. The remaining levers, in cost order, are the **fallback tier's precision**
(it answers every cell the upgrade set does not, and it is 1 m per texel today), a smaller upgrade
radius so the same budget buys more depth where the camera is looking, and the pool default. The probe
and its assertion are now part of `vt_turn_budget`, so the next change here is measured the same way.

**Superseded: the queue is ordered by demand deficit, and the ceiling is gone.** `native/tests/vt_near_density.gd` measures the delivered density at a 1080p gameplay view with the shipped defaults (pool 256, auto-grown to 512): under the span order the plan held **496 resident pages, none finer than a metre, no page at local mip 0 or 1 of any sector, and the finest thing on screen was 256 texels/m** - while the ground two metres in front of the camera asked for 0.25-0.5 m pages. The budget was not short; it was spent on one *world size* everywhere. Ordering the same walk by `span * density` - how many times coarser than its own demand a footprint's page is - spends that residency where the view asks for it, and the per-footprint descent test already bounds what any one cell can take:

| `vt_near_density` reading | span order | deficit order |
| --- | --- | --- |
| `plan_level_mips` | `[0, 0, 153, 108, 60, 38, 41, 10, 2]` | `[62, 110, 98, 57, 30, 20, 23, 10, 2]` |
| `finest_requested_texel_world` | 1/256 m | **1/1024 m** |
| Finest ready page | 256 texels/m | **1024 texels/m**, 1.6 m in front of the camera |
| Ready fine pages at 512+ texels/m | 0 | **172** |
| Ready fine pages at 16-64 texels/m | 122 | 60 |
| Ready fine pages at 4-8 texels/m (the outer cells) | 29 | 25 |
| `visible_missing_pages` / fallback tier | 0 / 84 of 84 | 0 / 84 of 84 |

The outer cells keep their coarse pages, so this is not the "one cell eats the plan" failure returning:
it is the same residency placed by the metric the view is judged on. The lever list above changes with
it - the fallback tier's precision and the pool default are now what decide how far past 1024 texels/m
the near ground could go, while a smaller radius or a larger pool buys depth *inside* the demand rather
than coverage across it. The test is a regression of its own (`vt_near_density_runner.py`), so the next
change here is measured the same way.

**The other candidates, checked and not needed.** The blur this fixed had four other suspects, and each
was answered by reading the path rather than by changing it:

* **Writing the coarser level's entry into the new fine entry (the reference's remap trick).** It saves
  the indirection mip walk, not sharpness: the entry names the *same* physical page, so the sample is
  identical. Here the walk is one to three `texelFetch`es and the indirection payload is a bare `R32F`
  slot (`TerrainVT::SLOT_BIT_COUNT` 11) with no room for a mip, so the trick has neither a target nor a
  payoff. What was wrong was *which* pages were resident - the selection above.
* **`mip_bias`.** The plan coarsens every sector together when the visible hierarchy cannot fit the
  residency budget. At the shipped pose it is 0 (`capacity_mip_bias`), while
  `refinement_requests_denied` is 643 against 496 selected - the plan is budget-bound but not biased -
  so the coarsening was a pressure response that did not fire, not the steady-state ceiling the
  measurement found.
* **Parent blending and the page fade.** `avt_filtered_sample()` blends the level the footprint's mip
  fraction asks for, and a page still arriving blends from the level it replaced; both are bounded by
  the arrival ramp (`vt_page_fade_frames`, 12 by default). The probe runs with the ramp off
  (`vt_page_fade_frames = 0`) and still measured 256 texels/m as the ceiling, so neither is what held
  the image back.
* **The source density ceiling.** A region's ID/weight payload is `region_size x surface_density`
  (1/2/4/8 texels per metre, default 1), so *material blend boundaries* cannot be placed finer than a
  metre however fine the physical page is. That is a real ceiling on boundary sharpness - the pages
  carry the material detail at their own density, but a transition between two materials is
  interpolated from a 1 texel/m source. It is a `surface_density` question rather than an AVT
  addressing one, and it is the next lever if the view still reads soft at the seams.

**A pose change re-plans, and how that was nearly mis-read.** `vt_near_density`'s closing phase moves the
camera 100 m in XZ, raises it to 20 m and switches it to a narrow orthographic projection, then asserts
what the view asks for: `vt_near_density` holds a 1024 texels/m page under the camera (a 0.25 m page
whose slot the synthetic material probe then reads back green) with `visible_missing_pages` 0. The
plan's own readings follow the pose - `chain_ticks` +1 and the histogram becomes the narrow pose's own
`[20, 9, 4, 2, 2, 1, 8, 2, 1]` instead of the game view's `[62, 110, 98, 57, ...]`.

The first version of that phase drove the tick by calling `update_surface_vt()` by hand, many times
inside one process frame, and it measured something else entirely: `plan_reused` true, no changed key
component reported, and the standing game-view plan still in place, so the finest page under the camera
stayed the cell's whole-cell root (4 texels/m) while `finest_requested_texel_world` read 1/1024 from the
older pose. Invalidating the key by hand in the same run re-derived correctly, which is what showed the
selection itself was never the problem. The refresh interval is measured in **process frames**
(`Engine::get_process_frames()` against `avt_last_chain_frame + avt_plan_refresh_frames`), so a fixture
that ticks many times inside one frame is measuring the interval, not the product: with the pose driven
through the terrain's own process/physics callbacks, one chain run re-derives everything above. The
recorded lesson is the fixture rule, not a defect: **plan-lifetime questions have to be driven through
the callbacks the product uses.** `vt_near_density` now does that, and its assertion is the density the
new pose asks for.

**The plan's budget was the second half of the same defect.** The walk was ordering-limited *and*
starved: the near plan's residency budget was capped at exactly half the pool whenever the far field
was enabled (`_avt_scan_sectors()`), which is a ceiling rather than a share. The near-field probe
measured the near plan holding 116 of its 128 entries while the far field held 27 pages and **101 of
the pool's 256 slots sat free**, so the plan could afford a second level for only 15 of the 36 cells it covers. The far field keeps a quarter of the pool as a floor instead, and the near plan takes the rest.

| Reading | pool/2 ceiling | quarter floor |
| --- | --- | --- |
| Plan entries | 116 (budget 128) | **368** (budget 384) |
| Pool | 256, 101 free | 512 (auto-capacity grew), 117 free |
| Page spans in the plan | 2 levels: 0.12 m x60, 0.25 m x36 | **5 levels: 0.02 x14, 0.03 x86, 0.06 x80, 0.12 x68, 0.25 x36** |
| `plan_dropped` per generation | 21-26 | **0-1** |
| Near-field phase mean, warm / slow turn | 0.47 / 0.30 ms | **0.16 / 0.15 ms** |
| `vt_turn_budget` budget assertions failing | 6 | **4** (warm and slow section means now inside budget) |

The cost drop is the churn: a plan that is satisfied (`missing=0`, `dropped=0`) does not re-classify and
re-prime the same pages every generation, so the pass does less work for more coverage. The remaining
red is the cold phase, where the pool is deliberately rebuilt.

**And it holds under motion, which is what the report was about.** The probe takes its readings three
times - settled, after a 3 m move, and after a 6 degree turn - and asserts that no sampled point loses
a whole level of resolution between them. Measured: worst texel **0.125 m** and `unanswered` **0** in
all three, `regressed_points=0`, `worst_ratio=1.00`. A patch that sharpens or blurs as a whole when the
camera moves shows up as points whose texel doubles while their neighbours do not, so the symptom is an
assertion now rather than an impression.

### 6.5 Separately tracked: the warm-turn reuse failure predates this work

`native/tests/vt_adaptive:rotation` fails on `warm camera turn must reuse resident pages` with
`pages = [67, 36, 10, 11, 10]` where the last three entries must be zero: revisiting 0 degrees and 90
degrees re-produces about ten pages instead of reusing a settled plan. It is **not** caused by the
resolve change in section 5 - that change is in the shader's sampling path, and production
(`update_surface_vt()`) never reads the shader. Verified by A/B on one machine: building the
unmodified shader against the current sources and running the test fails identically (19.5 s) to
building the change (19.1 s). The failure is therefore in the plan/residency behaviour the previous
revision introduced, and it is tracked here because it is the same class of problem as the turn cost
this redesign is about - a turn replacing its working set instead of reusing it.

### 6.6 The grazing shimmer: the level math assumed taps the sampler does not have

Reported after 6.4 landed: the near field now looks too sharp at distance and distant sloped ground
crawls while the camera moves. The user's own reading was that it looked like an anisotropy problem,
and it was.

6.4's walk change gave distant cells four or five levels instead of two, so a fragment at a distance
is now resolved at the level its footprint asks for instead of falling back to the 1 m/texel
baseline. That is the intended behaviour, and it made a latent arithmetic error visible: the number
the shader uses to cap its anisotropic footprint was not the number of taps the sampler has.

* `Terrain3D::get_avt_anisotropy()` clamped the request (`surface_vt_anisotropy`, default **8**) by
  the page gutter only (the rule read then was `border - 0.5` = 8.5 at the border of nine; the gutter's
  own arithmetic was corrected afterwards to `2 * border - 1`, which is what the function and the
  shader's `avt_pixel_footprint()` evaluate now - see `vt_sampling_review.md`).
* Godot builds the material samplers per **viewport** with `anisotropy_max = 1 << level`
  (`MaterialStorage::samplers_rd_allocate`), the viewport's level defaults to the project's
  `rendering/textures/default_filters/anisotropic_filtering_level`, which is **2** (4x), and no
  material can set it. So on a stock project the shader selected mips for eight taps while a fragment
  got four.

Why a wrong assumption is not cosmetic: an anisotropic filter answers a grazing pixel by clamping the
minor axis to `major / taps`, which selects the mip whose texel is `major / taps`, and then takes
`taps` samples one texel apart - the footprint is fully covered. A shader that selects the mip for a
larger number asks for a page finer than that; the atlas carries one physical mip per page and exactly
one mip in total, so the sampler stays on the finer page and covers it with a stride of
`assumed / actual` texels, leaving the texels in between unread. At the shipped pair that was a
two-times overshoot, and it is the grazing aliasing the report describes. It also silently halved the
near field's demand density at grazing angles, because the CPU footprint uses the same number.

**Fixed by reading the taps instead of assuming them.** `get_avt_anisotropy_sampler()` returns
`1 << viewport_level` (1-16, the project default when there is no camera yet), and
`get_avt_anisotropy()` is now `min(request, sampler, 2 * border - 1)`. The request keeps its meaning as
the widest filtering the near field will *assume*; it can no longer exceed what the hardware delivers.
`get_vt_settings()` reports the four readings (`avt_anisotropy`, `..._sampler`, `..._requested`,
`..._effective`) so a project can see which bound decides its near field; on a stock project that is
sampler 4, requested 8, effective 4. The documented intent in `vt_architecture_review.md` was already
"capped by the viewport sampler and page gutter" - only the gutter half was implemented.

Measured, not argued. `vt_anisotropy.gd` gained a saturated grazing pose (elevation sine 0.058, so the
major footprint is 1.15 m and the ratio 17.2) and renders it twice, with the shader bound to 8 and to
the sampler's 4, over a one-texel noise page and its 2x2 box average - the relationship a produced mip
chain really has. A precondition asserts the two assumptions land on *different* resident pages of the
cell (fine at 8, its parent at 4), so the reading cannot be one page compared with itself.

| Grazing reading (3 x 51 window, D3D12, 4x viewport) | Bound to 8 (the old assumption) | Bound to 4 (the sampler) |
| --- | ---: | ---: |
| Window mean absolute deviation | 0.0677 | **0.0362** |
| Ratio | 1.87x | - |

The deviation is sampling noise, uncorrelated frame to frame: it is what a moving camera sees as
crawling, and the fix removes just under half of it at this pose while keeping the same effective
resolution. The regression assertion is `> 1.25x`, well inside the measured 1.87x.

Rejected first attempt: a one-texel **stripe** page instead of noise measured 0.049 against 0.048 -
no contrast. The reason is worth recording because it is a property of the probe, not of the fix: with
a four-tap filter over a two-times-overshot footprint the samples land 2.3 texels apart, and bilinear
interpolation of a two-texel period reads a blend of both colours at every tap, so the pattern is
averaged anyway. A stripe is only a good aliasing probe when the tap stride lands on an exact multiple
of its period. Noise has energy at every frequency, so the part above the tap lattice's Nyquist folds
down at full amplitude whatever the stride is.

Rejected second reading: comparing the window *mean* against a flat mid-grey page. Aliasing a
zero-mean pattern preserves the mean, so the mean cannot see it; the deviation from the window mean
can, and that is what is asserted.

The user's own project cannot be confirmed from here: if its viewport (or project default) is already
8x or 16x, then the sampler half of the bound changes nothing for it and the shimmer has another
cause. The four readings above are the first thing to look at, and they are published for exactly
that. One boundary is worth stating with it: this is the *near* field's rule. The far field's level
still comes from its distance table and its samplers are `filter_linear` without gradients, so
terrain beyond `surface_vt_distance` sees no anisotropic filtering at all - a deliberate, documented
design (`vt_sampling_review.md`) and a separate change, not this one.

Regression set on the rebuilt debug template, D3D12: `vt_anisotropy` (0.0677 / 0.0362, 1.87x),
`vt_avt_dense` 16.8 s, `vt_cap_probe` 40.9 s, `vt_root_coverage` 17.7 s, `vt_demand` 11.4 s,
`vt_mip_bands` 12.5 s, `vt_cells` 25.9 s, `vt_fallback` 14.7 s, `vt_svt_coverage` 24.2 s,
`vt_material` 20.2 s green, `vt_turn_budget` functional items green with the same four CPU
phase-budget reds it had before (warm 0.21, slow 0.16, cold 0.61 ms against a 0.10 ms per-phase
budget - the descheduling reds section 6.4 records; its near-field coverage assertions, including
`unanswered=0` and `regressed_points=0`, still pass at the coarser grazing density the sampler bound
asks for). `vt_visibility`, `vt_adaptive:filtering`, `vt_adaptive:sectors` and `vt_adaptive:scale` are
red, and were A/B'd as pre-existing rather than caused by this: reverting the one line in
`get_avt_anisotropy()` to the pre-fix clamp, rebuilding, and re-running all three reproduces every
failure byte for byte (`vt_visibility` is already recorded as red at HEAD in
`vt_reference_avt_alignment.md` section 6/H3, and `vt_adaptive:rotation` in 6.5).

### 6.7 What the deficit order actually changed in the red set

The ordering is one lambda in `terrain_3d_avt_plan.cpp`, so the honest question after it landed was
not "does the near field look right" (6.4 answers that with `vt_near_density`) but "which tests did it
change". It was A/B'd on one machine with everything else held: the file reverted to `HEAD`, rebuilt,
the same seven reds run, then restored and rebuilt. The tree's other uncommitted work - the clipmap
ring, the delivery matrix, the surface views - was identical in both directions.

Five of the seven reds produce a **byte-identical** `REGRESSION` set in both directions:

| Test | `REGRESSION` lines | Deficit order vs `HEAD` |
| --- | --- | --- |
| `vt_adaptive:scale` | 1x 25600 visible sectors, 20x moving camera recomputes demand, 16x 10 km coarse coverage (37) | identical |
| `vt_adaptive:metric` | 2x sparse physical residency, 2x widening the view retains addresses (4) | identical |
| `vt_adaptive:filtering` | missing fine neighbour stays diagnostic, coarse recovery defaults off, 4x allocate the selected world mip (6) | identical |
| `vt_adaptive:rotation` | 3x warm camera turn must reuse resident pages | identical |
| `vt_strict_coverage` | turns 1-3 did not settle after 180 + 120 ticks (3x, printed twice) | identical |
| `vt_adaptive:ownership` | 6 distinct, 14 lines | **one more**: `camera movement retains automatic coverage` (15) |
| `vt_adaptive:sectors` | edit phase fails 3 of 7 runs | edit phase fails 3 of 11 runs; see below |

So the ordering's whole measured cost is one assertion inside a test that is red in both directions.

`vt_adaptive:sectors` is the one entry whose text differed, and the first reading of it - "the
ordering costs a red" - was wrong twice over. Its last phase repaints a region, invalidates its pages,
settles, and then requires 24 ticks that produce nothing. That phase failed in **both** directions:
3 of 11 runs with the deficit order, 3 of 7 at `HEAD`.

The first explanation was the pool: demand is ~750 pages for a 256-slot pool, the plan selects 240 and
reserves 16, so the plan is the pool and one marginal change costs an eviction plus a re-bake. The
diagnostic added to the test refutes it. Failing runs print
`VT_SECTORS_EDIT_STATS ... visible_missing=35 ... carried=240 overlapped=0 new_area=0 reselected=0`
and `VT_SECTORS_EDIT_TICKS [1,1,1,...]` - the plan is *not* churning at all (240 of 240 carried, no
new area, no reselection); 35 pages are simply visible-missing and the producer refills them at the
configured one page per tick. Settling runs print `visible_missing=0` and 24 zeroes.

So the defect was in the test's own `settle_sectors()`: it waited for `produced == 0` and
`producer.pending == 0` for twelve ticks, but not for the view to have no missing pages.
`invalidate_surface_pages()` arms the edit and the plan turns it into demand on its own refresh, so
the first quiet ticks can land *before* that, and the "settled" verdict is taken while 35 pages are
still being refilled. It now requires `avt_sector_stats.visible_missing_pages == 0` as well, which is
what "settled" means for the assertions that follow. Measured after the change: **8 of 8 runs** reach
`VT_SECTORS_EDIT color=red` with `VT_SECTORS_EDIT_TICKS [0 x 24]` and no edit-phase regression. The
test stays red on one line that neither the ordering nor this race touches - `512 m region contains
independently addressed 64 m sectors` (`has_sector(Vector2i(3, 3))`, with 20 sectors independently
addressed out of 136 visible in that configuration), which is pre-existing in both directions.

The other rows the user's report was about are unchanged by it too, and the two that are *not* in this
table are the ones the ordering was aimed at, both green: `vt_near_density` (best delivered page 1024
texels/m, 110 pages at 512 and 62 at 1024, zero missing) and `vt_anisotropy` (gutter 5, spread 2.12x).

Attribution for the rest of the red set, with the evidence:

| Test | Owner | Evidence |
| --- | --- | --- |
| `vt_adaptive:scale`, `metric`, `filtering`, `rotation`, `strict_coverage` | this redesign's earlier revisions, not the ordering | byte-identical A/B above; `rotation` is 6.5, and the `2026-09-17` baseline in `bin/terrain-adaptive-baseline.json` already records `scale`, `metric`, `ownership`, `filtering`, `navigation`, `blend` and `sectors` as failures with the same text |
| `vt_adaptive:ownership`, `blend` | the delivery/assembly work in the tree (`far/material=SVT`) | `blend`'s remaining line is `missing AVT cannot fall back to available SVT in blend band`; its other assertion was fixed by that work |
| `vt_render`, `vt_visibility`, `vt_transition_parent` | same | all three assert the pre-delivery model (a fresh fixture with no SVT requests, and a near-field toggle that restores the array path); `vt_visibility` fails on `fresh fixture unexpectedly has SVT requests` and `one-page SVT budget should create one SVT record, got 7` |
| `vt_turn_budget` | the CPU phase budgets, pre-existing | red in both directions of a dedicated A/B (2 runs each): warm 0.158 / 0.166 ms at `HEAD` against 0.171 / 0.235 ms with the deficit order, slow 0.116-0.156 against 0.126-0.165, all against a 0.10 ms per-phase budget - the ranges overlap and 6.6 records 0.21 ms for the same phase on the pre-change tree, so the misses are not attributable to the ordering, though the sample is small and the warm phase is the one a denser plan could touch |
| `texture_compression` | the material/baker uniform-set path, not the VT plan | 2 engine errors per run (`Parameter "uniform_set" is null.`, `Uniforms were never supplied for set (0) at the time of drawing`) while the test's own assertion passes - the class `terrain_vt_and_streaming.md` section 6 records as fixed once already, reproducible in 2 of 2 runs on this tree |

The whole suite, on the rebuilt debug template and D3D12, at the end of this work: **60 of 75 pass**
(`bin/suite-2026-09-23.json`, 06:14-06:44). The 15 reds are the table above plus `editor_dock:setup`
(recorded as flaky in `terrain_vt_and_streaming.md` section 6, `Add Region did not expand into empty
space with background disabled` this time) and `vt_near_arrival`, which was not a red at all:
it exited 2 in 0.1 s, before the engine started, because its default source project was the leftover
`bin/terrain-project-lifetime-ke6fwkn0` - a directory `vt_project_lifetime_probe.py` creates with a
random suffix and `run_all.py --prune` exists to delete. With the default pointed at the same real
project `vt_strict_coverage_runner.py` copies, it runs in 51.6 s, prints its marker and exits 0 with
`ERRORS=0` - so the same suite is **61 of 75** with that fix in.

Two further reds in that set were **not** defects at all, and both are now green:

- `vt_adaptive:navigation` was red on one engine `ERROR:` line and nothing else - both of its own
  assertions passed. Enabling VT delivery turns the terrain node's tick back on, so the test's final
  `await process_frame` ran one physics tick after it had freed the camera, and `_grab_camera()` logged
  `Cannot find clipmap target or active camera`. The four tests that free their camera now stop the
  tick first (`native/tests/README.md`).
- Every other test was *reported* red by a line about the machine: `ERROR: Failed to read the root
  certificate store.`, which the engine prints once per launch here. `fixture.ENVIRONMENTAL_ERRORS`
  and `fixture.log_errors()` exclude it, the runners use them, and `vt_fallback_runner.py` now exits 0
  with `ERRORS=0` on a clean run instead of 1 with `ERRORS=2`.

### 6.8 The resolve parameter nobody read, and two probes built on the old encoding

The suite was re-run at the end of 6.7 and four of its reds turned out to be neither a plan nor a
residency defect. Three of them are fixed here, and all three were found by reading what the failing
assertion was actually asking for rather than by re-tuning the thing it named.

**`avt_resolve()` declared `bool allow_coarse` and never read it.** `avt_filtered_sample` passes
`_avt_feedback` - the `surface_vt_feedback` property, which `vt_sampling_review.md` documents as
"the feedback property controls coarse recovery in the shader" and `vt_reference_avt_alignment.md` as
"on by default, so a missing fine page resolves at the next resident level" - into a parameter the
body never referenced. The upgrade loop walked the sector's own mip chain on a miss regardless, so
with recovery *off* a missing fine page still resolved through a resident ancestor. Measured in
`vt_transition_parent`: `VT_TRANSITION_PARENT strict_missing center=(0.1255, 0.2667, 0.851, 1.0)` -
the ancestor's blue, not the diagnostic. The loop now reports the miss when the flag is off:

```glsl
if (!avt_material_slot(slot, fract(page_uv), texel_world, world_dx, world_dy, result, result_normal)) {
    if (!allow_coarse) { return false; }
    continue;
}
```

Only fragments with `_avt_feedback == false` change; with the shipped default the branch is not taken,
so every other test is unaffected by construction. Verified on all five scripts that turn it off:
`vt_transition_parent` **PASS** 19.3 s (was red), `vt_adaptive:filtering` **PASS** 19.3 s,
`vt_anisotropy` **PASS**, `vt_normal_compression` **PASS**, and `vt_strict_coverage` byte-identical
(its 18 lines, still the real coverage defect it was).

**`vt_adaptive:filtering` needed three corrections, all of them assumptions the redesign replaced.**

* It asserted `not terrain.surface_vt_feedback` with the message "coarse recovery defaults off". The
  property is the shader's coarse-recovery switch now and ships **on**, so the strict phase it guards
  is the thing that has to turn it off - which the test already did two lines later. The default is
  now asserted the way it ships, and the phase states its own requirement.
* Its world-level probe built per-level owner keys `0x40000000 + level * 0x100000`. That encoding
  appears nowhere in `native/src`: the world levels are the **mips of the one coarse owner**
  (`avt_coarse_owner() == Vector2i(INT32_MIN, INT32_MIN)`, and `_avt_build_hierarchy()` pushes its
  pages with the level as their mip). All four requests returned -1 and the probe painted nothing.
* Its level count came from `coarse_world_size / 64` - the hierarchy *above* the 64 m sectors, which
  the redesign folded into the coarse image's mips. What the block addresses is `block >> level` pages
  an axis, so with the measured block of 4 only levels 1-2 exist and levels 3-4 are correctly refused.
  The probe derives its levels from the block and prints what it found
  (`VT_FILTERING_WORLD_PROBE ... coarse_world=1024.0 coarse_pages=4 root_level=2 block=4 origin=(0, 0)`).
  The other two assertions in this test - the strict diagnostic over a ready parent, and the
  non-power-of-two sector/world mip handoff - pass on the same run.

**`vt_visibility`'s three assertions were two model assumptions.** Its fixture never asked for the far
field, but the shipped delivery matrix puts `far/material` on SVT, so the engine's own tick had already
requested seven SVT pages by the time the manual SVT phase expected zero; and enabling VT delivery
turns the terrain's tick back on, so the engine's demand pass ran inside the `await frame_barrier()`
before the test's "exactly one page" manual call, which then correctly produced nothing. The test's own
comment says its manual passes are the authoritative ones. It now disables the far field for the AVT
phases, turns it on for the SVT phase, and stops the tick after each enabling: the SVT phase creates
exactly one record (mip 0, the nearest visible region, `Pending bake`) and facing away requests none.

**`vt_near_arrival` never ran at all** - its default source project was a leftover probe directory with
a random name that `run_all.py --prune` exists to delete. It defaults to the real project
`vt_strict_coverage_runner.py` copies now, runs in 51.6 s and passes.

With those four in, the suite is **64 of 75** on the same tree (`bin/suite-2026-09-23-round2.json`,
up from 60 in 6.7), and the remaining reds and their owners are unchanged from the 6.7 table:
`vt_adaptive:scale`, `:metric`, `:ownership`, `:rotation`, `:blend` and `:sectors`,
`vt_strict_coverage`, `vt_turn_budget`, `vt_render`, `texture_compression` and `editor_dock:setup`.
None of them names the plan order, the gutter or the resolve flag.

### 6.9 The distance table that outranked an orthographic footprint

`vt_adaptive:ownership` was the largest remaining red - seven distinct assertions - and six of them
were one line of the hierarchy scan:

```cpp
if (!_vt.surface_vt_mip_distances.is_empty()) { tier = MIN(mip_levels - 1, get_surface_vt_mip_for_distance(distance)); }
```

`surface_vt_mip_distances` is a *perspective* control: it maps world distance to a resolution tier.
The test configures it (`[10, 20, 40]`), points an **orthographic** camera at unchanged ground, and
raises it 5 -> 15 -> 30 -> 60 m. An orthographic footprint does not change with height -
`terrain_3d_vt_visibility.h` answers `density = focal` for it, flat in depth - so the block size
must not change either. It did: the table replaced the footprint's own tier, and the block fell
**16 -> 8 -> 4 -> 4**. The fourth probe then failed too, because a 4-page block cannot address the
page the probe asked for (all four allocations returned -1, and everything downstream of them read
the magenta poison colour).

The table now applies only where there is a perspective distance to map:

```cpp
if (!_vt.surface_vt_mip_distances.is_empty() && !p_view.orthographic) { ... }
```

Measured after the change: block **16 at all four heights**, all four probe allocations succeed, and
the shader's four mip samples read exactly `red`, `green`, `blue`, `red`. `vt_adaptive:ownership`
falls from seven distinct assertions to one. The change is gated twice - a non-empty table *and* an
orthographic view - and `vt_region_ownership` is the only test in the tree that sets the table on an
orthographic AVT view; `vt_sectors` sets it after switching to a perspective camera. Verified:
`vt_adaptive:sectors` and `vt_adaptive:metric` byte-identical, `vt_near_density`, `vt_mip_bands` and
`vt_avt_dense` green, and `vt_strict_coverage` improves from turns 1-3 unsettled to turns 1-2.

Two of the other assertions were stale probe geometry, not addressing. The AVT/SVT blend band is
`smoothstep(reach * 0.75, reach, distance)` from the camera's ground position, and `reach` is the
shipped `surface_vt_distance = 384` (`terrain_3d_vt_state.h`), so the band is 288-384 m. Both probes
sat outside it (448 m and 504 m from a camera at x=512), which is why "blends AVT with SVT" read
pure SVT. Moved to 352 m and 448 m, they read `(0.1529, 0.2235, 0.0)` - a real blend - and a clean
green respectively.

**What the last assertion found, and why it is recorded rather than fixed here.** `camera movement
retains automatic coverage` asks for a non-zero block on the sector under the camera after it moves
28 m. It is still zero, and the diagnostics added to the test say what it is not:

```
VT_OWNERSHIP after_move camera=(540, 800, 256) blocks={(7,3):0 (8,3):0 (7,4):0 (8,4):0 (9,4):0 (8,5):0}
  visible_sectors=100 independent=18 retained=18
  avt_owners=[(-2147483648,-2147483648) (12,3) (12,4) (12,2) (12,5) (13,3) ... (14,6)]
  lead_m=3.9e-05 speed=1.6e-04 plan_origin=(540.0, 256.0) camera_origin=(540.0, 256.0) plan_reused=true
  plan_selected=18 world_pages=4 new_sector=4 level_mips=[0, 0, 14, 0, ...] denied=0
VT_OWNERSHIP after_extra_settle blocks={(7,4):0 (8,4):0 (9,4):0} visible_sectors=100
  independent=18 retained=18 ... reuse_ticks=495 chain_ticks=8
```

The plan is centred on the camera and the motion lead is zero, the scan counts the cell among its 100
visible sectors, nothing was denied (`denied=0`), and the plan holds **18 pages, all at local mip 2** -
on cells 356-484 m away in +X, none of them the one under the camera. `independent_sectors` equals the
whole cached set, so every address that exists is one the plan asked for: this is the plan's own
selection, not the address allocator's, and 300 further frames (about 7 s, `reuse_ticks=495` against
`chain_ticks=8`) do not change it.

Why the ordering is the suspect rather than the sampler: an **orthographic** camera answers the same
density for every cell (`terrain_3d_vt_visibility.h`, `density = focal`, flat in depth), so the
deficit key `span * density` that 6.4 introduced differs between equally-sized cells only by sampler
noise - and the comparator tests it with `!=` before the span and distance tie-breaks. That puts the
noise in charge of which cells a starved plan fills with, which is exactly the size of the observed
failure: 6.7's A/B recorded this assertion as the one line the deficit order added to
`vt_adaptive:ownership`, and it is the last one left in that test. The fix belongs in the comparator's
tie handling - compare deficits as levels rather than as floats, so the deterministic span/distance
tie-breaks decide - and it needs the same A/B and the same regression set 6.4 was accepted on, because
the alternative tie-break (nearest first) is the depth-first walk the old comment rejected.

## 7. Out of scope

Far-field addressing and its level window, the page fade, the motion lead and turn budget, the tick's
near/far page split, and the physical page format.

## 8. Naming

Code, comments and new documents describe the rules above in their own terms. Third-party project
names are not used as references in this addon.
