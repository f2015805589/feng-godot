# FRP Runtime and Terrain Performance (2026-10-07)

Historical record: results and open findings apply to the builds and environments named below.
Current contracts are in [addon architecture](frp-addon-architecture.md) and
[engine contract](frp-engine-contract.md).

**Evidence status:** The validated code/build baseline is built. Focused `1e28` GBuffer, array-slice, material-hint, FRP post, exposure-lifecycle, and final editor/game performance windows completed. The performance windows are short matched workload captures, not a general cold-streaming or all-platform guarantee. Broader platform/feature coverage remains unverified. The 45b measurements below are historical and are not measurements of current HEAD. Supporting relative artifact paths are rooted at `C:\Temp\feng-frp-ue-tonemap-perf-20261006` unless a full path is shown.

## Validated source and build

The validated code/build baseline at test time was `1e28d1f2e3e1323ad32f3ddfa8d9dfa40da0cf40`, with `45b3a6a48a36cd6adc6b65c39a4857fd073ba54f` as the world-route-cache ancestor, the 13-file (+228/−39) FRP sRGB BaseColor/GBuffer change below it, and a one-file resolve-format correction on top. A later documentation-only integration may change repository HEAD without changing the tested executable. The standard editor build for `1e28d1f2` completed SCons exit 0 in 56.31 seconds. Build manifest: `C:\Temp\ue-gbuffer-color-20261007\build-1e28d1f2\build_manifest.txt`; log: `...\engine-scons.log`. GUI SHA-256 `0B035CD5D0B492D733C24C2A400EFF1448839499E2F929797D8E6A320C169220`; console SHA-256 `521189E2C6F4EF7FD1914DB4FD44ACD6ECDC5F5533C0EF52B9E81B8C9AF7F25E`. The build did not run C++ tests or GPU tests.

## Editor measurements

The first three historical rows use a 1569×839 viewport and lens FOV 70.01°, near 0.05, far 4000.01. The first is the prior c71 run. The next two are 45b addon/source measurements using the 6ee editor executable (runtime hash 6ee940a489c289afe2efc6165982cc089207f5c4; GUI SHA-256 11FA3FB15BA3BD9CCDA3C3E2EAF9C2CE7C863978D589D7F8FDBC8915247D76B1), with the 45b viewport-route snapshot SHA-256 5C36FA265C669C419E7E9101DE049086EA4947A6FFCB2342F7826290CE106BCD.

| Moving stage | Wall P95 | Viewport CPU P95 | Viewport GPU P95 | Important condition |
|---|---:|---:|---:|---|
| c71, preview OFF | 15.730 ms | 1.557 ms | 4.057 ms | Older engine/source baseline |
| 45b, preview OFF | 8.474 ms | 1.127 ms | 2.256 ms | Normal editor VT path in the 45b addon/source snapshot; measured on 6ee executable |
| 45b, preview ON | 8.220 ms | 0.935 ms | 2.148 ms | Editor-only VT Preview path in the 45b snapshot; different residency/material workload |
| 1e28, preview OFF | 8.417 ms | 1.030 ms | 2.271 ms | Final current-build 10 s moving window; 1569×839; mode 5 |

The 45b Preview-OFF and Preview-ON summaries are in `terrain-current-95d5\perf_data_editor_45b_owner_cache_mode5_off_retry2\editor_summary.json` and `...\perf_data_editor_45b_owner_cache_mode5_preview_on\editor_summary.json`. The OFF summary records preview inactive and 901 AVT ready slots; ON records preview active and 20 ready slots. Preview ON intentionally skips normal near/far VT service work. It is not an equal-quality or shipping-game comparison. The c71-to-45b OFF comparison also changes the compiled editor identity, so it does not isolate the 45b source change as the sole cause. These are useful measurements, not proof of a general causal speedup.

The final 1e28 editor capture is `terrain-current-95d5\perf_data_editor_final_1e28_20261007\editor_summary.json`; its raw logs are `final-editor-1e28-20261007-retry1.stdout.log` and `.stderr.log`. The frozen `CC494` scene was not edited. The run used an RTX 3080 Ti, 1569×839 viewport in a 2560×1337 window, camera position `(-1549.099, 3.570319, 198.093)`, rotation `(-0.266959, 1.800682, 0)`, FOV 70.01°, near 0.05, far 4000.01, mode 5, native 7, Environment tonemap 0, VSync 0, max FPS 0, Tracy disconnected, and VT Preview OFF. Moving ran 1450 frames for 10.061585 s: wall P50/P95/P99/max 6.885/8.417/9.801/12.850 ms, with zero frames over 16.7 ms; viewport CPU P95/P99 1.030/1.420 ms and GPU 2.271/3.696 ms. Static ran 1450 frames for 10.057320 s: wall P95/P99 8.407/9.835 ms, CPU 1.006/1.253 ms, GPU 1.994/2.031 ms, and zero frames over 16.7 ms.

Across the editor moving window, the producer boundary changed from 1828 to 2101 baked pages, 49 to 90 dispatches, 122 to 163 source-scatter calls, and 901 to 928 AVT-ready slots; encode failures and readbacks were zero. The registry diagnostic reported 362 viewports, a 361-entry world bucket, and 5 unique owner references. These are endpoint/counter observations, not per-frame cost attribution. The 1-second process-CPU monitor's maximum of 609.694 ms is a stale-window sample in that metric; it is not an individual frame time. The viewport wall-frame series itself had no frame above 16.7 ms.

The editor log records `RESULT=PASS`. The stderr also contains kept-addon warnings and two Safe Save errors for the scratch project. Its messages have no timestamps, so their timing relative to process exit is unknown; the run is not described as error-free. An earlier launch failed its guard and was not used for the measurements; retry 1 is the valid capture. The earlier attempt and its logs are retained with the other Temp artifacts.

These current results supersede the prior performance-pending status, but they do not isolate any one source change. The c71, 45b, and 1e28 measurements span different compiled engine/source packages and mode/workload details; the 45b Preview-ON run is also a different residency/rendering workload. The current 1e28 row is the final workload result, not an isolated before/after estimate for the GBuffer or registry changes.

## Trace alignment and attribution limits

The retained matched editor trace note is `audit\matched_editor_trace_alignment_20261006.md`. It aligns `editor_c71_cc494_matched.tracy` and `editor_bdc_mode5_connected.tracy`, not the current `1e28` candidate. The moving-stage windows are anchored to instrumented `_begin_stage` / `_finish_stage` events in the same Tracy clock as `MainLoop::process`: old `[81.556312526, 91.560289367)` s and new `[70.696235002, 80.711123753)` s. The note filters event start times, excludes the final serialization-contaminated `process` span, and records 816 old / 724 new moving frames. The old/new MainLoop `process` P95 excluding that boundary span is 11.701/15.301 ms, while viewport CPU P95 is 1.715/1.553 ms and viewport GPU P95 is 4.349/5.155 ms. Those traces are build- and tonemap-mode-confounded diagnostic evidence, not a causal estimate for the GBuffer change.

The nested Fog/Sky/route zones in that note are inclusive and overlap; do not add them. `NativePass.run_pass()` is the GDScript entry that dispatches an engine-native pass, so its inclusive span includes native work and any synchronization/wait inside that call. It is not a measurement of script-only overhead. A captured 16.58 ms frame/screenshot is likewise one frame observation, not a script-zone measurement.

The root-level Tracy CSVs were verified against the supplied user trace `F:\godot\trace\111.tracy` (83,316,945 bytes, SHA-256 `E1049F9373CF297B9951F3B8294BE3CEA94D28FBDA8589FAE3274305BB24091C`). Using the existing local `tracy-csvexport.exe` (SHA-256 `67D7AFED782BD84D8A2D4FA04F3D65062E7088BB54F3B7C90F628C3A97B1D144`), the summary command, `-e` self-time export, and `-u -f run_pass` event export all exited 0. Re-exported SHA-256 values match the existing root-level summary, self, and run-pass CSVs byte-for-byte. Commands, hashes, and exported files are recorded in `C:\Temp\feng-frp-ue-tonemap-perf-20261006\trace111-export-20261007-033042\provenance.txt`.

This single user trace's largest relevant inclusive scopes include `snapshot_worlds.gd::targets_for` (5.093 s over 2,965 calls; 4.690 ms max), `snapshot_worlds.gd::prune` (5.072 s over 2,965 calls; 4.674 ms max), `_prune_owners` (2.462 s over 1,532,352 calls), Fog `_publish` (4.955 s/1,058 calls), `_sync_debanding` (2.961 s/1,058), and Sky `_refresh_world_binding` (1.910 s/1,058). These are inclusive nested scopes, not additive totals: in the self-time export, `targets_for` contributes 17.3 ms total and `prune` 1.9 ms total; `_prune_owners` contributes 1.853 s self-time. `NativePass.run_pass()` accounts for 8,464 calls and 1.431 s total (0.169 ms mean, 17.564 ms max), but this is a native-call boundary with native work and possible waits inside it, not attributable to GDScript alone and not a GPU-time measurement. The `111.tracy` file is a single diagnostic capture, not a controlled before/after benchmark.

## Game measurements

The recorded 1152×648 moving-stage samples are:

| Run | Wall P95 | Viewport CPU P95 | Viewport GPU P95 | Frames over 16.7 ms |
|---|---:|---:|---:|---:|
| c71 earlier baseline | 13.142 ms | 8.005 ms | 7.983 ms | 22 |
| 6ee, VSync off, max FPS 0 | 7.732 ms | 2.946 ms | 7.526 ms | 2 |
| 1e28, mode 5, VSync off, max FPS 0 | 7.747 ms | 3.218 ms | 7.507 ms | 2 |

The final current run is `final-1e28-game-mode5-20261007\baseline_summary.json`, with stdout/stderr `final-game-1e28-20261007-attempt2.stdout.log` and `.stderr.log`. It used the frozen `CC494` scene, 1152×648 viewport/window, mode 5, actual VSync 0, max FPS 0, realtime full-scene SkyLight capture (1 s interval, resolution 128, shadows enabled, full cull mask), and no Magic GI volume. Static ran 6740 frames for 10.310190 s: wall P95/P99 2.089/2.640 ms, viewport CPU 0.835/0.996 ms, GPU 0.777/0.784 ms, with no frames above 16.7 ms. Moving ran 2923 frames for 10.134415 s: wall P50/P95/P99/max 2.044/7.747/9.408/19.128 ms, viewport CPU 3.218/5.133 ms, GPU 7.507/7.588 ms; two frames exceeded 16.7 ms and none exceeded 33 ms. Sky/fog effect ID changes were zero. The moving capture had 304 capture-busy frames; these frames' wall P95 was 7.769 ms and none exceeded 16.7 ms.

The stdout contains `RESULT=PASS` and the capture completed naturally, but the wrapper exit code was not recorded. Stderr reports one leaked UniformBuffer RID, one Sampler RID, and one Texture RID; their owners were not identified. Do not infer clean teardown or ongoing memory growth from these three warnings. The current game and editor samples complete the requested short workload gates, but are not a guarantee for cold startup, arbitrary streaming patterns, or other hardware. As with the editor table, differences from c71/6ee do not isolate an individual optimization because build/source packages and run conditions differ.

## What the preview switch measures

The native predicate is `is_vt_editor_preview_active() = IS_EDITOR && vt_editor_preview` (`terrain_3d_vt_service.cpp:315-316`). In `terrain_3d.cpp` lines 193–202, active preview enters an explicit bake-only branch and returns; near/far VT surface updates return early (`terrain_3d_surface_views_near.cpp:198`, `terrain_3d_surface_views_far.cpp:83`), and material setup disables VT (`terrain_3d_material.cpp:284`). In normal game runtime, editor preview is inactive and the normal VT path continues. Thus the preview-ON editor row changes the workload and residency state; it must not be presented as a performance improvement that preserves runtime rendering quality.

## Source interpretation and correctness evidence

The [dated source audit](frp-source-audit-20261007.md) records the registry, upload,
BaseColor storage, material-uniform and MSAA resolve changes, their exact build identities,
correctness gates and limits. Current interfaces are in [the engine contract](frp-engine-contract.md).
The performance rows here compare complete workload/build packages, so they do not isolate
those individual changes. Preview ON additionally changes the editor's rendering workload.

A historical producer snapshot recorded 863 packed upload/scatter calls for 12,266 pages and
5,207,358,576 payload bytes, with BC7 active and zero encode failures/readbacks. The two-layer
266×266 R16/R32F comparison at
`C:\Temp\feng-frp-ue-tonemap-perf-20261006\vt-gpu-codec-95d5\scatter-updatebit.stdout.log`
reported zero mismatches on the older 95d5 D3D12/RTX 3080 Ti build. These establish sampled
content and path activity, not an isolated throughput gain or current-build acceptance.

Earlier 6ee gates covered FRP post and authored-white Volume modes 2/4/inherit−1, whites 1.0/16.29,
enable/removal and zero pixel delta. The b866 tone-LUT reference reported maximum difference
0.0021742 versus UE's 10-bit SDR LUT after output clamp. A 6ee fixed-Sky Fog probe checked a
single pre-exposure application. These are earlier feature checks, separate from the 1e28
GBuffer gates and the workload measurements above.

## Artifacts, warnings, and scene state

- The 45b editor stderr capture recorded overflow counts 528 (Preview OFF) and 482 (Preview ON). The captured stderr has no event timestamps, so the timing of those overflow messages relative to process exit is unknown.
- The OFF and ON Temp-project stderr files also contain safe-save failure messages (OFF lines 15 and 527; ON lines 15 and 463) for the scratch benchmark project. These are Temp-path warnings; they do not establish a failure to save the user's project. The available records are insufficient to claim the runs were error-free or that every message occurred after editor exit.
- The final 1e28 editor retry-1 stderr contains kept-addon setup warnings and two Safe Save errors for its Temp scratch project; message timestamps are unavailable. The final 1e28 game attempt-2 stderr has three un-attributed leaked-RID warnings (UniformBuffer, Sampler, Texture), while its wrapper exit code was not captured. Preserve these warnings when interpreting the `RESULT=PASS` output.
- A later run overwrote the original `paired-game-bdc-mode5-final-repeat-mode5` output directory. Preserved stdout/stderr support the reconstructed summary `archive-reconstructed-20261007\game_bdc_mode5_final_repeat.reconstructed.json`; the original raw PNG and frame JSONL from that run cannot be recovered. Do not use reconstructed metrics as a replacement for C's current gate.
- `CC494` is the frozen benchmark scene state. `035` and `51B` are later external user-saved scene states; they were not edited by this work.
- Focused `1e28` GBuffer output/slice, material-hint compile/draw, FRP post, exposure-lifecycle, and short editor/game performance windows completed on their tested D3D12/Vulkan paths. Broader Metal/older-Vulkan/VR coverage, MSAA source-sample selection, arbitrary/cold streaming behavior, and C++ unit/integration tests remain **UNVERIFIED**.

