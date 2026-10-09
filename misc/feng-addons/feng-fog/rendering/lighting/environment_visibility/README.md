# Volumetric environment visibility

`FFogVolumeEnvironmentVisibilityProvider` owns a small set-4 packet used by the
volumetric light shader. It joins only immutable FengSky values and the current
FRP context's borrowed cloud maps. It never reads an `Environment`, resolves a
scene node, runs an atmospheric ray march, or frees a source RID.

## CPU input

Call `update_frame_inputs(ctx, rd, normalized_frame, cloud_maps_current,
sky_metadata)` after the FRP atmosphere inputs are published and, when the
current execution plan includes the cloud producer, after its maps are ready.
The frame must carry `world_id` from the current fog snapshot. `sky_metadata`
contains only these values:

| Key | Type | Meaning |
| --- | --- | --- |
| `world_id` | `int` | World owning the active sky provider. |
| `provider_id` | `int` | Active `FengSkyAtmosphere` provider instance. |
| `settings_revision` | `int` | Revision of the atmosphere settings used for the values. |
| `sun_light_rid` | `RID` | Primary sun base RID. |
| `secondary_sun_light_rid` | `RID` | Secondary sun base RID, if present. |
| `sun_ground_transmittance` | `Vector3` | Linear planet-top to ground transmission for the primary sun. |
| `secondary_sun_ground_transmittance` | `Vector3` | Same for the secondary sun. |

Metadata is accepted only when the world matches the frame. Each sun value also
requires exact equality between its metadata RID, `ctx.get_atmosphere_light_rid`
for that slot, and exactly one matching RID in
`normalized_frame.directional_light_base_rids`. An absent, stale, or mismatched
source leaves that sun's transmission at neutral `(1, 1, 1)`.

FRP's native directional light data contains the raw sun color and energy. The
consumer applies the matching sky's ground transmission once to direct volume
sunlight. The value is constant for the planet ground reference; it is not
recomputed at every froxel. It contains no light energy, scene normalization,
pre-exposure, or cloud visibility.

Set `cloud_maps_current` only for maps produced in this frame. A pre-lighting
fallback or a frame without the cloud pass passes `false`; the provider clears
the cloud mapping/validity packet and binds its neutral texture. It never reuses
cloud maps from a previous frame. Cloud shadows are sampled only when the
consumer says that native directional shadowing is enabled. Cloud AO is a
separate visibility factor for the Sky multiple-scattering term only.

## Set-4 GPU ABI v1

| Binding | Resource | Layout |
| --- | --- | --- |
| 0 | Uniform buffer, 48 bytes | `vec4 primary_ground`, `vec4 secondary_ground`, `ivec4 sun_slots`. Each ground vec4 stores RGB transmission and a valid flag. `sun_slots` stores native directional indices, current-cloud-map flag, and metadata-valid flag. |
| 1 | Uniform buffer, 592 bytes | 35 projection vec4s, `sun_mapping`, and `flags`, byte-compatible with the height-fog cloud visibility packet. |
| 2 | Sampler + texture | Current primary cloud-shadow map, otherwise a provider-owned neutral texture. |
| 3 | Sampler + texture | Current secondary cloud-shadow map, otherwise neutral. |
| 4 | Sampler + texture | Current raw cloud-AO map, otherwise neutral. |

The provider owns both UBOs, its sampler, and neutral texture. Results returned
by `update_frame_inputs` borrow those RIDs until the next update or `release()`.
Cloud output textures remain borrowed from the FRP context. The shader include
`fog_volume_environment_visibility.glslinc` exposes:

- `ffog_volume_sun_ground_transmittance(native_directional_index)`
- `ffog_volume_cloud_shadow_visibility(world_position_m, native_directional_index, native_shadowing_enabled)`
- `ffog_volume_directional_transmittance(world_position_m, native_directional_index, native_shadowing_enabled)`
- `ffog_volume_sky_cloud_visibility(world_position_m)`

None of these functions modifies radiance or exposure. Apply their returned
transmission/visibility exactly once in the corresponding direct-sun or Sky
multiple-scattering lighting term.
