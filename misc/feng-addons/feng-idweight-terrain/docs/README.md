# Terrain addon documentation

Read in this order:

| Document | Read it for |
| --- | --- |
| [`vt_architecture_review.md`](vt_architecture_review.md) | **Start here.** What the surface virtual texture is today: the module map, the controls and their units, the frame flow, the far/near split, baked sources and the editor/shader specialisation. |
| [`terrain_vt_and_streaming.md`](terrain_vt_and_streaming.md) | Why it is built this way: the addressing contract, the design of each subsystem, the rules the implementation is built around, and the per-subsystem verification commands. |
| [`cdlod_and_capture.md`](cdlod_and_capture.md) | The optional quadtree/MultiMesh geometry backend and RenderDoc capture. |
| [`vt_frame_budget.md`](vt_frame_budget.md) | Measured CPU/GPU costs and the budgets the demand passes obey. |
| [`vt_lifetime_review.md`](vt_lifetime_review.md) | CPU monitor units, sustained page arrivals, plugin ownership fixes, HDRP comparison and project reproduction. |
| [`vt_sampling_review.md`](vt_sampling_review.md) | Grazing-angle anisotropic sampling, matching CPU demand, camera-cut scheduling and regressions. |
| [`vt_compression_review.md`](vt_compression_review.md) | Baked normal-space contract, unified page compression, encoder corrections and fast-view scheduling. |
| [`vt_uncommitted_architecture_review.md`](vt_uncommitted_architecture_review.md) | Working-tree architecture audit, shared policy cleanup, compatibility and allocation constraints. |
| [`engine_patch_surface.md`](engine_patch_surface.md) | The only engine-side changes this addon depends on, and how to re-apply them after an engine upgrade. |
| [`vt_material_blending.md`](vt_material_blending.md) | How a page's material is composited when neighbouring cells differ. |
| [`terrain_optimization_audit.md`](terrain_optimization_audit.md) | The audit that produced the current code: source inventory, what was measured, what was deferred. Chronological; later sections supersede earlier ones. |
| [`history/vt_tuning_log.md`](history/vt_tuning_log.md) | Chronological tuning passes with their measurements. Superseded by the architecture review; kept for the numbers. |

Test documentation, including the full-regression command, is in
[`../native/tests/README.md`](../native/tests/README.md).
