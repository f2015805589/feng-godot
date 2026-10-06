# Feng Fog

`FengHeightFog` implements the supported part of Unreal Engine 5.8's
exponential height fog. It has two density layers, height falloff and offsets,
maximum opacity, start distance, sky cutoff distance, and directional
inscattering. The fullscreen path fogs opaque geometry and the sky; forward-only
opaque and transparent materials evaluate fog at their fragment position.

## Source and light contract

`fog_inscattering_color` is the authored Fog Inscattering Color. Its default is
black; entered RGB is used as scene-linear radiance without sRGB conversion,
clamping, albedo interpretation, or multiplication by sunlight. It remains a
separate base source when atmosphere lighting is disabled. Fog still attenuates
the scene when every source is black.

The runtime combines independent sources:

- Authored source: `fog_inscattering_color` unchanged.
- Sky ambient: the active Feng Sky atmosphere's sampled mean radiance multiplied
  by `height_fog_contribution` and `sky_atmosphere_ambient_contribution_color_scale`.
- Physical atmosphere sun: for the same World's visible primary sun selected by
  Feng Sky, post-transmittance `sun_ground_illuminance` multiplied by
  `height_fog_contribution`. It enters the directional phase, not the isotropic
  base source.
- Artist directional lobe: `directional_inscattering_color` multiplied by the
  raw selected scene light RGB luminance, then evaluated by the same directional
  phase. It stays independent of the physical atmosphere term and base source.

`Affect Height Fog` and a zero `height_fog_contribution` remove the atmosphere
ambient and physical sun terms. They leave the authored source and artist lobe
active. The active atmosphere's primary sun is preferred when it is visible in
the same World; otherwise a cached search selects a visible scene directional
light. The Fog component has no separate sun picker. The artist term uses the
selected light's scene-linear RGB and the existing Godot light-unit conversion;
the atmosphere term uses the atmosphere's already attenuated ground
illuminance. The pass applies pre-exposure once to the combined source.

Density and falloff use Unreal-authored units scaled by `0.1` for the meter
world (Unreal divides by `1000` in centimeters). Perspective observers are
capped at 655.36 m above the lowest active fog-layer height, matching Unreal's
default ray-origin guard. Orthographic cameras retain their actual height;
Unreal's separate ViewTarget-distance adjustment has no direct Godot equivalent.
Sky ambient is a sampled mean from Feng Sky rather than Unreal's
distant-sky-light LUT, so the results are not promised to be pixel-identical.

This component does not implement Unreal's fog cubemap/texture, volumetric fog,
multiple-scattering controls, nonzero optional EndDistance, SkyLight-capture
contribution to height fog, or dual-sun directional fog lobes. This documents the
supported subset, not full Unreal feature parity.

## Lifecycle and tests

Each runtime/editor plugin owns its world/render-target registrations. Disabling
Fog or Magic GI leaves the other addon's views registered. Fog enables viewport
debanding while active and restores the original value when its use ends.

Run ownership/lighting contracts and the optional Sky late-load check:

```sh
python misc/scripts/test_feng_runtime_contracts.py --editor /path/to/godot
python misc/feng-addons/feng-fog/tests/run_late_sky_runtime_load.py --editor /path/to/godot
```

The late-load check starts without Feng Sky, then loads a mock provider in the
same process and verifies discovery and world-matched radiance.

Run the CPU contracts with either light-unit setting:

```sh
python misc/feng-addons/feng-fog/tests/run_height_fog_tests.py --editor /path/to/godot
python misc/feng-addons/feng-fog/tests/run_height_fog_tests.py --editor /path/to/godot --physical-units false
```

The CPU test covers raw authored RGB, atmosphere ambient and ground-sun routing,
primary-sun precedence and world checks, `Affect Height Fog`, zero contribution,
scene-light fallback, signed artist light, and finite-value guards. Add
`--gpu-driver vulkan` (or another supported driver) for rendered checks. The
fixed-exposure GPU test checks authored-source independence from direct light,
black-source transmission, pre-exposure, deferred/unshaded/transparent paths,
and the low-sun atmosphere ground-illuminance case. It does not use auto
exposure to conceal changes in source units. Logs and PNGs stay in the reported
scratch project.
