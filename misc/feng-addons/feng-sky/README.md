# Feng Sky

`FengSkyAtmosphere` is a `WorldEnvironment` component with a spherical atmosphere:
RGB Rayleigh and Mie scattering, ozone absorption, and an isotropic
multiple-scattering approximation. New nodes use an Earth-like preset. The shader
produces scene-linear radiance; the renderer handles exposure and pre-exposure.

The authoring API targets Unreal Engine 5.8 Sky Atmosphere semantics. The numerical
implementation follows Sébastien Hillaire’s
[public atmosphere reference](https://github.com/sebh/UnrealEngineSkyAtmosphere).
It has its own presets and numerical limits; UE pixel parity is unverified.

## Setup and lighting

Add `FengSkyAtmosphere` and assign **Sun Light**, or leave it empty to select the
first visible, sky-compatible `DirectionalLight3D` in the same `World3D`.
**Sky Only** lights qualify; **Light Only** lights do not. Direction, sRGB color
and energy update live. Physical-light mode also applies color temperature and
uses `light_intensity_lux * light_energy`; nonphysical mode uses `PI * light_energy`,
matching FRP’s normalized directional-light scale.

**Secondary Sun Light** explicitly selects a second source. Both lights contribute
single scattering and a solar disk; only the primary contributes multiple
scattering. This slot rule also applies to the fog ambient calculation.
**Sun Source Angle** is the full disk diameter, default `0.5357°`; zero disables
the disk. Each slot has an independent disk color scale.

While the built-in atmosphere is selected, the component sets
`Environment.background_intensity` to `1.0` because its radiance already includes
solar irradiance. The saved custom/legacy value is restored when the atmosphere
is disabled or replaced. Use `background_energy_multiplier` for artistic sky
gain; it also scales the atmosphere’s fog ambient.

The component privately copies its Environment, Sky, material and shader per
scene instance. Assigning a custom Sky selects it and stops atmosphere
publication. **Atmosphere Enabled** switches back to the built-in model; disabling
it restores the custom selection. Existing physical, procedural, panorama and
custom shader skies retain their saved resources.

Godot’s first-`WorldEnvironment` rule selects the active provider in each world.
Viewports sharing a world share its sky; separate worlds have independent copies.

## Parameters

World units are metres; transport uses kilometres. The default planet radius is
6360 km with a 60 km atmosphere. Its center `(0, -6360000, 0)` puts world origin
at sea level. **Transform Mode**, **Planet Origin**, and optional **Planet Transform**
support top-at-origin, top-at-component and center-at-component positioning.
`WorldEnvironment` itself has no spatial transform.

- Rayleigh, Mie scattering, Mie absorption and other absorption each expose a
  coefficient scale and RGB color. The product is in km⁻¹. Mie extinction is
  scattering plus absorption, per channel
- **Rayleigh/Mie Exponential Distribution** is the density e-folding height in km
- **Mie Anisotropy** controls the normalized Henyey–Greenstein phase function;
  larger values concentrate scattering toward the sun
- The absorption **Tent** controls tip altitude, tip value and width. Defaults
  give zero density at 10 km, one at 25 km and zero again at 40 km
- **Multi Scattering Factor** scales second-and-higher-order illumination; zero
  disables it. **Ground Albedo**, default linear `(0.4, 0.4, 0.4)`, contributes
  through this illumination. The virtual ground occludes rays without drawing
  a visible Lambertian ground disk
- **Sky Luminance Factor** scales sky scattering and fog ambient.
  **Sky And Aerial Perspective Luminance Factor** additionally scales the surface
  aerial-perspective source. These gains leave extinction and the solar disk unchanged
- **Aerial Perspective Distance Scale** changes the aerial path length;
  **Aerial Perspective Start Depth**, default `0.1` km, controls its near fade
- **Transmittance Min Light Elevation Angle** clamps the direction used for
  direct-light transmittance. Default `-90°` leaves it unchanged; the visible sun
  and sky-scattering direction always follow the light
- **Trace Sample Count Scale** gives eight view segments at `1`, from two to 64
  across the supported `0.25–8` range

The Earth preset uses Rayleigh `(0.005802, 0.013558, 0.0331)` with an 8 km scale
height, Mie scattering `(0.003996, 0.003996, 0.003996)`, Mie absorption
`(0.000444, 0.000444, 0.000444)`, a 1.2 km Mie scale height, anisotropy `0.8`,
absorption `(0.000650, 0.001881, 0.000085)`, and multiple-scattering factor `1`.

`feng_sky_parameters.gd` normalizes author inputs for CPU and GPU consumers.
Finite bounds include radius 1–100000 km, atmosphere height 0.1–10000 km,
density scale heights 0.001–1000 km, coefficients 0–100 km⁻¹ and anisotropy
`0–0.999`. Invalid source energy/color disables that source; invalid or zero
directions use zenith. Legacy scalar Mie, radius and scale-height aliases remain
read/write compatible. Legacy disk-radius fields retain their radius semantics;
the current inspector uses diameter.

Sky cubemaps use RGBA16F. The shader caps disk and sky radiance at 60000, lowering
the pre-gain ceiling when necessary to stay finite after native sky gain. Thus
the disk preserves its angle and transmission but has bounded luminance.
Squared chord distance keeps very small disk edges distinct in float32. Fog
ambient is capped after angular integration, so extreme-gain clipping can differ
from the sky’s per-ray cap.

## Transport and caches

Each view segment integrates Rayleigh and HG-weighted Mie sources with
Beer–Lambert RGB extinction from Rayleigh, Mie and absorption. Multiple scattering
adds an isotropic incident field `Ψms = L2 / (1 - fms)`, built from atmospheric
scattering and ground-reflected sunlight. Analytical segment integration and a
per-channel feedback ceiling of `0.95` keep nearly conservative profiles finite.
Terrain/cloud shadows and refraction are outside this model.

- The 128 × 64 RGBF optical table stores density columns (96 KiB). Six nonuniform
  samples integrate each column. Horizon-focused distance mapping and texel-center
  lookup preserve grazing paths and endpoints. Very thin profiles use direct
  six-step transport when the table cannot resolve them
- The 16 × 16 RGBF multiple-scattering table (3 KiB) uses 16 solid-angle directions,
  12 path segments and six sun samples per texel. Squared altitude and signed-square
  solar-cosine mappings concentrate resolution near the ground and twilight
- Optical columns rebuild for geometry/density changes. RGB coefficients and
  ground albedo additionally affect the multiple-scattering table. Light motion,
  color/intensity, artist gains, exposure and view quality rebuild neither table
- Each provider owns its image and texture. Bounded shared byte caches reuse
  identical builds; providers retain their CPU multiple-scattering image. Builds
  run on the main thread when the profile changes
- Fog ambient uses 64 importance-sampled directions on cache misses, cached in
  two-degree sun-zenith bins and interpolated. Color/intensity scale the unit-source
  result; azimuth does not invalidate it

Exported setters invalidate settings; shader changes invalidate source identity.
Material and snapshot publication skip unchanged values. World/resource ownership
is checked each frame and on main-thread snapshot reads. Render-thread readers
consume immutable arrays exchanged under a mutex. `atmosphere_cache_stats()`
exposes sanitization, rebuild, integration and publication counters.

## Runtime integration

`FengSkyRuntime.snapshot_for_world(world_id)` returns a copied fog snapshot on the
main thread while the provider is active, the atmosphere is enabled, and
**Affect Height Fog** is true. It contains `world_id`, `provider_id`, `sun_light_id`,
`sun_direction`, `sun_ground_illuminance`, `sun_irradiance_unit`, `ambient_radiance`
and `height_fog_contribution`.

`ambient_radiance` is linear RGB `(1/(4π)) * ∫ L_sky(ω) dω`, including both sources
and sky-scattering gains. The integration samples the upper sky and treats the
lower hemisphere as an occluder; ground bounce reaches the upper sky through
multiple scattering. `sun_ground_illuminance` is RGB lux in physical mode and
FRP-normalized irradiance otherwise. Neither field includes exposure.

The separate rendering snapshot carries normalized optics, both sources and
their ground transmittance, matching optical textures, revision identity and
render targets for FRP aerial perspective, surface lighting and cloud consumers.
It remains available when **Affect Height Fog** is off. The component's main-thread
`rendering_snapshot(world)` provides the same source schema for an explicitly
selected same-world atmosphere, even when it does not own the visible Environment.
Returned value data is copied; private LUTs are leased only while their settings match.
Feng Fog soft-loads the runtime from `res://addons/feng-sky/feng_sky_runtime.gd`.
See [`doc/frp-unreal-atmosphere.md`](../../../doc/frp-unreal-atmosphere.md) for the
renderer mapping and integration limits.

## FengSkyLight global radiance

Add `FengSkyLight` as a `Node3D` in the target world. It is independent of the
visible `WorldEnvironment`: the captured scene can use the current World3D sky
as its background, or **Capture Sky** can select another `Sky` resource. An
empty **Capture Sky** uses the active world's sky. The component never replaces
the displayed sky or edits the shared Environment.

**Source Mode** selects **Captured Scene**, **Specified Cubemap**, or
**Specified Sky**. A captured scene includes direct-lit and emissive geometry
within **Capture Distance**; **Capture Sky** supplies the background for rays
that miss scene geometry. The capture also applies the active Feng Height Fog
snapshot. **Specified Cubemap** uses the supplied HDR cubemap as the radiance
source. **Specified Sky** renders only the selected `Sky` resource, with no
scene geometry or capture fog. The private scene-capture Environment disables
ambient and reflection sources so it does not fold in previous global IBL or
MagicGI output. It captures scene radiance, not post-GI output. **Capture
Position Anchor** and the world-space **Capture Offset** set the capture origin.
Without an anchor, the component's global position is used. The default offset
is `(0, 100, 0)` metres. Captured faces use world axes, so rotating the component
does not rotate a scene capture. A supplied Cubemap follows the component's
rotation. A captured cube is a global far-field approximation; it does not
provide parallax or position-accurate GI for nearby buildings.

**Realtime Capture** is on by default. **Capture Interval** schedules periodic
refreshes; the renderer captures faces over multiple frames, so the interval is
not a promise that a whole six-face update completes in one frame. Requests that
arrive during a capture coalesce into at most one follow-up, which starts after
the current capture completes; they do not cancel its faces. A completed capture
remains available while its replacement is being built. With **Realtime Capture**
off, the initial result stays fixed until **Capture Now** or **Bake Now** is
pressed. Assign a valid **Bake Data** resource to load saved radiance in this
mode. Use **Bake Path** and **Bake Now** to save a reusable `.res` or `.tres`
resource; the bake stores world-linear HDR radiance and capture metadata, not
camera exposure or **Radiance Energy**. Changes to position, source, or capture
settings do not replace a fixed result until an explicit capture or bake request.

The capture probe is internal and capture-only: it does not add a local reflection
probe or capture its own previous SkyLight output. **Capture Shadows** is on by
default; turning it off can reduce the cost of repeated full-scene captures.
**Capture Resolution** is rounded to the nearest supported power of two from 32
to 2048 pixels; the default is 128. **Capture Distance** defaults to 4000 metres
and limits scene geometry visible to the six capture faces. The output Sky's
filtering resolution follows this value for scene captures; a specified Cubemap
uses its width normalized to the same supported range. **Cull Mask** selects
which render layers enter the capture. Use a smaller distance, lower resolution,
or disabled capture shadows when frequent full-scene updates are too costly.

Only one provider is active in a `World3D`: higher **Priority** wins and the
earlier registered provider wins ties. Disabling or removing it hands off to the
next candidate. The same completed radiance feeds FRP's world IBL/ambient path
and `FengMagicGI`'s sky SH term; MagicGI keeps its existing directional-light
transport contribution. **Radiance Energy** is applied once to both consumers.
MagicGI reads the provider's cached SH projection instead of baking another
panorama for each volume. Without a ready FengSkyLight, MagicGI uses zero sky SH;
its directional-light and baked-emitter contributions remain available.

Captured radiance uses the Environment exposure recorded for the capture.
`FengSkyLight` keeps its capture Environment private and refreshes it for each
manual or scheduled capture, so Environment property changes are included even
when that resource does not emit `changed`.

## Example and tests

Run `res://addons/feng-sky/examples/feng_sky_atmosphere_60k.tscn` with Feng Sky,
Feng Fog and Feng Render Pipeline installed and FRP selected. It includes a
60,000 lux sun, atmosphere, height fog, near/far geometry and a camera-local
pipeline with extended-range Eye Adaptation and pre-exposure. Enable
**Rendering → Lights and Shadows → Use Physical Light Units** and restart to use
its authored lux value. The example leaves project-wide settings unchanged.

```sh
python misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py --editor /path/to/godot
python misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py --editor /path/to/godot --physical-units false
```

Headless checks cover resource isolation, custom/legacy sky selection, world
handoff, input normalization, disk numerics, transport/reference accuracy, cache
invalidation and aerial packet publication. The transport suite uses an
independent high-sample isotropic-closure reference.

Add `--gpu-driver vulkan` (or a supported driver) for shader-compute, rendered
fog/sky, aerial-perspective and moving-camera/sun checks. The numerical probe
reads float32 values before tone mapping/RGBA16F storage. Motion tests exercise
FRP, tiny/default disks, 60,000/10,000,000 irradiance and pre-exposure/TAA
combinations. GPU checks require a RenderingDevice-capable display/driver;
headless dummy rendering covers CPU contracts only. Logs and captured images
remain in the reported scratch project.

`res://addons/feng-sky/examples/feng_sky_light_capture.tscn` wraps the atmosphere
scene with a `FengSkyLight` using the full-scene source and realtime capture.
Use its **Capture Now** button for a one-off refresh or **Bake Now** to save
reusable world-linear HDR radiance.
