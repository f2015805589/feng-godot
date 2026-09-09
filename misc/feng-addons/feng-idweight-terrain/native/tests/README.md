# Terrain integration tests

Build the debug terrain extension, then run `texture_layers.gd` with this
engine from a project that has the terrain extension installed and imported.
Use a real rendering driver; `--headless` uses dummy textures and cannot test
GPU uploads or the rendered result.

For example, from the engine checkout on Windows (replace PROJECT):

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path PROJECT --rendering-method deferred --rendering-driver d3d12 --resolution 320x240 --script F:/godot/feng-godot/misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd
```

The default test constructs two RGB8/RGBA8 materials. Optional user arguments
`-- res://node_3d.tscn OUTPUT_DIRECTORY` load the same two-material regression
case from an existing scene instead. The scene must contain a child named
`Terrain3D`, with an RGBA8 asset at ID 0 and an RGB8 asset at ID 1. Changes are
made in memory only; the test does not save project scenes or texture assets.

The test checks matching GPU array layers, size/mipmap conversion, original
asset preservation, adding an empty third layer and assigning its texture,
brush CPU writes and GPU readback, red-to-green rendered output, and undo/redo.
Before/after PNGs are saved in OUTPUT_DIRECTORY (default: `user://`).

Each terrain manages its own array settings. Defaults are auto size, mipmaps
and BC7. Tests also exercise uncompressed storage, fixed resolution, disabling
mipmaps, owner isolation, slope mixing on a ramp, and height/ID/weight/slope views.
HDR sources require uncompressed arrays. Originals are never modified.
