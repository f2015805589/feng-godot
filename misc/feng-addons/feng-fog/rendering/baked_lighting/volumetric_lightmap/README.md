# Decoded Volumetric Lightmap Backend

`FFogVolumetricLightmap` stores an offline-decoded UE-style adaptive volumetric
lightmap payload. The module owns its GPU resources and sampling include; it
does not alter the shared Fog runtime or claim to read Unreal `.uasset` files.

For authoring, create this Resource and use the Inspector's `decoded_payload_path`
picker followed by **Import decoded VLM payload**. The visible capture transform,
local bounds, exposure, source flags, and primary Sun key describe the active
payload; the large raw byte arrays and ABI version remain hidden. The optional
`source_lightmap_gi_probe_volume` accepts the existing
`FFogBakedLightingVolume` Resource. Choose indirection dimensions and brick
size, then use **Resample LightmapGI probes to VLM** for the approximate
uniform-brick conversion. `last_import_status` reports the last action result.

## Resource and input formats

Create the Resource in a tool/import step and call
`import_decoded_payload(dictionary)`. The import validates a complete candidate
before replacing the active payload. A failed import keeps the previous data;
an identical import does not increment `revision` or invalidate the cache.
`get_rendering_snapshot()` is the main-thread boundary. It returns plain values
and packed arrays, plus a signed Resource instance ID and revision. It contains
no `Resource`, `Node`, `RenderingDevice`, or RID objects. The snapshot arrays
are immutable by contract and are copied/revalidated only when the revision
changes.

`import_decoded_payload_file(path)` accepts either a binary Variant Dictionary
or decoded JSON. Binary Variant dictionaries use native Godot values:
`Transform3D`, `AABB`, `Vector3i`, and `PackedByteArray`. JSON uses this shape:

```json
{
  "format_version": 1,
  "coordinate_units": "ue_cm",
  "capture_transform": {
    "basis_columns": [[1,0,0], [0,1,0], [0,0,1]],
    "origin": [0,0,0]
  },
  "bounds_local": {"position": [0,0,0], "size": [1000,1000,1000]},
  "brick_size": 4,
  "indirection_dimensions": [8,8,8],
  "brick_atlas_dimensions": [40,40,40],
  "indirection_rgba8_uint": "base64...",
  "ambient_rgba16f": "base64...",
  "sh_coefficients_rgba8_unorm": ["base64...", "base64...", "base64...", "base64...", "base64...", "base64..."],
  "sky_bent_normal_rgba8_unorm": "base64...",
  "directional_shadow_r8_unorm": "base64...",
  "baked_exposure": 1.0,
  "includes_environment_radiance": false,
  "contains_static_direct_directional_lighting": false,
  "has_sky_bent_normal": true,
  "has_directional_shadowing": true,
  "static_directional_light_key": "",
  "coefficient_domain": "ue_vlm_ambient_and_normalized_sh_v1",
  "source_revision": 0
}
```

The JSON `capture_transform` maps meter-space capture coordinates into FRP
world space. `coordinate_units="ue_cm"` converts only the local bounds by
0.01; the transform is still expressed for meter-space local coordinates. Set
the basis columns to include any deliberate axis or handedness conversion.
V1 requires six coefficient byte layers. Bent-normal and directional-shadow
layers may be omitted only when their `has_*` source flags are false; the
Resource materializes neutral textures in that case.

The separate `FFogVolumetricLightmapProbeConverter.build_payload()` path
resamples the existing LightmapGI tetra-probe adapter into uniform bricks. It
is an approximation with no adaptive brick density. It marks SkyBentNormal and
directional shadow data unavailable and does not invent static Sun lighting.
It does not reconstruct a UE adaptive VLM capture.

## Set 5 ABI v1

`FFogVolumetricLightmapProvider.get_gpu_inputs(snapshot, main_rd, frame)` owns
all textures, samplers, and parameter buffers. `frame.static_directional_light_key`
must be copied from the same-frame selected directional-light row. The result
contains borrowed RIDs; consumers bind them and never free them. A caller may
use `make_set5_uniforms(inputs)` to build a set for its own shader RID. Cached
uniform sets must be discarded when the provider replaces that Resource
revision or is released. Call `release_resource(resource_id)` only after no
submitted work references the old textures; `release()` releases all entries.
The provider also returns valid neutral resources for an absent/invalid source.

| Set 5 binding | Resource | Layout |
| ---: | --- | --- |
| 0 | UBO | 208 bytes; offsets below |
| 1 | indirection | 3D `RGBA8_UINT` |
| 2 | ambient | 3D `RGBA16F` |
| 3–8 | six SH coefficient layers | 3D `RGBA8_UNORM`, UE layer order |
| 9 | SkyBentNormal | 3D `RGBA8_UNORM`; neutral unless source flag says present |
| 10 | directional shadow | 3D `R8_UNORM`; neutral unless source flag says present |

The UBO is two column-major `mat4`s followed by `vec4 bounds_min`, `vec4
bounds_size`, `uvec4 indirection_dims_brick_size`, `uvec4
atlas_dims_source_flags`, and `vec4 baked_metadata`:

| Offset | Field |
| ---: | --- |
| 0 | `world_to_capture` |
| 64 | `world_direction_to_capture` (orthonormal inverse basis, no translation) |
| 128 | capture-local bounds minimum in meters |
| 144 | capture-local bounds size in meters |
| 160 | indirection XYZ dimensions, brick size |
| 176 | atlas XYZ dimensions, source flags |
| 192 | baked exposure, remaining lanes reserved |

For a receiver, UE's lookup clamps normalized capture position to `[0, 0.99]`,
fetches the RGBA8_UINT entry, and treats `w=0` as invalid. A valid entry is
`(brick_offset_x, brick_offset_y, brick_offset_z, covered_indirection_size)`.
For each axis the atlas coordinate is
`(offset * (brick_size + 1) + fract(indirection_coord / covered_size) * brick_size + 0.5) / atlas_dimension`.
The extra voxel is the one-texel brick padding used by UE.

The six coefficient layers are stored as two RGBA textures per color channel:
red layers 0/1, green 2/3, blue 4/5. Each RGBA texel carries the four normalized
coefficients for UE's L1/L2 encoding. The fog helper currently evaluates UE's
default SH2 path from L0 plus the first three L1 lanes, using the UE HG
component order `(1, dir.y, dir.z, dir.x) * (1, g, g, g)`. It decodes normalized
coefficients with `2 * byte / 255 - 1`, applies UE's `0.488603 / 0.282095`
normalization, and returns `irradiance_over_pi`. The six layers remain in the
asset for completeness; this default helper does not add L2.

`FFogVolumetricLightmapSample` also returns:

| Field | Meaning |
| --- | --- |
| `valid` | The position resolved to a valid brick and finite sample |
| `irradiance_over_pi` | UE SH2 phase result; no view pre-exposure applied |
| `sky_visibility` | Length of decoded `SkyBentNormal * 2 - 1`, or neutral 1 |
| `directional_shadow` | Scalar static shadow only for an exact primary-Sun key match; otherwise 1 |
| `baked_exposure` | Source exposure, returned separately |
| `source_flags` | The source and exact-key match flags described below |

Source flags are `VALID=1`, `INCLUDES_ENVIRONMENT_RADIANCE=2`,
`CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING=4`, `HAS_DIRECTIONAL_SHADOW=8`,
`STATIC_LIGHT_KEY_MATCH=16`, and `HAS_SKY_BENT_NORMAL=32`. Static directional
data is only associated with the primary Sun. `static_directional_light_key`
must exactly match the same-frame selected directional extension row; otherwise
the helper returns neutral shadow and never suppresses a live Sun. A matching
shadow-only resource keeps the Sun and applies its scalar shadow. A matching
resource that contains static direct directional lighting may be used by the
consumer to suppress that same Sun exactly once.

Multiply returned radiance by the consumer's scene normalization, divide by
`baked_exposure`, and apply view pre-exposure once. This provider does not apply
`P0`, scene normalization, material albedo, or fog component intensity.
`INCLUDES_ENVIRONMENT_RADIANCE` is independent of direct-light flags and may
only suppress duplicate live Sky when a valid VLM source actually contains that
environment contribution.

## CPU checks and current scope

Run `tests/run_volumetric_lightmap_tests.py --editor <editor-executable>` for
the isolated CPU contract. It checks UE's mapping and SH equations against an
independent literal oracle, JSON import, atomic revision behavior, neutral
missing layers, non-identity capture rotation, environment/Sun flags, and the
approximate probe resampler.

## GPU verification and limits

The main `FengHeightFog` consumer and Set 5 upload/sampling path passed a fixed
D3D12 fixture with 16 numeric captures and a disabled-resource cleanup case.
The cases cover the SH2 source oracle, matched and mismatched static-Sun keys,
static-scattering-zero suppression, live-Sun retention, matching and neutral
shadow behavior, environment deduplication, invalid-brick `w=0` behavior,
switching between VLM and tetra-probe modes, viewport resize, and return to a
neutral baked source. The disable case ended with zero retained volume states
and a cleared context output.

Evidence: `C:\Temp\feng-vlm-main-consumer-disable-20261009-02\project`, source
manifest SHA-256
`354daf180bf88c9929cdca4c425cd4cdd8d9d5306a8b182e4202051c76edd16d`, and
`evidence\gpu_run_02\run.json` (natural exit code 0, empty stderr). The
fixed GUI editor binary SHA-256 was
`045d2b8a49bf1b9e06f2e44e02970b1333abaeb46e6cc813636249ae612cb7e3`; the
console editor binary SHA-256 was
`0dc9b25d1b6bc2b21aa3d91725061063383e24ca06aeb47d2d47598ae7a0ec6b`. This is
a bounded consumer fixture, not pixel-identical UE output or universal asset
coverage. The importer accepts decoded JSON or a Godot
Variant dictionary; it does not parse Unreal `.uasset` files or run a
Lightmass/VLM bake. The separate LightmapGI probe-to-brick resampler remains
approximate and is not an Unreal VLM importer.

Stereo currently has 7 CPU checks only; no XR hardware run has been made.

Ray-traced fog shadows are conditional on a Vulkan RenderingDevice that reports
both ray-tracing-pipeline and buffer-device-address support. The standalone
provider fixture passed all 13 cases, including 32-bit masks, alpha-scissor,
alpha-hash, cast-shadow-off filtering, and transparent-to-opaque ordering. A
separate real FRP Vulkan end-to-end fixture passed 3 cases (blocked sun,
moved-caster clear, and mask mismatch) with natural exit 0. The fixtures do not
prove pixel-identical UE output or support for arbitrary caster/material
scenes. Unsupported or incomplete caster snapshots, invalid inputs, devices
without both features, and batch overflow require a complete raster fallback;
batches are capped at 128 MiB and 1<<24 rays. The Spot D3D12 fixture is not an
RT hardware test: that device used raster fallback. The standalone RT log and
E2E run contain non-fatal SPIR-V unsupported-operation notices.

Final merged-source integration and project test1/test2 acceptance remain
pending.
