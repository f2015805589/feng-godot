# VT budgets and historical measurements

Current budget, worker and missing-page contracts are in
[the architecture guide](vt_architecture_review.md). This record preserves the earlier
Windows/D3D12 optimization measurements; it does not report a fresh run of the current tree.

## Current measurement contract

- Pool page count is residency capacity; page allowance is production work per tick/frame
- AVT's default/max batch governor, source window and encoder admission use the same live allowance
- Repeated render callbacks share the frame's producer accounting; offline cell baking is separate
- Phase CPU deadlines are soft and cannot interrupt one in-progress page
- AVT and SVT runtime source work use separate bounded worker queues over immutable snapshots;
  main-thread planning/publication and offline bake/export remain separate costs
- Feedback controls coarse recovery; current defaults enable it, and arrival ramps count ticks
- Compare phase mean/peak, plan/source work, readiness, queue debt and the age of worst snapshots

## Recorded progression

The rows describe successive fixtures from the original review, not interchangeable A/B populations.

| Stage / evidence | Recorded values and coverage |
| --- | --- |
| Settled D3D12 rotation, `terrain-vtadaptive-nrsu7k9p` → `terrain-vtadaptive-m1ocwm1b` | Phase means 0.441–0.554 → 0.061–0.082 ms; producing mean 0.912 ms; five settled images equal |
| Original 16-page budget regression | Two callbacks after 32 queued pages completed 16 and retained 16, then drained later; cached gradients and Debug/Release builds passed |
| Peak CPU follow-up, `terrain-vtadaptive-qujlebic/*-final-optimization.log` | CDLOD means 0.0593 / 0.0502 ms and peaks 0.106 / 0.078 ms at tessellation 0/1; VT loading mean 0.7677 ms, peak 3.004 ms; warm-turn peaks 1.432/0.192/0.266/0.254 ms |
| AVT source worker | Loading mean 0.401 ms, peak 1.036 ms; warm replan peak 1.611 ms; 12,069 edited payload samples, reconfiguration and pending teardown checked |
| Separate SVT source worker | Source-corner, pending reconfiguration, async edit, rotation and incremental-bake tests passed in the same fixture family |
| Strict-only sampling stage | Loading mean 0.385175 ms, peak 0.825 ms; warm means 0.05195–0.0620625 ms, peaks 1.424/0.193/0.196/0.202 ms; selected misses remained visible |

The old strict-only stage removed fallback/fade work for that experiment. Later code restored
configurable recovery and tick-based arrival ramps; its figures are retained only as historical
cost observations. None of these runs met a strict every-frame 0.1 ms CPU target.

The normal-material evaluator used at most three layers with two texture-gradient reads each;
slope evaluation could add one overlay-normal read per triangle vertex. These six/nine reads
exclude ID, height, page-table and cached-material accesses.

## Reproduction and artifacts

After rebuilding the native extension, use the [test guide](../native/tests/README.md).
The source-worker check is `vt_adaptive_runner.py --async-pages`; other focused gates are
`--blend`, `--rotation`, `--cdlod`, `vt_page_budget`, `vt_page_fade`, `vt_idle_cost`,
`vt_turn_budget` and `vt_auto_bake`. GPU tests require a real driver and run serially.

Original logs under `terrain-vtadaptive-qujlebic`:

- `vt_blend-svtasync-final.log`, `vt_async-svtasync.log`
- `vt_rotation-svtasync.log`, `vt_auto_bake-svtasync-final.log`
- `*-strict-final.log`, `vt_filtering-strict.log`

These local ignored artifacts may be absent from a fresh checkout. Timing includes scheduling
and queue waits; source-worker time, main-thread phase time, whole-viewport GPU time and image
readback diagnostics are distinct measurements.
