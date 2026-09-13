# VT frame budget and CPU work

The runtime shared material producer processes at most 16 page bake/copy jobs per
rendered frame, including repeated callbacks in that frame. Remaining jobs stay
pending. Readiness is cleared for deferred reused slots so old material cannot
leak through. Default and maximum VT pages-per-update are 16. Offline cell baking
is a separate producer, not a count of runtime physical-page updates.

Cache invalidation clears the readiness texture instead of shading all invalid
pages. Fine-page source-corner production no longer first builds and discards a
full output-resolution height image. Once all AVT arrival fades have completed,
the CPU stops scanning page dictionaries and uploading identical fade arrays;
new/invalidated pages reactivate the fade work. Material precision is unchanged.

Windows D3D12, 256-page rotation fixture: prior settled phase averages were
0.441–0.554 ms (`terrain-vtadaptive-nrsu7k9p`). New phase averages were
0.061–0.082 ms (`terrain-vtadaptive-m1ocwm1b`). The producing phase averaged
0.912 ms, so this does NOT establish an all-frame 0.1 ms guarantee or measure
all terrain/engine CPU work. Five settled images matched pixel for pixel.
The test now waits for geometry initialization before disabling automatic
physics updates, and explicitly snaps after camera turns; it renders one terrain
draw instead of timing an absent mesh.

The budget regression queues 32 cached pages and two callbacks in one frame:
16 complete and 16 remain pending, then all complete over later frames. Cached
material gradient checks and both native Debug/Release builds pass.

Page count is cache capacity, not work per frame. A 256-pixel page at 1024 texels/m
covers 0.25 m; the same pixel count at 2 texels/m covers 128 m. The current cache
uses array layers for physical slots in three material channels. Nearer pages
can cover smaller world rectangles without changing physical pixel dimensions.


## Peak CPU follow-up

The September 13 follow-up removes repeated source-coordinate evaluation from
R16 page generation, reuses identical sampled rows, and caches height-source
region lookups without changing the triangle interpolation formula. AVT fade
updates use a single locked readiness snapshot and fixed slot arrays instead of
per-slot dictionary lookups and locks. Invalidated/reused slots reset fade state.
The existing 200 ms fade and 16-page rendered-frame ceiling are unchanged.

CDLOD now skips instance-list packing when classifications are unchanged and
computes projection planes locally, avoiding a TypedArray round trip. Selection,
frustum tests, geometry, and shadow routing remain the same.

Final Debug DLL tests in `terrain-vtadaptive-qujlebic` (the
`*-final-optimization.log` files) passed CDLOD geometry/rotation, VT rotation and
source-corner blending/page-budget regressions. CDLOD turn CPU means were
0.0593 / 0.0502 ms for tessellation 0 / 1; peaks were 0.106 / 0.078 ms.
VT loading mean was 0.7677 ms and peak 3.004 ms; warm-turn peaks were
1.432 / 0.192 / 0.266 / 0.254 ms. These are fixture measurements on D3D12,
not a guarantee for the user's project, and neither subsystem satisfies a
strict every-frame 0.1 ms acceptance criterion.

AVT sector stats now expose allocation_ms, payload_ms, queue_ms and commit_ms.
Payload includes R16 source generation and its atlas upload; queue includes
height/corner preparation and baker enqueue. Full asynchronous source production
and GPU-driven CDLOD selection are not implemented by this follow-up. The
existing 3 ms soft production deadline cannot interrupt a single page and must
not be presented as a hard bound on total VT CPU time.


## Asynchronous AVT source pipeline

Sector AVT now submits bounded source requests to a persistent worker. The main
thread snapshots resident region ID/height PackedByteArrays once per source
revision; their copy-on-write storage stays alive for the worker. The worker
never dereferences Terrain3D, Terrain3DData, region objects or renderer resources.
It builds R16 payloads, source-corner grids and triangle-interpolated heights.

There are at most 32 queued/running/completed entries, plus a cancelled job that
may be finishing. The worker processes submission order (visible demand before
prefetch). Changed demand prunes old rectangles/addresses; unique tokens reject
late results after cancellation. Map edits and configuration resets invalidate
both snapshots and queued results. Exit signals and joins the worker before
terrain resources are destroyed. No worker join/wait occurs during page updates.
Physical slots are allocated only when prepared data is available. Main-thread
submission and the render-thread baker retain the existing 16-page limit.

`vt_adaptive_runner.py --async-pages` checks edited source payloads on the GPU
(12069 interior samples in the final fixture), reconfiguration and teardown with
pending work. Blending and rotation regressions also pass. The final measured
loading mean is 0.401 ms, peak 1.036 ms; warm-turn replanning peaks at 1.611 ms.
This is not a 0.1 ms guarantee. Page planning, snapshot creation, atlas upload and
indirection commit remain on the main thread. SVT cell loading/cropping and the
legacy/non-sector source path are unchanged; this worker covers sector AVT
source preparation, not every producer in the terrain system.


## Asynchronous SVT runtime loading

SVT runtime source production now uses a separate bounded worker queue, so disk
reads/decompression cannot block the AVT source worker. ID payload generation,
cell signature hashing/validation, file reads, Zstd decompression and source
rectangle cropping run against immutable snapshots off the main thread.
Signatures are cached per snapshot/material/density; decoded cell mips use a
bounded 256 MiB / 64-entry cache (one oversized cell mip may be retained alone).

The main thread retains residency ownership, cancellation and completed-result
publication. Slot invalidation cancels pending work before reuse; unique request
tokens reject late completions. Missing files are reported only after an actual
worker result and can trigger the existing auto-bake path. New cell bakes requeue
runtime loads. `svt_source_pending` distinguishes queued source work from GPU
baker jobs. Actual GPU bake/copy dispatches keep the shared 16-page/frame ceiling.

The old synchronous runtime decompression/crop path has been removed. Explicit
and incremental offline cell baking, disk writing and editor preview reads are
separate workflows; this change does not move those operations onto this worker.
Page-table GPU uploads already run through the render-thread callback queue.
Residency planning, snapshot capture, patch packing and render-command submission
remain main-thread work; asynchronous streaming does not imply zero CPU work or
a proven 0.1 ms maximum.

D3D12 tests in `terrain-vtadaptive-qujlebic` passed source-corner blending including
SVT reconfiguration while work is pending, async edit invalidation (12069 payload
samples), rotation, and automatic incremental SVT baking. The relevant logs are
`vt_blend-svtasync-final.log`, `vt_async-svtasync.log`,
`vt_rotation-svtasync.log` and `vt_auto_bake-svtasync-final.log`.


## Strict residency policy (supersedes arrival/ancestor fallback above)

At the user's request, missing selected pages remain magenta diagnostics. SVT
no longer searches coarser mips on a miss; AVT stops at a missing selected local
page or directory entry. Distance/pixel-footprint LOD selection and interpolation
between the normally selected mip levels are retained, but a missing required
blend input is not replaced by the other input. The AVT/SVT coverage blend also
requires both producers when both have nonzero weights. There is no automatic
VT-miss-to-editor-material path: the existing editor-preview switch is explicit,
not driven by page residency. The material-required diagnostic path is preserved.

Neighbour-availability coarsening and arrival-to-parent fading were removed,
including the CPU fade arrays/readiness scan and shader neighbour probes.
Queue polling now uses one lock per request, unchanged view plans skip request
list retention work, and refinement uses a priority queue preserving old priority
and insertion-order ties rather than rescanning all candidates at each split.

The normal source material accumulator uses at most three material layers, two
textureGrad calls per layer (albedo and normal): at most six material-texture
samples. Slope evaluation can add one overlay-normal read per contributing
triangle vertex, at most three extra, giving at most nine. ID/height/page-table
and cached-material lookups are separate; six is not a whole-pipeline total.
Slope blending was audited, not altered. A pixel uses three triangle vertices;
the quad's fourth ID corner is still read for pair-coverage logic.

Final D3D12 rotation fixture: loading mean 0.385175 ms, loading peak 0.825 ms;
warm-turn means 0.05195-0.0620625 ms and peaks 1.424/0.193/0.196/0.202 ms.
The all-frame 0.1 ms target remains unmet. Magenta changes during first loading
are expected under strict residency, not a claim of seamless streaming.
Tests passed normal material gradients, strict AVT/SVT blend-band misses with
other sources available, no original-material fallback, missing fine pages with
ready parents, normal mip continuity, async invalidation and incremental baking.
Logs: `terrain-vtadaptive-qujlebic/*-strict-final.log` and
`vt_filtering-strict.log`. Earlier fallback/arrival test policies are superseded.
