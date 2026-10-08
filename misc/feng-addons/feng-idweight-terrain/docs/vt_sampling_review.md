# AVT sampling and camera cuts

## Sampling contract

Sector AVT uses the singular values of the world-XZ pixel Jacobian:
`footprint = max(minor, major / anisotropy)`. CPU bounds over clipped patches and shader
world derivatives use the same effective anisotropy. The pure bound lives in
`terrain_vt_sampling.h`; planning receives an immutable view.

Physical pages use explicit world gradients and hardware anisotropic filtering.
Derivatives are taken before page-coordinate wrapping. The effective tap assumption is
`min(request, viewport_sampler, 2 * border - 1)`. A request of zero follows the viewport.
The default request is 8× and border 5; a 4× viewport therefore uses 4×. A 16× request
needs a border of at least nine and a matching viewport sampler.

The gutter bound follows `n / 2 + 0.5 <= border`, including bilinear support.
`get_avt_anisotropy()` is the CPU authority used by both material binding and demand.
Reports expose requested, sampler and effective values. Stored page width is
`page_size + 2 * border`; border costs affect both paged fields. SVT retains distance
mips and linear page filtering rather than this AVT derivative path.

## Motion, source queues and arrival

Cuts use the full angle between directions, clear stale prediction and request a fresh
plan. Large spatial deviations can bypass ordinary refresh spacing. Normal motion reuses
in-flight work and quantized plan keys. Residency remains reusable across cuts.

Production snapshots bounded ready source keys, consumes them in plan priority and retains
only needed payloads. Refill does not discard completed wanted data merely to admit more
work. Coverage roots precede current visible distance bands, then optional requests;
parents precede children within a band.

Every ready batch starts its configured arrival ramp without a second cadence limiter.
The slot-bounded FIFO handles ordering/deduplication; the fade pass owns readiness and
blending. The first released frame has zero new-page weight. Ancestor lookup can skip an
unready transition parent while the selected fine-page lookup still obeys strict mode.
The current tick duration and lifetime are documented in [architecture](vt_architecture_review.md).

## Strict coverage and capacity

`surface_vt_feedback` controls shader coarse recovery, independently of projected GPU
request feedback. Disabling it keeps CPU production active. The strict sampler follows
the installed capacity-limited page plan:

- A real slot with unreadable content or `PLANNED_PHYSICAL_PAGE_SLOT` (65534) is a late selected page
- An empty level (65535) is absent from the plan; lookup continues to the level the plan selected

This separates intended LOD coarsening from asynchronous page loss. The coarse owner and
SVT roots retain their own coverage/protection policies. AVT/SVT transition behavior is
in the architecture guide. Cold views still require bounded production, and strict mode
can expose transient misses.

## Regression entry points

After rebuilding, run graphics tests serially:

```sh
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_anisotropy_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_snap_turn_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_project_lifetime_probe.py --project F:/godot/project/test-1 --motion snap
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_strict_coverage_runner.py --project F:/godot/project/test-1
```

The standalone VT suite covers front-facing/grazing/rolled Jacobians and 20,000 random
matrix intervals. The anisotropy image test first proves its two assumptions select different
resident pages. Other gates cover fade/transition-parent rendering, lost readiness,
root coverage, fixed-capacity convergence and copied-project cuts.
`vt_near_arrival_runner.py --existing-fixture` measures temporal image convergence;
its readbacks are not real-time latency measurements. The [test guide](../native/tests/README.md)
defines all modes, drivers and isolation rules.

## Historical measurements

The following tables are from earlier Windows/RTX 3080 Ti D3D12 builds, not this documentation
revision. The anisotropy comparison used the then-default 512 m reach and a nine-texel gutter;
the later default is 384 m / five texels. The 640×360 project comparison used four 240-frame
movement windows. Later strict/arrival experiments used copied test-1 at 1920×1080.
Viewport GPU includes other rendering work. Reverse-order runs showed meaningful noise.

### Measured: what 8x costs the near field's working set

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

### Recorded project comparison

| Measurement | Before | After |
| --- | ---: | ---: |
| Terrain VT CPU per tick | 0.818 ms | 0.658 ms |
| Whole viewport GPU per frame | 0.543 ms | 0.508 ms |

### Strict coverage and shared-budget repair (2026-09-21)

| Measurement | Previous DLL | Repaired DLL |
| --- | ---: | ---: |
| Terrain VT CPU, all four moving windows | 0.704 ms | 0.725 ms |
| Terrain VT CPU, three repeated moving windows after first fill | 0.685 ms | 0.684 ms |
| Whole-process CPU time per tick, all four moving windows | 8.431 ms | 7.682 ms |
| Whole-viewport GPU, all four moving windows | 1.022 ms | 0.998 ms |
| Terrain VT CPU, final stop/settle window | 0.377 ms | 0.247 ms |

### Temporal image evidence

| Metric | Previous DLL | Final DLL |
| --- | ---: | ---: |
| ROI mean absolute RGB error, sample 15 | 0.0039713 | 0.0016526 |
| Sum of ROI errors over 96 samples | 0.1405624 | 0.0816476 |
| Maximum ready pages held before fade | 109 | 0 |
| Final missing / pending | 0 / 0 | 0 / 0 |

### Cost and regression checks

| Metric | Previous DLL | Final DLL |
| --- | ---: | ---: |
| VT CPU, repeated moving windows | 0.6711 ms | 0.6707 ms |
| VT CPU, all moving windows | 0.7103 ms | 0.6919 ms |
| Viewport GPU, repeated moving windows | 0.9848 ms | 0.9223 ms |
| VT CPU, final stop window | 0.2408 ms | 0.2525 ms |

The 8× experiment increased near residency about 50%; a separate 4×-sampler noise test
measured deviation 0.0692 when assuming 8× versus 0.0326 when matching 4× (3×51 pixel window).
Those figures describe sampling noise in one fixture, not a universal image-error bound.

The 2026-09-21 strict-coverage run changed final diagnostic pixels from 1,409/7,329 to zero
at four views, with missing/pending zero. A fixed 64-page variant also settled with an explicit
capacity LOD. More valid pages raised a recorded project-memory plateau from about 620 to 680 MB.
The subsequent near-arrival fixture used 240 warm ticks, a 180° cut, 96 captures and 120 settle
frames, comparing the central 80% of the lower half at 160×90. Dark-scene errors quantify
convergence, not imperceptible transitions.

The 2026-09-24 plan-marker experiment changed static diagnostic samples 2.19%→0 and final
turn samples to 0, first settled frame 21/240. The same budget denied 282/1050 refinements;
the explicit plan LOD reconciled sampling. Moving CPU measurements remained within their
run-to-run spread; producer mutex/publication cost remained a separate concern.

Recorded artifacts:

- `bin/terrain-project-lifetime-ke6fwkn0/baseline_orbit.log`, `final_orbit.log`, `final_snap.log`
- `bin/terrain-project-lifetime-ke6fwkn0/streaming_*_orbit*`, `near_*cpu*.log`
- `bin/terrain-near-arrival-run-3p5qj8rk/near_arrival_output/`
- `bin/terrain-near-arrival-run-xfilvd_y/near_arrival_output/`
- `near_strict.log` / `near_strict_output` in the copied fixture

These records reported focused Debug/Release, numerical and GPU gates; use fresh same-build
runs to establish current status. Restart a running editor/scene to load a rebuilt extension.
