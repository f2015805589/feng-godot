# FRP runtime and terrain performance (2026-10-07)

This record describes named historical builds and workloads. Current interfaces are documented in [addon architecture](frp-addon-architecture.md) and [engine contract](frp-engine-contract.md).

## Editor workloads

Values are p95 milliseconds in wall-frame / viewport CPU / viewport GPU order. The first three rows use a 1569×839 viewport and 70.01° FOV.

| Snapshot and condition | Frames | Wall / CPU / GPU p95 |
|---|---:|---:|
| c71, preview off | — | 15.730 / 1.557 / 4.057 |
| 45b, preview off | — | 8.474 / 1.127 / 2.256 |
| 45b, preview on | — | 8.220 / 0.935 / 2.148 |
| 1e28, preview off, moving | 1,450 | 8.417 / 1.030 / 2.271 |
| 1e28, preview off, static | 1,450 | 8.407 / 1.006 / 1.994 |

The final 1e28 moving capture ran 10.061585 s: wall P50/P95/P99/max 6.885/8.417/9.801/12.850 ms, CPU P95/P99 1.030/1.420 ms, GPU P95/P99 2.271/3.696 ms, and no frames exceeded 16.7 ms. Static ran 10.057320 s; wall P95/P99 was 8.407/9.835 ms, CPU 1.006/1.253 ms, and GPU 1.994/2.031 ms.

A separate forced VT-preview attribution run recorded 580 static and 563 moving frames. Moving p95 was 8.512 ms wall, 2.634 ms viewport CPU and 1.921 ms viewport GPU. Its producer counters were 1,217 source uploads and 516.7 MB of upload-buffer traffic, including startup and warmup.

## Game workload

The moving-stage sample used a 1152×648 viewport.

| Snapshot and condition | Wall p95 | Viewport CPU p95 | Viewport GPU p95 | Frames over 16.7 ms |
|---|---:|---:|---:|---:|
| c71 baseline | 13.142 ms | 8.005 ms | 7.983 ms | 22 |
| 6ee, VSync off | 7.732 ms | 2.946 ms | 7.526 ms | 2 |
| 1e28, mode 5, VSync off | 7.747 ms | 3.218 ms | 7.507 ms | 2 |

The final 1e28 static game window ran 6,740 frames over 10.310190 s: wall p95/p99 2.089/2.640 ms, CPU 0.835/0.996 ms and GPU 0.777/0.784 ms. The moving window ran 2,923 frames over 10.134415 s: wall P50/P95/P99/max 2.044/7.747/9.408/19.128 ms, CPU 3.218/5.133 ms and GPU 7.507/7.588 ms. Two frames exceeded 16.7 ms; none exceeded 33 ms. There were 304 capture-busy frames; their wall p95 was 7.769 ms and none exceeded 16.7 ms. Sky/fog effect ID changes were zero.

## Trace and producer observations

The 1e28 editor producer counters changed from 1,828 to 2,101 baked pages, 49 to 90 dispatches, 122 to 163 source-scatter calls, and 901 to 928 AVT-ready slots. Encode failures and readbacks were zero. A registry snapshot reported 362 viewports, a 361-entry world bucket and 5 unique owner references.

The matched Tracy note compares c71 and bdc mode 5, not 1e28. Its moving windows are [81.556312526, 91.560289367) s and [70.696235002, 80.711123753) s, with 816 and 724 frames. Excluding the final serialization-contaminated process span, MainLoop process p95 was 11.701/15.301 ms; viewport CPU was 1.715/1.553 ms and GPU 4.349/5.155 ms.

| Tracy scope | Inclusive total | Self time |
|---|---:|---:|
| snapshot_worlds.targets_for | 5.093 s / 2,965 calls | 17.3 ms |
| snapshot_worlds.prune | 5.072 s / 2,965 calls | 1.9 ms |
| _prune_owners | 2.462 s / 1,532,352 calls | 1.853 s |
| Fog _publish | 4.955 s / 1,058 calls | — |
| Fog _sync_debanding | 2.961 s / 1,058 calls | — |
| Sky _refresh_world_binding | 1.910 s / 1,058 calls | — |
| NativePass.run_pass | 1.431 s / 8,464 calls | — |

Nested scopes overlap; see the limits below before interpreting the totals.

## Focused checks

| Check | Recorded result |
|---|---|
| 1e28 GBuffer output/slice, material-hint compile/draw, FRP post and exposure lifecycle | Completed |
| 1e28 short editor and game windows | Completed on tested D3D12 path |
| D3D12 mode-0 32×32 transport | Nonzero radiance; no non-finite output |
| D3D12 mode-2 temporal smoke | history_valid=true; one view history; finite output |
| D3D12 orthographic smoke | Mode 3; history disabled; no view history; finite output |
| Native packets | Atmosphere 64 finite lanes, lane 50 = 1; separate 28-lane fog and 148-lane cloud-visibility packets |
| BlueNoiseScalar and stock kernel | 128×8192 R8_UNORM; decoded pixel SHA-256 B135DD62C73CDEE1920885D28BAF2B71643A0577934A77CDA6D584C35162DE0B |
| PCK runtime closure | 21 raw shader sources, 5 default resources; PNG payload byte-exact |
| Schema migration | Canonical schema 8→9 moves Fog/Trace and preserves parameters; custom order and duplicate IDs covered |
| Earlier 6ee feature checks | Volume modes 2/4/inherit -1; white values 1.0/16.29; enable/removal; zero pixel delta; b866 tone-LUT max difference 0.0021742; one fixed-Sky pre-exposure check |

## Conditions, provenance and limits

- The 1e28 source/build snapshot was commit 1e28d1f2e3e1323ad32f3ddfa8d9dfa40da0cf40, descended from 45b3a6a48a36cd6adc6b65c39a4857fd073ba54f with a 13-file (+228/−39) sRGB BaseColor/GBuffer change and a one-file resolve-format correction. SCons exited 0 in 56.31 s. Build manifest and log: C:\Temp\ue-gbuffer-color-20261007\build-1e28d1f2\build_manifest.txt and engine-scons.log. GUI SHA-256 0B035CD5D0B492D733C24C2A400EFF1448839499E2F929797D8E6A320C169220; console SHA-256 521189E2C6F4EF7FD1914DB4FD44ACD6ECDC5F5533C0EF52B9E81B8C9AF7F25E.
- Final editor run used frozen CC494, RTX 3080 Ti, viewport 1569×839 in a 2560×1337 window, camera (-1549.099, 3.570319, 198.093), rotation (-0.266959, 1.800682, 0), FOV 70.01°, near 0.05, far 4000.01, mode 5, Environment tonemap 0, VSync 0, max FPS 0, Tracy disconnected and preview off. Summaries: C:\Temp\feng-heightfog-repro-1dca-20261007\project\perf_data_baseline_42586_20261007 and perf_data_final_42586_20261008; final logs: final-editor-1e28-20261007-retry1.stdout.log and .stderr.log.
- 45b rows use runtime 6ee940a489c289afe2efc6165982cc089207f5c4 and GUI SHA-256 11FA3FB15BA3BD9CCDA3C3E2EAF9C2CE7C863978D589D7F8FDBC8915247D76B1. Summaries are under terrain-current-95d5\perf_data_editor_45b_owner_cache_mode5_off_retry2 and perf_data_editor_45b_owner_cache_mode5_preview_on. Preview activation is IS_EDITOR && vt_editor_preview; active preview runs the bake-only branch and near/far surface updates return early. It changes residency and material work compared with normal editor/game rendering. The c71, 45b and 1e28 rows differ in build/source package and workload, so they do not isolate one change.
- Final game used CC494 at 1152×648, mode 5, VSync 0, max FPS 0, realtime full-scene SkyLight capture at 1 s/128 with shadows and full cull mask, and no Magic GI volume. Summary: C:\Temp\feng-heightfog-repro-1dca-20261007\project\final-1e28-game-mode5-20261007\baseline_summary.json; logs: final-game-1e28-20261007-attempt2.stdout.log and .stderr.log.
- The separate VT-preview attribution run's counters are cumulative, not timestamped to its moving interval. Its measurements and source records are under C:\Temp\feng-heightfog-repro-1dca-20261007\project; they do not explain all editor stalls.
- The 95d5 producer snapshot recorded 863 packed upload/scatter calls for 12,266 pages, 5,207,358,576 payload bytes, BC7 active, and zero encode failures/readbacks. The two-layer 266×266 R16/R32F comparison at C:\Temp\feng-frp-ue-tonemap-perf-20261006\vt-gpu-codec-95d5\scatter-updatebit.stdout.log had zero mismatches on that older D3D12/RTX 3080 Ti build.
- Trace source F:\godot\trace\111.tracy was 83,316,945 bytes, SHA-256 E1049F9373CF297B9951F3B8294BE3CEA94D28FBDA8589FAE3274305BB24091C. tracy-csvexport.exe SHA-256 67D7AFED782BD84D8A2D4FA04F3D65062E7088BB54F3B7C90F628C3A97B1D144; exports matched the retained CSVs. Provenance: C:\Temp\feng-frp-ue-tonemap-perf-20261006\trace111-export-20261007-033042\provenance.txt. The trace is one diagnostic capture, not a controlled before/after run.
- The 45b editor stderr recorded 528 overflow messages with preview off and 482 with preview on. Temp Safe Save errors appear at lines 15/527 in the off log and 15/463 in the on log. The final 1e28 editor retry-1 stderr has kept-addon warnings and two Temp Safe Save errors; log timestamps do not establish when these occurred. The final game stderr reports one UniformBuffer, one Sampler and one Texture RID warning; the owner is unknown and the wrapper exit code was not captured. A later run overwrote the paired bdc game output directory; only its reconstructed summary remains.
- Performance.TIME_PROCESS is not CPU thread time. The 1-second process monitor's 609.694 ms maximum is a stale-window sample, not frame time. Tracy's targets_for, prune, fog and sky scopes are inclusive/nested; NativePass.run_pass includes native work and possible waits, so these values are not script-only or GPU timings. Measurements are short samples, not a platform-wide guarantee; cold streaming, Metal/older Vulkan/VR, MSAA source-sample selection, C++ unit/integration tests and arbitrary scenes were not covered.
