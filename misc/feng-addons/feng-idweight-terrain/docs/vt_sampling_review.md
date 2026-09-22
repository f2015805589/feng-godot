# AVT grazing views and camera cuts

The sector AVT previously selected virtual mips from the larger of the two
world-XZ screen derivatives and sampled physical pages with linear filtering at
LOD zero. At grazing angles this discarded detail across the short axis too.
Changing the sampler alone cannot fix it: CPU demand used the same old scalar
footprint and did not request the finer pages.

Sector AVT now uses the two singular values of the pixel Jacobian. Its effective
footprint is `max(minor, major / anisotropy)`. Both the shader and CPU planning
use this rule. The CPU bounds the footprint over each clipped patch with matrix
intervals, rather than multiplying every demand by the maximum anisotropy.
The pure calculation is isolated in `terrain_vt_sampling.h`; view projection
owns the geometric bounds, and the planner still receives an immutable view.
The legacy/SVT density path is unchanged.

Physical pages use anisotropic samplers and explicit world-space gradients.
Derivatives never pass through the page-coordinate `fract` operation. No software
loop of additional material samples was added: hardware filtering does the work,
and the page gutter is what bounds it.

## The anisotropy triple, and why the default gutter is nine texels

A filtering footprint cannot reach past the border texels a page carries, so the
gutter is a physical bound rather than a policy: a page asked for more than its
gutter admits samples its own rim instead of the neighbouring ground. The bound is
`border - 0.5`, and it is conservative on purpose - it accounts for the smaller
texels of the lower virtual mip and for bilinear support.

The second physical bound is the sampler itself, and until it was added the level
math could assume taps no fragment gets. Godot builds a material sampler per
*viewport* with `anisotropy_max = 1 << level`
(`MaterialStorage::samplers_rd_allocate`), the viewport's level comes from
`rendering/textures/default_filters/anisotropic_filtering_level` - **4x** by
project default - and there is no per-material anisotropy, so a terrain setting
cannot raise it. What a wrong assumption costs is not subtle. An anisotropic
filter answers a grazing pixel by clamping the minor axis to `major / taps`, which
selects the mip whose texel is `major / taps`, and then takes `taps` samples a texel
apart: full coverage. A shader that selects the mip for a *larger* number asks for a
page finer than that, and an AVT page is one physical mip in a one-mip atlas, so the
sampler stays on it and covers it with a stride of `assumed / actual` texels. The
texels in between are never read. At the shipped pair - a nine-texel gutter and an
eight-times request on a stock 4x project - that was a two-times overshoot, and
`vt_anisotropy.gd` measures it at a saturated grazing pose on a noise page and its
box-averaged parent: **0.0677** window deviation for the page chosen for 8x against
**0.0362** for the page chosen for the sampler's 4x, a 1.87x difference in sampling
noise, which is what a moving camera sees as crawling.

The shipped values used to be a four-texel gutter and whatever the viewport's
filtering level said, which the gutter then reduced to **3.5x** silently, whatever
was asked for: a project set to 8x or 16x still filtered at 3.5x and nothing said
so. The near field now has one setting for the request, one reading for the taps,
and one function for the answer:

* `surface_vt_anisotropy` is the request, in multiples; `0` follows the viewport's
  level, which is what the addon did before the setting existed. The default is
  **8**, and it is an upper bound on what the near field will assume rather than a
  demand it can place on the hardware.
* `vt_page_border` is the gutter, and its default moved from four to **nine**, which
  admits 8.5.
* `Terrain3D::get_avt_anisotropy_sampler()` reads the taps the viewport's filtering
  level gives the material samplers. `Terrain3D::get_avt_anisotropy()` is the one
  home for the answer - the request clamped by that reading *and* the gutter - and
  both consumers call it: the material binds it to `_surface_vt_anisotropy`, and the
  sector AVT footprint (`TerrainVT::VisibleView::anisotropy`) uses it for CPU demand.
  Before this, the material bound the raw viewport value C++-side and the shader
  clamped it, while the planner clamped it separately: two spellings of one rule.
  The documented intent was already "capped by the viewport sampler and page
  gutter"; only the gutter was implemented.
* `get_vt_settings()["avt_anisotropy"]`, `["avt_anisotropy_sampler"]`,
  `["avt_anisotropy_requested"]` and `["avt_anisotropy_effective"]` are the four
  readings, so a project can see which bound decides its near field: a 4x project
  reads sampler 4, requested 8, effective 4. Raising the border admits a wider
  *request* up to `border - 0.5` (16x needs a gutter of seventeen, above the sixteen
  the setting allows); raising the *sampler* means setting the viewport's - or the
  project's default - anisotropic filtering level, which is the only thing that
  changes how many taps a fragment gets.

What nine costs: a stored page is `page_size + 2 * border`, so a 256-texel page goes
from 264 to 274 texels a side, **7.7% more texels per page** for the same world
coverage - a proportional cost in pool memory, source production and the encoder's
byte ceiling. Both views share `vt_page_border`, so the far field's gutter grows with
it. That is memory it does not need for filtering - **the far field's sampling is
unchanged**: it samples with a plain `textureLod(..., 0.0)` on `filter_linear`
samplers, with no gradients and no anisotropy, and its level comes from the distance
rule. Its gutter is for its own mip transitions. Giving the far field gradient-based
anisotropic sampling is a separate change and is not made here.

Camera cuts had a separate scheduling error: `asin(length(cross))` folds angles
above 90 degrees, making an approximately 180-degree turn look almost stationary.
The motion predictor now uses the full angle, clears the obsolete turn lead on
a cut and requests a fresh plan immediately. A large deviation from the standing
plan can also bypass the normal refresh interval. Ordinary movement retains
the refresh interval and in-flight planning reuse; physical pages and the source
queue are not flushed by a camera cut.

The project probe also found ready pages waiting unnecessarily in the arrival
queue: after one cut, all requested AVT pages were ready at sampled frame 31,
but 88 pages were still held for later fades. Recomputing `ceil(held/frames)`
every tick slows the release rate as the queue drains. A separate scalar
`PageArrivalCadence` now holds the burst's rate until the queue empties. The
queue continues to own slot order; the fade pass owns readiness and blending.
No extra allocation, rendering pass or page production is needed.

The finer demand exposed avoidable source-queue overhead. Production now takes a
fixed-size snapshot of ready source keys and polls only those keys, preserving
the plan's priority. This replaces a mutex acquisition for each unprepared page
with one queue read and allocation-free lookups. Retention includes only pages
that still need source payloads; the settled-state readiness check runs only
when the pass is actually eligible for the settled shortcut.

These changes preserve the fixed residency and production budgets. An abrupt
turn into uncached detail still requires asynchronous page production. Correct
anisotropic filtering also has a GPU cost relative to a single linear sample;
the implementation bounds that cost rather than claiming it is free.

## Measured: what 8x costs the near field's working set

`vt_cap_probe_runner.py --driver d3d12` at the default tick budget, the same script before and
after the default pair moved (a four-texel gutter with 3.5x effective, then nine texels with 8x).
Both columns were measured at the near-field reach that was the default at the time, 512 m; the
reach itself moved to 384 m in the same round, for reasons and with measurements of its own
(`vt_reference_avt_alignment.md` section 7.7.14), and the two changes are independent: this table is
about the anisotropy, and the reach's own cost is in that section.

| reading | 3.5x | 8x |
| --- | --- | --- |
| near plan pages `avt_pages` | 151 | **227** |
| sampled `avt_sampled` | 116 | **183** |
| plan `avt_sel` / `avt_carried` | 144 / 136 | 211 / 194 |
| near field `n_miss` | 4453 | 5528 |
| `fade_starts` | 4765 | 5842 |
| pool `alloc` | 172 | 248 |
| far field `miss` | 473 | 487 |
| session pages per frame | 7.54 | 7.89 |
| `produce_slot_wait` / `produce_source_wait` | 0 / 0 | 0 / 0 |
| worst far-field pass | 15.7 ms | 15.2 ms |

The request is what the finer singular footprint selects, so 8x asks for a finer mip at grazing
angles: the near field's plan grows about **50%** and its page churn about 25% with it. Nothing in
the probe was capacity-starved for it (`avt_missing` stays 0, both wait counters stay 0) and the far
field's own miss count barely moves - the cost lands where 8x is meant to spend it. The gutter's own
arithmetic is separate and certain: a stored page is `page_size + 2 * border`, so 264 -> 274 texels
is **7.7% more texels a page**, and under compression the encoder's 96 MB byte ceiling admits about
40 ring positions instead of 46, which is a compressed rate ceiling of ~20 pages a frame instead of
~23. A page-sized run is bounded by its slot count and does not move.

## Regressions

* Standalone VT contract tests cover front-facing, grazing and rolled Jacobians,
  plus conservative bounds over 20,000 random matrix intervals.
* `vt_anisotropy_runner.py` checks native fine-page demand and renders distinct
  fine/coarse page colors at three grazing orientations, including a rolled view.
  `vt_anisotropy.gd` also pins the rule that decides the number the shader and the
  planner may assume: the request clamped by the sampler's tap count *and* the
  gutter, read live in both directions (a 4x viewport under a nine-texel gutter reads
  4; an 8x viewport reads 8; a four-texel gutter caps it at 3.5). It then renders a
  saturated grazing pose twice - bound to 8 and to 4 - over a one-texel noise page and
  its box-averaged parent, and asserts that the page chosen for 8x reads noisier
  (measured 0.0677 against 0.0362, a 1.87x ratio; the window is 3 x 51 pixels and the
  assertion is `> 1.25x`). A precondition asserts the two assumptions land on
  different resident pages (fine at 8x, its parent at 4x), so the measurement cannot
  silently become a comparison of one page with itself.
* `vt_snap_turn_runner.py` checks camera-cut planning and normal-plan reuse.
* `vt_project_lifetime_probe.py --project F:/godot/project/test-1 --motion snap`
  alternates 180-degree views in a copied project, recording CPU diagnostics and
  sparse rendered images. It does not modify the source project.

Run graphical probes serially after rebuilding the native extension.

## Recorded project comparison

On this machine (RTX 3080 Ti, D3D12/FRP, 640x360), the same copied `test-1`
project was run with the preserved pre-change DLL and final debug DLL. Four
240-frame moving windows, excluding initial loading and the final stationary
window, averaged:

| Measurement | Before | After |
| --- | ---: | ---: |
| Terrain VT CPU per tick | 0.818 ms | 0.658 ms |
| Whole viewport GPU per frame | 0.543 ms | 0.508 ms |

Logs: `bin/terrain-project-lifetime-ke6fwkn0/baseline_orbit.log` and
`final_orbit.log`. GPU values include the whole viewport and measurement noise;
they do not isolate the cost of anisotropic sampling. The finer-page version
before source-queue optimization measured approximately 0.922 ms CPU, so the
batching optimization is material to the final result.

The separate 180-degree probe (`final_snap.log`) reached zero missing/pending
AVT pages by sampled frame 31 and zero held/ramping pages by sampled frame 63.
Before the cadence change, 16 pages were still ramping at frame 63. This is
bounded streaming convergence, not an assertion that an uncached view is fully
sharp on its first frame.

Final validation: native debug/release builds and standalone contracts passed.
D3D12 rendered regressions passed for anisotropic mip selection, exact camera
reversal, page-arrival fades, BC7/uncompressed lost-page recovery, settled idle
cost (0.0605 ms), and eight-page shared-pool pressure with movement and edits.
The final idle result is comparable to the earlier 0.0611 ms measurement.

## Strict coverage and shared-budget repair (2026-09-21)

The feedback property controls coarse recovery in the shader; it is not a GPU
request-feedback switch. Turning it off must not change CPU request production.
A settled CPU plan therefore has to describe the same LOD that the shader selects.

The 1920x1080 `test-1` reproduction exposed two independent failures. The AVT
budget reserved SVT detail but omitted its permanently protected roots. A
768-page near plan could compete with 320 far roots plus visible far detail in a
1024-slot pool. Separately, the refinement walk counted temporary intermediate
nodes as resident pages, then discarded requested children without telling the
shader to change LOD. The CPU could report zero missing requests while the image
still contained missing-page diagnostics.

The responsibilities now remain separate:

* The hierarchy computes available capacity from protected SVT roots and visible
  detail. Root-count changes invalidate the plan key. Combined AVT/SVT reserves
  at most a quarter of the pool for the permanent far root window (at least four
  slots); the existing root-window algorithm moves the entire window coarser.
  World coverage and the number of requested root levels are preserved where
  capacity permits. This changes cold far-field fallback quality, not the
  distance-selected visible SVT detail LOD. This project needs 80 roots instead
  of 320.
* The planner separates its bounded traversal (at most eight times its page
  budget, with a 32-node minimum) from sampled residency. Optional intermediate
  nodes and the speculative fine apron do not force quality reduction. World
  roots and incomplete refinement parents remain requested. If sampled demand
  really exceeds capacity, a bounded bias search emits both a fitting page set
  and its explicit `mip_bias`.
* Installing the plan publishes its sampling density to the material. Both CPU
  density bounds and GPU derivative LOD use `texels_per_pixel * 2^-mip_bias`.
  `capacity_mip_bias` and `sampling_density_scale` are reported in AVT statistics.
  Budget rejection is no longer treated as an asynchronous page that will
  eventually arrive at the original LOD.
* Production sorts coarse-first by world footprint, not local mip number;
  local mip numbers differ between independently sized sectors, and world roots
  have mip zero. Refill revisits unfinished requests skipped by the readiness
  snapshot without requeueing successfully consumed requests. Queue capacity,
  page count, and the 16-page production ceiling are unchanged.

`vt_strict_coverage_runner.py --project F:/godot/project/test-1` copies the
project and checks feedback-off image coverage as well as native missing/pending
counts. At 1920x1080 with a -20-degree camera pitch, the old DLL never settled:
final images contained 1,409 and 7,329 diagnostic pixels even with CPU missing
and pending both zero. The repaired four-view run had zero diagnostic pixels
and zero missing/pending at every final viewpoint. All those final views used
`capacity_mip_bias=0`. Full-image Python scans additionally verified the final
PNGs; the runtime diagnostic samples every eighth pixel. Per-frame readback
makes this a coverage test, not a representative streaming-speed benchmark.
The final binary also passed a fixed 64-page variant: all final images and native
missing/pending counts were zero while explicit capacity biases were nonzero.
This verifies that constrained capacity converges through a real LOD contract,
not by silently enabling feedback. Final native debug/release builds, standalone
contracts, anisotropic selection, snap handling, far root coverage, root-setting
lifetime, BC7/raw recovery and page-fade GPU regressions passed. The isolated
settled test produced zero pages for 150 ticks (approximately 0.065 ms per tick).

A separate paired run uses the same copied project, original 1024-page pool,
1920x1080 D3D12/FRP and six 240-tick windows, without image readbacks. Measurements
on the RTX 3080 Ti machine were:

| Measurement | Previous DLL | Repaired DLL |
| --- | ---: | ---: |
| Terrain VT CPU, all four moving windows | 0.704 ms | 0.725 ms |
| Terrain VT CPU, three repeated moving windows after first fill | 0.685 ms | 0.684 ms |
| Whole-process CPU time per tick, all four moving windows | 8.431 ms | 7.682 ms |
| Whole-viewport GPU, all four moving windows | 1.022 ms | 0.998 ms |
| Terrain VT CPU, final stop/settle window | 0.377 ms | 0.247 ms |

The first moving window pays for more valid detail; it is not a universal
main-thread speedup. Whole-process CPU includes renderer, scripts, workers and
measurement noise. Initial loading/shader compilation is excluded. Logs and
JSON summaries are in `bin/terrain-project-lifetime-ke6fwkn0/streaming_*_orbit*`.
The fixed physical pool does not imply identical CPU payload memory: keeping
more valid near pages raised this run's repeated-window static-memory plateau
from roughly 620 MB to 680 MB. These are whole-project Godot counters, not a
measurement of a growing allocation or a claim of unchanged RAM usage.

An uncached view cannot be guaranteed full detail on its first frame within a
fixed asynchronous production budget. Coarse recovery and page fades maintain
coverage and soften arrival; they do not make missing fine detail resident.
Strict feedback-off rendering intentionally exposes transient misses. A strict
no-visible-refinement requirement needs advance loading, enough resident capacity
for the intended camera views, or direct material evaluation with its separate
GPU cost. This repair does not silently enable feedback or source evaluation.

## Near-detail arrival scheduling (2026-09-21 follow-up)

The earlier global world-span sort made nearby fine pages wait for distant
coarse work. `terrain_vt_request_priority.h` now defines the shared, typed order:
coverage roots, current visible distance bands, then optional apron/retained
requests. Within a distance band, parents precede children. Metadata is computed
with the worker plan, so the main thread does not calculate logarithms per
missing page. Priority contracts cover ordering and non-finite distances.

Ready material pages no longer enter a second rate limiter. Every ready batch
starts its existing fade together, at zero weight on the first displayed frame.
The bounded slot FIFO remains for lifecycle/deduplication, but its cadence was
removed. Pages produced on different ticks can still start on different ticks;
this is not a promise of an atomic whole-view transition.

The fine resolve remains strict when feedback is disabled. Transition-parent
lookup independently allows skipping absent intermediate parents to a resident
ancestor. This avoids bypassing a page fade just because its direct parent is
missing. The new rendered transition test checks blue ancestor, mixed midpoint,
red fine page, then a strict diagnostic after removing that fine page.

A further queue bug was exposed by near-first ordering: `prime()` called
`_make_room()` before consumption and evicted completed, still-wanted payloads
from its full 32-entry queue. Those pages were prepared again. Prime now stops
at capacity; the producer consumes ready results before the bounded refill.
Obsolete view requests are still removed by retain, and the single-request
poll path retains its existing eviction behavior. Final movement measurements
reported zero worker evictions. Neither production budget nor pool size grew.

### Temporal image evidence

`vt_near_arrival_runner.py --existing-fixture` uses the copied test-1 scene at
1920x1080, D3D12/FRP, -20 degree pitch, 240 warm ticks, a 180-degree snap,
96 captured frames and 120 settle frames. Each frame's central 80% of the lower
half is compared against its own final reference at 160x90. These dark scene
images have small absolute errors; the metric measures the duration of detail
change, not a perceptual guarantee of invisible page edges. Readbacks also
mean sample indices are not real-time latency measurements.

| Metric | Previous DLL | Final DLL |
| --- | ---: | ---: |
| ROI mean absolute RGB error, sample 15 | 0.0039713 | 0.0016526 |
| Sum of ROI errors over 96 samples | 0.1405624 | 0.0816476 |
| Maximum ready pages held before fade | 109 | 0 |
| Final missing / pending | 0 / 0 | 0 / 0 |

Baseline report: `bin/terrain-near-arrival-run-3p5qj8rk/near_arrival_output/`.
Final report: `bin/terrain-near-arrival-run-xfilvd_y/near_arrival_output/`.
This is approximately 58% lower error at sample 15 and 42% less accumulated
image change. It does not prove arbitrary uncached turns are imperceptible.

### Cost and regression checks

The same six-window, 240-tick movement benchmark was run without screenshots.
An initial run showed higher CPU (repeated moving windows 0.707 to 0.816 ms),
so this was checked again in reverse binary order. The repeat measured:

| Metric | Previous DLL | Final DLL |
| --- | ---: | ---: |
| VT CPU, repeated moving windows | 0.6711 ms | 0.6707 ms |
| VT CPU, all moving windows | 0.7103 ms | 0.6919 ms |
| Viewport GPU, repeated moving windows | 0.9848 ms | 0.9223 ms |
| VT CPU, final stop window | 0.2408 ms | 0.2525 ms |

These runs show substantial timing variability; the matched reverse-order run
supports approximately unchanged steady movement CPU, not a universal speedup
or a hard CPU ceiling. All raw runs are retained as `near_*cpu*.log` under
`bin/terrain-project-lifetime-ke6fwkn0/`. The priority-only intermediate binary
also showed wasteful queue evictions and was superseded by the queue repair.

Debug and release builds, standalone contracts, 20/40-frame fade rendering,
strict transition-parent rendering, and three anisotropic camera orientations
passed. The final queue-repaired binary additionally passed the actual-project
feedback-off static plus two-turn coverage test, with final missing/pending
and diagnostic sample counts zero (`near_strict.log` / `near_strict_output`).
The actual test-1 addon is a junction to the rebuilt source addon; restarting
a running scene/editor is necessary to load its new native DLL.
