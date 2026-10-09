# Feng Fog

`FengHeightFog` implements the supported part of Unreal Engine 5.8's
exponential height fog. It has two density layers, height falloff and offsets,
maximum opacity, start distance, sky cutoff distance, and directional
inscattering. The fullscreen path fogs opaque geometry and the sky; forward-only
opaque and transparent materials evaluate fog at their fragment position.

## Source and light contract

`fog_inscattering_color` is the authored Fog Inscattering Color. Its default is
black; RGB is scene-linear radiance and supplies an independent base source.
Black sources still attenuate the scene.

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
A layer falloff of `0` is valid and makes that layer's density independent of
height.
Sky ambient is a sampled mean from Feng Sky rather than Unreal's
distant-sky-light LUT, so the results are not promised to be pixel-identical.

## Volumetric fog component contract

Fog and FSSS compute programs are plain runtime-compiled sources with the
`.glslinc` suffix. Their services read them with `FileAccess` and compile them
through the RenderingDevice; they are not Godot `ShaderFile` resources and are
not referenced by scenes. This keeps these compute sources out of the automatic
shader-resource import path.

The same `FengHeightFog` node exposes UE 5.8's volumetric-fog controls under a
separate inspector group. Volumetric fog is disabled by default. Its
`snapshot_fields()` result carries a distinct `volumetric_fog` dictionary;
the existing height-fog density and falloff remain the medium source. Distances
are authored in meters: the default 60 m view distance corresponds to UE's
6000 cm, and view distance is the extent after the separate start distance.
The renderer derives its far limit from `start_distance + distance`.

The height-fog `Albedo` is authored as sRGB Color and decoded to linear RGB to
match UE's `FColor` conversion. Its `Emissive` is authored linear; its UE
per-centimeter coefficient is converted to a per-meter coefficient in the
packet. Extinction, scattering distribution, and distance values receive
finite/nonnegative safety checks when packed. UI ranges are author guidance;
the helper retains wider finite values where the UE renderer accepts them.

UE's optional experimental 2D FSSS controls are published separately under
`screen_space_scattering`, with UE defaults (disabled, scale 1, power 1, spread
0.1, blur 0.5). They stay separate from the 3D volume parameters.

The FRP addon now consumes the separate 3D packet through an addon-owned
froxel renderer and publishes an integrated volume texture for opaque, cloud,
and transparent composition. `FengVolumetricFogVolume` contributes local
declared media independently of `WorldEnvironment`. Each local-medium dispatch
handles up to 16 records; larger sets are split into ordered GPU batches and
accumulated into the same medium textures. This is an addon compute path and
does not modify Godot's generic Fog renderer.

The renderer keeps one tiled 2D conservative-depth map per frame. It scans the
current resolved depth over each froxel screen tile expanded by half a tile on
each edge and stores the minimum reverse-Z depth. This matches the conservative
depth comparison and neighborhood repair used by UE's volumetric history path;
it avoids requiring a separate HZB, at the cost of scanning the expanded pixel
footprint. Current depth constraints still read the frame's jittered depth
directly. When the current GBuffer depth is unavailable, occlusion rejection is
disabled and history uses the projected in-bounds sample without a depth fixup.

Local declared fog volumes use linear albedo clamped to `[0, 1]`, matching UE's
UNorm albedo payload; their independent emissive source remains linear HDR and
is not multiplied by density. These rules are separate from the height-fog
component's sRGB albedo conversion above.

The addon also provides an opt-in LightmapGI capture-probe adapter. In the
`FFogBakedLightingVolume` Inspector, assign `source_lightmap_gi_data`, set its
`source_capture_transform`, and run **Import / Refresh LightmapGI Probes**.
These are staged inputs: a failed import keeps the last active payload. The
`capture_lightmap_gi_node(lightmap_gi)` helper reads that node's `light_data`
and `global_transform` without searching the scene. Probe positions and bounds
are capture-local and the transform maps them to world space. These captured
probes contain indirect surface radiance and may contain environment radiance,
but they are not Unreal volumetric lightmaps, do not contain direct illumination
evaluated at the probe origin, and do not suppress live direct lights. Ordinary
surface lightmaps are not treated as volumetric-lightmap data. Runtime lighting
uses UE's two-band L0/L1 HG path; the adapter also exposes a generic SH9 helper
that retains L2, which is not the UE default path. UE VLM brick layout,
BentNormal handling, and native volume-lightmap import are not implemented by
this LightmapGI probe adapter, so matching its two-band evaluation does not mean
the underlying baked representation is byte- or feature-equivalent.

UE-style volumetric lightmap bricks use a separate, mutually exclusive resource
in the same `baked_irradiance` slot. `FFogVolumetricLightmap` imports an
offline-decoded payload from JSON or a binary Godot Variant dictionary; it does
not parse Unreal `.uasset` files. Its Set 5 provider uploads the indirection,
ambient, SH, SkyBentNormal, and directional-shadow volumes, then the light
shader evaluates UE's SH2 HG path. The optional `static_directional_light_key`
must exactly match the selected same-frame `FFogLightExtension` key before the
payload can suppress that Sun or apply its directional shadow. A matching
static-direct Sun remains suppressed when static scattering intensity is zero;
the baked static contribution is then zero instead of being reclassified as a
movable source. Missing or mismatched keys keep the live Sun and use neutral
shadow. The tetrahedral LightmapGI probe adapter and UE-brick source are never
added together. A fixed D3D12 fixture has exercised the main Set 5 consumer
through `FengHeightFog`: 16 numeric paths and the disabled-resource cleanup
case passed. This verifies that fixture and its decoded payload, not every
imported asset or full UE parity. The tetrahedral LightmapGI probe adapter has
not had an end-to-end GPU run; its headless storage roundtrip is skipped.

Rect area lights use the renderer area-source atlas and an addon area-light
integral. A fixed D3D12 advanced-light fixture completed 20 finite captures.
Its Spot half-angle case used a 45-degree authored angle, a 35.60-degree
receiver direction, and `tan_half_spot_angle = 1`; the corrected cookie UV was
inside the projection, unlike the old half-angle UV. The measured gray-cookie
response was approximately 0.498 of the no-cookie response. This bounded
fixture used the complete raster shadow fallback because that D3D12 device did
not expose the required ray-tracing pipeline and device-address features; it
does not validate hardware RT.

FSSS is a separate 2D GPU path with source-energy separation, temporal history,
and mip filtering. It remains opt-in and is not part of the 3D medium packet.

## UE 5.8 volumetric-fog status

| Path | Addon state | Current verification |
| --- | --- | --- |
| Component defaults, units, and quality profiles | Volume and FSSS default off; Medium/High/Cinematic profiles are exposed | CPU contracts; no pixel-identity claim |
| Height medium, log-Z froxels, lighting, exposure, and integration | Implemented in the FRP addon alongside the analytic height-fog pass | Fixed D3D12 core fixture passed with natural exit 0 and empty stderr; fixture-level verification only |
| Local box, ellipsoid, cylinder, cone, world media, and density textures | Implemented with ordered 16-volume batches and linear albedo clamping | Core fixture exercised 17 media in two batches (16 + 1), including an independent emissive marker at zero density; output was finite |
| Conservative current depth | Per-tile conservative depth and current-depth rejection | Core fixture covered fully occluded, moved-occluder/disocclusion, and zero-depth sky cases with finite output |
| Screen-space FSSS | Independent opt-in 2D path with separated source energy and mip filtering | Core fixture read an unsaturated HDR source (max 3.0) and the zero-fog W=0 no-write case |
| Rect, Spot, and other advanced light extensions | Rect irradiance, optional source atlas, barn doors, Spot mapping, cookies, and capsule extensions are implemented | Fixed D3D12 fixture completed 20 finite captures; the Spot half-angle/cookie case passed with the corrected 45-degree mapping. This run used raster fallback for shadows; it is not hardware RT evidence |
| Sky SH and baked GI | Explicit FengSky source, tetrahedral LightmapGI probes, and a separate UE-style VLM brick Set 5 consumer are implemented | VLM main consumer passed 16 numeric paths plus disabled cleanup on a fixed D3D12 fixture; tetrahedral LightmapGI GPU path remains unverified |
| Hardware ray-traced shadows | Optional Vulkan provider; requires ray-tracing-pipeline and buffer-device-address support, a complete supported caster snapshot, and per-batch capacity. Unsupported devices/casters, invalid inputs, or overflow select complete raster fallback | Standalone Vulkan provider fixture passed all 13 binary-visibility cases. A separate real FRP Vulkan end-to-end fixture passed 3 cases: blocked sun (0), moved caster (1), and full-mask mismatch (1). These fixtures are bounded; the provider caps a batch at 128 MiB and 1<<24 rays |
| Cloud and transparent composition | Shared integrated volume sampling and delayed composition | Core D3D12 fixture used a real cloud sidecar plus transparent/refraction content; sidecar radiance/transmittance were non-neutral and reported closure error 1.1162 |

The core D3D12 result used the fixed source snapshot `67C57…` in
`C:\Temp\feng-volume-core-cloud-visible-fixture-20261009-01\project`; its run
record is under `evidence\gpu_cloud_visible_20261009_01`; stdout SHA-256 is
`DA27DDB7F5401C46B6D85D967D187F70CCCFEB43556CA3C36C4EE4C212F02D18`, with
empty stderr. The VLM consumer run used source manifest
`354daf180bf88c9929cdca4c425cd4cdd8d9d5306a8b182e4202051c76edd16d`.

The standalone RT run record is
`C:\Temp\feng-rt-anyhit-13case-20261009-01\evidence\gpu_13case_20261009T032512Z\run.json`;
all 13 expected binary visibility values passed with natural exit 0. Its log
contains non-fatal SPIR-V unsupported-operation notices, so stderr is not
empty. The real FRP RT end-to-end record is
`C:\Temp\feng-volumetric-rt-e2e-observer-schema-20261009-01\evidence\gpu_e2e_observer_schema_corrected_wrapper_20261009T034734Z\run.json`;
it passed 3 cases with natural exit 0: blocked sun, moved caster, and full-mask
mismatch. The injected volume RGB was zero for the blocked case and
`(238.625,224.75,236.75)` for the clear and mask-mismatch cases. The E2E run
also emitted non-fatal SPIR-V unsupported-operation notices.

These bounded fixtures do not establish pixel-identical UE output or universal
scene coverage. Hardware RT is used only when the active device has both
ray-tracing-pipeline and buffer-device-address support and the active caster
snapshot is fully supported. Unsupported devices/casters, invalid inputs, or
overflow use complete raster fallback; batches are limited to 128 MiB and
1<<24 rays. The 20-capture Spot fixture described above used D3D12 raster
fallback, not hardware RT. The LightmapGI probe adapter does not reproduce UE's
native volumetric-lightmap bricks; the decoded-brick importer supports
UE-style runtime sampling but does not read `.uasset` files or run a
Lightmass/VLM bake. The LightmapGI probe GPU path remains unverified. Stereo
currently has 7 CPU checks only, with no XR hardware run. The fixed-fixture
results above do not by themselves verify another merged build or project
test1/test2.

Other unsupported height-fog features are fog cubemaps, nonzero EndDistance,
SkyLight-capture contribution and dual-sun lobes.

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
and low-sun atmosphere ground illuminance. Logs and PNGs stay in the reported
scratch project.
