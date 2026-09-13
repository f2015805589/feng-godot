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

The engine searches `FENG_RENDERDOC_PATH`, `bin/tools/RenderDoc/qrenderdoc.exe`
alongside this build, then the normal Windows Program Files installation.
This checkout has portable RenderDoc 1.46 under `bin/tools/RenderDoc/`, an ignored
local dependency. The system RenderDoc installation is unchanged. Portable builds
are available at https://renderdoc.org/builds. Version 1.39 crashed during D3D12
capture with this checkout's Agility 1.618.5 runtime; 1.46 is used for verification.

Each click requests one frame. F12 and the RenderDoc corner overlay are disabled.
Closing the analyzer does not start further captures or restart the editor.
**The DLL and graphics wrappers remain until editor exit.** RenderDoc cannot
safely remove them after graphics initialization; closing its window is not an
unload operation. This is the accepted tradeoff for capturing the live editor
without restarting it. No claim of zero instrumentation overhead is made.
Captures remain under `.godot/renderdoc/captures/`.

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

This Windows/D3D12 GPU test requires `psutil` and RenderDoc. It uses a disposable
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
