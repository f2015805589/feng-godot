# AVT addressing redesign: historical evidence

This record covers the earlier mip-table/residency redesign and the September 2026
planning experiments. The measured builds are not the current working tree. Current
addressing, strict/recovery behavior and controls are defined in
[terrain_vt_and_streaming.md](terrain_vt_and_streaming.md) and
[avt_page_table.md](avt_page_table.md).

## Decisions and interpretation

The work distinguished a flat sector directory from a mip-carrying page table, reserved
the independent coarse owner against detail eviction, and published one fine/coarse
sample threshold. `avt_adaptive_threshold_level` is a sample-level boundary;
`avt_max_adaptive_level` names the coarse grid's structural boundary.
Cold rebuilds still require production before reserved pages are ready.

Upgrade reach was bounded separately from coarse extent. In the recorded D3D12 turn
fixture with SVT disabled, this changed 333 settled diagnostic pixels to zero.
The reservation test reported 20 planned, ready and reserved coarse pages, with no
blocked upgrade at that load. The default sample threshold was 10 and the plan counted
zero upgrades above it.

Planner ordering progressed from depth-first to span breadth-first, then demand deficit.
Span order distributed coverage but reduced near density; deficit order restored fine
near requests. A capacity floor preserved a longer ancestor chain. These experiments
preserved coarse coverage while changing where a finite pool spent detail.

Sampling clamped anisotropy to the actual viewport/gutter limit. Strict-mode tests
explicitly disabled shader coarse recovery and used the real coarse-owner mip addressing.
Perspective distance-tier overrides were separated from orthographic footprint selection.
The later production miss policy also distinguishes unrequested and planned-but-late
levels; the earlier fallback-only assertions below describe the stages when they ran.

## Recorded measurements

Original before/after tables follow. Their test status and ownership attributions apply
only to the compared revisions; no historical red is waived for a later build.

### Coarse residency

| Reading | Result |
| --- | --- |
| `fallback_plan_pages` / `fallback_ready_pages` / `fallback_reserved_pages` | **20 / 20 / 20** in all four live reports (warm, slow, far field alone, cold) |
| `fallback_reserved_blocked` | **0** - the reservation never blocked an upgrade acquisition at this load |
| Near-field phase mean, warm / slow / cold | 0.484 / 0.282 / 0.436 ms, unchanged from 0.496 / 0.279 / 0.383 within this suite's documented run-to-run variance |
| 180-degree settled turn, far field off | still 0 diagnostic pixels |

### Span-first planning

| Reading | Before | After |
| --- | --- | --- |
| Points within 16 m with no ready page finer than 0.2 m per texel | 43 of 45 | **0** |
| Worst texel among those points | 0.25 m (whole-cell page) | **0.125 m** |
| `plan_level_mips` | bimodal: fine cluster + 36 roots | unimodal: `[0, 0, 0, 0, 0, 58, 35, 1, 1, ...]` |
| `vt_avt_dense`, `vt_cap_probe`, `vt_root_coverage` | green | **green** |

### Deficit ordering

| `vt_near_density` reading | span order | deficit order |
| --- | --- | --- |
| `plan_level_mips` | `[0, 0, 153, 108, 60, 38, 41, 10, 2]` | `[62, 110, 98, 57, 30, 20, 23, 10, 2]` |
| `finest_requested_texel_world` | 1/256 m | **1/1024 m** |
| Finest ready page | 256 texels/m | **1024 texels/m**, 1.6 m in front of the camera |
| Ready fine pages at 512+ texels/m | 0 | **172** |
| Ready fine pages at 16-64 texels/m | 122 | 60 |
| Ready fine pages at 4-8 texels/m (the outer cells) | 29 | 25 |
| `visible_missing_pages` / fallback tier | 0 / 84 of 84 | 0 / 84 of 84 |

### Capacity floor

| Reading | pool/2 ceiling | quarter floor |
| --- | --- | --- |
| Plan entries | 116 (budget 128) | **368** (budget 384) |
| Pool | 256, 101 free | 512 (auto-capacity grew), 117 free |
| Page spans in the plan | 2 levels: 0.12 m x60, 0.25 m x36 | **5 levels: 0.02 x14, 0.03 x86, 0.06 x80, 0.12 x68, 0.25 x36** |
| `plan_dropped` per generation | 21-26 | **0-1** |
| Near-field phase mean, warm / slow turn | 0.47 / 0.30 ms | **0.16 / 0.15 ms** |
| `vt_turn_budget` budget assertions failing | 6 | **4** (warm and slow section means now inside budget) |

### Matched anisotropy

| Grazing reading (3 x 51 window, D3D12, 4x viewport) | Bound to 8 (the old assumption) | Bound to 4 (the sampler) |
| --- | ---: | ---: |
| Window mean absolute deviation | 0.0677 | **0.0362** |
| Ratio | 1.87x | - |

### Regression comparison

| Test | `REGRESSION` lines | Deficit order vs `HEAD` |
| --- | --- | --- |
| `vt_adaptive:scale` | 1x 25600 visible sectors, 20x moving camera recomputes demand, 16x 10 km coarse coverage (37) | identical |
| `vt_adaptive:metric` | 2x sparse physical residency, 2x widening the view retains addresses (4) | identical |
| `vt_adaptive:filtering` | missing fine neighbour stays diagnostic, coarse recovery defaults off, 4x allocate the selected world mip (6) | identical |
| `vt_adaptive:rotation` | 3x warm camera turn must reuse resident pages | identical |
| `vt_strict_coverage` | turns 1-3 did not settle after 180 + 120 ticks (3x, printed twice) | identical |
| `vt_adaptive:ownership` | 6 distinct, 14 lines | **one more**: `camera movement retains automatic coverage` (15) |
| `vt_adaptive:sectors` | edit phase fails 3 of 7 runs | edit phase fails 3 of 11 runs; see below |

### Failure attribution

| Test | Owner | Evidence |
| --- | --- | --- |
| `vt_adaptive:scale`, `metric`, `filtering`, `rotation`, `strict_coverage` | this redesign's earlier revisions, not the ordering | byte-identical A/B above; the `2026-09-17` baseline in `bin/terrain-adaptive-baseline.json` already records `scale`, `metric`, `ownership`, `filtering`, `navigation`, `blend` and `sectors` as failures with the same text |
| `vt_adaptive:ownership`, `blend` | the delivery/assembly work in the tree (`far/material=SVT`) | `blend`'s remaining line is `missing AVT cannot fall back to available SVT in blend band`; its other assertion was fixed by that work |
| `vt_render`, `vt_visibility`, `vt_transition_parent` | same | all three assert the pre-delivery model (a fresh fixture with no SVT requests, and a near-field toggle that restores the array path); `vt_visibility` fails on `fresh fixture unexpectedly has SVT requests` and `one-page SVT budget should create one SVT record, got 7` |
| `vt_turn_budget` | the CPU phase budgets, pre-existing | red in both directions of a dedicated A/B (2 runs each): warm 0.158 / 0.166 ms at `HEAD` against 0.171 / 0.235 ms with the deficit order, slow 0.116-0.156 against 0.126-0.165, all against a 0.10 ms per-phase budget - the ranges overlap; the earlier sampling record measured 0.21 ms for the same phase, so the misses are not attributable to the ordering, though the sample is small and the warm phase is the one a denser plan could touch |
| `texture_compression` | the material/baker uniform-set path, not the VT plan | 2 engine errors per run (`Parameter "uniform_set" is null.`, `Uniforms were never supplied for set (0) at the time of drawing`) while the test's own assertion passes - the class `terrain_vt_and_streaming.md` section 6 records as fixed once already, reproducible in 2 of 2 runs on this tree |

## Test corrections and remaining evidence

The original 2026-09-23 full suite recorded 60/75, then 64/75 in
`bin/suite-2026-09-23.json` and `bin/suite-2026-09-23-round2.json`. The later run fixed
fixture/control assumptions: explicit strict feedback state, the single coarse owner,
manual-tick ordering after delivery enable, camera teardown and a stable project input
for `vt_near_arrival`. Certificate-store errors used the shared harness exemption.

Orthographic ownership improved from seven distinct failed assertions to one after
retaining block size 16 at camera heights 5/15/30/60 m and correcting blend-band probes.
The remaining recorded case selected 18 pages away from the camera despite 100 visible
sectors, zero denied requests and a stable camera-centered plan. Float deficit tie handling
was a hypothesis for a later experiment, not a verified fix in this record.

Focused entry points were `vt_avt_dense`, `vt_cap_probe`, `vt_root_coverage`,
`vt_turn_budget`, `vt_near_density`, `vt_transition_parent`, adaptive `metric`, `ownership`,
`filtering`, `rotation`, `blend`, `sectors`, and the real-project `vt_strict_coverage` /
`vt_near_arrival` runners. Build with `scons platform=windows target=template_debug` in
`native/`, then use the exact invocations and project requirements in the
[test guide](../native/tests/README.md). The recorded comparison baseline also included
`bin/terrain-adaptive-baseline.json`.

The grazing measurement was a 3×51 pixel D3D12 window at viewport anisotropy 4×.
Historical run times and pixel thresholds establish those fixtures only. Far-field
addressing, page format, motion lead and near/far budget policy were separate work.
