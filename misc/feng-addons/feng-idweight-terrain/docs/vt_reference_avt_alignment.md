# Reference AVT comparison: historical decisions and measurements

This records the earlier adaptive-VT comparison and its staged experiments. The counters,
results and limits below describe those revisions. Current behavior is maintained in
[architecture](vt_architecture_review.md), [addressing](terrain_vt_and_streaming.md) and
[delivery](vt_delivery_assembly.md); this file is not another current specification.

## Architectural comparison

The reviewed reference used Unity C#/HLSL, 64 m sectors, a fixed physical pool and
fragment-authored requests. Feng uses a Godot GDExtension, adaptive sector addresses,
a configurable shared pool and a separate SVT world grid for distant coverage.
The common mechanisms were POT block allocation, mip-chain lookup, world-footprint-preserving
block remap, LRU eviction and virtual-image sizing. Feng additionally retained transactional
slot acquisition, source workers, coalesced table uploads, page fades and predictive demand.

The adopted boundaries were small data contracts:

- `TerrainVT::MipRule` expresses automatic bands or an explicit distance table
- SVT fallback selection chooses global-root or per-unit-coarsest planning
- CPU demand remains available; the optional projected-page result refines the legacy region path
- Shader coarse recovery is a sampling setting, separate from GPU demand production

The reference's fixed near reach and pool layout were not substituted for Feng's distant
world grid. Screen-driven demand required an additional engine integration: the terrain VT
callback ran before GBuffer and carried no frame context, while spatial shaders exposed
no fragment storage-image write. The review therefore retained projected demand and
recorded fragment-authored feedback as an unimplemented capability.

## Experiment conclusions

The `vt_cap_probe` fixture separated 15° turns, 85 m/frame teleports and 3.33 m/frame cruise.
Turns produced no arrivals or served-level changes. Cruise exposed shared-pool churn;
AVT-only hit counters were not a hit-rate denominator because the planner checked ready
pages before requesting them. Pool counters required near/far attribution.

1. Bounding the unsampled plan tail by rate reduced its size and churn. Giving the near
   field a demand-aware larger share increased churn; it was rejected in that experiment
2. Overlapping new/old rectangles alone did not prove mip instability. Per-owner depth
   showed stable depth and lateral page reselection; a child necessarily overlaps its parent
3. Per-unit SVT fallback reduced pinned pages from 20 to 1 without improving served levels,
   and lost whole-domain coverage. Global roots remained the default
4. Raising the SVT level cap reused full-mip cell sources without a whole-world rebake.
   Capacity growth still recreated physical storage, so address remap alone could not
   preserve that content. Lowering the cap retained 512 resident pages and pool generation
5. Ring admission and allocated headroom were measured separately. Raising allocation
   headroom enabled late budget increases, but did not by itself raise the fixture's actual rate
6. Root cell-source probing was bounded and shared, and root production obeyed the page
   allowance while pinning remained complete. The former dominant root-request stall fell;
   detail walking then dominated the worst pass
7. Reducing AVT reach from 512 to 384 m saved distant residency. It did not reduce the
   per-generation lateral churn, and moved more coverage into SVT

Near pages were independently evaluated at their own footprints; SVT cells already held
mips. Deriving AVT parent pages from four children remained a proposal: it would require
matching page sets, a derivation job and finer-first scheduling, trading work/order rather
than eliminating parent residency. The dense mip ladder's geometric sum bounds that
opportunity; the review did not implement it.

## Recorded measurements

The following original tables are kept as data from successive experimental revisions.
A later table can supersede an earlier inference. In particular, overlap counters did not
establish level instability, and ring ceilings were not proof that the ring limited actual
throughput. Timings are fixture wall-time observations, not general CPU/GPU guarantees.

### 7.2 Three motion profiles, and a correction

| Profile | The far field's own demand | The shared pool | A fixed distant point |
| --- | --- | --- | --- |
| Turns (15 degrees) | `miss` unchanged, no arrivals | unchanged | `moved = 0` on all twelve reports |
| Teleport walk (85 m per frame) | arrivals; `served` falls back coarser | grows | `4>5`, `3>5` |
| Cruise (3.33 m per frame) | **about one miss per frame** (`miss` 58 -> 324 over 300 frames), 97% hit rate | **churns**: `alloc` 151 -> 1825, `evict` 516, `free` 210 -> 0, `pool_gen` 1, peak `fade_active` 136 | at the end **`3>8` and `4>8`** |

### 7.4 Attribution (measured)

| View | Its own hits | Its own misses | Reading |
| --- | --- | --- | --- |
| Far field, `get_surface_svt()` | 9675 | 324 | 97% hit rate: it asks for a page, and usually finds it already published |
| Near field, `get_surface_vt()` | **0** | **1636** | not a hit rate at all - see below |

### 7.4 Attribution (measured)

| 100 cruise frames | Near field on (phase C) | Near field off (phase D) |
| --- | --- | --- |
| `alloc` (shared pool) | 723 and 836 across the two legs | **11** |
| `fade_starts` | about 200 per leg | **11** |
| `evict` | 189 and 252 | **4** |
| The far field's own `miss` | about 65 per leg | **11** |

### 7.5 The reproduced defect: a saturated plan and a thrashing pool

| Reading | Value | What it means |
| --- | --- | --- |
| The plan | 17 -> **241 -> 305 -> 357 -> 384**, then back to 300 | It does not grow without bound: it **saturates at its budget** (`budget = 384` of a 512-slot pool) |
| What the image samples | **100-147** of those 300-384 pages | **Half to two thirds of the plan is never sampled** |
| What is missing among the sampled | 0 -> 48 -> **97** -> 20 | The near field's own image is starved, not just wasteful |
| Retained addresses | 74 -> **399**, then settling near 307 | The retention window fills the plan and is not released as the camera leaves |
| The pool | `free` 373 -> **0** by leg 2, and never returns | The pool is completely full for the rest of the run |
| Eviction | `evict` 520 -> **2651**, `alloc` 1862 -> **4373** | A steady eviction/re-production loop: about 0.8 allocations and 0.8 evictions per frame, indefinitely |
| Pages mid-fade | `fade_active` **90-100 continuously** | About a hundred pages are ramping at all times, which is what a visitor sees as pages updating in the distance |
| The far field | served level collapses to `2>8`, `3>8`, `4>8` | Kilometre-scale pages answering points whose rule wants mip 2-4 |

### 7.6 The mechanism: the plan's unsampled pages take the residency its sampled pages need

| Part | Pages | Note |
| --- | --- | --- |
| Roots | `avt_roots` 18-25 | not the filler |
| Retained requests | `avt_retained_reqs` 96-128 | saturates `RETAIN_RESERVE = 128` (`terrain_3d_avt_plan.cpp:166`) |
| Sampled by the image | `avt_sampled` 95-147 | **a third to a half of the plan** |
| The rest (apron and optional refinement) | about 150-200 | |
| **The plan** | 300-384 | its whole budget |
| Producer waits | `avt_slot_wait = 0`, `avt_source_wait = 0`, `avt_denied = 0`, `avt_mip_bias = 0` | **the producer is not blocked by anything** |
| The pool | `free = 0`; `alloc` and `evict` both advance by about **6 a frame, equal** | every production takes an LRU victim, and there is no victim to spare |

### 7.7.1 The demand-aware split, measured and rejected

| Reading | Even split, rate term (7.7.2) | Demand-aware split (`avt_allowance=14`) | Change |
| --- | --- | --- | --- |
| `avt_missing` peak | 91 | 82 | -10% |
| `n_miss` (near-field misses, whole run) | 3588 | **5053** | **+41%** |
| `alloc` (shared pool) | 3850 | **5316** | **+38%** |
| `evict` (shared pool) | 2558 | **3946** | **+54%** |
| `fade_starts` | 3841 | **5299** | **+38%** |
| `fade_active` | 88 | 90 (peaks 159) | worse |
| far field served | `3>8`, `4>8` | `3>8`, `4>8` | unchanged |

### 7.7.2 The rate term, landed

| Reading | Baseline (section 7.5) | With the rate term | Change |
| --- | --- | --- | --- |
| Plan size, peak | 384 (its whole budget) | **202** | -47% |
| Pages the image never samples | ~237 | **56** (`avt_apron` 28 + `avt_retained_reqs` 28) | -76% |
| `alloc` | 4373 | **3850** | -12% |
| `evict` | 2651 | 2558 | -4% |
| `n_miss` | 4125 | **3588** | -13% |
| `fade_starts` | 4361 | **3841** | -12% |
| `avt_cpu_ms` | 0.33-0.99 | 0.21-1.04 | unchanged |
| `avt_missing` peak | 97 | 91 | -6% |
| `free` at the end | 0 | 0 | unchanged |
| far field served | `2>8`, `3>8`, `4>8` | `3>8`, `4>8` | marginal |

### 7.7.3 P0e: what the churn is, measured

| Counter | Meaning |
| --- | --- |
| `plan_carried` | the same address. No slot, no production - the share of a generation that is free. |
| `plan_overlapped` | a new address whose rect **intersects** a rect the previous plan had *for the same owner*. The same ground at the level the rule re-derived. |
| `plan_rescaled` | a new address in an owner the previous plan had, but at a **span** the previous plan did not have. |
| `plan_reselected` | a new address in an owner the previous plan had, at a span it had: the same scale, a different page. |
| `plan_new_sector` | no page of that owner was in the previous plan at all. |
| `plan_dropped` | the other direction: addresses the previous plan named that this one does not. |

### 7.7.3 P0e: what the churn is, measured

| Generation | New addresses | Capacity | `avt_missing` |
| --- | --- | --- | --- |
| cruise 1 (`sel` 114) | 23 | ~50 | 9 |
| cruise 2 (`sel` 122) | 26 | ~50 | 0 |
| cruise 2 (`sel` 144) | 42 | ~50 | 24 |
| cruise 3 (`sel` 164) | 71 | ~50 | 50 |
| cruise 3 (`sel` 175) | **123** | ~50 | **93** |
| cruise 4 (`sel` 144) | **110** | ~50 | **80** |
| cruise 4 (`sel` 128) | 37 | ~50 | 20 |

### 7.7.10 Step 2 closed structurally: this renderer cannot preserve a page across its own capacity change

| Reading at "F settled" | `auto_capacity=true` | `false` | Change |
| --- | --- | --- | --- |
| `alloc` | 3873 | 3717 | **-4%** |
| `fade_starts` | 3871 | 3716 | **-4%** |
| `evict` | 2552 | 3082 | **+21%** |
| `free` | 443 | 193 | -250 slots |
| `eff_pool` | 512 | 256 | half |
| `avt_missing` peak over A-F | 102 | 102 | **unchanged** |
| `max_mip`, `root_page_world` before phase G | 9, 16384 | 9, 16384 | unchanged |
| `served_level_changes` (whole run) | 52 | 48 | -4 |

### 7.7.11 The shared page budget: the ceiling came off, and what the rate actually buys

| Reading | 16 | 32 | 64 |
| --- | --- | --- | --- |
| `alloc` | 3872 | 5723 | 6008 |
| `evict` | 2551 | 4101 | 4383 |
| `fade_starts` | 3870 | 5718 | 6004 |
| `free` | 443 | 449 | 449 |
| far field's own `miss` | 429 | 315 | **277** |
| far field `hit` | 21805 | 21866 | 21906 |
| `n_miss` (near field) | 4452 | 6486 | 6848 |
| **`avt_missing` peak over A-F** | 102 | 101 | **101** |
| plan tail `avt_tail_cap` | 56 | 112 | 224 |
| plan size `avt_sel` | 144 | 172 | 191 |
| worst far-field pass `svt_worst_ms` | 236.9 | 307.3 | 291.7 |

### 7.7.12 What the rate actually is: the ring is the ceiling, and the producer sits under it

| Reading | 16 | 32 | 64 |
| --- | --- | --- | --- |
| ring `capacity` / `allocated` | 32 / 32 | 64 / 64 | 64 / 64 |
| session pages per frame | 7.55 | 12.48 | 12.73 |
| cruise interval peaks | 8.0 | 16.0 | 16.0 |
| `pending`, against the budget | 0-17 | 0-17 | 0-17 |
| near plan `carried` / `sel` | 136 / 144 | 164 / 172 | 181 / 191 |
| `produce_slot_wait` / `produce_source_wait` | 0 / 0 | 0 / 0 | 0 / 0 |
| near field `n_miss` | 4457 | 6490 | 6846 |
| far field `miss` | 481 | 356 | 318 |

### 7.7.13 Three fixes: the ring's allocation, the rate ceiling, and the root pyramid's one-pass scan

| Reading | before | after |
| --- | --- | --- |
| worst far-field pass `svt_worst_ms` | 214.054 | **15.760** |
| `rootreq_ms` | 213.934 | **1.724** |
| worst pass `roots` / `produced` | 20 / 16 | 4 / 16 |
| disk probes at phase A (`probe_skips` / `probe_cells`) | - / - | 20 / 251 |
| session `svt_persist_probe_cells` | - | 2292 |
| `svt_root_passes` | 9 | 12 |
| `fade_starts` | 4769 | 4767 |
| far field `miss` | 481 | 473 |
| near field `n_miss` | 4457 | 4455 |
| `avt_missing` peak over A-F | 102 | 102 |
| pool `alloc` / `evict` / `free` at the end | 172 / 0 / 852 | 172 / 0 / 852 |
| session pages per frame at a budget of 16 | 7.55 | 7.56 |

### 7.7.14 The near field's reach default moved from 512 m to 384 m

| Reading | 512 | 384 | 256 |
| --- | --- | --- | --- |
| settled plan at one fixed pose: `avt_sectors` / `avt_pages` | 54 / 15 | 30 / 9 | 11 / 3 |
| end of run: `avt_sectors` / `avt_pages` | 134 / 226 | 89 / 222 | 51 / 167 |
| one generation, cruise 3 f75: `new_area` / `overlapped` / `reselected` / `missing` | 124 / 124 / 112 / 112 | 124 / 124 / 112 / 111 | 125 / 124 / 112 / 111 |
| teleport 512 m: `new_area` / `missing` | 97 / 70 | 96 / 69 | 17 / 17 |
| far field `visible_pages` / `miss` | 19 / 487 | 25 / 520 | 28 / 549 |

## Reproduction and acceptance

From the addon directory after rebuilding the native extension:

```sh
scons -C native platform=windows target=template_debug
python native/tests/run_all.py --driver d3d12 --only vt_cap_probe
python native/tests/vt_cap_probe_runner.py --driver d3d12
```

`VT_PROBE_PAGES_PER_UPDATE` and `VT_PROBE_AVT_DISTANCE` selected the reported budget
and reach experiments. Read `VTCAP` / `VTCAPRING` values: this is a diagnostic probe,
so an exit-0 result does not assert that its performance or coverage is acceptable.
Use the source-defined flags and current [test guide](../native/tests/README.md) when rerunning.

Recorded focused gates included `vt_mip_bands`, `vt_svt_coverage`, `vt_root_coverage`,
`vt_fallback`, `vt_demand`, `vt_root_budget`, `vt_svt_root_mips`, `vt_anisotropy`,
`vt_feedback`, `vt_perf`, `vt_idle_cost`, `vt_material`, `vt_auto_bake`, `vt_cells`,
`vt_pressure` and editor SVT inspection. Historical reds were compared against the same
engine with baseline addon builds; they are not permanent exemptions for later tests.

Validation principles retained from the experiments:

- Choose counters with independently reachable outcomes; distinguish a fact from a structural tautology
- Test the user-visible property, such as serving a new persisted mip, rather than requiring a specific repair mechanism
- Record build identity, work counters, active versus cumulative/peak data and machine conditions together
- Compare rate and residency independently; changing both confounds a throughput experiment
- Treat missing external projects as blocked fixtures and report them separately from runtime failures

Original evidence includes `bin/terrain-adaptive-baseline.json` and the probe's local logs.
Old line numbers, phase plans and temporary hypotheses were removed in favor of the current
source map. Current completion is established only by rerunning the relevant gates.
