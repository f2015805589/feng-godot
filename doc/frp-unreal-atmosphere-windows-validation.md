# Windows atmosphere validation (2026-10-02)

This record contains the Windows D3D12 checks run for the Atmosphere repair. The test projects were disposable copies under `C:\Temp`; neither `F:\godot\project\test-1` nor `test-2` was edited.

## Binaries and source

| Build | Executable | SHA-256 | Version |
|---|---|---|---|
| Baseline | `pre-27def-e002/godot.windows.editor.x86_64.console.exe` | `6375D5B0E38B8003F2D2931FB0DA3E86C2A1C08E657FB391FADCA9384945B344` | `4.7.3.rc.custom_build.e002032f4` |
| Repaired native build | `bin/godot.windows.editor.x86_64.console.exe` | `37D1CFDE445B9D7557E8A1BEBE89B2972E715507C2492DA297CD445636C1853B` | `4.7.3.rc.custom_build.27def4b95` |

The baseline executables were copied and hash-verified before the incremental native build. The 27def build was produced from main commit `27def4b954`; the small-angle follow-up is source commit `52149843da` on `auto-atmosphere-nan`. That change updates the shader approximation and its GPU fixture; it does not require a native rebuild.

The D3D12 adapter reported `NVIDIA GeForce RTX 3080 Ti`. The transient and timing probes used a minimal copy of test-1's serialized sky, world environment, camera, exposure/compositor settings, and embedded e002 shader. Terrain was omitted. This minimal scene does not exercise the FengSky component's embedded-shader migration; that migration is covered separately by the host migration tests.

## Transient high-pre-exposure check

The camera began at its saved test-1 orientation (`dot(view, sun) = -0.9742243`), warmed for 240 process frames, and then turned to the serialized sun direction. The warm view reached PE `16.34`; the first reported PE after turning was `16.4785`.

| Binary | Sample PE | NaN channels | Inf channels | Channels above 65504 | Maximum finite HDR channel |
|---|---:|---:|---:|---:|---:|
| e002 baseline | 16.4785 | 0 | 0 | 0 | 19584 |
| e002 baseline | 16.4789 | 0 | 0 | 0 | 126.3125 |
| e002 baseline | 16.2756 | 0 | 0 | 0 | 102.375 |
| 27def native | 16.4794 | 0 | 0 | 0 | 19584 |
| 27def native | 16.4799 | 0 | 0 | 0 | 126.3125 |
| 27def native | 16.2803 | 0 | 0 | 0 | 102.375 |

**This probe did not reproduce NaN, Inf, or FP16 overflow in either binary.** It therefore does not establish the black sun mark's cause or demonstrate a before/after fix. The sampled peak falls on frames two and three; the probe records that behavior without attributing it to exposure adaptation. The HDR counters were added only in the disposable copy of the eye-adaptation histogram shader and read once for each of the first three post-turn frames. The timing run used no HDR readback. The screenshot-specific full editor view remains unverified by this minimal scene.

## Sky GPU profile

A separate 320x240 run used three 240-frame stages: static camera/material, camera translation, and sun-direction rotation. No HDR or image readback was enabled during this timing run. The values below are the RenderingServer's captured GPU frame timestamps averaged over the reported profile windows.

| Stage | `Setup Sky` | `Render Sky` | Profile total |
|---|---:|---:|---:|
| Static | 0.0131 ms | 0.0517 ms | 0.668 ms |
| Camera translation | 0.3021 ms | 0.0565 ms | 1.143 ms |
| Sun rotation | 0.8229 ms | 0.0579 ms | 1.114 ms |

`Render Sky` stayed near 0.05–0.06 ms, while `Setup Sky` rose during camera and sun changes. The `Render Sky Octmap`, `Downsample Radiance Map`, and `Fast Filter Radiance` names are GPU command labels nested under sky setup, not separate RenderingServer timestamps exposed by this capture. Consequently their individual GPU durations are unavailable in this run. CPU `run_pass` submit/synchronization time was not measured, and these results do not assign the setup increase to a specific radiance subpass.

## Numerical GPU regression

The D3D12 numerical probe ran four 3,072-ray configurations (12,288 rays total) on the 27def native executable, loading the shader and fixture from source commit `52149843da`.

- All configurations passed with `bad_values=0`.
- Maximum solar mask error: `0.00022143125534` at radius `0.02°`.
- The legacy cosine-disk comparison still failed 216 samples per configuration, as expected for the regression fixture.
- Zero-radius, microscopic positive-radius, and independently tinted disk checks passed.

The corrected small-angle shader uses `x * (1 - x*x/6)` for `|x| < 0.01`; the Taylor truncation error is below `8.4e-11` over that interval. The measured D3D12 behavior that motivated this path was `sin(8.726646e-9) = 0` in the previous GPU implementation.


## Independent final validation on main 9f5149

The final source is main commit `9f5149db7a`, with sky shader SHA-256 `FECD4D6C7E913134CD27EFE95DAFBC5876E61C262620368FF701AA534D47863E`. A used the e002 backup with this final add-on source for the CPU base suite, Registry, exact e002 default-shader migration, and preservation of a user-modified custom shader. A used the new native `4.7.3.rc.custom_build.27def4b95` with the same source for GPU numerics, Fog, pre-TAA HDR stress, and the 1920×1080 profile.

### Pre-TAA generic HDR stress

A's 320×240 generic HDR stress captured the final HDR values before TAA. All 76,800 checked samples were finite and nonzero; `bad=0`; the saturation counter was 2; the center maximum was 65504. This is a generic output-boundary stress case. It is not an e002 before/after comparison and does not claim Feng's serialized default atmosphere reaches the cap.

Log: `C:\Temp\ue_atmo_cpu_independent_9684a72c39cd45a7b93c7f318dc45624\final_hdr_literal_extreme_stats_capture.log`.

### 1920×1080 mixed-bucket GPU profile

The independent 1080p mixed-bucket profile reported `Setup Sky` samples of 0.0167/0.2488 ms and `Render Sky` samples of 0.2339/0.2840 ms. Wall-stage means were 5.50/5.54/5.54 ms in static, camera-motion, and sun-rotation order.

Log: `C:\Temp\ue_atmo_cpu_independent_9684a72c39cd45a7b93c7f318dc45624\final_1080_profile.log`.

The full test-1 terrain/editor default black mark remains unreproduced. These HDR stress results establish finite writes for the tested generic stimulus; they do not identify the screenshot's cause or establish that the default scene overflows.
