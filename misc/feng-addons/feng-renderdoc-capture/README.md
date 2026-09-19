# RenderDoc Capture

The 3D toolbar camera captures the next actual frame presented by the current
editor window. It waits for the completed `.rdc` and opens it in `qrenderdoc.exe`.
It never launches another Godot process, saves/reloads a scene, or restarts the
editor to capture. Unsaved scene changes, the current viewport, editor overlays,
and the editor's real GPU resources are included in the window frame.

## Setup and lifetime

Enable the RenderDoc Capture plugin before starting the editor. The engine loads
RenderDoc before creating the editor's graphics device. Normal game launches,
headless tools and recovery mode do not load it. If the plugin is disabled at
startup, the editor does not load it either.

In Editor Settings, search for `renderdoc`, then set **RenderDoc > Capture >
Executable Path** to `qrenderdoc.exe`. This file picker is visible without Advanced
Settings. Empty means auto-detect. The matching `renderdoc.dll` accompanies the GUI.
The path is cached in `.godot/renderdoc/editor.cfg` for early device initialization;
changing the installation takes effect the next time this editor is started.
It does not force an editor restart.

A cached path only wins while it still exists: if RenderDoc is moved, upgraded or
removed, that cache entry is ignored, the search below runs again, and the stale
path is reported on the console. The capture button also shows the reason the last
startup probe failed (`FengRenderDoc.get_mount_status()`) instead of only reporting
that the device is not attached.

The engine searches, in order: the configured executable's folder, `FENG_RENDERDOC_PATH`,
this build's folder and `bin/tools/RenderDoc/` next to it, then the normal Windows
Program Files installation. `bin/tools/RenderDoc/` is not part of this checkout; it
exists only if a portable build was unpacked there (that path is ignored by git).
Portable builds are available at https://renderdoc.org/builds.

The matching `renderdoc.dll` is searched through that same list, not only inside the
configured folder: an executable that points at a folder without a usable DLL no longer
hides the installed copy. If the DLL and the configured executable come from different
folders, the mount reports both, so a version mismatch between capture and analyzer is
visible instead of silent.

On this machine the capture itself then hit a RenderDoc/runtime incompatibility that is
unrelated to the renderer: with `bin/D3D12Core.dll` (the Agility D3D12 runtime installed
in this checkout) present, RenderDoc 1.39 killed the editor inside the forced draw for
both the FRP and the `forward_plus` renderer. Renaming that one file away made the exact
same capture succeed. See "D3D12 capture and the Agility runtime" below. This checkout
pins no RenderDoc version and ships no RenderDoc.

Each click requests one frame. F12 and the RenderDoc corner overlay are disabled.
Closing the analyzer does not start further captures or restart the editor.
**The DLL and graphics wrappers remain until editor exit.** RenderDoc cannot
safely remove them after graphics initialization; closing its window is not an
unload operation. This is the accepted tradeoff for capturing the live editor
without restarting it. No claim of zero instrumentation overhead is made.
Captures remain under `.godot/renderdoc/captures/`.

## D3D12 capture and the Agility runtime

The editor loads `D3D12Core.dll` from its own directory whenever that file exists (the
D3D12 Agility SDK layout). RenderDoc 1.39 does not record that combination on this
machine: the editor dies inside `rendering->force_draw()` while the capture is open, so
the toolbar never returns and no `.rdc` is written. Measured with an empty probe project,
one mesh, `--rendering-driver d3d12`:

| D3D12 runtime the editor uses | renderer | result |
| --- | --- | --- |
| Agility `D3D12Core.dll` (default) | `forward_plus` | editor killed inside `force_draw` |
| Agility `D3D12Core.dll` (default) | `frp` | editor killed inside `force_draw` |
| Windows runtime, `agility_sdk_version=0` | `forward_plus` | `capture: complete in 515 ms`, 47 MB `.rdc` |
| Windows runtime, `D3D12Core.dll` renamed away | `forward_plus` | `capture: complete in 639 ms`, 47 MB `.rdc` |

The failure therefore follows the Agility runtime, not the renderer and not this addon.
Any frame RenderDoc records from that runtime kills the editor, including a capture that
only arms the queued trigger and lets the editor present normally. Ways out, best first:

- **Per project, no files touched:** set
  `rendering/rendering_device/d3d12/agility_sdk_version = 0` (Project Settings >
  Rendering > Device > D3D12, Advanced). The engine then creates its device through the
  Windows D3D12 runtime instead of the Agility factory and the capture succeeds with
  `bin/D3D12Core.dll` still in place. Setting it back to `618` restores Agility for that
  project.
- Use a RenderDoc build that records this Agility runtime. Portable builds live at
  https://renderdoc.org/builds; unpack one under `bin/tools/RenderDoc/` (ignored by git)
  or point the executable path at it.
- Move `bin/D3D12Core.dll` aside (whole editor, every project) and put it back afterwards.
  Do not delete it permanently: this checkout installs that runtime on purpose
  (`misc/scripts/install_d3d12_sdk_windows.py`).

`tests/run_capture.py` needs one of the last two states to pass on this machine.

## Building

The plugin script calls native statics (`RenderDocCapture.capture_frame()`), so a source
change is only live once this addon's DLL is rebuilt. An editor started against a stale
`bin/libfeng-renderdoc-capture.windows.debug.x86_64.dll` fails at plugin load with

```
ERROR: res://addons/feng-renderdoc-capture/src/editor_plugin.gd:84 - Parse Error:
Static function "capture_frame()" not found in base "GDScriptNativeClass".
ERROR: Failed to load script "res://addons/feng-renderdoc-capture/src/editor_plugin.gd"
with error "Parse error".
```

and the whole plugin (button, capture, analyzer launch) is unavailable for that session.

```powershell
cd misc/feng-addons/feng-renderdoc-capture/native
scons platform=windows target=template_debug arch=x86_64 -j8
```

The DLL is a build artifact and is not tracked by git, so a fresh checkout has to build it
before the plugin loads. Projects that link this addon (the junctions under `bin/`) resolve
the library relative to the addon directory, so one rebuild fixes every one of them.

## Validation

The toolbar captures resident textures and naturally pending work. It does not
call terrain `prepare_vt_capture()` or regenerate the entire resident cache.
The previous forced replay bypassed normal page budgets and concentrated all
resident AVT bakes/SVT uploads into one capture. The explicit native diagnostic
API remains available to callers that deliberately want that extra workload.

The native capture helper logs begin, viewport drawing, resource/command saving,
and completion with elapsed milliseconds. If a driver or capture-library stall
persists, the last `[frd] capture:` line identifies the blocked stage; this does
not provide cancellation inside a blocked RenderDoc API call.

Captures opened by the toolbar enable RenderDoc's empty-region display, so an
idle VT Pass remains visible with the normal action filter. An idle pass has no
page work to replay in that frame. Active terrain updates show `Surface VT Page
Updates`, `VT Source Upload`, `SVT Cached Page Upload`, and the bake Dispatch.
Select that Dispatch and inspect the named `Surface VT Albedo Height`,
`Surface VT Normal Roughness`, and `Surface VT Parameters` texture arrays;
the array layer is the physical slot. Dispatch Z selects a job, whose 64-byte
record in `Surface VT Jobs` contains the world rectangle, slot, and operation.

After building the engine and addons, run:

```powershell
python misc/feng-addons/feng-renderdoc-capture/tests/run_capture.py
```

Set `FENG_TEST_VT_WORK=1` to additionally capture the actual terrain page baker
and a cached SVT upload. The default run verifies that an idle VT marker is
visible in RenderDoc's UI, not just present in the capture file.

This Windows/D3D12 GPU test requires `psutil` and RenderDoc, and a RenderDoc build that
can record the Agility runtime the editor loads (see "D3D12 capture and the Agility
runtime" above). It uses a disposable
project and isolated editor settings under `bin/renderdoc-smoke-*`. It presses the
real camera button, checks the EXE file picker, verifies no second Godot process
is created, opens an actual capture, closes only that analyzer, and confirms the
original editor survives with no additional captures. It places a live editor UI
label containing its PID in the frame and extracts a thumbnail for inspection.
The capture must include that label and the actual editor UI, not a reconstructed
scene image. Test fixtures are excluded from addon imports.

Set `FENG_TEST_VT_TERRAIN=1` to capture a default-capacity actual Terrain3D and
verify capture does not increase resident bake/upload counters. Optionally set
`FENG_TEST_TERRAIN_PROJECT` to a project with `render/test.tscn`, `texture/` and
`terrain/`; the runner copies its scene, materials and current cell sources into
an isolated fixture, excluding obsolete `.vtpage` files. It never saves into the
source project. Analyzer shutdown uses a handshake so slow replay does not race
an arbitrary editor quit timer.
