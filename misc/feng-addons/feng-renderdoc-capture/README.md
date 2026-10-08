# RenderDoc Capture

The 3D toolbar camera captures the current editor frame and opens the `.rdc` in
RenderDoc. It includes unsaved scene changes, the current viewport, editor
overlays and resident GPU resources. Captures stay in `.godot/renderdoc/captures/`.

## Setup

Install RenderDoc from https://renderdoc.org/builds and enable this plugin before
starting the editor. In Editor Settings, set **RenderDoc > Capture > Executable
Path** to `qrenderdoc.exe` on Windows or `qrenderdoc` on Linux; empty selects
auto-detection. The setting is cached in `.godot/renderdoc/editor.cfg` for the
next editor startup.

The engine loads RenderDoc before creating the editor's graphics device. It
skips normal game launches, headless tools, recovery mode and projects where the
plugin is disabled. The library and its instrumentation remain loaded until
editor exit. Each toolbar click requests one capture; hotkeys and the corner
overlay are disabled.

Executable and library discovery checks:

- Windows: configured executable folder, `FENG_RENDERDOC_PATH`, editor folder,
  its `tools/RenderDoc/` directory, then Program Files
- Linux: configured GUI folder and parent, `FENG_RENDERDOC_PATH` (including
  `bin`), editor-local `tools/RenderDoc/`, common GUI/library locations, then the
  dynamic loader path for `librenderdoc.so`

A missing cached executable falls through to discovery. Windows library search
continues through these locations even when the configured GUI has no adjacent
DLL; differing GUI/library folders are reported. Linux keeps the library globally
visible so the extension can resolve its API. `FENG_RENDERDOC_PATH` can point at
a portable installation root. Build-local `bin/tools/RenderDoc/` is untracked.
The toolbar reports startup failures from `FengRenderDoc.get_mount_status()`.

## Capture lifecycle

The immediate capture draws one frame synchronously. Its queued fallback retains
the same viewport-update snapshot. Completion, failure, timeout and plugin
disable restore the original update modes; generation ownership retires an
interrupted wait before another capture starts.

The toolbar captures pending work within normal terrain page budgets. Use the
native `prepare_vt_capture()` diagnostic API to request resident-cache replay.
Stage logs identify drawing or resource-saving stalls; a blocked RenderDoc API
call cannot be cancelled by the plugin.

The analyzer shows empty regions, including an idle VT pass. Active terrain
updates expose `Surface VT Page Updates`, `VT Source Upload`, `SVT Cached Page
Upload` and the bake Dispatch. The `Surface VT Albedo Height`, `Surface VT Normal
Roughness` and `Surface VT Parameters` array layers identify physical slots.
Dispatch Z selects a 64-byte record in `Surface VT Jobs` containing the world
rectangle, slot and operation.

## D3D12 Agility compatibility

An earlier Windows probe with RenderDoc 1.39 and this checkout's Agility runtime
failed inside `force_draw()` for both `forward_plus` and `frp`; the Windows system
runtime captured successfully. These are recorded results, not a compatibility
claim for other RenderDoc, driver or runtime versions.

For that combination, set the project setting
`rendering/rendering_device/d3d12/agility_sdk_version = 0` to use the Windows
runtime; `618` restores the configured Agility version. Alternatively, select a
compatible RenderDoc build. Temporarily moving the editor's `D3D12Core.dll`
aside affects every project using that editor; restore it after the probe.

## Build

Build before first use and after native changes, then restart editors that have
the library loaded:

```sh
scons -C misc/feng-addons/feng-renderdoc-capture/native platform=linux target=template_debug arch=x86_64 -j8
```

Use `platform=windows` for Windows and `target=template_release` for release
exports. Libraries are untracked artifacts in this addon's `bin/`; linked
projects share them. Linux links `libdl` for API discovery.

## Validation

Lifecycle tests need no RenderDoc installation and cover viewport restoration,
plugin reload and launch argument forwarding:

```sh
python misc/scripts/test_feng_tools_lifecycle.py --editor /path/to/feng-godot
```

Add `--driver vulkan` for GPU execution. The Windows/D3D12 integration test needs
`psutil`, the built engine/addons and a compatible RenderDoc installation:

```sh
python misc/feng-addons/feng-renderdoc-capture/tests/run_capture.py
```

It uses an isolated project/settings, clicks the actual toolbar, checks the
executable picker, captures the editor UI with a PID label, opens the analyzer
and verifies that closing it leaves the original editor running without another
capture. The default run checks the idle VT marker in the analyzer UI.

- `FENG_TEST_VT_WORK=1`: capture actual terrain baking and cached SVT upload
- `FENG_TEST_VT_TERRAIN=1`: use default-capacity Terrain3D and check that capture
  preserves resident bake/upload counters
- `FENG_TEST_TERRAIN_PROJECT`: optional source project with `render/test.tscn`,
  `texture/` and `terrain/`; fixtures copy current sources and exclude `.vtpage`
  files, leaving the source project untouched
