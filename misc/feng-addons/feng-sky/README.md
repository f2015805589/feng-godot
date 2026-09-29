# Feng Sky

`FengSkyAtmosphere` is a world-level sky component built on Godot's
`WorldEnvironment`, `Environment`, and `Sky` resources. Enable the Feng Sky
plugin, add a `FengSkyAtmosphere` node to a scene, then assign a `Sky` resource
to its **Sky** property. A new node starts with a `PhysicalSkyMaterial` sky.

The **Sky** property accepts any `Sky` resource. Its `sky_material` can use
`PhysicalSkyMaterial`, `PanoramaSkyMaterial`, `ProceduralSkyMaterial`, or a
`ShaderMaterial` with a sky shader. A panorama is an equirectangular texture.
To drive Godot's built-in physical sky with a chosen directional light, set
that light's `sky_mode` to **Sky Only** and set other directional lights to
**Light Only** as appropriate.

The component keeps its `Environment.background_mode` at `BG_SKY`. It makes
private copies of an assigned Environment, Sky, sky material, and Shader before
using them, so editing one component does not change another world's shared
settings. External texture assets remain shared. The `Sky` property is the
component's saved sky slot; changes made to the underlying Environment's sky
are reflected by that property.

Godot applies the component through the normal WorldEnvironment rule: the
first WorldEnvironment in each `World3D` provides that world's Environment.
Additional environments do not replace it and receive a configuration warning.
The scope is a `World3D`, so scene instances sharing a world also share its sky.

FRP draws this Environment through its native Sky pass. Its existing eye
adaptation path applies pre-exposure to the background and sky, so the component
does not multiply sky color by exposure itself. The built-in `PhysicalSkyMaterial`
provides a sky background approximation; this addon does not implement UE's full
atmospheric perspective or multi-scattering on scene geometry. Use Environment
fog or the separate Feng height fog for scene fog effects.

## Tests

With a built editor available, run:

```powershell
python misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py --editor F:/path/to/godot.windows.editor.x86_64.exe
```

The test starts a temporary headless project and checks default and replaceable
skies, per-world environment selection, isolation of shared resources, and
handoff to an existing WorldEnvironment.
