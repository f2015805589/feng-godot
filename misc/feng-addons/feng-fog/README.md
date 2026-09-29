# Feng Fog

`FengHeightFog` provides exponential height fog with two density layers, a start distance, a cutoff distance, and optional directional inscattering. The Sky-anchored fullscreen pass fogs the opaque scene and sky. Forward-only opaque fallback and transparent materials use their own fragment position, so their fog follows the surface rather than the opaque depth buffer.

Fog and inscattering colors are scene-linear radiance. Pre-exposure scales them once with the rendered surface. A high-energy sun can therefore make a fixed fog color look dim after automatic exposure adapts to the bright scene; raise the authored fog color when a brighter haze is desired. Directional inscattering follows the selected `DirectionalLight3D` and includes its light color, `light_energy`, and the renderer's energy conversion (`PI` for non-physical units, authored lux for physical units).

Godot's sky radiance is filtered environment lighting, not atmospheric transmittance or in-scattering along a camera ray. `FengHeightFog` does not synthesize Unreal's `SkyAtmosphere` coupling from a `PhysicalSkyMaterial`; its fog color and directional sun lobe remain authored inputs.
