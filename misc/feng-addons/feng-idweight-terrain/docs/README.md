# Terrain documentation

## Current contracts

| Document | Subject |
| --- | --- |
| [Architecture](vt_architecture_review.md) | Ownership, defaults, frame flow and lifetime |
| [Addressing and streaming](terrain_vt_and_streaming.md) | Regions, slots, AVT/SVT addresses, readiness and cell sources |
| [Delivery assembly](vt_delivery_assembly.md) | Channel matrix, Clipmap implementations/profiles, incremental baking and detail cache |
| [AVT page table](avt_page_table.md) | Sector tiers, coarse coverage and Inspector preview |
| [Sampling](vt_sampling_review.md) | Anisotropy, camera cuts, strict plan LOD and regression entry points |
| [Compression](vt_compression_review.md) | Canonical normals, per-tier codecs and encoding |
| [CDLOD and capture](cdlod_and_capture.md) | Geometry modes, shared edges and normal-budget frame capture |
| [Engine interfaces](engine_patch_surface.md) | Render callback, GPU buffer copy and upgrade checks |
| [Native tests](../native/tests/README.md) | Build prerequisites, runner inventory, fixture rules and coverage |

## Historical evidence

The following records preserve earlier decisions, build identities, measurements and limitations.
Their pass/fail status and temporary hypotheses do not describe the latest source tree.

- [Optimization audit](terrain_optimization_audit.md): historical decisions, reading ledger, image/performance data and artifacts
- [Reference AVT comparison](vt_reference_avt_alignment.md): demand, rate, residency and fallback experiments
- [AVT addressing redesign](avt_addressing_redesign.md): threshold, coarse reservation and planning-order evidence
- [Frame budgets](vt_frame_budget.md): successive CPU/worker measurements
- [Lifetime review](vt_lifetime_review.md): monitor units, bounded ownership and copied-project observations
- [Tuning log](history/vt_tuning_log.md): dated 2026-09-13 experiments
- [Clipmap pre-fix baseline](../native/tests/baselines/clipmap-material-baseline-2026-09-23.md)

Current-contract documents label their own historical measurement sections separately.
