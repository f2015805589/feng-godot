# Feng Fog

`FengHeightFog` provides exponential height fog with two density layers, a start distance, a cutoff distance, and optional directional inscattering. The Sky-anchored fullscreen pass fogs the opaque scene and sky. Forward-only opaque fallback and transparent materials use their own fragment position, so their fog follows the surface rather than the opaque depth buffer.

Fog sources are scene-linear radiance and pre-exposure scales the combined source once with the rendered surface. When an active `FengSkyAtmosphere` uses the built-in atmosphere and `affect_height_fog` is enabled, the fog runtime adds `ambient_radiance * height_fog_contribution` to the authored `fog_inscattering_color`. `ambient_radiance` is the atmosphere model's direction-averaged Rayleigh/Mie single-scattered sky radiance, `(1 / 4π) ∫ L_sky(ω) dω`; it is scene-referred, has no exposure or pre-exposure applied, and is not solar lux. The scale defaults to 1. With no matching supported sky snapshot, the fog keeps its authored color unchanged. A high-energy sun can still make the authored fog contribution look dim after automatic exposure adapts to the bright scene. Directional inscattering remains a separate artistic sun lobe and keeps its existing selected `DirectionalLight3D` color and energy conversion (`PI` for non-physical units, authored lux for physical units). Sky transmittance does not modify the Godot light or automatically extinguish this lobe; the atmosphere's ground illuminance is not added to it a second time.

The sky-to-fog ambient contribution is computed by FengSkyAtmosphere's built-in Rayleigh/Mie single-scattering model and folded into the existing fog source on the main thread, scoped to the matching world. This is not a full Unreal `SkyAtmosphere` height-fog or atmosphere-light integration: it does not implement UE's full multi-scattering or distance-dependent aerial-perspective path, and it does not apply atmospheric transmittance to Godot's selected light or to the separate artist lobe. Custom sky providers that do not publish an atmospheric snapshot, including `PhysicalSkyMaterial`, retain the existing authored fog behavior.

## Test

With a built Godot editor available, run the optional-runtime late-load check:

```powershell
python misc/feng-addons/feng-fog/tests/run_late_sky_runtime_load.py --editor F:/path/to/godot.windows.editor.x86_64.exe
```

It first queries fog with no `feng-sky` runtime, then makes a mock provider available in the same process and verifies that fog discovers and consumes its world-matched radiance snapshot.
