# Feng Fog

`FengHeightFog` provides exponential height fog with two density layers, start
and cutoff distances, and optional directional inscattering. The Sky-anchored
fullscreen pass fogs the opaque scene and sky. Forward-only opaque fallback and
transparent materials evaluate fog at their own fragment position.

## Lighting and color

`fog_color_mode = Unreal Radiance` is the default. `fog_inscattering_color`
defaults to black and is an independent scene-linear source, matching Unreal's
separate authored fog source. It is not clamped, sRGB-converted, or multiplied
by sunlight. A nonblack value therefore remains visible when atmosphere lighting
is disabled. The directional artist lobe has its own color.

The runtime constructs scene-linear sources for both rendering paths:

- Authored base source: `fog_inscattering_color`, unchanged.
- Base sky source, when a supported Feng Sky atmosphere contributes to fog:
  `sky_mean_radiance * height_fog_contribution * sky_ambient_color_scale`.
- When the selected sun exactly matches a supported Feng Sky atmosphere light,
  its post-transmittance ground illuminance is routed through the existing
  directional phase: `sun_ground_illuminance * height_fog_contribution * cos(angle)^exponent / (4 * PI)`.
- The artist lobe is an independent addition:
  `directional_color * luminance(selected_sun_irradiance_rgb)`, followed by the
  same directional phase.

`sky_atmosphere_ambient_contribution_color_scale` tints only the sky ambient.
The directional artist color is authored in scene-linear RGB and is independent
of the authored base. The pass applies pre-exposure once to the combined source.

Sun irradiance uses `light_energy * light_intensity_lux` in physical mode and
`light_energy * PI` otherwise, with linear light color and physical-mode color
temperature. For a matching atmosphere light, its directional direct term uses
post-transmittance ground illuminance; the artist lobe keeps the selected
light's luminance scaling. Sky mean radiance is already phase-integrated and
needs no additional `1/(4π)` factor.

Without a supported atmosphere provider, Unreal Radiance consists of the
authored base plus the optional artist directional lobe; it does not add an
isotropic direct-sun source. With no authored or atmosphere source, and with no
active artist directional lobe, fog still attenuates scene color but has black
in-scattering. `height_fog_contribution = 0`
removes atmosphere-provided ambient and matched-atmosphere direct light; the
authored base and independent artist lobe remain. **Affect Height Fog** off
disables the atmosphere contribution while keeping the authored base and the
selected scene-light artist lobe. Camera exposure still determines final screen
brightness.

## Optional Lit Albedo mode

Set `fog_color_mode = Lit Albedo` to opt into the previous physical material
model. In this mode `fog_inscattering_color` is converted from sRGB to linear
albedo in `[0, 1]`: sky and a matching atmosphere sun are tinted by this albedo,
and an unmatched scene sun contributes the isotropic fallback
`albedo * sun_irradiance_rgb / (4 * PI)`. Black albedo absorbs without a base
source. This mode is deliberately distinct from Unreal Radiance; switch back to
Unreal Radiance when the color should be an independent authored source.

The fog model does not include multiple scattering, terrain occlusion or
distance-varying atmospheric aerial perspective.

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

The headless CPU test covers default Unreal Radiance, independent authored RGB,
matched atmosphere direction, zero contribution, and explicit Lit Albedo
behavior. Add `--gpu-driver vulkan` (or a supported driver) for rendered checks.
The 320 × 240 GPU test checks default Radiance at fixed exposure with zero
atmosphere contribution across deferred opaque, unshaded, and transparent
surfaces, plus a 10,000× lighting range, pre-exposure on/off, direct-only
lighting, low-sun sky/Fog comparison, and the independent directional lobe
including a horizontal sun. Logs and PNGs remain in the reported scratch project.
