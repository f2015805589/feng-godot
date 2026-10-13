# Feng Reflect Probe

Feng Reflect Probe is a standalone FRP reflection-volume addon. It samples its own HDR cubemaps and does not instantiate a Godot `ReflectionProbe` or use the native reflection atlas.

## Setup

1. Install and enable the Feng Render Pipeline addon and this addon.
2. Add a `FengReflectProbe` node to the scene. Its editor gizmo shows the influence box and capture origin.
3. Set `Box Size`, `Blend Distance`, `Priority`, and `Intensity` for the volume.
4. Leave `Source Mode` on `Scene Capture` to capture the current world, or choose `External Cubemap` and assign a `FengReflectProbeData` resource containing a square HDR `Cubemap`.

The scene capture uses six private 90-degree cameras in the current `World3D`. It copies linear HDR color after transparent rendering and divides out the active pre-exposure and scene exposure normalization before building the cubemap. Capture omits temporal AA, eye adaptation, and reflection providers, so the probe cannot feed its own result back into the capture. Safe diffuse lighting, Sky, fog, clouds, and transparent objects remain in the capture plan.

## Updates and baking

- `On Ready` captures once after the node enters the running scene.
- `Realtime` captures one scene cubemap face per scheduled frame, or snapshots an assigned External Cubemap at `realtime_interval`; both rebuild filtered mips within the configured per-frame budget.
- `Manual` skips periodic updates. Use **Capture Now** for a scene capture or **Refresh Cubemap** for an External Cubemap; `request_update()` does the same.
- An assigned External Cubemap is ingested once for availability, including when `Update Mode` is `Manual`. **Refresh Cubemap** snapshots later in-place layer changes that do not emit a Resource `changed` signal; `Realtime` polling detects them at `realtime_interval`.
- **Bake Cubemap Resource** captures a portable, linear HDR base cubemap into `Probe Data` and marks the edited scene unsaved. A standalone `Probe Data` resource with a valid local path is saved by the bake; embedded data is saved with the scene. In `Scene Capture` mode, a saved bake supplies the startup reflection until a new scene capture completes. The filtered roughness mip chain is rebuilt when used.
- `Enabled` removes the probe from active render snapshots immediately. Re-enabling reuses the last complete scene capture or reloads the assigned External Cubemap, then publishes its filtered mips when ready.

The renderer keeps the prior complete cubemap available while six new faces and the full GGX mip chain are built. On restart, Scene Capture mode first uploads and filters its saved bake, then replaces it after a new capture completes. A failed capture leaves the prior complete reflection active. The shared probe atlas is capped at 32 entries; a 128-pixel RGBA16F cubemap with its mip chain uses about 1 MiB per entry. Capture face resolution and mip work budget are adjustable per node.

External cubemap `capture_position` and `capture_basis` are in world space. The basis controls cubemap orientation, while the node's transform controls its box volume. Assign a square, six-face sampleable color Cubemap containing linear HDR radiance. The render callback snapshots all six faces directly into an owned RGBA16F cube, sanitizing non-finite values and clamping to the half-float range. The snapshot is capped at 256 pixels per face before the existing 128-pixel GGX mip chain is built. This path does not read image pixels back to the CPU.

The latest complete cubemap remains available until the whole new mip chain finishes. `prefilter_mips_per_frame` controls how many mip levels are scheduled per process frame; a value of 1 spreads filtering across eight frames, while 8 schedules the full chain in one frame. A zero `realtime_interval` requests a new source snapshot every process frame, but newer requests coalesce while an in-flight filter finishes. Automatic External Cubemap polling is suppressed in the editor unless `Capture In Editor` is enabled; **Refresh Cubemap** remains available for an explicit editor update.

## Runtime ownership

The probe node owns its private viewport and camera; the camera retains the compositor, renderer, and capture passes. Capture completion, failure, and cancellation share one teardown transition. The runtime owns published capture status and complete cubemap snapshots; the capture pass owns the GPU textures, including the previous complete cube while a replacement is built.
