# Feng Hardware Ray Tracing

Add **Hardware RTGI** from the FRP pass library, place it after Lighting and before Sky, then enable it. The library template starts disabled. Scene meshes are discovered automatically; no registration component or project autoload is required.

This is one-bounce diffuse GI using RenderingDevice ray pipelines on Vulkan and D3D12 DXR. It is not the NVIDIA RTXGI SDK and does not provide specular reflections. The pass selects the diffuse GI owner: enabling RTGI replaces Magic GI. A supported frame subtracts the exact native SkyLight diffuse attachment before adding RTGI; an unsupported frame retains SkyLight lighting.

## Settings

- **Strength:** indirect contribution; zero preserves SkyLight.
- **Max Distance:** ray distance in scene meters.
- **Samples Per Pixel:** 1, 2 or 4 rays.
- **Half Resolution:** enabled by default.
- **History Weight:** temporal accumulation, with depth/normal rejection and exposure compensation.

## Scene support

ArrayMesh and PrimitiveMesh triangle surfaces support transforms, per-instance material overrides, opaque BaseMaterial3D albedo colors and UV1 textures, constant metallic, emission, a selected directional sun and FengSkyLight radiance. Texture arrays retain source resolution and sampling wrap/filter, with at most eight groups, 32 layers per group and 128 MiB of albedo data. Diffuse hit lighting uses Lambert scattering and samples texture mip zero.

Skinned/blend-shaped geometry, terrain/custom shader materials, transparent materials, material overlays and advanced material layers are currently unsupported. Their presence in the visible world causes an explicit warning and SkyLight fallback. Local omni/spot/area lights are not evaluated by this diffuse pass. Existing raster rendering is unchanged while the pass is disabled.

## Backend

Vulkan requires ray-tracing pipelines and buffer device addresses. D3D12 requires DXR and compatible `dxcompiler.dll` plus `dxil.dll` beside the executable. A missing capability leaves the raster path available. The engine exposes paired GLSL/SPIR-V and native HLSL RT stages; resources use matching set/binding and register/space indices. Fog's hardware shadow provider also supplies paired HLSL stages.

Scene discovery and material extraction run on the main thread. Immutable snapshots cross to the render thread. The GPU service owns BLAS/TLAS, shader tables and texture arrays; the pass owns per-view history and composition. Geometry/material changes invalidate cached resources, transforms rebuild TLAS only, and returning to a previously inactive world starts a new snapshot epoch.

## Validation

Run the scripts in `tests` from a project with the FRP and ray-tracing addons, using a GPU-capable engine and either `--rendering-driver vulkan` or `--rendering-driver d3d12`:

- `test_rt_gi_gpu.gd`: numerical emission, exposure, strength, sun visibility, culling and SkyLight array tests.
- `test_rt_gi_scene.gd`: complete FRP on/off rendering and viewport CPU/GPU timing in a small synthetic scene.

The scene test saves `rtgi_on.png` and `rtgi_off.png` in the project's user-data directory. Its timings are not a benchmark of a production scene.
