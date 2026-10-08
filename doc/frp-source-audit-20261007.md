# FRP Source Audit and Color-Pipeline Contract (2026-10-07)

Historical record: results and open findings apply to the builds and environments named below.
Current contracts are in [addon architecture](frp-addon-architecture.md) and
[engine contract](frp-engine-contract.md).

**Evidence scope:** This report records snapshot-bounded source review and focused gates. It does not claim a full engine audit or complete cross-device acceptance. Supporting relative artifact paths are rooted at `C:\Temp\feng-frp-ue-tonemap-perf-20261006` unless a full path is shown.

## Source and build identity

- Validated code/build baseline at test time: `F:\godot\feng-godot`, branch `feng-godot`, HEAD `1e28d1f2e3e1323ad32f3ddfa8d9dfa40da0cf40` (`Match FRP resolve storage image format`). Its parent GBuffer change is `eb6d16d7d4376fab0d22cec1746e709233dbd8d5` (13 files, +228/−39); `1e28` adds a five-line conditional storage-image format declaration in `resolve.glsl`. A later documentation-only integration may change repository HEAD without changing the tested executable.
- A standard Windows x86_64 editor build of exact HEAD `1e28d1f2` completed with SCons exit 0 in 56.31 seconds. Manifest: `C:\Temp\ue-gbuffer-color-20261007\build-1e28d1f2\build_manifest.txt`; log: `...\engine-scons.log`. It used the regular editor configuration (D3D12 and Vulkan, Tracy, AccessKit, static C++, `optimize=speed_trace`, `-j8`; no module-disable flags). GUI SHA-256 `0B035CD5D0B492D733C24C2A400EFF1448839499E2F929797D8E6A320C169220`; console SHA-256 `521189E2C6F4EF7FD1914DB4FD44ACD6ECDC5F5533C0EF52B9E81B8C9AF7F25E`.
- The build did not run C++ tests or GPU/render tests. C passed the current-build 2× MSAA GBuffer output, array-slice, material-hint, FRP post, and exposure-lifecycle gates on their tested D3D12/Vulkan paths. The final short editor/game performance windows are recorded in the companion performance report; broader device and workload coverage remains unverified.

## Audit coverage and limits

The Terrain, FRP-addon, and Tracy/RenderDoc broad body-read counts below are anchored at the earlier `95d5fda70eb72b5db1f4752458c5e2885afdef0c` snapshot, not at current HEAD. Fog/Sky/Magic GI full-file entries are separately recorded by per-file source hash in `source_sha_body_coverage.csv`. Later changed files received targeted diff/call-path review unless the ledger explicitly records a full-body read.

| Snapshot scope | Recorded coverage | Evidence |
|---|---:|---|
| Terrain native VT/baker and remaining native code | 155 unique files full-body read: 60 VT/baker + 79 non-VT + 16 additional native files | `C:\Temp\feng-frp-ue-tonemap-perf-20261006\terrain_vt_baker_body_coverage_95d5fda.csv`, `audit\terrain_c_nonvt_native_body_coverage.csv`, `audit\terrain_c_remaining16_body_coverage_95d5fda.csv` |
| Terrain build/audit tools and extras | 4 tooling files + 5 extra shader/resource files full-body read | `audit\terrain_c_fresh_body_read_95d5fda.csv` |
| Terrain addon production scripts | 52 full-body files: 41 GDScript + 11 C# | `audit\terrain_production_body_review_manifest.csv` |
| FRP addon | 87/87 production source/resource files full-body read; 71 generated metadata entries excluded/pending | `frp_body_read_coverage_95d5fda.csv` |
| Fog, Sky, Magic GI | 32 full-body files: Fog 3, Sky 15, Magic GI 14, recorded with individual file hashes | `audit\source_sha_body_coverage.csv` |
| Tracy/RenderDoc tools and bridges | 52 full-body files, 8 engine bridge files in listed ranges, 8 vendor/generated/UID exclusions | `audit\tracy_renderdoc_bridge_body_coverage_95d5fda.csv` |
| Tone mapping and native FRP bridge | 19 tone files and 7 native bridge files received targeted diff/call-path review; not full-file reads | `audit\source_sha_body_coverage.csv` |

These counts describe the ledgers' stated snapshots and ranges. They do not imply a full read of all engine code or tests. The 13-file GBuffer change and the later one-file resolve-format correction received targeted diff/call-path review; neither has full-body-read credit.

## Color storage and lighting semantics

Godot's default material path works with linear Rec.709 values after sRGB source-texture decoding. UE's default material BaseColor storage is 8-bit sRGB; lighting consumes the decoded linear color. The current FRP change aligns **only BaseColor's 8-bit storage encoding** with that UE default while retaining the existing linear Rec.709 working primaries. Emission and scene-HDR storage are unchanged; this does not convert the GBuffer to ACEScg/AP1.

The FRP GBuffer uses a UNORM backing texture and, on supported devices, an sRGB public view for color sampling/attachment. The public sampled binding is `gbuffer_albedo`; sampling through its sRGB view returns linear values. The distinct `gbuffer_albedo_storage` binding is a UNORM storage view: on the sRGB-view path its stored values are raw sRGB code values, because `imageStore` does not encode sRGB. Shader compute writers must write OETF-encoded values explicitly. On the unsupported-device precision fallback, the public view remains same-format UNORM and its values remain linear. Consumers should query the actual public view format rather than assume which path was selected. The version-related inability to restrict the required view usage occurs only when neither Vulkan core 1.1 nor enabled `VK_KHR_maintenance2` is available; this does not remove the format and usage-feature requirements for a valid view. Normal, ORM, emission, and other scene-HDR formats are unchanged.

For MSAA resolve, the resolve continues selecting one depth sample and copies the material channels from that same sample. The albedo path decodes the sRGB multisample view, then explicitly applies the sRGB OETF before writing through the UNORM storage image when the sRGB attachment path is active. The depth/sample-selection rule is unchanged. In the precision fallback, values stay linear. This encoding distinction is why storage writers and readers must use the named binding and inspect the actual public view format.

UE's default GBuffer colorspace evidence is in `F:\ue\ue\UnrealEngine-5.8\Engine\Source\Runtime\RenderCore\Private\GBufferInfo.cpp:137-191,359-367`, `F:\ue\ue\UnrealEngine-5.8\Engine\Shaders\Private\DeferredShadingCommon.ush:192-201`, `F:\ue\ue\UnrealEngine-5.8\Engine\Source\Runtime\Engine\Classes\Engine\RendererSettings.h`, and its defaults in `F:\ue\ue\UnrealEngine-5.8\Engine\Source\Runtime\Engine\Private\RendererSettings.cpp`. UE decodes the transfer function before a gamut conversion; a primary-conversion matrix is only needed when input and working primaries differ. Under the default Rec.709 working space, no extra gamut matrix is needed. This BaseColor storage change does not add an AP1 conversion.

The forced-sRGB BaseMaterial baseline captured 55/55 cases; its actual table and detailed notes are `C:\Temp\feng-gbuf-color-20261007\reports\gbuf-color-baseline-6ee.md` and `...\gbuf-color-baseline-6ee.json`. The 55 total include color, shader uniform/texture, RGBA8 texture, and float-texture cases. Of the 9 RGBA8 `force_sRGB=true` cases, 7 are within one output-code tolerance; the gray 0.18 and 0.5 cases mismatch the once-EOTF target by about 0.027451 and 0.176471. RGBA8 `force_sRGB=false` is 9/9; RGBAF force-sRGB off/on is 10/10 within one code. The current `scene/resources/material.cpp` branch suppresses the sampler hint only when its manual forced decode runs; the default non-forced path retains automatic decoding, and the MSDF/triplanar exception remains distinct. This is baseline material-path evidence, not current GBuffer GPU acceptance.

## Other delivered runtime/data changes

The 45b public per-world viewport registry maintains event-generation world-to-viewport maps and unique-owner handles across queries. Each synchronous query still validates each distinct owner's weak reference for liveness; the legacy viewport path refreshes live world identity. The route map keeps a bounded 32-world cache. Viewport world-change events invalidate the event-backed route entries; Fog debanding and SkyLight consumers use the same per-world registry rather than separate whole-tree scans.

The terrain uploader packs up to 16 R16_UNORM or R32_SFLOAT page payloads into scratch storage, then GPU-scatters them into the existing texture-array layers. It preserves formats, layer assignment, page budgets, and source values. The old two-layer 266×266 comparison in `C:\Temp\feng-frp-ue-tonemap-perf-20261006\vt-gpu-codec-95d5\scatter-updatebit.stdout.log` records zero R16_UNORM and R32_SFLOAT mismatches against direct region updates. That fixture ran `4.7.3.rc.custom_build.95d5fda70` on D3D12 / NVIDIA RTX 3080 Ti; it is an older artifact, not a validation of the current candidate. It validates those sampled data patterns, not every device or a standalone performance gain.

In the 3D `MaterialStorage` `p_use_linear_color` path, a GDScript `Color` Variant is treated as sRGB-authored and decoded even when the shader uniform has no `source_color` hint. Pass already-linear scene values as `Vector3` or `Vector4`; removing the hint alone does not make a `Color` Variant linear. This finding is scoped to that 3D material-storage path, not every GDScript color, texture, or 2D path.

## Resolve storage-image qualifier correction and validation boundary

Before `1e28`, the `MODE_RESOLVE_GI` normal/roughness storage image was declared `rgba8`, while FRP's `get_normal_roughness_format()` returns `A2B10G10R10_UNORM_PACK32` (`frp_clustered/render_frp_clustered.cpp:404-409`) and the FRP MSAA GBuffer path passes that destination to `resolve_gi()` (`render_frp_clustered.cpp:2587`). Khronos' SPIR-V/Vulkan format mapping pairs `Rgba8` with `VK_FORMAT_R8G8B8A8_UNORM` and `Rgb10A2` with `VK_FORMAT_A2B10G10R10_UNORM_PACK32`; storage-image format compatibility requires the declared format to match the image view format. These source formats therefore had a real spec-level mismatch. This establishes a source contract defect, not proof that it caused a visible error on the RTX device.

Commit `1e28d1f2` fixes the contract in `servers/rendering/renderer_rd/shaders/effects/resolve.glsl`: `GBUFFER_RESOLVE` declares `layout(rgb10_a2)` for the FRP normal/roughness destination, while the generic/non-FRP path retains `layout(rgba8)`. Khronos references: [SPIR-V image-format to Vulkan-format compatibility](https://docs.vulkan.org/spec/latest/appendices/spirvenv.html#_compatibility_between_spir_v_image_formats_and_vulkan_formats) and [storage-image format compatibility](https://docs.vulkan.org/guide/latest/storage_image_and_texel_buffers.html#format-compatibility-requirements). `Rgb10A2` uses the extended storage-image format capability; tests below establish the exercised D3D12 and Vulkan device paths, not universal support on every Vulkan device or all VR configurations.

C's current `1e28` 2× MSAA runs completed on D3D12 and Vulkan (`C:\Temp\feng-gbuf-color-20261007\logs\eb6d_1e28_d3d12_msaa2.stdout.log` and `...\eb6d_1e28_vulkan_msaa2.stdout.log`). Each run captured 67/67 color cases, 3/3 raw storage cases, and six auxiliary attachment captures with zero auxiliary delta; the strict color oracle's maximum error was 0.24675 sRGB code (≤1 code), and raw UNORM storage codes were exact. This validates resolved output for these runs; it does not prove which MSAA source sample was selected or coverage across all devices/VR.

The prior EB no-MSAA 67-case strict oracle is `C:\Temp\feng-gbuf-color-20261007\logs\retry7_oetf_code_analysis.json`: maximum error 0.24675 sRGB code (≤1 code), exact raw storage codes. An earlier EB D3D12 2× run was preliminary and is not the final result; it did not prove source-sample selection. Non-MSAA does not execute this resolve path.

C's `1e28` array-slice GPU gates also passed on D3D12 and Vulkan: `C:\Temp\feng-gbuf-color-20261007\logs\eb6d_1e28_d3d12_array_gpu_slice_final2.stdout.log` and `...\eb6d_1e28_vulkan_array_gpu_slice.stdout.log` (both exit 0, empty stderr). The local readback helper SHA-256 is `8187DB435344A2CD079271ACBA9E0D209193D612D080BEA33FF4E24ED4DA6257`. Layer 0/1 UNORM byte patterns matched, updating owner layer 1 did not modify layer 0, sRGB output error was at most 0.28491 code (≤1), and authored alpha 128 remained 128/255 without EOTF. A separate existing CPU API limitation remains: `texture_get_data(slice1, 0)` reads layer 0 because the existing CPU readback path does not apply a base-layer offset. This is not a GPU shared-view failure and was not changed here.

## Focused current-build runtime smoke gates

The 1e28 Forward+ and Forward Mobile material-hint smoke logs are `C:\Temp\feng-gbuf-color-20261007\logs\eb6d_1e28_forward_plus_material_hint.stdout.log` and `...\eb6d_1e28_mobile_material_hint_vulkan.stdout.log` (both exit 0). Each exercised three visible/drawn variants: force-sRGB only, force-sRGB plus MSDF, and force-sRGB plus MSDF with triplanar precedence. The compile summary reports 3 expected variants, 3 draw calls, and zero errors. Each stderr contains only the expected warning that MSDF is unsupported on triplanar material and ignored in favor of triplanar mapping. This verifies shader-variant compilation/drawing, not numeric color output.

The FRP post smoke (`eb6d_1e28_frp_post_gpu_smoke.stdout.log`, exit 0, empty stderr) reports post-overlay output `(0,1,0,1)`, pre-tonemap output `(0.9294,0,0.0314,1)`, and the same gray `(0.3765,0.3765,0.3765,1)` with the overlay disabled or absent. The exposure/lifecycle smoke (`eb6d_1e28_exposure_lifecycle_gpu_smoke.stdout.log`, exit 0, empty stderr) reports `PASS FRP exposure readback retirement, pre-exposure toggle, TAA restart, resize and compositor switch`. These are focused runtime smoke cases, not a complete test suite.

## UE Film mode and exposure checks already recorded

FRP mode 5 is a cached 32³ LUT implementing the fixed UE 5.8 default SDR/Rec.709 film profile (Film parameters 0.88/0.55/0.26/0/0.04, BlueCorrection 0.6, ExpandGamut 1, ToneCurve 1). It is an SDR filmic transform, not a PQ/HLG display ODT or a complete UE HDR output pipeline. The existing LUT path emulates UE's 10-bit SDR LUT payload in the RGBA16F carrier: entries are scaled by 1/1.05 and quantized to 10-bit UNORM codes, filtering restores the 1.05 scale before sRGB decode, retaining the intended encoded headroom. This is not bitwise parity with UE's device-specific output.

The targeted b866 comparison against the UE 10-bit reference reported maximum channel error 0.0021742 after display clamp, below one RGB8 code; that was a LUT/reference comparison, not a test of the later GBuffer commit. On 6ee, the product post and authored-white Volume tests passed: explicit modes 2/4/inherit −1, regular/AgX authored whites 1.0/16.29, enable/removal transitions, and zero all-pixel delta in the fixture. The 6ee test result does not cover the new sRGB GBuffer.

The internal Environment override carries regular and AgX authored whites separately; the old four-argument RenderingServer setter keeps its prior one-white behavior. Mode 5 uses its fixed LUT profile. Mode-5 Bloom composition uses additive HDR composition before the tonemap and avoids applying exposure a second time; the UE Bloom kernel itself is not claimed as ported.

The fixed-Sky Fog gate previously checked the FRP pre-exposure path: the native Sky draw forwards pre-exposure to the raw Fog/sun source contribution once, while already-pre-exposed sky color is not multiplied again. This is not a claim that addon HeightFog implements every UE fog feature.

## VT editor preview versus game runtime

The preview mode is editor-only by the native predicate `terrain_3d_vt_service.cpp:315-316`: `is_vt_editor_preview_active()` is `IS_EDITOR && vt_editor_preview`. When active, `terrain_3d.cpp:193-202` takes the explicit bake-only branch and returns; near/far surface updates return early at `terrain_3d_surface_views_near.cpp:198` and `terrain_3d_surface_views_far.cpp:83`; material setup disables VT at `terrain_3d_material.cpp:284`. A normal game run has preview inactive and uses the normal streaming path; setting the editor preference does not disable runtime VT.

This matters for the recorded editor A/B: Preview ON is not the same terrain residency/material workload or equivalent quality as Preview OFF. It must not be used to claim a shipping-game speedup.

## Deferred source issue and acceptance boundary

The source-only SVT cell-publication failure path remains unfixed and unverified at runtime. A partial multi-channel page upload failure can leave mapping/layer recovery at risk; the audit proposed making failed publication undiscoverable before retrying through the existing queue. It is not counted as a reproduced issue or a fix.

The validated source tree and editor build are identified above. Focused 1e28 gates passed for 2× MSAA output and array slices on D3D12/Vulkan, material-hint variants on Forward+/Forward Mobile, and FRP post/exposure lifecycle smoke paths. The short 1e28 editor/game performance windows completed; see `frp-performance-20261007.md` for exact timings, run conditions, and warning boundaries. The build did not run C++ unit/integration tests; Metal, older Vulkan devices, VR, MSAA source-sample selection, and arbitrary/cold streaming performance remain unverified. The benchmark used frozen `CC494` scene state; the later `035` and `51B` scene states were external user saves. I did not edit those scenes.


