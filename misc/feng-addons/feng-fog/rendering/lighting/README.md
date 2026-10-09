# Fog lighting providers

These addon-owned helpers provide lighting data for the FRP volumetric-fog service. They do not change the native renderer and are not connected to the height-fog runtime until that service calls them.

## Point and capsule light integral

`FFogCapsuleLight.distance_bias_m(cell_radius_m, scale)` converts UE's one-centimeter minimum distance bias to meters. `FFogCapsuleLight.integrate(to_light, axis, source_length_m, bias_m, inverse_squared)` is the CPU oracle; `ffog_integrate_capsule_light(...)` is its GLSL mirror. A zero length uses `1 / (distance² + bias²)` when inverse-squared falloff is enabled. A nonzero length uses UE's two-endpoint capsule equation and returns the unnormalized average endpoint direction. With inverse-squared falloff disabled, the helper returns falloff 1 while preserving that direction. If a segment endpoint collapses onto the receiver, both helpers use the finite point-source limit. The caller retains the native range/spot mask as a separate multiplier.

The set-3 light-extension record's final `vec4` stores source length in meters and local axis index (X/Y/Z). `Light3D.size` is not used as capsule length. Consumers use `ffog_light_capsule_axis_world()` to map that axis through the orthonormalized light transform, then transform it into the same center-view basis as the native light record.

## Sky SH

`FFogSkySHProvider.update_frame_inputs(frame, rd, sky_metadata)` accepts the immutable FRP volume frame dictionary, the RenderingServer main `RenderingDevice`, and the plain-value result of `FengSkyLightRuntime.volumetric_metadata_for_world(world_id)`. It returns a provider-owned storage-buffer RID with 112 bytes of seven `vec4` values in the UE ReflectionEnvironment diffuse-convolved SH9 layout. The input radiance texture is borrowed from the explicit, ready `FengSkyLight` frame source. No `WorldEnvironment` fallback is queried.

The frame's `sky_radiance_size` is the nominal cube-face resolution, not the RD texture width. SkyRD stores the octmap interior at `2 * nominal_size`, then adds a mip-filtering border. The provider reads the actual `RDTextureFormat.width/height`, requires a square sampleable 2D or 2D-array float texture, and checks `actual_dimension * (1 - 2 * border) ~= 2 * nominal_size` within half a pixel. Regular sky and external-capture storage use the same relation; their array/non-array modes can choose different padding. Actual dimensions, texture type/layers, nominal size, and border all participate in the SH cache key. A failed size check reports the actual dimensions, nominal size, border, and measured interior.

The provider reads the `.glslinc` compute source through `FileAccess`, strips Godot's leading `#[compute]` hint, then submits raw GLSL through `RDShaderSource.source_compute` with its public `language` property. The `.glslinc` extension keeps these runtime-only RD compute stages out of `ResourceImporterShaderFile`; the hint is importer metadata, not part of the raw RD GLSL compiler input.

The packed coefficients stay in sky-local coordinates. Before evaluating them, transform the world camera/froxel direction into the registered sky's local coordinates exactly once, then use the UE simple diffuse lookup direction `camera_vector * -g`. The first three `vec4` values implement `GetSkySHDiffuseSimple`; the remaining four preserve the UE L2 terms and V6 constant lane. The raw SH projection is cached by source owner, source and texture RIDs, radiance revisions, rotation, texture layout, and octahedral border. Rotation is part of the cache identity, but is not baked into the coefficients.

The SH buffer contains raw linear sky radiance only. The caller applies these independent factors once:

```text
raw_SH_radiance * source_energy * scene_normalization
    / captured_exposure * pre_exposure * volumetric_scattering_intensity
```

`scene_normalization` removes the renderer's luminance normalization and includes camera exposure; do not divide by luminance or apply camera exposure again. `pre_exposure` is the output atlas storage exposure. Energy and `volumetric_scattering_intensity` are not baked into the cache. If the active `FengSkyLight` owner, source revision, radiance energy, exposure, or rotation does not match the frame, the result cannot be applied. No source returns a neutral provider-owned buffer when the main RenderingDevice is available.

`evaluate_simple_diffuse`, `pack_ue_diffuse_over_pi`, and `project_samples_to_raw_sh` are CPU mirrors for fixtures. They do not read back or access GPU data.

## Rect-area light

`FFogRectLight.evaluate_volume(...)` is a CPU oracle. `fog_rect_light.glslinc` provides the corresponding GLSL helpers for the addon GPU service:

- `ffog_rect_integrate` mirrors UE's spherical-rectangle angular integral. Its scalar falloff already includes the solid-angle distance behavior; do not add another inverse-square factor.
- `ffog_rect_radius_mask` provides the finite light-range mask.
- `ffog_rect_front_and_soft_fade` provides the one-sided emission mask and UE cell-footprint soft fade.
- `ffog_rect_source_texture_uv` maps the froxel-to-light ray to the packed AreaLight3D source-texture atlas and UE mip selection. Native `area_width/area_height` are full-span vectors, while UE `Rect.FullExtent` is a half extent; the helper halves both vectors before computing UV and LOD. The frame's `projector_rect`, `cos_spot_angle`, `area_profile_atlas`, and `area_profile_sampler` describe this atlas. If no source rect is bound, use a white source-color multiplier.
- `ffog_rect_sample_source_texture` samples the atlas after UV/mip validation.

The light position, direction, area axes, shadow matrix, and cluster data in the native 224-byte light record use the renderer's center-camera view basis. The frame projection and camera transform are per-view and already contain eye offset. Add the frame's `eye_offset` to a per-eye froxel position before using local-light and cluster data. `area_width` and `area_height` are full-span vectors in that center-view basis.

`FFogRectLight` returns the FRP Henyey–Greenstein cosine `c = dot(L, viewRay)`, where `L` points from froxel to light and `viewRay` points from camera to froxel; FRP's denominator is `1 + g² - 2gc`. UE names that camera-to-froxel ray `CameraVector`, uses `cosUE = dot(L, -CameraVector) = -c`, and evaluates `1 + g² + 2g cosUE`. These conventions produce the same phase value. The spherical polygon's integrated direction is diagnostic only. Rect source-texture UV uses the same center froxel-to-light vector. `FFogRectLight` does not model UE barn doors because the current FRP light packet and Godot `AreaLight3D` do not expose those controls. An unbound area source texture contributes white; this is not a missing shadow or lighting fallback.

## CPU checks

Run `tests/run_fog_lighting_helper_tests.py` with the local editor binary. It checks uniform-sky calibration, L1 removal at zero anisotropy, retained UE L2 packing, rectangular angular integration, point/capsule falloff, range/front/soft fades, phase-vector sign, and source-atlas UV/mip boundaries. The runner uses a disposable headless project and performs no GPU work.
