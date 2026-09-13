# CDLOD geometry and VT frame capture

## Controls and behavior

`Terrain3D > Surface VT > CDLOD` is a native foldout immediately after SVT.
The Surface VT window also places CDLOD after SVT. AVT, SVT and CDLOD are enabled by default for new terrain nodes. New materials
use finite background (NONE), allowing CDLOD to activate. Explicit saved switches
and background settings are respected when loading existing scenes.

- `cdlod_patch_size`: internal grid size, hidden from both editor panels; the stored property remains readable for existing scenes. It does not control batching.
- `cdlod_lod_scale`: default 8, range 8–32. A leaf's morph ends at its world width times this scale; the last quarter is its morph band. Larger values keep fine geometry farther away.
- `get_cdlod_stats()`: active state, visible/selected/shadow-only patch counts and main batch count.

The backend selects nonoverlapping quadtree leaves for loaded terrain regions,
continuously collapses odd grid vertices onto the next dyadic grid, and submits
one regular grid through a MultiMesh. The main view's visible terrain uses one
batch; offscreen patches needed for shadows use a separate shadows-only batch.
Shadow cascades, depth passes, additional lights and other objects are separate
draw calls. One terrain batch is not a promise of one draw for the whole frame.

With CDLOD disabled, finite built-in terrain now uses the same grid resource
owner with individual region instances in fixed-grid mode instead of returning to clipmaps. At tessellation zero,
each 512-cell region is one 512-by-512 grid with 513-by-513 vertices. Higher
explicit tessellation subdivides regions into uniform grids to preserve spacing.
There are no EDGE/FILL/TRIM draws in this mode. Full-resolution geometry can cost
more triangles than distant clipmap rings; reduced draw count does not establish
a net GPU performance improvement. Infinite backgrounds, custom shader overrides
and the ocean retain the compatible clipmap path.

### Shared cell boundaries

CDLOD creates only regular grid triangles, with no skirts, FILL or TRIM strip
meshes. All patches resolve height and ID samples using world coordinates and
the same region lookup. A boundary sample belongs to the adjacent region's
first row/column; there is no independently editable duplicate on either side.
Thus 512 cells have 513 logical corner positions without changing the existing
512-wide on-disk region maps into padded maps. Texture padding is unrelated to
geometry stitching. Mixed LOD edges use vertex morphing onto the shared coarse
grid, not extra triangles around the cell. Explicit infinite backgrounds or
custom shaders still select the compatible legacy clipmap backend.

This implementation uses a shared horizontal distance function for selection and
vertex morphing. It follows the quadtree/continuous-morph approach described in
[Filip Strugar's CDLOD reference](https://github.com/fstrugar/CDLOD), but is not an
exact port of its 3D-distance selection, partial-quadrant indexing or streaming
system. The horizontal metric preserves a simple bound for crack-free shared
edges and keeps the finest grid at the terrain's existing vertex spacing and
tessellation level. High-altitude views can therefore retain more detail than a
3D-distance selector. AVT/SVT density and material generation are unchanged.

A region root does not morph beyond its available coarsest level. Selection
uses conservative height bounds including neighbouring layers and displacement
margin. Camera/projection, region bounds and relevant settings form an exact
selection cache; unchanged views do not rebuild/upload instance lists. Changed
lists use one packed transform/custom-data upload per batch and retain capacity.

CDLOD currently supports finite terrain (`World Background=None`) and the
built-in terrain shader. Infinite backgrounds and custom vertex overrides retain
the existing clipmap backend even if the option is checked; the Inspector and
window describe this requirement. Ocean meshes remain on their own clipmap.
The selection is driven by Terrain3D's assigned camera; arbitrary simultaneous
secondary-camera/VR views have not been validated. Geometry LOD can change the
far-field silhouette relative to clipmaps; this is not a bit-identical mesh mode.

## Frame capture correction

The RenderDoc toolbar previously requeued every resident terrain page before
forcing a frame, bypassing runtime page budgets. Normal capture now records
current cache resources and actually pending updates. No VT resolution or cache
precision is reduced to make capture cheaper. Native capture stage messages
separate beginning, drawing, saving and completion for further diagnostics.

The installed test projects use D3D12 and the portable RenderDoc configured under
`bin/tools/RenderDoc`. A copied `test-1` scene with its authored materials, terrain
and current cell cache completed capture without regenerating resident pages.
The original project's files were read only. The reported indefinite freeze was
not reproduced in the tested camera state, so eliminating all driver/library
hangs is not claimed; captures still serialize GPU resources and can pause.

## Validation

`native/tests/vt_adaptive_runner.py --cdlod` checks an actual GPU frame: multiple
patches add exactly one main-view terrain draw, four-region coverage, patch-size
rebuild, turning, material VT, background fallback/resume, original clipmap image
restoration, a hilly interior without visible background cracks, painted holes,
region removal/reload, LOD scale and offscreen shadow-batch retention. The hole
render test disables collision; the existing Godot Physics all-hole tile error
is outside this geometry change. This is not a full shadow-image or arbitrary
custom displacement equivalence certification.

`native/tests/editor_dock_runner.py --test dock` checks native group order,
foldout placement and the Surface VT window's CDLOD toggle alongside existing
bake/editor workflows. RenderDoc's integration runner checks capture contents,
resident production counters, analyzer closure and original-editor survival.

Validated builds: terrain and capture extensions, Windows x86_64 Debug and
Release. Final GPU fixtures:

- `terrain-vtadaptive-nkpvoz8i`: CDLOD checks passed; 178 visible patches added
  exactly one main-view terrain draw.
- `feng-editor-dock-clean-hby03kfb`: editor checks passed.
- `renderdoc-smoke-bx02pc4q`: copied authored project captured in 1623 ms;
  resident page production counters stayed unchanged and analyzer lifecycle
  checks passed.
- `terrain-vtadaptive-tfaar22_`: original AVT rotation/control regression passed;
  all five rotation images matched `terrain-vtadaptive-tn_caows` pixel for pixel.

After enabling the new defaults, `terrain-vtadaptive-oxega1u0` passed the CDLOD
and VT controls checks with zero errors, including moving the camera across both
shared boundary axes on the hilly four-region terrain. Debug/Release builds
passed. The subsequent editor GUI run `feng-editor-dock-clean-6j6aclj5` failed
because its synthetic mouse click did not reach MeshesBtn (hovered object null);
that run does not certify the editor interaction checks.

Fixed-grid validation: `terrain-vtadaptive-oung84ug` passed ordinary four-region
mesh count, one main draw without strip draws, moving boundary checks with CDLOD
off and on, holes and mode restoration, with zero errors.

CDLOD controls now synchronize the displayed switch and backend status. The
ordinary grid shader path has its own `_region_grid_enabled` flag; the separate
`_cdlod_enabled` flag is false when adaptive geometry is disabled. The explanatory
paragraph above the Inspector switch and both Patch Size controls were removed.
With CDLOD off, region grids now use individual mesh instances and individual
draw submissions. With CDLOD on, visible patches use a MultiMesh batch. This
makes the switch observable in frame-capture draw counts as well as geometry LOD.

The earlier fixed-grid one-draw validation describes the superseded batched
off-mode; the current regression requires four main draws for four ordinary
regions and one main draw for CDLOD. No seam strip draws are added.

Ordinary regions use one-instance draw resources sharing the grid mesh, because
FRP automatically merges ordinary Mesh instances with identical surfaces. This
preserves distinct per-region submissions without duplicating vertex buffers.
A capture may still name the API call DrawIndexedInstanced, but its instance
count is one and each region has a separate call; CDLOD combines many patches.

## Render-frame geometry updates

Terrain mesh snapping now runs from RenderingServer.frame_pre_draw, after camera
processing, rather than depending on physics ticks or displacement-buffer
position changes. The callback disconnects when the terrain exits the tree.
Pure camera rotation reuses cached distance-selected quadtree leaves; only
frustum classification and changed instance lists are updated. Map changes
invalidate selection, including region reloads and changed height bounds. Plane
coefficients and instance-list storage are reused to avoid per-node Variant
conversion and repeated list allocation. Source precision and seam morph rules
are unchanged.

The GPU test pauses physics and rotates 360 degrees with tessellation 0 and 1.
It verifies current-frame terrain coverage and that rotation does not rebuild
selection. `terrain-vtadaptive-qujlebic` passes, including existing holes,
shared-region boundaries, mode switches and region reload tests. Measured CDLOD
rotation means were 0.116 / 0.085 ms, with peaks 0.281 / 0.130 ms. This does not
meet a strict all-frame 0.1 ms target. Reserving both GPU buffers for all selected
patches increased padded uploads and was not retained.

VT rotation timing now records peaks in addition to averages. In
`terrain-vtadaptive-qtdsc4xt`, the producing phase peaked at 4.549 ms and warm
phase peaks ranged from 0.185 to 1.585 ms. A previous 0.91 ms average therefore
cannot rule out visible stalls. Moving VT source generation off the main thread
or GPU-side geometry compaction would be further architectural work; neither is
claimed by these changes.
