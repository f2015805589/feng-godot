# Feng Sky

`FengSkyAtmosphere` is a `WorldEnvironment` component with a GPU-rendered,
spherical atmosphere with RGB Rayleigh and Mie transport, ozone absorption,
and an isotropic multiple-scattering approximation. New nodes use an Earth-like
preset. Its atmosphere shader produces scene-linear radiance and leaves camera
exposure and pre-exposure to the renderer.

The API and rendering roles target Unreal Engine 5.8 Sky Atmosphere semantics.
The numerical implementation is independent and informed by Sébastien Hillaire’s
[public atmosphere reference](https://github.com/sebh/UnrealEngineSkyAtmosphere).
It is not a copy of private UE 5.8 source, and no matching UE 5.8 render baseline
has been available to establish pixel parity. Preset values below are explicit
Feng defaults, not a claim that every value matches a verified UE 5.8 constructor.

FRP applies `Environment.background_intensity` to sky radiance, so the provider
sets that nits-valued multiplier to `1.0` only while the built-in atmosphere is
selected; it is otherwise a second exposure-scale multiplication on a source
already driven by the sun's authored irradiance. The prior custom or legacy
value is stored with the component and restored when the built-in atmosphere is
disabled or replaced. Use `Environment.background_energy_multiplier` for an
artistic sky gain; the same gain scales the atmosphere's fog ambient snapshot,
and the shader lowers its HDR output ceiling to keep the native-gained sky under
the RGBA16F limit. The fog snapshot also clamps its already averaged RGB value
to 60,000 as a range guard; under extreme gain or sun intensity this is not the
same as integrating the shader's per-ray radiance cap over the sky.

Add `FengSkyAtmosphere` to a scene and assign a visible `DirectionalLight3D` to
**Sun Light**, or leave the field empty to select the first compatible sun in
the same `World3D`. A light in **Sky Only** mode can drive the atmosphere;
**Light Only** lights are ignored. Sun direction, authored sRGB color, optional
physical temperature, and energy update the sky as the light changes. With
`rendering/lights_and_shadows/use_physical_light_units` enabled, the source uses
`light_intensity_lux * light_energy`; otherwise it uses `PI * light_energy`,
matching the FRP renderer's normalized directional-light scale. The latter is
not a lux measurement. Both modes use the same linear scattering equations.

## Parameters and transport

The default planet has a radius of 6360 km and a 60 km atmosphere. World units
are metres; the default planet center `(0, -6360000, 0)` places world origin at
sea level. **Transform Mode**, **Planet Origin**, and an optional **Planet
Transform** node support top-at-origin, top-at-component-position, and
center-at-component-position authoring. `WorldEnvironment` itself has no spatial
transform. The component converts author-facing controls into one normalized,
renderer-independent parameter dictionary.

- **Rayleigh Scattering** is RGB km⁻¹, multiplied by **Rayleigh Scattering Scale**.
  **Rayleigh Exponential Distribution** is its density e-folding height in km
- **Mie Scattering** and **Mie Absorption** are independent RGB km⁻¹ values with
  independent scales. Extinction is their nonnegative sum, never a grayscale
  substitute. **Mie Exponential Distribution** is the aerosol e-folding height
- **Mie Anisotropy** controls the normalized Cornette–Shanks phase function.
  Positive values produce a forward circumsolar lobe
- **Absorption** is RGB km⁻¹ with its own scale. The tent profile is exposed
  as **Tent / Tip Altitude**, **Tip Value**, and **Width**; two clamped linear
  layers implement it. The default density is zero at 10 km, one at 25 km, and
  zero again at 40 km. Default coefficients are `(0.000650, 0.001881, 0.000085)`
- **Multi Scattering Factor** scales second-and-higher-order illumination. Zero
  disables it. **Ground Albedo**, default linear `(0.4, 0.4, 0.4)`, contributes
  only through that illumination. It does not paint a visible ground disk
- **Sky Luminance Factor** changes sky scattering and its captured fog ambient.
  **Sky And Aerial Perspective Luminance Factor** also controls the surface
  aerial-perspective source. Neither changes extinction or the solar disk
- **Transmittance Min Light Elevation Angle** clamps only the direction used to
  evaluate direct-light transmittance. It does not move the visible sun or alter
  sky scattering. Its default `-90°` leaves the physical direction unchanged
- **Trace Sample Count Scale** controls the actual view-ray budget: eight
  segments at `1`, from two to 32 within its supported `0.25–4` range

The Earth preset uses Rayleigh `(0.005802, 0.013558, 0.0331)` with an 8 km scale
height, Mie scattering `(0.003996, 0.003996, 0.003996)`, Mie absorption
`(0.000444, 0.000444, 0.000444)`, a 1.2 km Mie scale height, anisotropy `0.8`,
and multiple-scattering factor `1`. The solar angular radius defaults to
`0.26785°`. An explicitly linked **Secondary Sun Light** supplies a second
independent directional source and disk. Its transport is evaluated only when
its irradiance is positive; it reuses both optical tables.

Each view segment integrates the direct source

`βR ρR PR(μ) + βM,scatter ρM PCS(μ, g)`

with transmittance

`T = exp(-∫(βR ρR + βM,extinction ρM + βabsorption ρabsorption) ds)`.

The multiple-scattering source adds `(βR ρR + βM,scatter ρM) Ψms`, where `Ψms`
is a cached isotropic incident-radiance field for unit solar irradiance. Its
builder integrates first-order isotropic atmosphere scattering and sunlight
reflected from the ground over the sphere, estimates the scattering feedback
`fms`, then evaluates `Ψms = L2 / (1 - fms)`. Analytical constant-medium segment
integration keeps the feedback bounded; a final per-channel `0.95` ceiling
prevents divergence in extreme nearly conservative authored atmospheres. This
is a lower-resolution Hillaire-style closure, not full directional path tracing.

The virtual planet occludes sunlight and view rays. No direct Lambertian ground
fill is drawn. Short atmosphere segments above the planet still scatter light,
and high-altitude/space rays can traverse the limb. Terrain or cloud shadowing,
atmospheric refraction, and a matching UE 5.8 sky-view LUT implementation are
not part of this transport model.

`feng_sky_parameters.gd` owns finite-input normalization; CPU and GPU consumers
receive the same units and nonnegative coefficients. Numerical guard ranges are
Feng implementation choices: radius 1–100000 km, atmosphere height 0.1–10000 km,
density scale heights 0.001–1000 km, coefficients 0–100 km⁻¹, anisotropy
`[-0.99, 0.99]`, and finite bounded artist gains. These guards are not claimed
Unreal UI limits. Old `planet_radius_km`, scale-height, and scalar Mie properties
remain loadable read/write aliases; newly saved scenes use the canonical fields.

Godot stores sky radiance in an RGBA16F cubemap, whose finite range ends at 65504.
To prevent solar-disk overflow and fireflies, the shader caps each disk and final
sky radiance at 60000, reduced before native sky gain is applied. The solar disk
therefore keeps its angle and atmospheric color/transmission but is not an
absolute physical luminance measurement.

The solar edge is evaluated using squared chord distance rather than two
cosines near one. This is the same angular profile, but keeps distinct edges at
the supported 0.01° minimum disk radius in float32; the old cosine edges could
round together at 0.01°–0.02° and make `smoothstep` undefined. Non-finite sun
energy or color disables the source, and invalid/zero directions fall back to
zenith before either CPU integration or GPU uniform publication. Finite sun
directions are scaled before normalization to avoid squared-length overflow.
These guards do not reduce valid sunlight or alter the fog lighting contract.

The component privately copies its Environment, Sky, material, and shader per
scene instance. Assigning a non-atmosphere `Sky` switches to that custom sky and
does not publish atmospheric fog lighting. Older scenes saved with
`PhysicalSkyMaterial`, panoramas, procedural skies, or custom sky shaders keep
their saved resource. Set **Atmosphere Enabled** to turn the model back on; the
component retains the custom sky so disabling it restores that selection.

Godot's normal first-`WorldEnvironment` rule still applies: only the first
provider for a `World3D` renders there. Multiple viewports sharing a world share
its sky, while separate worlds receive independent copies. `affect_height_fog`
controls only the optional main-thread snapshot for Feng Fog; disabling it
leaves sky rendering and sun updates active.

Feng Fog can soft-load
`res://addons/feng-sky/feng_sky_runtime.gd` and call
`FengSkyRuntime.snapshot_for_world(world_id)` on the main thread. The copied
snapshot is available only while this component is the active WorldEnvironment
provider, its atmosphere model is enabled, and `affect_height_fog` is true. It
contains `world_id`, `provider_id`, `sun_light_id`, `sun_direction`,
`sun_ground_illuminance`, `sun_irradiance_unit`, `ambient_radiance`, and
`height_fog_contribution`. `ambient_radiance` is a linear RGB isotropic source
defined as `(1/(4π)) * ∫ L_sky(ω) dω`; the integration samples the upper sky and
treats the lower hemisphere as an occluder. Ground bounce contributes to the
upper sky through multiple scattering. It includes both enabled light sources
and authored sky-scattering gains, not exposure or pre-exposure.
`sun_ground_illuminance` is RGB lux when physical light units are enabled and
FRP-normalized irradiance otherwise. The independent rendering snapshot remains available when **Affect Height Fog**
is disabled. It carries normalized optics, both light sources, optical textures,
and render-target identity for FRP aerial perspective and atmosphere-aware
surface lighting. The fog ambient snapshot remains separately gated by
**Affect Height Fog**. See `doc/frp-unreal-atmosphere.md` for the renderer mapping
and integration limits.

Ambient integration is cached per two-degree sun-zenith bins and linearly
interpolated. Sun color and intensity scale the cached unit-source result;
sun azimuth does not invalidate it. Atmosphere parameter changes clear the
cache. Each cache miss evaluates 64 importance-sampled directions, including
samples drawn from a Henyey–Greenstein proposal distribution to cover the
Cornette–Shanks forward peak, with the correct proposal-density weights. The
bounded cost is observable through
`FengSkyAtmosphere.atmosphere_cache_stats()`.

## Atmosphere performance

`feng_sky_runtime.gd` owns world publication and compatibility entry points;
`feng_sky_transport.gd` owns pure CPU transport. `feng_sky_optical_lut.gd` and
`feng_sky_multiscattering_lut.gd` build light-independent tables. Neither table
contains sun color, intensity, exposure, or pre-exposure.

The optical table stores Rayleigh, Mie and absorption density columns in
kilometres. The shader multiplies these by the current RGB extinction
coefficients and evaluates Beer–Lambert transmission. Planet shadow remains an
analytic ray/sphere test, so filtering cannot bleed daylight through the planet.
Factored radial differences avoid subtracting large nearly equal squared radii;
an outward zero-length ray exactly on the atmosphere boundary transmits vacuum.

The 128 × 64 `RGBF` table takes 96 KiB. Its coordinates are
`rho / sqrt(top_radius² - planet_radius²)`, where
`rho = sqrt((r - planet_radius) * (r + planet_radius))`, and normalized
distance-to-atmosphere-exit. A quadratic distance warp concentrates samples near
grazing paths, and texel-center mapping preserves the domain endpoints. Six
nonuniform midpoint samples build each density column. Very thin exponential
or absorption profiles fall back to the same direct six-step calculation rather
than using a table that cannot resolve them. This is a bounded numerical
approximation, especially for extremely thin authored profiles.

The 16 × 16 `RGBF` multiple-scattering table takes 3 KiB. It integrates 16
uniform-solid-angle directions and 12 nonuniform path segments per texel, with
six sun-path samples. Altitude uses a squared mapping; signed-square solar
cosine mapping concentrates texels around twilight. Runtime lookups use the
inverse mappings and texel centers. The field is computed per unit solar source,
so moving either light only changes lookup coordinates. This table is not a
screen-space history and does not add a frame of temporal lag.

Only geometry and density-profile changes rebuild optical columns. Changing
RGB coefficients or ground albedo rebuilds the multiple-scattering table but not
the optical columns. Changing multiple-scattering strength, sky artist gains,
view quality, light direction/color/intensity, world position or exposure
rebuilds neither table. Each provider owns its image and texture; the bounded
shared CPU byte caches avoid repeating identical builds. Providers retain their
CPU multiple-scattering image so sun-bin cache misses cannot trigger rebuilds
when other worlds evict shared cache entries. Property edits within one update
are coalesced. These builds can cause a one-time main-thread cost when an
atmosphere profile changes; they are not performed every frame.

On a Linux headless run, the new optical table built in roughly 30–47 ms and the
multiple-scattering table in roughly 0.4–0.8 s, with exact-signature reuse taking
only image creation/copy-on-write overhead. These are startup/profile-edit CPU
measurements, not GPU timings. The 520 default-profile optical comparisons had
maximum absolute RGB transmission error `0.00302` against direct transport.

`tests/test_unreal_transport.gd` also compares the multiple-scattering field
against an independent 64-direction, 64-view-step, 32-sun-step implementation of
the same isotropic closure at three altitudes and five solar elevations,
including twilight. With the horizon-concentrated mapping, measured normalized
RMS error was `2.81%`, maximum absolute unit-source radiance error `0.00203`.
Relative error can be large in very dark twilight samples; this does not establish
UE image parity, path-tracing accuracy, or target-device performance.

Exported setters invalidate sanitized settings; shader `changed` notifications
invalidate cached source identity. Static and light-dependent material updates
are separate, and unchanged snapshots are not republished. World ownership and
resource identity are checked every frame and at main-thread snapshot reads.
Render-thread readers consume immutable arrays exchanged under a mutex, never
scene-tree nodes. `atmosphere_cache_stats()` exposes rebuild and update counters.

## Example

Open and run `res://addons/feng-sky/examples/feng_sky_atmosphere_60k.tscn` in a
project with Feng Sky, Feng Fog, and Feng Render Pipeline installed. Select the
FRP rendering method before starting the project. The scene contains a 60,000
lux sun, the built-in atmosphere and height fog, a camera, and simple near and
far geometry. Its scene script attaches a camera-local FRP pipeline with Eye
Adaptation enabled, extended luminance range, and pre-exposure enabled; Magic GI
is disabled to keep the sample focused on atmosphere and fog.

For the sun to use its authored 60,000 lux value, enable **Rendering → Lights
and Shadows → Use Physical Light Units** in Project Settings and restart the
project. This is a startup renderer setting; the scene warns when it is off.
The sample does not change project-wide renderer settings or pipeline selection.

## Tests

With a built editor available, run:

```powershell
python misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py --editor F:/path/to/godot.windows.editor.x86_64.exe
```

The test starts a temporary headless project and checks default and replaceable
skies, per-world environment selection, isolation of shared resources, and
handoff to an existing WorldEnvironment.

`tests/test_sky_numerics.gd` checks finite source inputs and reproduces the old
float32 disk-edge collapse. With `-- --gpu`, it dispatches the production sky
shader's math as compute work and reads float32 values before tone mapping or
RGBA16F storage. The 8,192 ray cases cover sun and camera motion, horizon and
space views, tiny/large solar disks, zero/60,000/10,000,000 irradiance, phase
extrema, zero/dense extinction, and both lookup/direct sun paths. It checks disk
profile agreement, finite unclamped scattering, and transmission/radiance ranges.
The Python runner includes the CPU checks and adds this GPU probe when
`--gpu-driver` is provided. A RenderingDevice-capable display/driver is required
for GPU checks; Godot's headless dummy renderer is not a GPU test.

`tests/test_sky_motion_gpu.gd` exercises the complete default 13-enabled-pass FRP
schedule while both the camera and sun move. An isolated 129 × 129 viewport
tracks the solar disk across the image at 60,000 and 10,000,000 irradiance, with
0.01°/default disk radii and pre-exposure/TAA combinations. It reads a 5 × 5
sun-centered region every fourth moving frame (36 captures across 12 cases),
checks for non-finite values/blackouts and invalid exposure, and saves one image
per case. Eight cases keep all 13 passes enabled; four isolated control cases
disable only the local native TAA entry (12 enabled passes). Exposure buffers
are read from the active effect on the render thread. The full test runner
includes this after the existing fog/sky GPU probe.

`tests/test_unreal_transport.gd` checks the absorption tent, normalized phase
function, analytic spectral Mie transmission, RGB optical-table accuracy,
multiple-scattering reference error, ground-albedo monotonicity, zero-medium
behavior, finite high-extinction profiles, cache/image isolation, artist gains,
minimum light elevation and actual trace quality budgets. These checks are
separate from real GPU rendering and the UE 5.8 visual comparison still needed.

Secondary atmospheric light index 1 contributes single scattering and its disk;
multiple scattering is evaluated only for index 0, matching the UE 5.8 documented
secondary-light limitation. CPU fog ambient uses the same slot rule.
