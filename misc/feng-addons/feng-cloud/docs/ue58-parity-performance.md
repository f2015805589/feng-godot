# UE 5.8 cloud behavior and measurements

Recorded 2026-10-08. Source comparisons and measurements apply to the named source/build
snapshots. Current usage is in [the addon README](../README.md).

## Source comparison

| UE 5.8 contract | Feng implementation | Scope and remaining difference |
| --- | --- | --- |
| The default cloud component starts at 5 km, is 10 km thick, starts tracing at 350 km, and caps the primary ray at 50 km (`Engine/Source/Runtime/Engine/Private/Components/VolumetricCloudComponent.cpp:40-45`). | The default Feng component/material path uses the same authored shell and trace limits. Distances are expressed in kilometres in the component and converted for renderer packets. | These are the reviewed default values; this does not make arbitrary component/material settings interchangeable. |
| The cloud view jitters its ray start with `BlueNoiseScalar(FullResPixelCoord, StateFrameIndexMod8)` (`Engine/Shaders/Private/VolumetricCloud.usf:801-804`). UE cloud view, reflection, shadow, and Sky AO permutations force texture mip 0 (`Engine/Source/Runtime/Renderer/Private/VolumetricCloudRendering.cpp:847-855, 964-975, 1047-1057, 1396-1406`). | Feng loads the preserved 128×8192 BlueNoiseScalar payload once on the main thread, samples the half-pixel trace coordinate with the eight-frame wrap, and uses the midpoint for SkyLight capture. The default material kernel uses explicit mip 0 for its UE layout textures. | The copied source payload and sample/addressing contract are recorded. It has not been compared against every platform’s UE cooked texture. |
| UE writes its cloud representative depth as the transmittance-weighted `tAP`: accumulation is gated by positive extinction and uses `min(TransmittanceToView)` as the weight (`VolumetricCloud.usf:1226-1230, 1492-1497`). | Feng keeps first-hit depth in `x`, the corresponding weighted representative depth in `y`, and opaque near/far bounds in `z/w`. Composition, history tests, and transparent cloud coverage use the representative `y`; retaining first-hit `x` is an additional Feng output. | Feng’s extra first-hit channel is separate from the UE-style `tAP` representative depth. |
| UE reprojection samples the representative depth at the current low-resolution trace texel (`VolumetricRenderTarget.usf:285-299`). The default disocclusion cutoff is 5 km (`VolumetricRenderTarget.cpp:67-68`); near/far depth bounds participate in reprojection rejection (`VolumetricRenderTarget.usf:402-404`). | Feng’s temporal resolve uses the center trace texel for history reprojection, preserves the representative depth and opaque bounds with selected history, and applies the reviewed MMD distance gates (`shaders/cloud_reconstruct.glslinc:284-371`). Orthographic views and captures use full-resolution tracing without temporal history (`feng_cloud_gpu.gd:223-224`). | The current source follows the reviewed depth and mode rules. Reprojection still uses Feng’s renderer data path and has not been shown pixel-identical to UE’s device-depth reconstruction. |
| UE defaults to VRT upsampling mode 4 (`VolumetricRenderTarget.cpp:37-38`). Its mode-4 branch chooses among four near/far depth candidates and uses the 5 km / 1 km safety conditions before bilinear upsampling (`VolumetricRenderTarget.usf:1349-1355`). | Feng mode 0 is the default quarter-resolution trace, temporal half-resolution resolve, then full-resolution mode-4-style composition. Mode 1 is half-resolution trace without history; mode 2 is quarter-resolution trace with full-resolution temporal resolve; mode 3 is full-resolution trace without history and is used for captures. The compositor considers representative cloud depth, opaque bounds, and clear taps (`shaders/cloud_composite.glslinc:120-184, 193-228`). | These are supported paths, not interchangeable quality selectors for every UE permutation. UE’s other VRT and upsampling permutations are not exposed as empty Feng UI options. |
| UE applies aerial perspective and height fog to cloud radiance at its representative cloud depth (`VolumetricCloud.usf:1516, 1568-1569`; `VolumetricRenderTarget.usf:381`). Its transparent path has separate cloud-depth handling. | Feng’s cloud trace applies its atmosphere and height-fog transport before opaque composition; transparent FRP materials opt into **Cloud Fogging**. Legacy stock pass order is migrated only when the old canonical sequence is recognized (`renderer.gd:503-562`), while later manual ordering remains user-controlled. | Feng’s atmosphere/aerial transport is its own implementation, not UE’s exact LUT and fog execution. Arbitrary custom pass order can change which fog packet is available. |
| UE cloud lighting uses the atmosphere’s ground-post-transmittance sun irradiance by default, optionally samples atmosphere transmittance per cloud sample, and adds distant-sky lighting from the view-distance sky source or sky SH (`VolumetricCloud.usf:646-660, 723-737, 947-953`). | Feng consumes the active `FengSkyAtmosphere` and selected sky inputs. Its cached ambient estimate uses Feng’s atmosphere transport or an explicit ready sky source (`shaders/cloud_sky_ambient.glslinc:102-141`); the trace applies that estimate only to its ambient term. | The ambient estimate and atmosphere transport are not UE’s distant-sky luminance LUT or full UE sky integral. Pixel equivalence of this ambient estimate is unverified. |
| UE’s SkyAtmosphere applies cloud Sky AO to the first sun’s multiple-scattered term, and cloud transmittance to matching atmosphere-light direct terms (`SkyAtmosphere.usf:736-748, 776-778`). Cloud shadow and Sky AO have separate producers and consumers (`VolumetricCloudRendering.cpp:2059-2080, 2084-2110`). | Feng has separate cloud-shadow and Sky AO outputs and applies them to their supported FRP direct-light / global diffuse / atmosphere consumers. Both features are off by default. | This records the implemented consumer split; tested consumers and remaining mode coverage are listed below. |
| The supplied UE default instance overrides Pattern, Cloud Mask, height profile, and 3D noise inputs; its serialized active path uses Base Color 0.98, zero Emission, AO 0.5, phase `(0.8, 0.166667, 0.575)`, and multiscatter `(2, 0.666667, 0.25, 0.18)` (source asset under `resources/ue58/source/Engine/Content/EngineSky/VolumetricClouds/`; extracted graph map `resources/ue58/material/feng_cloud_ue58_default_kernel.source.json`). | Feng has a specialized kernel for that audited default material instance plus a separate built-in layout and user kernel hook. The kernel maps its Pattern/Mask/Profile/Noise inputs and the audited graph outputs; the source-to-kernel mapping is recorded beside it in `resources/ue58/material/`. | This is not a general Unreal material graph importer. Other UE materials, RHI backends, and cooked texture outputs can differ. |

## Editor measurements

The baseline and final addon snapshots use the same saved scene (`1569×839`), Godot
`4.7.3.rc.custom_build.1dca21024`, D3D12 on an RTX 3080 Ti, VSync off, and unlimited
FPS. Values are p50 / p95 milliseconds. Final frame counts use each summary's
`all_frames` population, including capture-busy frames. Viewport GPU time is the whole
viewport, not an individual cloud-pass timer.

| Condition | Snapshot | Frames | CPU p50 / p95 ms | GPU p50 / p95 ms | Wall p50 / p95 ms |
| --- | --- | ---: | --- | --- | --- |
| Cloud on, static | Baseline | — | 1.581 / 1.859 | 2.836 / 2.872 | 3.383 / 3.901 |
| Cloud on, static | Final | 2,323 | 1.504 / 1.734 | 2.836 / 2.873 | 3.384 / 3.661 |
| Cloud on, moving | Baseline | — | 1.817 / 4.251 | 3.056 / 9.730 | 3.960 / 10.167 |
| Cloud on, moving | Final | 1,550 | 1.709 / 4.190 | 3.070 / 9.738 | 3.804 / 10.168 |
| Cloud off, static | Final | 3,821 | 0.614 / 0.740 | 1.609 / 1.630 | 2.055 / 2.248 |
| Cloud off, moving | Baseline | — | 0.805 / 3.163 | 1.790 / 8.428 | 2.568 / 8.969 |
| Cloud off, moving | Final | 2,078 | 0.769 / 3.215 | 1.814 / 8.479 | 2.499 / 8.934 |

The moving cloud-on CPU p50 is about 5.9% lower in the final snapshot; GPU medians and p95
are effectively unchanged.

The paired summaries are under `C:\Temp\feng-heightfog-repro-1dca-20261007\project`:
`perf_data_baseline_42586_20261007` and `perf_data_final_42586_20261008`. CPU, viewport
GPU, and wall-frame metrics are reported separately.

## Focused validation

| Gate | Status |
| --- | --- |
| D3D12 mode-0 32×32 transport smoke: nonzero radiance and zero non-finite values | Pass |
| D3D12 mode-2 targeted smoke: `history_valid=true`, one view-history, finite output | Pass |
| D3D12 orthographic targeted smoke: forced mode 3, history disabled, zero view-history, finite output | Pass |
| Native atmosphere packet: 64 finite lanes with lane 50 equal to 1; height-fog packet (28 lanes) and cloud-visibility packet (148 lanes) populated separately | Pass |
| Published BlueNoiseScalar binding: 128×8192 R8_UNORM; decoded pixel SHA-256 `B135DD62C73CDEE1920885D28BAF2B71643A0577934A77CDA6D584C35162DE0B`; stock kernel recognition active | Pass |
| PCK runtime-source/resource closure: 21 raw shader sources and 5 default resources; PNG payload byte-exact | Pass |
| Schema CPU gate: canonical schema 8-to-9 stock-order migration swaps Fog/Trace while preserving parameters; custom-order and duplicate-ID cases | Pass |
| Broader cross-mode, view, and scene matrix | Pending |

## Measurement and validation limits

The captures contain no named `library:cloud_*` GPU intervals, so they do not isolate
cloud-pass cost or explain editor stalls. Preview-on and normal VT workloads differ.
`Performance.TIME_PROCESS` is not CPU thread time; viewport CPU, viewport GPU and
wall-frame metrics are separate. These runs are workload measurements, not a general
performance guarantee or a complete material, RHI, cooked-texture or LUT parity matrix.

Cloud-enabled shutdown recorded 4 Compute, 11 UniformBuffer, 4 Shader, 4 Sampler and 7
Texture RID warnings; cloud-off shutdown recorded 2 UniformBuffer, 1 Sampler and 1 Texture
warning. These counts match the earlier cloud-enabled baseline; exact ownership was not
identified. Logs are `C:\Temp\feng-cloud-ue58-20261007\final-42586-20261008\formal-pair.stderr.log`
and `shutdown-off.stderr.log`.
