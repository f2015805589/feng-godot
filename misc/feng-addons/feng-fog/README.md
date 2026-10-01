# Feng Fog

`FengHeightFog` provides exponential height fog with two density layers, a start distance, a cutoff distance, and optional directional inscattering. The Sky-anchored fullscreen pass fogs the opaque scene and sky. Forward-only opaque fallback and transparent materials use their own fragment position, so their fog follows the surface rather than the opaque depth buffer.

## Lit fog color

`fog_color_mode = Lit` is the default. `fog_inscattering_color` now behaves like
an sRGB material color: it is converted to linear single-scattering albedo in
[0, 1]. White scatters incident illumination without tinting it; black absorbs
without emitting base light. The optional directional artist lobe is independent.
The density, two height layers, opacity and distances still control the same
extinction integral.

The runtime constructs scene-linear sources before either fog rendering path:

- Base: `albedo * (sky_mean_radiance * height_fog_contribution + sun_irradiance_rgb / (4 * PI))`
- Additional directional artist lobe: `directional_color * luminance(sun_irradiance_rgb)`, followed by the existing `cos(angle)^exponent / (4 * PI)` shader phase

Both sources follow light intensity, while their author colors stay independent.
The base uses linear sRGB albedo; the directional color retains its original
scene-linear artistic semantics and is never multiplied by the base albedo.
Changing a physical sun from 6 to 60,000 lux no longer overwhelms a fixed, additive fog
color. This does not bypass exposure or guarantee a fixed screen brightness:
camera metering, the illuminant's color, and the scene still affect the result.
The pass applies pre-exposure to the combined source exactly once.

The isotropic direct-light phase is `1/(4π)`; the atmosphere's `ambient_radiance`
is already `(1/(4π)) ∫ L_sky(ω) dω` and is not divided again. Sun irradiance is
`light_energy * light_intensity_lux` in physical mode and `light_energy * PI`
otherwise, with linear light color and physical color temperature. Both fog
components use the same raw selected sun as scene surfaces. The sky
snapshot's `sun_ground_illuminance` does not replace it: the renderer does not
apply that atmospheric transmission to surface lighting, and the snapshot is
zero at the horizon. Applying it only to fog erases its white base and lobe.
Sky mean radiance remains a separately albedo-tinted ambient contribution.

With no supported atmosphere provider, including custom skies, the selected sun
still illuminates the fog. With neither sun nor atmosphere lighting, lit fog
has extinction but no source. `height_fog_contribution = 0` removes only sky
ambient; `affect_height_fog = false` disables the provider entirely, so fog then
keeps its selected light and removes only that provider's sky ambient.

The directional term remains an optional artistic addition. The combined
isotropic-plus-lobe phase is not an energy-conserving volumetric model; this
feature does not add multiple scattering, terrain occlusion, or distance-varying
atmospheric aerial perspective.

## Legacy scenes

This is an intentional authoring change: the default color is now white, and
saved colors are interpreted as lit sRGB albedo unless the mode is overridden.
For an older scene that needs the exact previous appearance, select
`Legacy Radiance` and keep its original color (black if the old scene omitted
it). That mode preserves the fixed scene-linear authored RGB plus untinted sky
ambient and the luminance-scaled raw-sun artist lobe. It is still expected to
lose the relative contribution of a fixed color under much brighter lighting
and automatic exposure. Legacy values are not clamped or converted to sRGB.

## Test

World/render-target registrations are owned independently by each runtime and
editor plugin. Disabling Magic GI or Fog cannot unregister the other addon's
views. Node exit releases its registrations and restores the viewport's original
debanding setting. The headless ownership/lighting regression is:

```sh
python misc/scripts/test_feng_runtime_contracts.py --editor /path/to/godot
```

With a built Godot editor available, run the optional-runtime late-load check:

```powershell
python misc/feng-addons/feng-fog/tests/run_late_sky_runtime_load.py --editor F:/path/to/godot.windows.editor.x86_64.exe
```

It first queries fog with no `feng-sky` runtime, then makes a mock provider available in the same process and verifies that fog discovers and consumes its world-matched radiance snapshot.

Run the lit-material tests (headless unit checks; optional real-renderer checks):

```sh
python misc/feng-addons/feng-fog/tests/run_lit_fog_tests.py --editor /path/to/godot --gpu-driver vulkan
python misc/feng-addons/feng-fog/tests/run_lit_fog_tests.py --editor /path/to/godot --physical-units false --gpu-driver vulkan
```

The rendered test uses a fixed 320×240 viewport and covers a 10,000× lighting
range, colored fog, deferred opaque/forward fallback/transparent surfaces,
pre-exposure on/off, direct-only fog, the independent directional lobe, and black
base albedo with the lobe disabled, white fog visibility at a horizontal sun
in three viewing directions, and an orange lobe independent of base color. PNGs
and source-value logs remain in the reported scratch project.
