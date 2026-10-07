# Feng Cloud

Feng Cloud adds the `FengVolumetricCloud` component and the replaceable
`FengCloudMaterial` resource. Inspector distances are in kilometres and are
converted to metres for rendering.

## Use

Enable Feng Cloud and the Feng Render Pipeline, then add a
`FengVolumetricCloud` to the world. The component creates the bundled default
material when none is assigned. You can also assign a `FengCloudMaterial` and
choose its Built-in layout or UE 5.8 Default layout.

Cloud lighting uses the active `FengSkyAtmosphere` snapshot for the same world;
an explicitly selected same-world atmosphere can be used as well. Directional
light inputs can come from the atmosphere or be selected on the cloud
component. Without an atmosphere source, the component uses its authored planet
fallback. There is no `WorldEnvironment` fallback. Only the FRP renderer runs
the cloud passes.

Cloud-shadow casting and Sky AO are opt-in and off by default. SkyLight scene
captures trace at full resolution without temporal history. Their cloud, sky,
and lighting inputs are frozen for each six-face capture batch.

For transparent surfaces that should receive cloud depth-aware transport, use a
`BaseMaterial3D`, enable transparency, and turn on **Cloud Fogging**. This
material option applies to FRP.

## Rendering choices

`FengCloudTracePass` provides four VRT modes:

| Mode | Workload |
| --- | --- |
| 0 — Quarter trace + temporal half resolve | Quarter-resolution tracing, temporal half-resolution reconstruction, then full-resolution composition. This is the default balance. |
| 1 — Half trace | Half-resolution tracing without temporal history. |
| 2 — Quarter trace + full temporal resolve | Quarter-resolution tracing with full-resolution temporal reconstruction. |
| 3 — Full trace | Full-resolution tracing without temporal history; used for SkyLight captures. |

These modes trade tracing and reconstruction work; they are not claims of
pixel-identical UE output. The FRP shadow pass supplies cloud shadows and Sky AO
to their supported lighting consumers. Cloud rendering keeps radiance,
transmittance, and depth data separate so opaque composition and eligible
transparent surfaces can use the cloud depth.

## Resources and source

UE source packages are preserved under `resources/ue58/source/`; converted
Godot resources and the runtime default material inputs are under
`resources/ue58/converted/`. The default material and its graph kernel are
stored in the plugin resources. Runtime loading does not depend on an external
staging directory or the original Unreal Engine Content folder. The raw `.uasset`
files are ignored by Godot and retained as source evidence.

`T_CloudPattern_UE58_Runtime256.res` uses a 256-to-1 RGBA32F mip chain from a
source-ordered CPU reference of UE's legacy `TMGS_Blur1` filter. Its mip payload
round-trips byte-for-byte through Godot as RGBAF. This reference is not UE
cooker/DDC output, so platform-cooked texel identity is not claimed. The
original 1024×1024 decoded source resource is also retained.

This README describes implemented paths, not a claim that every configuration
has passed independent validation or matches UE pixel for pixel.

The editor export plugin explicitly packages the runtime shader source and its
recursive include files, along with the default material and converted texture
resources.
