# Volumetric shadow ray provider

## Verified integration snapshot

The standalone CPU contracts pass 71 ray-input checks and 13 any-hit checks.
A separate Vulkan end-to-end fixture on Godot 4.7.3 (`7180b8114`) exercised
the native frame input, generated 48-byte ray records, provider slot mapping,
and volume injection/integration for three cases: blocked visibility `0`,
moved-out visibility `1`, and full-width mask-mismatch visibility `1`. The
sampled injected RGB was zero for the blocked case and `(238.625, 224.75,
236.75)` for the two visible cases. Integrated RGB changed from
`(1201, 1131, 1192)` to `(1602, 1509, 1590)`; transmittance alpha remained
`0.664062`.

The generator's GLSL local named `active` was renamed `ray_active` because
`active` is reserved by the shader compiler. Raygen reads the borrowed ray
buffer at set 0, binding 1; any-hit reads the same RID at set 0, binding 10.
The 48-byte input layout and visibility output remain unchanged. These results
cover the listed fixture and do not establish pixel-level or complete UE
feature parity. Device, caster, capacity, and incomplete-build failures still
require the complete raster fallback described below.

`FFogRayTracingShadowProvider` traces batched shadow rays through the main
RenderingDevice ray-tracing pipeline. `FFogRayTracingGeometryRegistry` builds
immutable main-thread scene snapshots and receives SceneTree membership changes;
it does not rescan the whole scene each frame.

The raygen, miss, closest-hit, and any-hit stages are raw `RDShaderSource`
inputs with `#version` and ray-tracing extensions. They use the `.glslinc`
extension and are read directly by `FileAccess`; they are not Godot `Shader`
resources. This prevents `ResourceImporterShaderFile` from treating a ray stage
as a regular vertex/fragment/compute shader when an editor opens the addon.

All four stages share one 32-bit `uint` payload at location 0: raygen initializes
it to visible (`1`), closest-hit writes blocked (`0`), and miss writes visible
(`1`). Any-hit reads the original one-dimensional ray record through
`gl_LaunchIDEXT.x`; the GLSL ray-tracing extension specifies that any-hit sees
the same launch ID as its raygen invocation. This avoids carrying a redundant
ray index inside the cross-stage payload while leaving the external 48-byte
ray-record and visibility-buffer layouts unchanged.

Any-hit applies layer-mask and alpha rejection before accepting an occluder.
Rejected candidates use `ignoreIntersectionEXT` and leave the ray visible so
later candidates can still block it. An accepted opaque hit, threshold-accepted
alpha hit, or missing per-geometry material metadata uses one shared helper to
write `0` to the payload and call `terminateRayEXT`; the ray therefore stops at
its first accepted occluder and does not depend on closest-hit execution to mark
the binary shadow result. The closest-hit stage still writes `0` as a fallback.
The focused CPU source contract is `tests/test_raytracing_any_hit_contract.gd`;
it checks branch ordering and the accepted/rejected payload contract without
claiming that the RT shader has been GPU-compiled.

## GPU input and output

Use `FFogRayInputGenerator.generate_batch(rd, frame_inputs, grid,
log_z_params, pixel_size, light_slots, max_ray_distance_m, min_ray_t_m,
sample_offset, sample_depth_offset, depth_options, work_mask_options,
light_extension_inputs)` to build ray records. The final
`light_extension_inputs` argument is the optional same-frame result from
`FFogLightExtensionProvider`. `light_slots` is a small CPU list of
`[type, index, ...]` pairs (directional=0, omni=1, spot=2, area=3). The GPU
generator reads the frame's borrowed native 464-byte directional UBO and
224-byte local-light SSBOs, reconstructs each froxel with the unjittered
per-eye projection, then writes the records into its own RD storage buffer.
It does not traverse lights per froxel on the CPU or read GPU data back.
It requires the main RD ray-tracing-pipeline and buffer-device-address
features; unsupported devices return complete-raster fallback before dispatch.

The method has an optional trailing `depth_options` dictionary. It accepts
`gbuffer_completed` from `ctx.is_operation_completed(OP_GBUFFER)` and the
same-view current `depth_texture` RID from `RenderSceneBuffersRD.get_depth_layer`.
Depth constraining is enabled only when that operation completed, the frame's
`depth_prepass_enabled` is true, and the RID is a valid resolved 2D texture
with sampling usage. The addon binds this current depth layer directly; it does
not copy or blit it and therefore does not assume `CAN_COPY_FROM` or
`CAN_COPY_TO`. If the frame has no depth prepass/GBuffer, it binds a neutral
depth texture and explicitly disables the constraint. If the caller claims a
current depth layer is available but its RID/format is invalid, the whole batch
requires complete raster fallback.

The independent 256-byte RayFrame UBO is owned by the generator and packs the
unjittered inverse projection, per-eye camera-to-world transform, center-view
eye offset, grid/log-Z/pixel-size values, light counts, and frame generation.
Native local-light positions and light directions use the center-view basis;
the generator adds the eye offset to a per-eye froxel before comparing those
light records. World-space origins and directions are then written to the ray
buffer. One shared within-froxel XYZ offset defaults to `(0.5, 0.5, 0.5)` and is
not derived from TAA jitter. Pass the volume service's same Halton offset for
XY and Z so the ray origin and volume-light sample refer to the same point.

The generator binds the borrowed light-extension provider result at set 3,
bindings 0–2 (144-byte ABI v2 records, cookie array/sampler, and 16-byte
header). It checks the frame generation, record counts and offsets, stride,
capacity, and cookie-array layout before dispatch. With no extension result it
binds neutral set-3 resources and preserves native source-radius sampling. For
local omni, spot, and area slots, positive `source_length_m` samples an
explicit line along the record's local X/Y/Z axis using an independent random
dimension, then retains the native `Light3D.size` source-radius sample. Zero
length leaves the prior radius-disk or rectangular-area sample intact. The
line axis maps local→world→center-view using rotation only, and the sampled
source point determines ray maximum `t`. Keep the extension result alive and
unchanged through this dispatch; do not update its provider before the compute
list is recorded. Its line variate is the third `feng_ray_random()` value from
`hash(ray_index XOR generation_low XOR light_type*0x85ebca6b XOR
sample_index*0xc2b2ae35)`, so each history-miss sample uses a deterministic,
different source point.

The runtime compute source is
`fog_rt_ray_input_generate.glslinc`. The generator reads it with `FileAccess`,
inserts the native-light and extension ABI includes, strips Godot's leading
`#[compute]` marker, and compiles it through `RDShaderSource.source_compute`.
The `.glslinc` extension prevents ordinary editor shader import from treating
it as a standard shader resource.

Current-depth correction uses a separate 144-byte UBO at set 0, binding 8
(jittered current projection, its inverse, then `[available, 0.5, 1.0, 0]`) and
a nearest `sampler2D` at binding 7. RayFrame remains 256 bytes. With valid
depth, the compute shader projects the unjittered volume sample through the
jittered projection, samples the matching depth layer, reconstructs view depth,
and applies the same nearest-front-froxel one-slice rule as the volume-light
service. With depth unavailable, the UBO availability lane is zero and the
shader does not read the neutral texture. The ray batch must receive the same
XYZ offset that the light service uses for that sample.

Pass the returned buffer and its metadata to
`trace_shadow_batch(rd, geometry_snapshot, ray_input_buffer,
ray_input_capacity_bytes, stride_bytes, generation, ray_count, light_count,
froxel_count, frame_generation, ray_input_abi_version)`. The trace provider
requires that buffer to be on the same `RenderingServer` main `RenderingDevice`
and validates its capacity and matching frame generation. It borrows the input
and never copies, reads back, or frees it. The input buffer is owned by the
generator and remains valid only until its next `generate_batch` call or
`release`; trace the batch before generating another one.

Each std430 record is three 16-byte vector values (48 bytes):

| Offset | Field | Contents |
| ---: | --- | --- |
| 0 | `origin_min_t` | Ray origin xyz, minimum t |
| 16 | `direction_max_t` | Ray direction xyz, maximum t |
| 32 | `cone_words` | `uvec4` raw words in the same 16-byte slot. ABI v1 reads `x/y` as IEEE-754 radius/growth bits and ignores `z/w`. ABI v2 keeps `x/y`, reads `z` directly as the full uint32 light mask, and converts `w` to float only for the active `1.0` / skip `0.0` test. |

Origins and normalized directions are world-space, matching the registry's
world transforms; minimum and maximum `t` are meters. Records are light-major,
froxel-minor. The provider compiles a matching raygen and any-hit shader variant
with `FENG_FOG_RAY_ABI` set to the caller's input ABI. Raygen reads the borrowed
input SSBO at set 0/binding 1; any-hit reads it at set 0/binding 10. The provider
binds the exact same caller-owned RID at both bindings, without copying the data
or changing the 48-byte record. ABI v1 ignores `cone_words.z/w`, traces every ray,
and applies no layer-mask filter for compatibility. ABI v2 interprets the raw uint mask and active-float bit
lane explicitly; an inactive ray or zero mask writes neutral visibility `1` without
tracing. The trace provider keeps binary visibility:
`1` means visible and `0` means blocked. Consume or accumulate its returned
provider-owned uint32 buffer on the same RD after each ray-tracing list ends and
before tracing another batch; the provider reuses it on the next trace. Do not
read visibility back to the CPU during rendering.

The provider keeps one active ABI pipeline. Changing ABI releases its TLAS before
the old SBT and pipeline, then rebuilds the TLAS against the new hit SBT range;
unchanged BLAS and alpha buffers remain cached. The normal volume service uses
ABI 2, so it does not switch variants per frame.

The generator and trace provider cap each batch at 128 MiB and the provider's
maximum trace count. `max_lights_per_batch(grid)` reports the safe light count
for one generation. For multiple light batches, finish the current trace and
consume its visibility before generating or tracing the next batch; the input
and visibility buffers are both reused. The raw mask lane is never converted to a float, so all 32 mask bits—including `0x80000000` and `0xffffffff`—retain their exact words. The radius, growth, and active lanes are converted from IEEE-754 words only where numeric float values are needed.

`trace_shadow_batch` accepts legacy v1
records by default for callers that still use zeroed `z/w`, and callers of the
new generator must pass its returned `abi_version` (2).

RD TLAS instance masks are only eight bits, so the any-hit stage compares the
record's full 32-bit light cull mask against the full caster layer mask stored
in provider metadata. BLAS geometry remains non-opaque to ensure that filter
runs for both opaque and alpha-tested hits. If a caster's 32-bit mask cannot be
read, the geometry snapshot requests a complete raster fallback rather than
truncating the mask or silently treating the caster as absent.

Every invalid input, missing pipeline feature, unsupported caster, overflow,
or incomplete AS build returns `fallback_required=true` and
`fallback_provider=complete_raster_shadow_batch`. Missing visibility is never
treated as unoccluded. D3D12 currently reports hardware RT unavailable and
uses the raster provider; the provider does not substitute software tracing
for a hardware capability claim.

## Geometry coverage and costs

Static `ArrayMesh` and `PrimitiveMesh` triangles, visible/cast-shadow state,
instance transforms, `MultiMesh` transforms, per-instance material overrides,
alpha scissor, and alpha hash are captured. Static mesh BLAS data is cached by
resource revision; transform-only changes rebuild the TLAS instance list while
reusing unchanged BLAS data. The public RD API has `tlas_build` but no incremental
TLAS refit call, so moving casters still incur a TLAS rebuild. Alpha
texture data is copied to immutable GPU metadata only when a material or
texture revision changes. Texture sampling uses base-level nearest or bilinear
alpha; mip-filtered alpha textures are unsupported because the ray path has no
matching raster derivatives for mip selection. Alpha hash uses a froxel-cone
footprint estimate, not exact raster derivatives.

Root `CSGShape3D` casters use the public `get_meshes()` result and its local
transform. CSG updates are deferred by one frame; an empty root mesh stays a
raster fallback until the public mesh is ready. Child CSG shapes are represented
by their root result. `Terrain3D` uses its public `bake_mesh(lod,
HEIGHT_FILTER_NEAREST)` result, cached until the public region-map, height-map,
control-map, or edited-area signals change. The bake is local-space and the
registry applies the node transform. LOD is selected to keep the estimated bake
under one million triangles; that geometry covers the terrain but does not
match the camera's current clipmap LOD. A missing data set, empty bake, or bake
over budget requests complete raster fallback.

Any other visible `GeometryInstance3D` with shadow casting enabled is reported
as unsupported and requests complete raster fallback. This currently includes
`Sprite3D` and `GPUParticles3D` draw passes. Ordinary `Node3D` helpers such as
fog and sky components are not treated as casters. Unsupported casters are
never silently omitted from an RT batch.

Mesh LODs are retained, and the provider currently traces the highest-detail
surface indices rather than matching camera screen-LOD selection. Transparent
surfaces, custom material shaders, triplanar alpha, alpha antialiasing, and
unavailable CPU alpha images mark an active caster unsupported. One such caster
requests the complete raster shadow batch.

Skinned meshes and blend shapes are behind
`set_cpu_deformation_enabled(true)`. Skeleton pose changes use the engine's
`MeshInstance3D.bake_mesh_from_current_skeleton_pose`; blend-shape-only changes
use `bake_mesh_from_current_blend_shape_mix`. Combined skin and blend-shape
poses use the engine's skin bake plus the source mesh's blend deltas transformed
by the same per-vertex bone weights. The resulting per-instance geometry cache
is rebuilt only when the skeleton signal, blend weights, or source resource
revision changes. These public bake helpers read geometry back from the
RenderingServer and can stall; keep the opt-in off unless that cost is
acceptable. Static BLAS caches are not rebuilt for a different instance's
pose. If the renderer cannot provide a valid registered skeleton RID or the
mesh data is unsupported, the full raster batch is required.

Arbitrary vertex shader deformation and exact screen-LOD parity are not
represented. Unsupported visible shadow casters always force complete raster
fallback rather than silently leaving holes in the RT result.
