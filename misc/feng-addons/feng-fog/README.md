# Feng Fog

`FengHeightFog` provides exponential height fog with two density layers, start
and cutoff distances, and optional directional inscattering. The Sky-anchored
fullscreen pass fogs the opaque scene and sky. Forward-only opaque fallback and
transparent materials evaluate fog at their own fragment position.

## Lighting and color

`fog_color_mode = Lit` is the default, with white `fog_inscattering_color`.
The color is converted from sRGB to linear single-scattering albedo in `[0, 1]`.
White scatters incident light without tinting it; black contributes extinction
without a base light source. The directional artist lobe has its own color.

The runtime constructs scene-linear sources for both rendering paths:

- Base sky source: `albedo * sky_mean_radiance * height_fog_contribution * sky_ambient_color_scale`.
- An unmatched/custom scene sun remains an isotropic source:
  `albedo * sun_irradiance_rgb / (4 * PI)`.
- When the selected sun exactly matches a supported Feng Sky atmosphere light,
  its post-transmittance ground illuminance is routed through the existing
  directional phase: `albedo * sun_ground_illuminance * height_fog_contribution * cos(angle)^exponent / (4 * PI)`.
- The artist lobe remains independent of albedo:
  `directional_color * luminance(selected_sun_irradiance_rgb)`, followed by the
  same directional phase.

`sky_atmosphere_ambient_contribution_color_scale` tints only the sky ambient.
The directional artist color is authored in scene-linear RGB and is independent
of base albedo. The pass applies pre-exposure once to the combined source.

Sun irradiance uses `light_energy * light_intensity_lux` in physical mode and
`light_energy * PI` otherwise, with linear light color and physical-mode color
temperature. For a matching atmosphere light, its directional direct term uses
post-transmittance ground illuminance; the artist lobe keeps the selected
light's luminance scaling. Sky mean radiance is already phase-integrated and
needs no additional `1/(4π)` factor.

Without a supported atmosphere provider, the selected sun still lights the fog.
With neither source, Lit fog has extinction only. `height_fog_contribution = 0`
removes atmosphere-provided ambient and matched-atmosphere direct light; the
independent artist lobe remains. **Affect Height Fog** off disables the
atmosphere contribution while retaining the selected scene sun's fallback
lighting. Camera exposure and light color still determine final screen brightness.

The optional directional color remains an artistic addition. For a matched
atmosphere sun it shares the existing directional phase with that atmosphere's
albedo-tinted direct source; for an unmatched sun, the direct source remains
isotropic. This model does not include multiple scattering, terrain occlusion
or distance-varying atmospheric aerial perspective.

## Legacy scenes

Select **Legacy Radiance** to preserve the previous fixed, scene-linear authored
RGB, untinted sky ambient and luminance-scaled directional lobe. Keep the old
color, including black when an older scene omitted it. Legacy RGB is neither
clamped nor sRGB-converted. Its fixed source can become relatively dim under
brighter lighting and automatic exposure.

## Lifecycle and tests

Each runtime/editor plugin owns its world/render-target registrations. Disabling
Fog or Magic GI leaves the other addon’s views registered. Fog enables viewport
debanding while active and restores the original value when its use ends.

Run ownership/lighting contracts and the optional Sky late-load check:

```sh
python misc/scripts/test_feng_runtime_contracts.py --editor /path/to/godot
python misc/feng-addons/feng-fog/tests/run_late_sky_runtime_load.py --editor /path/to/godot
```

The late-load check starts without Feng Sky, then loads a mock provider in the
same process and verifies discovery and world-matched radiance.

```sh
python misc/feng-addons/feng-fog/tests/run_lit_fog_tests.py --editor /path/to/godot
python misc/feng-addons/feng-fog/tests/run_lit_fog_tests.py --editor /path/to/godot --physical-units false
```

Add `--gpu-driver vulkan` (or a supported driver) for rendered checks. The
320 × 240 test covers a 10,000× lighting range, colored/black/white fog,
deferred opaque/forward fallback/transparent surfaces, pre-exposure on/off,
direct-only lighting and the independent directional lobe, including a
horizontal sun. Logs and PNGs remain in the reported scratch project.
