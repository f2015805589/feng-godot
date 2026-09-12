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

It is normally run through its runner, which builds an isolated copied addon fixture and
rejects engine errors even if the script prints PASS:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers_runner.py --driver d3d12
```

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

## Region chunk streaming

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_streaming_runner.py --driver d3d12
```

Build the debug extension first. The runner uses an isolated copied addon and a real
graphics driver, saves a 5x5 grid of 64 m regions to a temporary data directory, drops
them from memory and then drives `Terrain3DStreamer` around it. It checks ring residency,
the per-update load/unload budgets, the missing-file cache (probed once, re-probed only
after `reset_missing()`), modified-region protection, save-on-unload, that unloading never
deletes a file, out-of-bounds rejection, and that a `Terrain3D::set_data_directory()`
rebuild does not leave the streamer on a freed `Terrain3DData`.

Each update touches only the layer slots that changed (see "Region layer slots" below), so
the budgets cost one layer upload per map type rather than a full array rebuild.

## Region layer slots

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/region_slots_runner.py --driver d3d12
```

Build the debug extension first. Renders a 2x2 grid of 64 m regions, each painted with its own
material, then unloads one region and adds another elsewhere. The re-rendered frame is sampled
per region, which proves the region map, the four texture arrays and the layer -> location
table the shader reads as `_region_locations` all still agree after a swap. `get_map_stats()`
additionally proves the swap reallocated zero texture arrays (`map_create_count == 0`), cost
exactly one layer upload per map (4), and that a region keeps its slot while unrelated regions
come and go. The last phase places a region at (40, -40) — outside the 32x32 grid the shader's
old `uniform int _region_map[1024]` forced — and asserts it renders through the directory
texture. Three PNGs are written to the fixture directory.

## Virtual texture runtime

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_runtime_runner.py --driver d3d12
```

Build the debug extension first. Exercises `Terrain3DVirtualTexture`: the physical page atlas,
the indirection mip chain and the LRU/protected slot allocator, built on the addressing core in
`src/terrain_vt.h`. The atlas is configured small (32 texel pages, 8 physical pages, 64x64
indirection) so every assertion can be checked against **GPU readback** rather than the CPU
mirror: the indirection texel a request published, the invalidation after an eviction, and a
full page-content round trip through the atlas.

It also pins sector block allocation (disjoint, aligned, idempotent re-register), the mip-chain
walk (a coarse page serves the finer pages it covers, and pages past the block edge do not
resolve), LRU eviction order, that protected pages survive and that a fully protected atlas
fails instead of stealing a page, and that `unregister_sector` frees the block.

Note the indirection writes are batched: `request_page()` only marks the CPU chain dirty and
`commit()` uploads it, so anything inspecting GPU state has to commit first.

## Surface virtual texture page production

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_surface_runner.py --driver d3d12
```

Build the debug extension first. Drives `Terrain3D::update_surface_vt()`: the demand pass picks a
mip per sector from its distance to the clipmap target, asks the virtual texture for that mip's
pages, and fills only the ones it actually allocated by resampling the region's surface map.

The region surface maps are filled with a pattern where every texel is distinguishable, so each
page read back from the GPU atlas can be compared texel by texel against an independently
restated version of the crop rule — at mip 0 (a 1:1 crop) and mip 1 (a 2x downsample), border
included. A border texel whose region coordinate falls outside the region belongs to a
neighbouring region, so the expectation is that region's pattern (or material 0 when no region
covers the position) rather than a clamped copy. It also pins the distance rule and that a
settled pass writes no pages and does not re-upload the indirection.

The atlas must be at least `sectors * pages_per_axis^2` pages or the LRU will evict pages the
test is about to look for; the test asserts that sizing up front.

## Surface virtual texture render integration

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_render_runner.py --driver d3d12
```

Build the debug extension first. Renders the same scene three ways — array path, virtual texture
on, and virtual texture on with the four atlas pages covering the probe point blanked — and
checks three things:

* The virtual texture path is **pixel identical** to the region texture array path. The pages
  come from the same surface map, so this catches any addressing slip in the indirection walk,
  the page grid or the border.
* Blanking the atlas pages **changes** the rendered colour. That is what proves the shader is
  reading the physical atlas rather than quietly falling back to the array.
* Turning the toggle back off restores the array path unchanged.

PNGs of all three frames are written to the fixture directory.

Note `src/shaders/*.glsl` are `#include`d into the extension's C++ sources, so a shader edit
needs a rebuild before any test can see it.

## Surface virtual texture GPU page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_feedback_runner.py --driver d3d12
```

Build the debug extension first. Exercises `Terrain3DVTFeedback`: a compute pass on its own local
RenderingDevice that projects every candidate page, measures its screen extent and writes the
local mip that would put about one page texel on one screen pixel into an `R32_UINT` storage
image, read back asynchronously with `texture_get_data_async`.

All 9216 cells of a 96x96 page grid are compared against an independently restated version of the
rule computed in GDScript, so the projection, the off-screen cull and the mip maths are pinned
together. It also checks the readback is genuinely deferred (no result at request time, result
after `sync()`), and that a camera pointing away requests nothing.

Two things to know before changing this code:

* The call order is `dispatch()` -> `request_readback()` -> `sync()`. `texture_get_data_async`
  registers the texture copy as a draw graph node, and a node only runs in `_execute_frame`, so
  the submit has to happen *after* the request. A local device has no frame advance of its own,
  which is why `sync()` is the only place the callback fires.
* The shader writes diagnostic sentinels for each early-out (`0xFFFFFFFE` behind, `0xFFFFFFFD`
  off screen, `0xFFFFFFFC` too small) and the test histograms them. When a run reports nothing
  requested, that histogram says which branch fired.

This pass is consumed by `Terrain3D::update_surface_vt()` when `surface_vt_feedback_enabled`
is on: the mip is then chosen per mip 0 page instead of per sector. See the per-page demand test
below. The readback stalls the frame, so `surface_vt_feedback_interval` (default 4) amortises it
and the demand pass keeps using the last result in between.

## Surface virtual texture per-page demand

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_demand_runner.py --driver d3d12
```

Build the debug extension first. Drives `Terrain3D::update_surface_vt()` with the GPU feedback on
and checks the demand it arrives at, page by page, through the indirection texture:

* The mip the runtime reads for every page matches an independently restated projection rule,
  computed in GDScript through the same window origin the runtime derived. That pins the wiring —
  feedback window origin, page coordinates, level grouping — not just the shader.
* Exactly the demanded pages are resident, each at its own level, and nothing else is. The check
  uses the exact level entry rather than `lookup_page()`, which walks the mip chain and therefore
  cannot tell "this level is resident" from "a finer level covers it".
* A sector behind the camera that is inside both the feedback window and `surface_vt_distance`
  gets no pages at all. A distance rule cannot do that, so this is the check that the cull is
  genuinely honoured rather than treated as a failure.
* Page contents are read back and compared texel by texel, so a resident page filled from the
  wrong region texel still fails.
* A second pass with nothing changed produces nothing, even though the feedback runs again.
* With the feedback off, the forced-mip path still produces its 16 pages per sector.

The test asserts that its own configuration puts at least two levels inside one sector (11 of 25
sectors in the current setup) and culls at least one page, because otherwise it would pass on the
old per-sector rule too.

Two things to know before changing this code:

* `surface_vt_feedback_min_extent` (default 8 px) is the floor below which a page is culled
  instead of requested, and the viewport size comes from the camera's real viewport, so the
  window size matters: the runners pass `--resolution 320x240`.
* A culled page is not a failure. The shader walks mips fine to coarse and falls back to the
  region texture array when no page covers a texel, so a culled page simply renders through the
  array path.

## Surface density

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_density_runner.py --driver d3d12
```

Build the debug extension first. `surface_density` (terrain-wide, 1..8 texels per region texel)
makes the stored surface payload finer than the region texture array, which stays at
`region_size` and only ever carries the block-origin reduction. The test pins:

* the two sizes (`region_size * density` squared for the payload, `region_size` squared for the
  array layer), and that the region adopts the terrain's density;
* that the brush writes whole `density²` blocks and leaves blocks outside the brush untouched;
* that a 4 → 1 → 4 density round trip is **byte exact** for block-uniform data, i.e. resampling
  is a nearest block reduction and not a re-derivation from the legacy control map;
* the `add_region()` migration: a `region_size` squared payload with no density (what a file
  written before `surface_density` existed carries) is resampled to the terrain's density on
  entry and keeps its painted material;
* a real region file round trip at density 4: the payload bytes and the stored density both
  survive save → unload → load;
* that mip 0 pages are 1:1 crops of the dense payload at `page_size == span0`;
* the render: with the array path the probe shows the block-origin material, with the virtual
  texture on it shows the finer material, and the two frames differ. That last check is what
  proves the shader evaluates the idweight cell on the payload's grid — before it did, a denser
  payload rendered identically to density 1.

## Far-field sparse virtual texture

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_sparse_runner.py --driver d3d12
```

Build the debug extension first. The far field is a **world-space** page grid that spans regions,
which is the tier the region-aligned near field cannot express (its mip chain is capped at "one
page = one region"). The test pins:

* world addressing: a page is a fixed world square, and a page may span several regions;
* page content texel by texel, border included: a border texel must read the **neighbouring**
  region's payload, not a clamped copy of this page's own edge (a producer property — the shader
  point-samples corners and never reads the border today);
* the world-space mip chain: the page under the target is published at mip 0 while a page 181 m
  away is published at mip 1, and that page holds no mip 0 entry;
* the root pyramid: every texel of the coarsest `surface_svt_root_mips` levels is resident and
  protected, and a page 6.4 km away (far outside the 256 m distance window) resolves through it;
* invalidating a region's pages re-produces them from the payload and restores the frame;
* array-free mode (`surface_array_enabled = false`): the frame stays **pixel identical** to the
  array-backed one, the array layers hold no payload, and an edit still reaches the screen
  because `invalidate_surface_pages()` drops the pages that carry it;
* the safety gate: with both virtual texture tiers off the array must carry the channel again,
  or every texel would render as material 0.

Root pages are protected because they are the fallback of last resort: if one is evicted, a miss
has nothing to show. Size `surface_svt_page_count` for the distance window **plus** the root
pyramid, or the LRU will evict the near pages the test is about to look for.

## AVT material pages and persisted SVT

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_material_runner.py --editor bin/godot.vt-test.exe
```

Runs the actual VT Pass on D3D12: verifies material-cache sampling independently
of source texture bindings, terrain painting/rebaking, adaptive virtual image
resizing, offline SVT mip generation, disk reload and SVT-only rendering.
Use an engine containing the VT callback registry and rebuild the native addon.
The older `vt_surface`, `vt_render`, `vt_sparse`, `vt_density`, `vt_demand` and
`vt_perf` scripts explicitly select the diagnostic raw ID/weight mode to test
that lower-level contract separately.

## Terrain virtual texture addressing contract

```powershell
cd misc/feng-addons/feng-idweight-terrain/native/tests/vt
scons && ./terrain_vt_contract_test.exe
```

Standalone C++ test for `src/terrain_vt.h`, the Hydra-compatible AVT/SVT addressing core.
No engine and no GPU. It pins both address profiles descriptor by descriptor, the 12/12/4/4
bit PageID layout, AVT page resolution, the indirection mip-chain walk, LRU keys, sector LOD
selection, physical page UV/world rect, POT `VirtualImageAtlas` allocation, and the 8x8
feedback dither. See `docs/terrain_vt_and_streaming.md` for the design.

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

## Strict material VT and incremental SVT

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_fallback_runner.py
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_auto_bake_runner.py
```

The strict GPU test checks missing SVT with original materials still present,
valid baked SVT output, and a selected AVT miss above otherwise valid SVT.
The automatic bake test checks 500 ms stroke coalescing, affected region/parent
updates, unchanged distant file hashes, zero idle bakes, and forced full regeneration.
A second process then releases authoring texture resources and verifies that it
uploads the saved SVT pages without generating replacements.
