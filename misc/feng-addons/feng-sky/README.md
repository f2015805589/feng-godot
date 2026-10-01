# Feng Sky

`FengSkyAtmosphere` is a `WorldEnvironment` component with a GPU-rendered,
spherical, Earth-like single-scattering atmosphere. New nodes use this model by
default. Its atmosphere shader produces scene-linear radiance and leaves camera
exposure and pre-exposure to the renderer.

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

The default planet has a radius of 6360 km and a 60 km atmosphere. World units
are meters; the default planet center `(0, -6360000, 0)` places world origin at
sea level. Atmospheric distances and extinction/scattering coefficients are
exposed in kilometers and inverse kilometers. The implementation evaluates
the spherical ray/sphere intersections and numerically integrates Rayleigh and
Mie single scattering. For a view ray, the source term is

`βR ρR PR(μ) + βM,scatter ρM PHG(μ, g)`

and each segment is attenuated by view-path and sun-path transmittance
`T = exp(-∫(βR ρR + βM,extinction ρM) ds)`. Density falls exponentially with
altitude. The Mie extinction coefficient is constrained to be at least its
scattering coefficient, so the model cannot create energy from negative
absorption. The GPU keeps eight view segments, with more samples concentrated
near the dense lower atmosphere. Six sun-path samples are preintegrated into a
small optical-column lookup table, described below. It also shades a
Lambertian lower-sky ground disk from direct sunlight; that ground reflection is
not included in the fog ambient snapshot.

The same runtime sanitizer supplies GPU sky uniforms and CPU fog samples,
including values assigned from code outside Inspector hints. It bounds planet
radius to 6000–7000 km, atmosphere height to 1–120 km, Rayleigh and Mie scale
heights to 1–30 km and 0.1–10 km, each scattering coefficient to 0–1 km⁻¹,
and Mie extinction to at least its scattering coefficient. Non-finite scalar
and vector inputs fall back to documented defaults.

This is a single-scattering model. It does not implement ozone absorption,
multiple scattering, terrain shadows, or atmospheric refraction. Godot stores
sky radiance in an RGBA16F cubemap, whose finite range ends at 65504. To prevent
solar-disk overflow and fireflies, the shader caps the disk and final sky
radiance at 60000. The solar disk therefore keeps its angle and atmospheric
color/transmission but is not an absolute physical luminance measurement.

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
treats the lower hemisphere as ground with no ground-bounce contribution. It
includes sun-driven atmosphere scattering, not exposure or pre-exposure.
`sun_ground_illuminance` is RGB lux when physical light units are enabled and
FRP-normalized irradiance otherwise. Feng Fog does not substitute this field
for the selected light: scene surfaces still use raw DirectionalLight3D
irradiance, so applying atmospheric transmission only to fog would erase its
base at the horizon. Lit fog uses raw RGB sunlight for its albedo-tinted base;
the independent directional artist color keeps its raw-sun luminance scaling.
See the Feng Fog README for color modes and the source-lighting contract.

Ambient integration is cached per two-degree sun-zenith bins and linearly
interpolated. Sun color and intensity scale the cached unit-source result;
sun azimuth does not invalidate it. Atmosphere parameter changes clear the
cache. Each cache miss evaluates 64 importance-sampled directions, including
samples drawn from the Henyey–Greenstein distribution to cover its forward
peak; the bounded cost is observable through
`FengSkyAtmosphere.atmosphere_cache_stats()`.

## Atmosphere performance

The sun-path lookup contains Rayleigh and Mie density columns in kilometres,
not baked light colors or already exponentiated transmittance. The shader applies
current extinction coefficients to the interpolated columns and then evaluates
Beer–Lambert transmission. Planet shadow remains an analytic ray/sphere test,
so filtering cannot bleed daylight across the planet's shadow. A zero-length
outward path at the exact atmosphere boundary has unit transmission.

The 128 × 64 `RGF` table takes 64 KiB. Its coordinates are altitude expressed as
`rho / sqrt(top_radius² - planet_radius²)`, where `rho = sqrt(r² - planet_radius²)`,
and distance-to-atmosphere-exit normalized between the vertical and ground-tangent
rays. A quadratic warp concentrates distance samples toward the grazing horizon;
texel-center mapping keeps all domain endpoints defined. The table uses the same
six nonuniform midpoint sun samples as the original direct shader. Atmospheres
whose height exceeds 64 times either density scale height use the direct
six-sample path instead, preserving very thin authored layers without an
undersampled lookup or an unbounded build.

For the default atmosphere, each view segment replaces six square roots and
12 density exponentials with a filtered texture lookup. View density is evaluated
once for both scattering and extinction, and segment transmission is reused by
its integral. Eight view segments, the solar disk, spherical intersections,
space views, lower-sky ground shading and the physical/nonphysical light scale
are preserved. The CPU fog ambient integration remains the independent direct
reference, and the raw-sun fog contract is unchanged.

Only changes to planet radius, atmosphere height or the two density scale heights
rebuild optical columns. Sun motion/color/intensity, extinction and scattering
coefficients, phase asymmetry, planet position, ground albedo, exposure and sky
energy do not rebuild them. Each provider owns its texture; one bounded,
copy-on-write CPU byte cache avoids repeating construction for identical worlds.
Multiple property edits before the next update are coalesced into one rebuild.

Exported setters invalidate sanitized settings. Shader `changed` notifications
invalidate cached source identity, including nested shader edits. Static and
sun-dependent material updates are separate, and an unchanged world snapshot is
not republished. World ownership and resource identity are still checked every
frame and at snapshot read time. Cache counters expose these operations through
`atmosphere_cache_stats()`.

`tests/test_sky_optimization.gd` checks direct/LUT transmission and integrated
sky/ground agreement, ground shadow, zero extinction, atmosphere boundaries,
extreme valid profiles, stable update counts, parameter invalidation, shader
edits, same-frame world handoff/back, and per-world texture isolation. It runs
with either a Feng editor or a stock Godot 4.6 project containing this addon;
the Python test runner includes it after the existing component suite.

On one Linux stock Godot 4.6.3 headless run, table construction took 14–20 ms
and identical-geometry reuse took 7–24 µs. The default-atmosphere test's 1,584
sky/ground rays had 0.0914% maximum relative RGB error (excluding near-zero rays)
and 0.0285% normalized RMS error against direct integration. These are numerical
and CPU measurements, not a renderer/GPU timing guarantee; use the GPU probe
for target-device frame measurements.

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
