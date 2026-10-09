# Baked volumetric irradiance input

`FFogBakedLightingVolume` adapts the LightmapGI capture-probe data exposed by
`LightmapGIData`. It does not read or reuse the surface lightmap atlases.

LightmapGI stores probe positions, BSP planes, and bounds in the bake's
capture-local coordinates; the `LightmapGIData` resource does not own the scene
node transform. In `FFogBakedLightingVolume` Inspector, choose
`source_lightmap_gi_data`, set `source_capture_transform`, then press
**Import / Refresh LightmapGI Probes**. These are staged inputs: changing them
does not alter the active serialized payload until import succeeds.
`capture_lightmap_gi_node(lightmap_gi)` is the direct helper for a component's
future NodePath button; it reads `light_data` and `global_transform` from that
node without searching the scene. LightmapGI's baker transforms mesh geometry
by the inverse node transform before producing capture bounds and points, so
the node's `global_transform` maps capture-local data into world space.

A successful import replaces the probe arrays and active `capture_transform`
as one update, increments `revision` once, and emits one `changed` signal.
Identical probe data and transform leave the revision unchanged. A failed staged
import returns `{valid: false, reason: ...}` and preserves the previous active
payload. The older direct `capture_lightmap_gi_data` and `capture_probe_data`
methods retain their clear-on-invalid behavior for compatibility. The adapter
retains capture-space data and publishes `capture_transform`, `world_to_capture`,
and transformed `world_bounds` for the volume renderer. SH coefficients remain
in capture-space axes. A consumer evaluating them with a world-space direction
must first use `world_direction_to_capture` (the orthonormalized inverse capture
basis) and normalize it. Transform scale affects positions and transformed
bounds; it never scales radiance or direction length. Nonuniform scale is
reported in `capture_scale` and has no radiometric effect.

`get_gpu_payload()` returns the immutable v1 payload:

| Field | Layout |
| --- | --- |
| `bounds` | Capture-space `AABB` |
| `probe_positions` | Capture-space `PackedVector3Array` |
| `probe_sh` | Probe-major SH9, 27 floats per probe, RGB interleaved per coefficient |
| `coefficient_domain` | Godot LightmapperRD incident-radiance SH, projected with its `4 / ray_count` estimator; coefficients are scaled by `1 / PI` relative to physical radiance SH |
| `coefficient_to_physical_radiance_scale` | `PI`; apply once before using probe data as incident radiance in a volume |
| `phase_convolution` | For normalized Henyey-Greenstein scattering, multiply SH band `l` by `g^l`, then restore the stored `1 / PI` scale. Do not apply the Lambert cosine convolution used by surface shading. |
| `tetrahedra` | Four probe indices per tetrahedron |
| `bsp_nodes` | Six int32 lanes per node: four float bit patterns `(normal.xyz, d)`, then signed `over` and `under` indices |
| `capture_transform` / `world_to_capture` | Capture and inverse transforms |
| `world_bounds` | Capture bounds transformed into world-space AABB |
| `world_direction_to_capture` | Orthonormalized inverse basis for SH direction evaluation |
| `baked_exposure` | Source exposure normalization; consumers apply it once |
| `includes_environment_radiance` | Explicit source metadata; defaults to `true` because LightmapGI probe rays trace the configured bake environment on a miss |
| `contains_surface_direct_radiance` / `includes_probe_origin_direct_lighting` / `baked_direct_semantics` / `bake_mode` | Probe rays can contain direct-lit surface radiance and bounces, but not direct illumination evaluated at the probe position. The adapter sets `includes_probe_origin_direct_lighting=false` and `suppresses_live_direct_lighting=false`; valid probes never suppress live direct fog lighting. |
| `source_lightprobe_hash` / `source_revision` | Source probe-position hash and payload-content revision |

`sample_sh9(world_position)` is a CPU reference sampler. It follows the engine
probe sampler's BSP branch (`normal.dot(point) > d` selects `over`), uses the
selected tetrahedron's four indices, and interpolates each of its nine `Color`
coefficients by the engine's tetrahedral barycentric formula. The coefficients
are incident-radiance SH, not cosine-convolved irradiance: LightmapperRD
projects uniformly sampled `trace_indirect_light` with `4 / ray_count`, which
is the usual `4 * PI / ray_count` radiance projection with a `1 / PI` scale.
The surface shader restores the Lambertian cosine integral with its `PI`-bearing
band factors before multiplying by albedo. Volume phase convolution instead
uses `PI * sum(a_lm * g^l * Y_lm(direction))`; for `g = 0`, only `l=0`
contributes and a uniform environment reconstructs its original radiance.
Invalid or
out-of-bounds input returns 27 zero floats. Use
`sample_sh9_with_validity(world_position)` when zero radiance must be
distinguished from a point outside the captured probe domain. The volume shader
may use a valid sample for baked indirect and surface-reflected radiance. It
must keep live direct fog lighting enabled both inside and outside the probe
domain because this LightmapGI probe format contains no direct-at-probe term.

### Environment source de-duplication

The probe baker follows the scene's bake environment on ray misses, so valid
probe SH can already include the environment contribution. `LightmapGIData`
does not retain the complete bake-time environment configuration. The resource
therefore exposes `includes_environment_radiance` as explicit source metadata,
defaulting conservatively to `true`. Set it to `false` only when the selected
bake did not include environment radiance. Changing this field advances the
resource revision and invalidates its GPU snapshot.

For each froxel, `resolve_source_usage(sample_valid, includes_environment,
static_lighting_scattering_intensity)` defines the source rule:

| Probe sample | Static scattering | Baked probe | Live sky | Live direct lights |
| --- | ---: | --- | --- | --- |
| Valid; environment included | Positive | Apply | Suppress to avoid adding the same environment twice | Keep |
| Valid; environment excluded | Positive | Apply | Keep | Keep |
| Valid | Zero | Skip | Keep | Keep |
| Invalid or outside bounds | Any | Skip | Keep | Keep |

The environment flag never suppresses direct lights. The current LightmapGI
adapter publishes `includes_probe_origin_direct_lighting=false`; the other
source flags are diagnostics and must not be interpreted as a direct-light
deduplication signal.

### GPU provider ABI v1

`FFogBakedLightingProvider.snapshot_for_rendering(resource)` is the main-thread
boundary. It validates and copies the resource arrays once per revision into
an immutable-by-contract value snapshot. Callers must treat its packed arrays
as read-only. Pass that snapshot across the render boundary; do not call
`get_gpu_payload()`, walk CPU arrays, or run the CPU sampler per frame/froxel.

`get_gpu_inputs(snapshot, RenderingServer.get_rendering_device(), frame)` creates
or reuses provider-owned buffers by resource, revision, and main RenderingDevice.
The returned RIDs are borrowed. The fog service binds them and must not free
them. Call `release_resource(resource_id)` only after consumers stop submitting
work that references the buffers; `release()` drops every provider-owned GPU
buffer and cached snapshot.

The shader include `fog_baked_lighting_sampling.glslinc` uses set 2:

| Binding | Buffer | std430/std140 contents |
| ---: | --- | --- |
| 0 | Probe positions | `vec4[probe_count]`, capture-space xyz |
| 1 | Probe SH | `float[probe_count * 27]`, probe-major, SH9 coefficient then RGB |
| 2 | Tetrahedra | `int[tetrahedron_count * 4]`, four probe indices |
| 3 | BSP nodes | `int[bsp_node_count * 6]`, plane float bits then signed over/under |
| 4 | Parameters | 176-byte std140 block: two mat4s followed by three vec4s |

The parameter block offsets are: world-to-capture matrix at 0, world-direction-
to-capture matrix at 64, capture min plus baked exposure at 128, capture size at
144, and `(probe_count, tetrahedron_count, bsp_node_count, source_flags)` at
160. Source flag bits are environment radiance `1`, surface direct radiance
`2`, interior bake `4`, and direct-at-probe `8`.

`ffog_sample_baked_probe_volume(world_position, world_camera_vector, g)` returns
`valid`, physical incident radiance, and source flags. `world_camera_vector`
points from the froxel toward the camera. The helper negates it to obtain the
camera-to-froxel view ray used by the LightmapGI phase-SH lookup, rotates that
ray into capture space once, interpolates the probe SH with the Godot BSP/tetra
data, then computes
`PI * sum(a_lm * g^l * Y_lm)`. It does not apply baked exposure, scene
normalization, pre-exposure, or static scattering intensity. Multiply the
returned radiance by
`scene_normalization * pre_exposure / baked_exposure` once, then apply the
component's static scattering intensity once. Do not apply surface cosine
convolution. The separate
`ffog_sample_baked_probe_volume_ue_two_band(...)` entry point uses the same
probe selection and interpolation but retains only L0/L1, matching UE
`GetVolumetricLightmapSH2`/`FTwoBandHG`. The generic entry point remains full
SH9 and retains L2. The CPU `evaluate_hg_incident_radiance` and
`evaluate_hg_incident_radiance_ue_two_band` methods mirror those two paths.

### Verification

`tests/run_baked_lighting_volume_tests.py` runs the CPU oracle, provider snapshot
and ABI packing checks, constant-environment calibration, and source selection
tests in a disposable headless project. It does not exercise GPU buffer upload
or compile the GLSL include; those remain part of the addon service's GPU
acceptance.

The volume resource owns no `RenderingDevice` RID and is safe to serialize or
replace from the main thread. The provider owns its cached probe buffers; the
volume service owns only its bindings and sampling work. Cache validation and
uploads by `revision`; do not call the CPU oracle or scan payload arrays per
froxel or render frame.
