# Feng Hardware Ray Tracing

Add **Hardware RTGI** from the FRP pass library. Its default position is after Lighting and before Sky; keep it before native Transparent, Temporal AA, Bloom and Post Process, and before custom fog passes. The library template starts disabled. Scene meshes are discovered automatically; no registration component or project autoload is required.

The pass provides one-bounce hardware-traced diffuse GI and an independent one-bounce specular reflection replacement on Vulkan ray tracing pipelines and D3D12 DXR. Reflections use GGX visible-normal sampling, the native DFG lookup and the receiver's GBuffer material values. A hit evaluates the supported material, selected directional sun, emission and FengSkyLight diffuse/specular lighting; a miss uses the captured FengSkyLight radiance. There is no WorldEnvironment sky fallback.

## Settings

- **Strength:** diffuse GI contribution. Zero leaves native diffuse lighting unchanged and does not turn off reflections. Diffuse ownership transfers to the unique Magic GI pass when its resolved RTGI strength is zero.
- **Reflections Enabled:** enables hardware-traced reflections; enabled by default when the pass is enabled.
- **Reflection Strength:** native indirect-specular replacement fraction from zero to one. Zero keeps the native indirect specular term. A valid RT result replaces that fraction; direct specular remains intact. The captured native term includes SkyLight and local reflection probes, so successful RT reflection replaces both together and does not double-add them.
- **Max Distance:** maximum ray distance in scene meters.
- **Samples Per Pixel:** 1, 2 or 4 rays per pixel.
- **Half Resolution:** applies to diffuse GI only. Reflections trace at full resolution to preserve material and silhouette edges.
- **History Weight:** temporal accumulation. Reflection history rejects depth, normal, roughness, metallic, specular, albedo, hit/miss and hit-distance changes; camera cuts/movement and relevant scene, light, sky or trace-setting changes reset it. Exposure jumps outside a 4:1 range reject old reflection history.

The native indirect-specular attachment is captured after DFG and energy compensation and at the native exposure point. The RT contribution uses that same exposure once. If the trace, scene, DFG LUT or supported-geometry check fails, native lighting remains in place.

## Scene support

ArrayMesh and PrimitiveMesh triangle surfaces support transforms, per-instance material overrides, opaque BaseMaterial3D albedo colors and UV1 textures, metallic, roughness, specular, emission, a selected directional sun and FengSkyLight radiance. Texture arrays retain source resolution and sampling wrap/filter, with at most eight groups, 32 layers per group and 128 MiB of albedo data. Diffuse hit lighting uses Lambert scattering and samples texture mip zero. Reflection hits use the supported material's direct/emissive lighting plus one evaluated FengSkyLight environment term; the tracer does not recursively trace secondary reflections.

Skinned/blend-shaped geometry, Terrain3D/GridMap, custom shader materials, transparent materials, material overlays and advanced material layers are unsupported. Their presence in the visible world causes an explicit warning and retains native indirect lighting; unsupported geometry is not silently removed from the acceleration structure. Local omni/spot/area lights are not evaluated by this pass. WorldEnvironment ambient and sky reflection remain isolated from the FengSkyLight indirect inputs.

The pass must run before native Transparent, Temporal AA, Bloom and Post Process. The validator checks those native pass bounds. Custom Height Fog is not represented by a native pass ID, so keep Height Fog after RTGI; the validator cannot currently detect a manually moved Height Fog pass that runs first.

## Backend and lifetime

Vulkan requires ray-tracing pipelines and buffer device addresses. D3D12 requires DXR and compatible `dxcompiler.dll` plus `dxil.dll` beside the executable. A missing capability leaves the raster path available. The engine exposes paired GLSL/SPIR-V and native HLSL RT stages; resources use matching set/binding and register/space indices.

Scene discovery and material extraction run on the main thread. Immutable snapshots cross to the render thread. Diffuse and reflection share one per-target/view scene owner, BLAS/TLAS, material and texture uploads, while keeping independent trace outputs and temporal histories. Geometry/material changes invalidate cached resources, transforms rebuild TLAS only, and idle target/view resources expire after 120 frames.

## Validation

Run the scripts in `tests` from an isolated project with the FRP, ray-tracing, Magic GI and FengSkyLight addons, using a GPU-capable engine and either `--rendering-driver vulkan` or `--rendering-driver d3d12`:

- `test_rt_gi_gpu.gd`: numerical emission, exposure, strength, three-row material ABI, sun visibility, culling and FengSkyLight array tests.
- `test_rt_gi_reflections.gd`: Sky-lit nonemissive geometry, material response, runtime toggle, independent HDR/exposure history readback, invalid-trace preservation, duplicate-owner preservation and diffuse-only versus diffuse-plus-reflection GPU timings.
- `test_rt_gi_scene.gd`: complete FRP on/off rendering and viewport timing in a small synthetic scene.

Timings are fixture measurements, not a production benchmark.
