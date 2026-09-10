# Terrain integration tests

Build the debug terrain extension, then run `texture_layers.gd` with this
engine from a project that has the terrain extension installed and imported.
Use a real rendering driver; `--headless` uses dummy textures and cannot test
GPU uploads or the rendered result.

For example, from the engine checkout on Windows (replace PROJECT):

```powershell
.\bin\godot.windows.editor.x86_64.console.exe --path PROJECT --rendering-method frp --rendering-driver d3d12 --resolution 320x240 --script F:/godot/feng-godot/misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd
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
HDR sources support uncompressed, BC6H, and HDR ASTC arrays. Originals are never modified.

## Graphical editor asset dock

After building the editor and the debug terrain extension, run the asset-dock
layout and menu regression with a real graphics driver:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --driver d3d12
```

The runner creates a disposable copied addon fixture under `bin/`, excluding
compiler sources and stale temporary DLLs. It launches the graphical editor
off-screen with `--rendering-method frp` (without `--headless`), measures the
real dock at widths 900 and 500, and exercises Texture Array, Terrain Maps,
and all five Debug Views menu actions. The command succeeds only when the log
reports `ERROR_LINES=0` and `PASS graphical Terrain3D asset dock layout and
management menu actions`; the absolute fixture log path is printed in the
result.

## Editor brush input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test input --driver d3d12
```

This graphical FRP test sends mouse-button events through the production
terrain editor callback with an oblique camera. It requires an empty first
GPU pick, then checks that the same press paints overlay ID 1 through the CPU
fallback, verifies the packed R16 map on CPU and GPU, and checks release
outside the terrain and right-button navigation. It exercises the input
callback directly; it does not simulate OS mouse delivery.

The dock regression also routes mouse motion, press, and release through the
editor viewport for Textures/Meshes, asset highlight/edit/clear, mesh visibility,
and opening the Terrain menu. Icon clicks must not bubble into tile selection
and rebuild the clicked button before release.

## New terrain setup and Scene input

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test setup --driver d3d12
```

Creates an empty saved scene, verifies the folder chooser, chooses a temporary
data directory, and checks the initial 64x64 region and disabled background.
Texture-role clicks, mesh selection, painting, and Add Region are delivered
through Input.parse_input_event and the actual Scene editor event routing.
The test also saves/reloads regions and checks cancellation and existing data
folders. It never edits a user project.

## Texture array codecs

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_compression_runner.py --driver d3d12
```

Build the editor and debug extension first. This uses an isolated copied addon
and real GPU upload/readback for every exposed compression choice, two layers,
both channel arrays, mipmaps on/off, packed alpha and HDR values above 1.
It checks ASTC 8x8 HDR block sizing, source preservation, and uploaded format,
and rejects engine errors even if the script prints PASS. Unsupported GPU
formats use explicit decoded uploads; this does not test native mobile GPU
support on a desktop adapter. Logs remain in the printed fixture directory.
