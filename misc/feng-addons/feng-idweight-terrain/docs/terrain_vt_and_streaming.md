# Terrain addressing and region streaming

The [architecture guide](vt_architecture_review.md) owns the module map and frame flow.
This document defines storage, addressing and residency. Delivery selection and Clipmap
storage are described in [delivery assembly](vt_delivery_assembly.md).

## Region storage

`Terrain3DData` stores regions on a 128×128 grid, coordinates −64…63. New regions use
512 samples at 1 m spacing; loaded files preserve their region dimensions. Region files
are `terrain3d_<x>_<z>.res` in the selected data directory.

The four map families are RF height, control metadata, color and packed R16 Surface Maps.
`surface_density` selects 1/2/4/8 surface texels per region texel. The stored surface edge
is `region_size × density`; the direct GPU array retains a region-sized nearest
block-origin reduction. IDs are discrete data and are never averaged. Density changes
nearest-resample existing Surface Maps; legacy control conversion supplies a map only
when no surface payload exists. Brush/undo storage grows with density squared.

GPU array slots are stable across unrelated region arrivals and departures. Free slots
hold cached blank images; freeing a region releases its former image references. Changed
slots upload one layer per map family and clear their dirty state after upload.
The R32F region directory stores `slot + 1`, with zero for absent regions; the separate
layer-location table uses the same slot indices. Shader lookup clamps directory bounds.
Editor dummy-region previews use their own directory image.

## Region streaming

`Terrain3DStreamer` updates around the clipmap target using Chebyshev-distance load and
unload rings, separate per-update budgets and a resident limit. It unloads only regions
it loaded. Modified-region protection and save-on-unload preserve edits; failed saves
retain ownership/residency. Missing files are cached until `reset_missing()` or a source
reset. Data replacement must reset the streamer's dataset-dependent state.

`unload_region()` releases memory without deleting the file. `remove_region()` represents
an authored deletion and participates in saved deletion state. Region operations use one
map-array update after a batch. The directory remains a bounded world grid.

## Virtual addresses

`native/src/terrain_vt.h` provides engine-independent page coordinates, mip lookup and the
POT `VirtualImageAtlas`. Runtime view objects own virtual addresses; the shared page pool
owns physical residency. Allocation of a virtual block does not allocate its material pages.

| Structure | Layout |
| --- | --- |
| AVT world sector | Fixed 64 × 64 m; virtual resolution selected from projected density |
| Physical page | Default 256² core plus 5 texels on each edge, 266² stored |
| Indirection | R32F slot values with manually authored mip levels |
| Invalid / planned | `65535` = unrequested/invalid; `65534` = planned page not yet resident |
| AVT page table | `min(4096, max(2048, base_block_size * 2))` entries per axis |
| SVT page table | `max(64, page_count * 4)` entries per axis |
| Region directory | R32F region → array-slot lookup, separate from either VT address space |

### AVT

The flat RGBA32F hashed directory stores two texels per sector:
`[key.x, key.y, level, 1]` and `[block_x, block_y, block_size, logical_pages]`.
`avt_find_sector()` uses the same hash/probe contract as the publisher. Fine-sector
queries use directory level 0; local mip belongs to the page table.

Each sector has an aligned POT block with `log2(block_size) + 1` local mip levels.
Logical density can use a non-POT image; allocator padding changes storage, not world
texel size. A block resize preserves compatible page footprints by shifting their local
mips. Failed resize restores the previous allocation and its generation-bearing owner.
Virtual-address pressure applies a common size bias so the visible blocks fit the atlas.

The independent coarse owner has a complete planned grid with a mip chain and reserved
physical pages. A rebuild starts cold and must produce those pages again.
`avt_adaptive_threshold_level = log2(coarse_texel / fine_texel)` selects the upgrade
versus coarse address path. `avt_max_adaptive_level` describes a different quantity:
the coarse grid's structural mip boundary. Upgrade reach and coarse-table extent are
separate bounds.

Near-field demand uses projected pixel footprint, anisotropy and available capacity.
The shader distinguishes planned-but-late entries from levels absent from the plan,
so an intentional capacity coarsening is not a perpetual missing-page error. Fine misses
recover through ready ancestors when `surface_vt_feedback` is enabled; strict tests turn
it off. See [page-table preview](avt_page_table.md) for editor-visible records.

### SVT

For mip-0 world page `page = floor(world / page_world)` and
`half = indirection_size / 2`, the table coordinate is `(page + half) >> mip`.
CPU/shader calculations agree for negative coordinates. A page can cross region borders;
its source texels come from the owning neighboring regions.

`surface_svt_mip_distances` lists each level's farthest distance in metres. An empty table
uses the automatic doubling rule. Visible footprints request every level crossed by a
band. Capacity pressure raises a shared coarseness floor and merges addresses in the
selected mip's canonical coordinates. Protected root levels cover the address domain
within their budget. `surface_svt_feedback` permits recovery to ready coarser mips.

SVT world extent is the table size times mip-0 page-world size; raising density at fixed
page dimensions reduces that extent. Read the editor's bounds and actual resolved mip cap.

## Physical residency and readiness

Both paged fields share slots, LRU and pin counts. After address validation, allocation
and page-table publication run synchronously on the scene thread. Reusing a slot clears
the previous owners' still-matching entries before publishing its new owner. Pinned and
coarse-reserved pages are excluded from eviction; demand epochs protect sampled work.

Mappings and ready content are distinct. A mapped slot can still be queued, encoding or
invalidated. Demand checks producer readiness, retries stale production and verifies the
ready set before using the settled shortcut. Repeated idle plans continue marking demand.
Page-table writes dirty CPU tiles; `commit()` schedules render-thread upload. Initial or
patch-upload failure remains retryable.

Automatic capacity grows toward 1024 slots with overlap headroom. The published capacity
and pool generation are separate from an authored capacity request. The producer publishes
larger resources before the views follow; the wait is bounded to eight frames. Growth
retains address/plan identity where supported while page content may need regeneration.
Replaced bundles stay alive until material-output acknowledgement makes retirement safe.

## Material sources and production

AVT prepares source payloads from immutable resident-region snapshots and evaluates
materials on the render thread. SVT chooses:

1. GPU-resident cell channels, copied/composed by layer and mip
2. Valid persisted `.vtcell` source chunks, loaded/decompressed/cropped on the SVT worker
3. Resident region payloads, prepared for the same GPU material evaluator

A page requires available valid source data, not necessarily an offline bake. Worker
queues are bounded and separate per field; tokens reject cancelled/obsolete results.
The decoded cell-mip cache is 256 MiB / 64 entries with one oversized-entry exception.
The GPU cell store has its own memory/LRU budget. Edits invalidate overlapping source
cells and border neighbors; material/density signatures prevent stale reuse. World-region
invalidation scans physical resident owners, so its work is bounded by residency rather
than the full virtual page domain, while preserving the coarse-page border margin.

Cell files contain versioned metadata, a preview and indexed Zstandard channel/mip chunks.
Writes use a temporary file plus rename. A default 512 m cell at 1 texel/m produces three
512² RGBA16F source images and complete mips; resolution is capped at 8192 per axis.
Physical page border/size changes preserve source validity. `.vtpage` data requires a
rebake to `.vtcell`. Auto Bake waits 500 ms after editing; explicit Bake refreshes all
cells. Saving terrain does not save a new offline bake automatically during editor preview.

The page producer is the registered FRP VT callback on the main RenderingDevice.
Queued GPU work respects the live page allowance even with repeated callbacks in a frame.
CPU phase budgets are soft. Render-thread ownership and source queue lifetime are defined
in the architecture guide; engine hooks are in [engine_patch_surface.md](engine_patch_surface.md).

## Material layout and compression

Canonical material pages contain albedo/height, signed world-normal/roughness and parameters
(normal depth, AO, AO affect, validity). Baking uses source-corner triangle weights with
output-page texture footprints. Height geometry remains RF and separate from material height.
Packed R16 IDs and table entries use nearest reads; material channels use their filter rules.

Each paged tier selects Uncompressed, BC7 or BC3. Albedo uses sRGB block storage; other
channels remain linear. Compressed world normals use full-sphere octahedral encoding,
RG for BC7 and AG for BC3. The source texture-array codec setting is independent.
Legacy aliases remain loadable; new scenes serialize the unified tier setting.

The GPU encoder writes blocks to a bounded ring. The optional engine buffer-copy method
stores them directly with render-graph dependencies; otherwise asynchronous readback queues
an upload for a valid render callback. A ring position remains owned until its consumer
finishes. Tier metadata, sampled RIDs and readiness publish together.
Read `*_compression_available`, `*_compression_applied`, refusal reasons,
`encode_readbacks`, ring occupancy and actual material bytes to identify the active path.
See [compression contracts and historical results](vt_compression_review.md).

## Geometry and explicit direct rendering

Mesh clipmap and optional CDLOD control geometry independently from material delivery.
CDLOD is a quadtree/MultiMesh backend with vertex morphing and separate visible/shadow
classification; [cdlod_and_capture.md](cdlod_and_capture.md) defines its supported range.

All-Direct delivery and editor preview evaluate author materials. Built-in shader variants
include only selected delivery resources; custom overrides retain their interface.
`surface_array_enabled=false` skips payload upload only when the selected paths can supply
it. Legacy raw-ID diagnostic modes are tested separately from the production baked-material
cache. This distinction matters when interpreting missing-page or image-equality assertions.

## Verification

Run the following from the repository root; the standalone build changes directory, so
return to the root before the Python runners:

```powershell
# VT addressing contract (standalone, no engine)
cd misc/feng-addons/feng-idweight-terrain/native/tests/vt
scons && ./terrain_vt_contract_test.exe

# Region streaming and layer slots (graphical driver required)
python misc/feng-addons/feng-idweight-terrain/native/tests/region_streaming_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/region_slots_runner.py --driver d3d12

# Near field: runtime, page production, shader integration and per-page demand
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_runtime_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_surface_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_render_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_feedback_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_demand_runner.py --driver d3d12

# Far field: world grid, distance bands, root pyramid, array-free rendering
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_sparse_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_mip_bands_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_root_budget_runner.py --driver d3d12

# Atlas compression: codec resolution, refusal reasons and the applied format
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_compression_runner.py --driver d3d12

# Surface density: dense payload, coarse array, migration and the render grid
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_density_runner.py --driver d3d12

# Geometry, adaptive allocation and pool pressure
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_adaptive_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_adaptive_runner.py --cdlod --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_pressure_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_visibility_runner.py --driver d3d12

# Existing terrain regressions
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test pairroles --driver d3d12
```

The full inventory, fixture rules, material-cache tests and editor checks are in
[native/tests/README.md](../native/tests/README.md). Historical suite pass counts and
failures in the design/audit records describe those builds only. Current acceptance
requires rebuilt binaries and the relevant CPU, GPU and editor gates.
