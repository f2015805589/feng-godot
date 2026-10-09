# VT tuning history

This record keeps the dated changes and measurements from the September 2026 VT work.
Current ownership and runtime behavior are described in the
[architecture guide](../vt_architecture_review.md), the
[addressing and streaming guide](../terrain_vt_and_streaming.md), and the
[test guide](../../native/tests/README.md). Measurements below are specific to their
fixtures and are not fresh results for the current tree.

## Changes retained

| Date | Work | Change and resulting contract |
| --- | --- | --- |
| 2026-09-13 | Demand and residency | The planner stopped reserving half the physical pool for AVT, removed SVT CPU-only mip coarsening, and routed visible SVT source work through its worker. Source workers publish height-bound snapshots; later slope-projection demand and ready-page retention fixed settled repeated-turn hill coverage. Frustum clipping uses polygon bounds and tested height planes. Missing required pages still use the diagnostic checker. |
| 2026-09-13 | Planning and production | Planning and source preparation use persistent workers over immutable snapshots. Completed demand survives a replacement plan; AVT and SVT share a sixteen-new-page frame budget. The 40 μs production slice is a soft phase budget, not a whole-update deadline. |
| 2026-09-13 | Pool growth | Auto Capacity can grow the shared pool to 1024 pages while preserving owners, jobs, addresses, and ready material results. Migration copies existing pages separately from newly generated pages and may copy more than sixteen pages in one frame. At 256-texel pages with a four-texel border, the recorded 1024-page estimate is about 2.13 GiB; migration temporarily holds both arrays. |
| 2026-09-13 | Stationary editor updates | `has_pending_indirection()` keeps the normal editor draw loop active while a submitted upload is waiting for consumption. It does not force a draw or spin when a failed upload has no patches left. The idle regression caught an upload stall after the baker queue had emptied. |
| 2026-09-13 | CPU reuse | SVT reuses visibility results for ancestors in the same region. AVT remaps requests only when the directory or logical scale changes, performs exact residency lookup in one atlas query, and reserves known temporary request capacity. An experimental coarse AVT fallback remained separate from precise demand. |

The source-worker, page-fade, and lifetime contracts are in the architecture guide.
The coarse-recovery toggle described by one experiment is historical; current sampling
behavior is documented in the addressing guide.

## Recorded measurements

| Fixture | Result |
| --- | --- |
| Initial 1280×720 hill probe; 256 physical pages, 1024 texels/m, 90 m hill, alternating 0°/90° views | The half-pool planner left about 283,339 diagnostic pixels. Demand sharing removed the first-view holes; repeated turns still showed 25,615 pixels (2.78%). The probe used camera `(256,55,256)`, pitch −35°, and 240 update frames per view. |
| Initial ordinary rotation | CPU updates averaged 0.369 ms while filling and 0.061–0.070 ms when warm; a view change peaked at 1.467 ms, versus 0.227–0.243 ms on repeated warm turns. |
| Repeated-turn hill fix; five 1280×720 views, 300 frames each | Every settled image had zero diagnostic pixels. D3D12 hill CPU updates averaged 0.053–0.071 ms and peaked at 0.243–0.303 ms. Ordinary rotations averaged 0.031–0.100 ms; a new direction peaked at 0.801 ms. |
| Continuous navigation; 1920×1080, 16 settled directions and 24 movement checkpoints | The recorded D3D12 and Vulkan images had zero settled diagnostic pixels; peak generation was 16 pages and 147 ready pages migrated without resetting cache generation. A copied 64-cell test-1 scene completed three surface-following paths with 64/64 SVT bakes and no settled diagnostic pixels. |
| Continuous-navigation CPU follow-up | AVT update peaks were 1.325 ms on D3D12 and 1.243 ms on Vulkan. Whole terrain physics-notification peaks were 4.284 and 4.058 ms, including work outside AVT and excluding worker/GPU timing. |
| Stationary editor upload | The idle viewport reached zero missing pixels. A field-extraction variant without the pending-upload wakeup remained at 1,681,252 missing pixels in three byte-identical runs; restoring the wakeup passed the same check. |
| CPU query reuse | AVT peak was 1.472 ms on D3D12 and 1.253 ms on Vulkan; whole physics-update averages were 0.184075 and 0.180674 ms. Async edit/content/teardown sampled 104,209 checks. The average was lower in that comparison, but the peak did not establish a stable reduction or meet 0.1 ms. |

The runs varied by driver, camera motion, pool state, and measured phase. CPU update time,
whole physics time, source-worker time, and viewport GPU time are separate metrics. The
recorded artifacts are under `bin/terrain-vtadaptive-*` and `bin/vt-editor-idle-*`; those
ignored directories may not be present in a checkout. The focused commands are collected
in the [test guide](../../native/tests/README.md).
