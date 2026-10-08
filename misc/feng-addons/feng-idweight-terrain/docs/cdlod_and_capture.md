# CDLOD geometry and VT capture

## Geometry modes

`Terrain3D > Surface VT > CDLOD` follows SVT in the Inspector and Surface VT window.
New nodes enable CDLOD and use finite background (`None`); saved settings remain authoritative.

| Setting / query | Contract |
| --- | --- |
| `cdlod_lod_scale` | Default 8, range 8–32; morph ends at patch-world width × scale, with the last quarter as the morph band |
| `cdlod_patch_size` | Hidden stored grid-size compatibility property; independent of draw batching |
| `get_cdlod_stats()` | Active state, selected/visible/shadow-only patches and main batch count |

For finite terrain using the built-in shader, CDLOD selects nonoverlapping quadtree leaves.
A shared regular grid is submitted through a visible MultiMesh batch and a separate
shadow-only batch. Odd vertices collapse continuously to the next dyadic grid.
Shadows, depth passes, additional lights and other objects contribute their own draw calls.

With CDLOD off, the same finite built-in path uses individual region-grid submissions.
At tessellation 0 a 512-cell region has a 512×512-cell grid with 513×513 vertices; higher
explicit tessellation subdivides it to preserve spacing. One-instance draw resources
keep each region separate even when FRP merges identical ordinary mesh surfaces.
Infinite backgrounds, custom shader overrides and the ocean use their compatible clipmap paths.

## Shared edges and update lifetime

Height/ID reads use world coordinates and the same region lookup. A boundary belongs to
the adjacent region's first row/column, so 512-wide stored maps describe 513 logical corner
positions without duplicate editable borders. Mixed LOD edges morph onto a shared coarse
grid. CDLOD/fixed-grid terrain adds no skirt, FILL or TRIM seam geometry.

Selection and morphing share horizontal distance. The implementation follows the
quadtree/continuous-morph approach in [Filip Strugar's reference](https://github.com/fstrugar/CDLOD),
with its own metric and region storage. High-altitude views can retain more detail than
3D-distance selection. Geometry LOD can change distant silhouettes; material density is
configured independently.

Region roots stop at their available coarsest level. Conservative bounds include neighboring
heights and displacement margin. `RenderingServer.frame_pre_draw` updates geometry after
camera processing; the callback disconnects on exit. Pure rotation reuses distance selection
and recomputes frustum classification. Changed maps, bounds, camera projection or settings
invalidate the relevant cache. Batch reuse requires matching instances and bounds; empty
region-grid batches release their draw resources. Changed batches use packed
transform/custom-data buffers.

The assigned Terrain3D camera drives selection. Arbitrary simultaneous secondary-camera/VR
views and all custom displacement/shadow combinations require separate validation.

## Frame capture

The RenderDoc toolbar records current resources and pending work under normal page budgets.
`prepare_vt_capture()` is a separate explicit replay diagnostic. Capture-stage messages
identify begin, drawing, saving and completion. Captures serialize GPU resources and may
pause; driver/library stalls remain possible.
See the [capture addon](../../feng-renderdoc-capture/README.md) for setup, Agility guidance,
builds and analyzer lifecycle tests.

## Verification

After rebuilding the editor and native extensions, run from the repository root:

```sh
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_adaptive_runner.py --cdlod --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test dock --driver d3d12
python misc/feng-addons/feng-renderdoc-capture/tests/run_capture.py
```

The geometry fixture covers multiple regions, draws, shared boundaries, hills, holes,
patch rebuild, turning, VT, background/mode changes, unload/reload and offscreen shadow
retention. Physics-paused rotation exercises render-frame updates at tessellation 0/1.
The hole image fixture disables collision; it does not certify the physics all-hole case.
The current draw assertion distinguishes four ordinary regions from one CDLOD main batch.
Editor tests cover group order and controls; capture tests cover resources, unchanged resident
production counters, analyzer closure and survival of the original editor.

## Historical Windows/D3D12 evidence

These are past fixtures, not fresh validation of later revisions:

- `terrain-vtadaptive-nkpvoz8i`:178 visible patches added one main terrain draw
- `feng-editor-dock-clean-hby03kfb`: editor checks passed
- `renderdoc-smoke-bx02pc4q`: copied authored scene captured in 1623 ms with unchanged
  resident production counters; original project files remained untouched
- `terrain-vtadaptive-tfaar22_`: five AVT rotation images matched `terrain-vtadaptive-tn_caows`
- `terrain-vtadaptive-oxega1u0`: defaults/shared-boundary checks passed; subsequent editor
  fixture `feng-editor-dock-clean-6j6aclj5` failed to deliver its synthetic MeshesBtn click
- `terrain-vtadaptive-oung84ug`: the former batched fixed-grid off-mode passed; its one-draw
  result predates the current separate-region submissions
- `terrain-vtadaptive-qujlebic`: render-frame rotation means 0.116/0.085 ms, peaks 0.281/0.130 ms
- `terrain-vtadaptive-qtdsc4xt`: VT producing peak 4.549 ms, warm peaks 0.185–1.585 ms

The original Debug/Release builds and focused image gates were recorded separately.
The timings did not meet a strict every-frame 0.1 ms target and do not establish a total
GPU improvement. Background source work and later VT changes have their own records.
