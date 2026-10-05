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

- Base: `albedo * (sky_mean_radiance * height_fog_contribution * sky_ambient_color_scale + sun_irradiance_rgb / (4 * PI))`
- Directional artist lobe: `directional_color * luminance(sun_irradiance_rgb)`,
  followed by the shader’s `cos(angle)^exponent / (4 * PI)` phase

`sky_atmosphere_ambient_contribution_color_scale` tints only the sky ambient.
The directional color is authored in scene-linear RGB and is independent of
base albedo. The pass applies pre-exposure once to the combined source.

Sun irradiance uses `light_energy * light_intensity_lux` in physical mode and
`light_energy * PI` otherwise, with linear light color and physical-mode color
temperature. Fog uses the selected source light’s authored irradiance. Atmospheric surface
transmittance and the sky snapshot’s ground illuminance do not alter this fog
source. Sky mean radiance
is already phase-integrated and needs no additional `1/(4π)` factor.

Without a supported atmosphere provider, the selected sun still lights the fog.
With neither source, Lit fog has extinction only. `height_fog_contribution = 0`
or **Affect Height Fog** off removes sky ambient while retaining direct sunlight.
Camera exposure and light color still determine the final screen brightness.

The optional directional lobe is an artistic addition to isotropic scattering.
This model does not include multiple scattering, terrain occlusion or
distance-varying atmospheric aerial perspective.

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
