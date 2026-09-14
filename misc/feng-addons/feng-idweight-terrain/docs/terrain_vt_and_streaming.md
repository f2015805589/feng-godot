# Hydra terrain VT + chunk streaming → Godot port

**Current implementation:** Surface VT has shared physical residency and settings,
GPU material baking with adaptive AVT allocation, and persisted SVT material pages.
The historical Hydra analysis below describes the reference architecture; see
[current architecture](vt_architecture_review.md) for the Godot implementation.

Read of Hydra's terrain stack (`D:\hydra\hydra-unity`, Unity 2022.3.59f1) and the plan for
bringing the parts we need into `feng-idweight-terrain`. Written after reading the sources
listed at the bottom; every Hydra number below has a `file:line` behind it.

## 1. Hydra has three separate systems, not one

| System | Job | Key files |
|---|---|---|
| **CDLOD** | Geometry quadtree + height-page streaming + GPU vertex morphing | `ZRP/Runtime/TerrainCdlod/*`, `ZTerrain/Runtime/Height/TerrainCdlodHeightStore.cs`, `Terrain/Shaders/Terrain/TerrainCdlod.hlsl` |
| **AVT** | Near-field adaptive virtual texture, pages baked on the GPU per 64 m sector | `ZRP/Runtime/TerrainVT/TerrainAVT*`, `TerrainVT/AVT/TerrainAVTFunctions.hlsl` |
| **SVT** | Far-field sparse virtual texture, pages composited from per-cell baked sector textures | `ZRP/Runtime/TerrainVT/TerrainSvtAddressing.cs`, `ZTerrain/Runtime/Asset/TerrainSvtPageManifestAsset.cs` |

They share the world cell grid but have **separate LOD trackers and separate streaming
centres**. Don't port them as one thing.

Two negative findings worth stating up front, because they change the shape of a port:

* **There is no disk page store for AVT pages.** `TerrainAVTPageStorage.cs` is GPU storage.
  AVT pages are baked on demand from already-loaded cell data; SVT dynamic pages are GPU
  copies of per-cell baked sector textures. The only thing resembling "streaming" is the
  async cell/pack load in `ZTerrain`, plus `TerrainSvtFallbackPageBaker` which is
  **editor-only** and bakes 5 fallback pages into a manifest asset.
* **`TerrainVTLodTracker` is not the AVT mip selector.** It drives the height/hole clipmap
  only; for AVT it is called with `centerSize: 0` and its color output is ignored
  (`TerrainVTPass.cs:913-935`). AVT mip selection is screen-space anisotropic LOD computed
  in the shader (`TerrainAVTFunctions.hlsl:217-226`).

## 2. Constants that define the addressing contract

Ported verbatim into `native/src/terrain_vt.h` (`TerrainVT` namespace).

| Constant | Value | Hydra source |
|---|---|---|
| Sector size | 64 m | `TerrainAVTConstants.cs:5` |
| Page content / border / stored | 256 / 4 / **264** | `:7-9` |
| PageID texture downscale | 8 | `:12` |
| Indirection texture | 1024×1024, **R16_UInt**, 11 mips, autoGen off | `:16`, `:25`; `TerrainAVTIndirectionTexture.cs:135-144` |
| Invalid physical slot | 65535 | `:18` |
| AVT global mips | 0..8 | `:19` |
| SVT start global mip | 9 | `:20` |
| Indirection writes / frame | 64 | `:23` |
| Indirection writes / page | 4 | `:24` |
| Fallback pages | 5 (4 + 1) | `:26` |
| Sector preload distance | 6 → 7×7 = 49 sectors | `:30`; `TerrainAVTRuntime.cs:998-1014` |
| Camera move threshold | 2 m (squared 4) | `:31` |
| `SwitchDistance` | 64·64·1.5 = **6144** | `:38` |
| Descriptor slots | 16 (0 invalid, 1–7 AVT, 15 SVT) | `TerrainAVTAddressProfile.cs:131-139` |

### Packed PageID (feedback texel, `R32_UInt`)

```
packed = ((x & 0xFFF) << 20) | ((y & 0xFFF) << 8) | ((mip & 0xF) << 4) | (sizeIndex & 0xF)
```
`TerrainAVTUtility.cs:144-159`, mirrored bit-for-bit in `TerrainAVTFunctions.hlsl:82-99`.
`0` is the canonical "no request".

### Indirection texel (`R16_UInt`)

Low **11 bits** = physical page slot; `65535` = invalid. No mip field, no valid flag — the
matched mip is *which indirection mip the lookup succeeded at*.

### Sector image info (packed `uint32`, different layout)

```
packed = ((offsetX & 0xFFF) << 20) | ((offsetY & 0xFFF) << 8) | (sizeIndex & 0xFF)
```
Note the **full low byte** for `sizeIndex`, unlike PageID's nibble.

### Address profile descriptor formula

```
minGlobalMip        = sizeIndex - 1
resolutionTexels    = (64 * baseTexelsPerMeter) >> minGlobalMip
mip0PageCount       = ceil(resolutionTexels / 256)
allocationBlockSize = nextPow2(mip0PageCount)
maxLocalMip         = 8 - minGlobalMip
```

| Base800 (8/4/2 texel·cm⁻¹ | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| resolutionTexels | 51200 | 25600 | 12800 | 6400 | 3200 | 1600 | 800 |
| mip0PageCount | 200 | 100 | 50 | 25 | 13 | 7 | 4 |
| allocationBlockSize | 256 | 128 | 64 | 32 | 16 | 8 | 4 |
| maxLocalMip | 8 | 7 | 6 | 5 | 4 | 3 | 2 |

Base1024 (10.24 texel·cm⁻¹ is the clean power-of-two chain: 65536/256/256 — 1024/4/4.

Density preset → `(profile, finestSizeIndex)`: 2 → (Base800, 3), 4 → (Base800, 2),
8 → (Base800, 1), 10.24 → (Base1024, 1).

### The capacity cliff (important, and Hydra has it too)

`TerrainVirtualImageAtlas` is a POT quadtree over the 1024×1024 **page space**, minimum
block 4 pages. A `B×B` block therefore admits only `(1024/B)²` resident sectors:

| density | block | resident sectors |
|---|---|---|
| 10.24 texel/cm | 256 | **16** |
| 8 texel/cm | 256 | 16 |
| 4 texel/cm | 64 | 256 |
| 2 texel/cm | 64 | 256 |

Hydra requests a 7×7 = 49 sector grid regardless, so at the default density most
`TryInsertAvtImage` calls fail (`TerrainAVTRuntime.cs:1345-1354`). This looks like a real
capacity cliff, not an intentional design. A Godot port must either pick a density whose
block fits the preload radius, or add an LRU over virtual-image allocations. **Decide this
deliberately; don't inherit it.**

## 3. What the Godot addon already has

Written as of the state *before* this work; see section 4 for what changed.

| Concern | Status |
|---|---|
| Chunking | `Terrain3D::region_size` (64–2048, default 256) on a fixed **32×32 region grid** (`REGION_MAP_SIZE`, valid −16..15). Regions are the storage chunk *and* the texture-array layer. |
| Mesh LOD | Clipmap ring (`Terrain3DMesher`, `mesh_size` 48 + `mesh_lods` 7), snapped to the clipmap target. **Not** a CDLOD quadtree. Geometry is shader vertex displacement over instanced tiles, so there is **no per-chunk draw call** — chunking only affects data residency. |
| Region files | `terrain3d_{x}_{y}.res` in the data directory; `save_directory` / `load_directory` / `load_region` are synchronous. |
| GPU maps | Per-region `Image` → 4 `Texture2DArray`s (height, control/idweight R16, color, surface) rebuilt wholesale by `update_maps()` whenever the region set changes. |
| Streaming | **None.** No runtime load/unload around a moving centre. |
| Virtual texturing | **None.** Textures are a resident array indexed by the idweight control map. |

Two numbers make the chunking limits concrete at the default `region_size` 256:

* The clipmap's outermost ring reaches `2 × mesh_size 48 × 2⁶ = 6144 m`, but the 32×32 grid
  only reaches ±16 × 256 = **±4096 m**. The world could not fill its own clipmap.
* A region's maps are `region_size²`, so the surface/control maps are **1 texel/m**.
  Detail density is welded to chunk size: going finer means bigger chunks, which costs
  memory per region *and* coarsens streaming granularity.

## 4. Gap analysis → what to build

### 4.1 Region streaming — implemented now

`Terrain3DStreamer` (`native/src/terrain_3d_streamer.{h,cpp}`), owned by `Terrain3D` and
driven from `__physics_process` around the clipmap target:

* Square ring of `load_radius` regions around the centre; unload beyond `unload_radius`
  (hysteresis), both in Chebyshev distance.
* Per-update budgets `loads_per_update` / `unloads_per_update`; one `update_maps()` per
  update at most, and only when something actually changed.
* Only unloads regions **it** loaded (`_streamed`); user-authored regions are never taken
  away.
* `protect_modified` keeps edited regions resident; `save_on_unload` writes them first.
* Absent files are remembered in a `_missing` cache so they are probed once, not per frame;
  `reset_missing()` forces a re-probe.
* `max_resident` is a hard cap.
* New `Terrain3DData::unload_region(loc)` frees a region **without** marking it deleted or
  touching its file — `remove_region()` cannot be used for streaming because it sets the
  deleted flag and `save_region()` would then delete the file.

Tests: `native/tests/region_streaming.gd` +
`native/tests/region_streaming_runner.py` (ring, budgets, move, missing cache, modified
protection, save-on-unload, file preservation, bounds, data rebuild).

**Pre-existing crash fixed on the way:** `Terrain3DData::initialize()` set `_region_size`
*after* `load_directory()`, so loading a populated data directory at startup sized the blank
surface layer from 0 and crashed. `Terrain3D::set_region_size()` cannot repair it because it
short-circuits when the terrain's region size already matches the file. Streaming from a
data directory needs this, so the assignment moved above the load.

### 4.2 Stable region→ layer slots — implemented now

The first version of streaming rebuilt all four `Texture2DArray`s on every resident-set
change, because `region_id` *was* the index of the region inside `_region_locations`: adding
or removing anything renumbered every later region. At `region_size` 256 that is about 1 MB
per region of re-upload plus a fresh VRAM allocation, per streamed step.

Each resident region now owns a **slot**: a stable layer index that is only reused after the
region leaves memory.

* `_slot_locations[slot]` → region location (`V2I_MAX` when free); `_region_slots[loc]` →  slot; `_free_slots` is the reuse list.
* `_region_map` stores `slot + 1` exactly where it used to store `region_id + 1`, so the
  shader is unchanged — it still indexes the arrays with `_region_map[...] - 1`.
* The shader's `_region_locations` uniform (a layer → location table, used by
  `get_index_uv`) is now fed from `get_slot_locations()`, not from the dense region list.
  That was the one place the shader depended on layer indices being dense.
* `get_region_id()` validates the slot table instead of trusting `_region_map`, so
  `has_region()` is correct immediately after `add_region()`/`unload_region()` rather than
  waiting for the next `update_maps()`. The streamer's workaround for that lag is gone.
* Capacity doubles from 4 and never shrinks, so steady streaming stops reallocating. It must
  stay within the material's `max_regions` (64..1024) because the shader rejects layer
  indices at or above `MAX_REGIONS`.
* `_region_map_dirty` now means "recompute the whole map and slot table" (bulk paths:
  `load_directory`, `change_region_size`, `set_region_locations`) and is separate from
  `_region_map_signal_dirty`, which just tells listeners the map moved.
* `update_maps()` uploads only the slots whose `_slot_dirty` bits are set, per map type.
  `p_all_regions = true` no longer throws the arrays away; it forces a re-upload of every
  resident slot for the requested maps, which is what "assume everything changed" needs.
  `GeneratedTexture::ensure_layers()` recreates the array only when the capacity, layer size
  or format actually changes.
* `get_map_stats()` / `reset_map_stats()` expose `map_create_count` (GPU array allocations)
  versus `map_update_count` (single layer uploads) so the property is testable.

Tests: `native/tests/region_slots.gd` + `native/tests/region_slots_runner.py`. It renders a
2×2 grid of 64 m regions each painted with its own material, unloads one and adds another,
and re-renders: the rendered colours prove the region map, the four arrays and the layer → location table still agree, and the stats prove the swap cost zero array allocations.

Three things bit during implementation and are easy to reintroduce:

* Growing the slot table must push the **new** slots onto the free list. The first version
  allocated `_slot_capacity` directly and only then grew, so every allocation landed above
  the old capacity and the table doubled per region — 4 regions reserved 32 slots.
  `region_slots.gd` now asserts the capacity stays within 2× the resident count.
* A free slot's entry in `_height_maps` / `_control_maps` / `_color_maps` / `_surface_maps`
  must be a real image, not null, because callers iterate those arrays (the editor setup
  test does). It must also be reset to the blank when the slot is freed, otherwise the
  unloaded region's images stay referenced and streaming frees no CPU memory.
* The blank layer is cached per map type. Building it is a full region-sized image fill, so
  rebuilding it on every `update_maps()` call is a real cost on every paint step.
* **`_slot_dirty` must be cleared per slot after the layer is uploaded.** The first version
  only cleared the bits on a full sync, so a slot stayed dirty forever and every later sync
  re-uploaded every resident layer — a settled 3×3 ring re-uploaded 36 layers per step
  instead of 4. `region_streaming.gd` now asserts a five-region ring step costs exactly
  20 uploads (5 regions × 4 maps) and `region_slots.gd` asserts a one-region swap costs 4.
  Both also assert `map_create_count == 0`. These counters, not a stopwatch, are what make
  the property testable.

### 4.3 Chunk directory texture — implemented now

The shader used to read the chunk → layer map from `uniform int _region_map[1024]`, which
capped the world at 32×32 chunks. A bigger uniform array is not an option: 64×64 would be
16 KB and 128×128 64 KB, against a guaranteed uniform buffer size of 16 KB. So the map is
now a **texture**:

* `Terrain3DData::REGION_MAP_SIZE` is **128** (valid −64..63), i.e. a 32.8 km square world at
  the default 256 m chunks. The bounds test in `get_region_map_index()` derives its mask from
  the constant instead of the hard-coded `~0x1F`.
* The directory is `REGION_MAP_SIZE²` **R32F**, holding `slot + 1` as a float with `0.0` for
  "no region", so the decode `int(texelFetch(...).r + 0.5)` reproduces the old int array
  values exactly. Negative values are still the editor's "dummy region" preview encoding.
* `Terrain3DData::_set_directory_entry()` patches one texel when a region enters or leaves
  memory; `_rebuild_region_directory()` rebuilds the whole image for bulk paths. The texture
  is created once and then updated in place, so a region swap uploads 64 KB instead of
  reallocating.
* The shader reads it through one helper, `get_region_layer(ivec2 chunk)`, defined in
  `main.glsl`, `displacement_buffer.glsl` and the `extras/` example shaders. It clamps the
  coordinate before `texelFetch` (an out of range fetch is undefined) and keeps the exact
  `is_region` / `is_dummy` / `-1` semantics of the old lookup.
* `_region_locations` was already a layer → location table; it is now fed from
  `get_slot_locations()` everywhere, including the particle example, which used to pass the
  dense region list.
* The editor region-tool preview writes a negative dummy slot for the hovered chunk. That
  needs its own texture, so `ui.gd` builds one through the new bound
  `Terrain3DData::region_map_to_image()` and reuses it; when no preview is active it binds
  the live directory RID directly instead of rebuilding a copy.

Note the side effect: `Terrain3DMaterial::_update_uniforms()` no longer copies a
`REGION_MAP_SIZE²` `PackedInt32Array` on every uniform update — at 128×128 that would have
been a 64 KB copy per update.

**Not done:** the directory is a straight 128×128 window with no wrapping, so the world is
bounded at ±64 chunks. A wrapping directory that follows the camera would make it unbounded,
but it also means two far-apart chunks cannot be resident at once, which is a real design
change rather than a size bump.

Tests: the far-chunk phase of `native/tests/region_slots.gd` places a region at (40, −40) — impossible before — and asserts it renders; `region_streaming.gd` asserts the grid now accepts
(20, 0) and (0, −20) while rejecting one chunk past the edge.

### 4.4 VT addressing core — implemented now

`native/src/terrain_vt.h` is a dependency-free port of the addressing contract. It was
originally a near-complete port of Hydra's constant and descriptor tables; the parts
production never used — the `AddressProfile` descriptor tables and their
`TexelDensityPreset` selection, the `PackPageId`/`UnpackPageId`/`TryResolveAvtPageAddress`
helpers, the LRU key encoding, the physical-page UV/world-rect math and the feedback
sizing/Bayer dither — have been deleted. What is left is what the runtime actually calls:

* the indirection payload constants (`SLOT_MASK`, `INVALID_PHYSICAL_PAGE_SLOT`) and the
  power-of-two rule (`AddressProfile::is_power_of_two`);
* `PageId`, the local page coordinate + local mip + descriptor slot tuple;
* `try_match_indirection_slot`, the indirection mip-chain walk;
* `VirtualImageKind` / `VirtualImageOwner` / `ImageInfo` and `VirtualImageAtlas`, the POT
  quadtree allocator over the indirection page space.

The allocator only ever allocates AVT blocks in low coordinates: SVT addresses a fixed
world grid and never asks for a block, so the high-coordinate-first allocation order and
its traversal branch are gone too.

Tests: `native/tests/vt/terrain_vt_contract_test.cpp` (`scons` in that directory) covers the
mip-chain walk, POT allocation/non-overlap/resize-rollback and the full 65,536-leaf atlas.

### 4.5 VT runtime skeleton — implemented now

`Terrain3DVirtualTexture` (`native/src/terrain_3d_virtual_texture.{h,cpp}`) is the physical
page atlas, the indirection texture and the slot allocator, built directly on the
contract-tested core in `terrain_vt.h`. It owns no terrain data, so it is constructible and
testable on its own.

* **Sectors.** `register_sector(loc, block_size)` hands a region a power-of-two block of
  virtual pages through `TerrainVT::VirtualImageAtlas`, so blocks never overlap and AVT
  clusters in the low coordinates. Re-registering the same size is idempotent; a different
  size is refused rather than silently allocating a second block.
* **Indirection.** One `R32F` texture, `indirection_size` squared at mip 0, holding the
  physical slot or `65535`. The mip chain is built **by hand** — `generate_mipmaps()` would
  average slot indices, which is meaningless; a coarser texel has to hold a real slot or the
  invalid marker. The whole chain lives in one `PackedByteArray` laid out exactly as
  `Image::create_from_data` expects, and that array is the single source of truth for both
  the CPU mirror and the uploaded image.
* **Lookup.** `lookup_page()` resolves a sector-local page by walking mips coarse-ward with
  `TerrainVT::try_match_indirection_slot`, so a coarse page legitimately serves the finer
  pages it covers. Pages outside the sector's block do not resolve at all.
* **Physical atlas.** A `Texture2DArray` of `page_count` layers, each
  `page_size + 2 * page_border` texels, defaulting to R16 because that is what the packed
  id/weight surface map uses. `write_page()`/`read_page()` are the page producer's interface.
* **Slot allocator.** LRU with a protected set. Eviction invalidates exactly the indirection
  entries that still publish the slot, using a per-slot reverse index — Hydra's rule, and it
  is what stops a stale reverse entry from clobbering an entry a later allocation already
  republished. A fully protected atlas fails the allocation instead of stealing a page.
* **Batching.** `request_page()` only marks the chain dirty; `commit()` uploads it. The test
  asserts `commit()` is a no-op when nothing changed.

Tests: `native/tests/vt_runtime.gd` + `native/tests/vt_runtime_runner.py`. Everything is
checked against **GPU readback**, not just the CPU mirror: the indirection texel that a
request published, the invalidation after an eviction, and a full page-content round trip
through the atlas. It also pins the mip-chain walk, block disjointness, LRU order, protection
and that `unregister_sector` actually frees the block.

Two things bit here and are worth remembering:

* `VirtualImageOwner` carries a `generation` counter, so `unregister_sector` has to present
  the owner the atlas *created*. A hand-rebuilt owner with `generation = 0` never matches and
  removal silently fails. The runtime now stores the owner it was given.
* Indirection writes are batched, so anything inspecting the GPU state has to `commit()`
  first. Reading the texture before the commit is a test bug, not a runtime one.

### 4.6 Surface page production — implemented now

`Terrain3D::update_surface_vt()` is the demand pass, and `Terrain3DData::produce_surface_page_set()`
is the producer. It owns a `Terrain3DVirtualTexture` (`terrain.surface_vt`, off by default):

* **Demand.** For every resident region within `surface_vt_distance` of the clipmap target, the
  sector is registered with a `surface_vt_pages_per_axis` block and a local mip is chosen per mip 0
  page: from the distance rule by default (a mip 0 page covers `region_size / pages_per_axis`
  metres, and each doubling of that threshold steps one mip), or from the GPU feedback pass when
  `surface_vt_feedback_enabled` is on (4.8). `surface_vt_force_mip` overrides both so a test can
  ask for an exact level.
* **Production.** Only the pages that this pass actually *allocated* are filled — a hit already
  holds content, and rewriting every page per tick would swamp the atlas uploads. The producer
  reads the region's R16 surface map once and resamples it into every page of the mip, nearest,
  with the border replicating the region edge so a bilinear tap at a page seam cannot pull in a
  neighbour's data.
* **Layout.** The block is `pages_per_axis` pages per axis at local mip 0, so mip `m` has
  `max(1, pages >> m)` pages per axis covering `region_size / pages_at_mip` region texels each.
  The sampling is therefore correct whether a page carries the region's texels 1:1 or at a
  different density.

Tests: `native/tests/vt_surface.gd` + `native/tests/vt_surface_runner.py`. Every page is read
back from the GPU atlas and compared **texel by texel** against an independently restated
version of the crop rule, at mip 0 (a 1:1 crop) and mip 1 (a 2× downsample), including the
clamped border. It also pins the distance rule (nearest sector publishes a mip 0 page, sectors
64 m away publish mip 1 and no mip 0) and that a settled pass writes no pages and does not
re-upload the indirection.

**Resolution: `surface_density` — implemented.** The source used to be `region_size²` R16, i.e.
**1 texel/m** at the default 256 m region, so a page smaller than the region only *upsampled*:
at Hydra's ratio (64 m pages, 256 texel pages) a 4× point upsample that added no detail. The
producer was resolution-agnostic, so raising the region's surface resolution is what turns this
from "a correct paging layer" into "more detail than the array can afford to keep resident".

`Terrain3D::surface_density` (1..8 texels per region texel, default 1) now sets it. It is a
**terrain-wide** setting, and three rules keep it from becoming a regression:

* **Terrain-wide, not per region.** The region texture array is one texture whose layers must
  all be the same size, so regions cannot disagree. `Terrain3DData::change_surface_density()`
  resamples every resident payload and re-uploads only the surface layers.
* **The array stays at `region_size`.** `Terrain3DRegion::get_surface_map_array_image()` returns
  a nearest `region_size²` reduction of the stored payload (block origin, never an average: the
  payload is packed material IDs, not numbers). Growing the array with the density would
  multiply resident VRAM by `density²` — 128 KB → 2 MB per region at density 4 — which is the
  cost the virtual texture exists to avoid.
* **Migration resamples; it never re-derives.** `ensure_surface_map()` resamples an existing
  payload to the new size and only falls back to the legacy control map conversion when there is
  no payload at all. A region file written before `surface_density` existed loads with density 1
  and no key, and `add_region()` adopts the terrain's density through
  `ensure_surface_density()`. Re-running the conversion there would wipe every painted material,
  because after migration the control map no longer carries the material bits.

Two costs to know about: `Terrain3DEditor::backup_region()` deep-copies the payload for undo, so
a brush snapshot grows from 128 KB to 2 MB per region at density 4 (32 MB at region_size 1024);
and the brush writes whole `density²` blocks, because it authors one region texel per step.

**The shader had to move to the same grid.** The idweight cell used to be evaluated on the mesh's
1 m grid (`floor(uv)`/`fract(uv)`), so a denser payload was unreachable: every corner read its
block origin and the render was identical to density 1. With the virtual texture on, the cell is
now evaluated on the payload's own grid (`fract(uv * density)` and `get_surface_texel()`). At
density 1 that is bit-for-bit the old behaviour, and a denser payload is the same Hydra contract
on a dyadically subdivided cell — the fixed BL-TR diagonal survives dyadic subdivision, so the
triangle selection stays consistent with the clipmap mesh. With the virtual texture **off** the
cell keeps the 1 m grid, so the array path renders exactly as it did before.

Tests: `native/tests/vt_density.gd` + `vt_density_runner.py`. It pins the two sizes, the brush's
block writes, a byte-exact 4 → 1 → 4 round trip, the `add_region()` migration of a legacy
payload, a real region file round trip at density 4 (payload bytes and stored density both
survive save → unload → load), mip 0 pages as 1:1 crops of the dense payload, and a render where
the array path shows the block-origin material while the virtual texture shows the finer one.

### 4.7 Surface VT shader integration — implemented now

`surface_vt_enabled` (off by default) switches the terrain fragment shader's surface id/weight
reads from the region texture array to the virtual texture, with the array as the fallback.

* The shader resolves the sector from the chunk it already computed, and gets its virtual page
  block from `_surface_vt_blocks[MAX_REGIONS]`, a layer-slot indexed table the CPU rebuilds
  each demand pass. No separate sector lookup is needed: the chunk directory already returned
  the layer slot.
* `surface_vt_sample()` walks the indirection mip chain from local mip 0 upward and takes the
  first resident page, mirroring the CPU lookup, so a coarse page serves the finer texels it
  covers. It uses `textureLod` with a dynamic level rather than `texelFetch`, because Godot's
  shader language requires a constant level there.
* The page texel is `offset * page_size / span + border` where `span = span0 << mip` and
  `page_origin = ((coord << mip) - block) * span0` — algebraically the same rule
  `produce_surface_pages()` uses, which is what makes the two paths agree texel for texel.
* Godot's shader language does not allow `const` initialized from a uniform ("Expected constant
  expression"), so the derived values are plain locals.
* `set_surface_vt_enabled()` pushes the material uniforms itself. Without that the material keeps
  sampling the atlas after the toggle is turned off.

Tests: `native/tests/vt_render.gd` + `native/tests/vt_render_runner.py`. It renders the same
scene three ways: array path, virtual texture on, and virtual texture on with the four pages
covering the probe point blanked. The first two must be **pixel identical**, which is what
catches any addressing slip in the indirection walk, the page grid or the border; the third
must change the rendered colour, which is what proves the shader is reading the physical atlas
rather than silently falling back to the array. Turning the toggle back off must restore the
array path unchanged. PNGs of all three frames land in the fixture directory.

**Remember:** `shaders/*.glsl` are `#include`d into the extension's C++ sources, so editing a
shader needs a rebuild before the test can see it.

### 4.8 GPU page demand (feedback) — implemented now, and wired into the demand pass

`Terrain3DVTFeedback` (`native/src/terrain_3d_vt_feedback.{h,cpp}`) runs a compute pass that
projects every candidate page, measures its screen extent and writes the local mip that would
put roughly one page texel on one screen pixel — or a rejection code when the page is behind
the camera, off screen or smaller than a threshold. This is what replaces the CPU distance
rule's blind spots: it does not know the field of view, the resolution, the viewing angle, or
what is off screen, and it cannot cull.

* **Mechanism.** A local `RenderingServer::create_local_rendering_device()`, so it cannot
  disturb the main renderer's frame. GLSL is compiled to SPIR-V at runtime with
  `shader_compile_spirv_from_source` (glslang ships whenever d3d12/vulkan/metal is enabled).
  The output is an **`R32_UINT`** storage image, one texel per candidate page.
* **Async readback.** `texture_get_data_async` with a callback, decoded into a mip per cell.
  The result is one frame behind the dispatch, which is the usual feedback latency.
* **Diagnostic sentinels.** The shader writes distinct values for each early-out
  (`0xFFFFFFFE` behind, `0xFFFFFFFD` off screen, `0xFFFFFFFC` too small), and the test
  histograms them. That is what turned "nothing was requested" into "the dispatch is not
  writing at all" and then into the exact ordering bug below.

Tests: `native/tests/vt_feedback.gd` + `native/tests/vt_feedback_runner.py`. All 9216 cells of
a 96x96 page grid are compared against an independently restated version of the rule computed
in GDScript, which pins the projection, the off-screen cull and the mip maths together. It also
checks that the readback is genuinely deferred, and that a camera pointing away requests
nothing.

Four things bit here, and the first two are the reason this took a whole round:

* **Order matters: record everything, then submit once.** `texture_get_data_async` registers
  the texture copy as a *draw graph node*, and a node only runs in `_execute_frame`. Calling
  `submit()` in `dispatch()` ends the graph before the copy is added, so the copy never runs and
  the readback silently returns a zeroed staging buffer. `dispatch()` now only records; `sync()`
  does one `submit()` + `sync()` covering both the compute and the copy.
* **A local device has no frame advance of its own.** `submit()` does not call `_begin_frame`;
  only `swap_buffers()` does, and that is main-device only. `sync()` is the only place the
  download is transferred and the callback fires, so the flow is
  `dispatch() -> request_readback() -> sync()`.
* **No `#[compute]` marker when compiling from source.** That directive is for Godot's RD shader
  *importer*; glslang rejects it as an invalid directive when the stage is passed explicitly.
* **The rejection sentinels are the smallest of the reserved values**, so a decode that tests
  `packed >= REJECT_BEHIND` lets `REJECT_OFFSCREEN` and `REJECT_TOO_SMALL` fall through as
  "mip -4". The check has to be against `REJECT_TOO_SMALL`.

**Not done, and why.** The objective for this step also named Bayer sub-pixel selection, which
is a property of *fragment* feedback: Hydra's terrain pass writes one packed PageID for one
sub-pixel per 8x8 block into an `R32_UInt` target. Godot's `RenderingServer` exposes no MRT hook
for a scene shader and no integer viewport format, so a faithful fragment pass needs a **second
terrain draw** (a second `Terrain3DMesher` on its own render layer, a `SubViewport`, and a
`main.glsl` variant that outputs the page id) plus packing the 32-bit payload into an RGBA8
viewport. What fragment feedback would add over this pass is occlusion and exact rendered
coverage; for a clipmap ring whose visible set is analytic, the projected demand is within a
hair of it, which is why the projection pass is where the value is here.

**Consumption — implemented.** `Terrain3D::update_surface_vt()` calls
`_update_surface_vt_feedback(target)` and then resolves a mip **per mip 0 page** with
`_surface_vt_mip_for_page()`, replacing the per-sector distance rule. Settings:
`surface_vt_feedback_enabled` (default off), `surface_vt_feedback_interval` (default 4 — the
readback stalls the frame, so this amortises it and the pass keeps using the last result in
between), `surface_vt_feedback_grid_chunks` (default 8, the window is `grid_chunks * pages_per_axis`
pages per axis centred on the camera's chunk) and `surface_vt_feedback_min_extent` (default 8 px).
`get_surface_vt_feedback()` exposes the pass for stats and debugging.

The request set is built in three steps, and the middle one is the part that is easy to get
wrong:

1. Resolve every mip 0 page of the sector to a level (or `-1` for culled).
2. **Exactly one level per mip 0 page.** For each level `m`, request the level `m` page covering
   each mip 0 page that resolved to `m`. The tempting rule — "a mip 0 page wanting level `L` also
   needs every ancestor" — is wrong here, because the shader walks mips *fine to coarse* and
   takes the first hit, so a page resolved to `L` is already served by the level `L` page. The
   ancestor rule multiplies the request count by the level count and re-produces pages every
   pass.
3. Produce only the pages that were actually allocated (`request_page_internal`'s `was_miss`),
   through `Terrain3DData::produce_surface_page_set()`, which takes a mixed `(page_x, page_y,
   local_mip)` request list and returns the pages in request order.

A culled page is not a failure: the shader falls back to the region texture array when no page
covers a texel, so a culled page renders through the array path.

Tests: `native/tests/vt_demand.gd` + `native/tests/vt_demand_runner.py`, which drive
`update_surface_vt()` with the feedback on and compare the resident set page by page through the
indirection texture, including a sector behind the camera that a distance rule would have kept.
`vt_feedback.gd` remains the shader-only test: it passes the viewport size as a *parameter*, so it
is independent of the real window size, while the runtime reads the camera's real viewport.

### 4.9 VT GPU pipeline — what is left

Hydra's own pipeline, for reference — the port took a different route on every item, and the
difference is what the addon is:

1. **Feedback.** Hydra: `R32_UInt` target at `(refW/8+1) × (refH/8+1)`; the terrain fragment
   shader writes `PackPageId` for the one sub-pixel per 8×8 block selected by the rotating Bayer
   index, and `0` elsewhere. Port: **the projection pass** (4.8), consumed by the demand pass.
   The fragment version is the remaining gap and only buys occlusion and exact coverage.
2. **Indirection.** Hydra: 1024×1024 `R16_UInt`, 11 mips, written per-mip with a compute scatter
   (sorted by `(mip, y, x)`, one dispatch per contiguous mip run) or a 1×1-quad raster fallback.
   Port: `R32F` with a **hand-built** mip chain on the CPU, written per page as it is allocated
   (4.5) — no compute scatter, because the demand pass already knows every page it wants.
3. **Physical page atlas.** Hydra: `264×264` pages, compressed `Texture2DArray` (BC3 on Windows,
   ASTC on mobile) with an `R32G32B32A32_UInt` block-RT encoder, RGBA8 fallback. Port: an
   uncompressed `Texture2DArray` of `page_size + 2·border`, LRU with a protected set and
   reserve/commit/rollback (4.5); eviction invalidates the indirection texel only if the
   published slot still matches.
4. **Page production.** Hydra: compute bake from the loaded cell's surface data, or the raster
   MRT fallback, budgeted at `renderingPagePerFrame` = 4 pages per cycle. Port:
   `Terrain3DData::produce_surface_page_set()` on the CPU (4.6), filling only the pages that were
   newly allocated. A compute bake is what a higher `surface_density` would need.
5. **SVT.** Not started, and only worth it once the world is bigger than the AVT address space.
   The manifest is an *existence + hierarchy* record set plus 5 baked fallback slices — there is
   no page→byte-offset table to port.

Godot mapping notes: `RenderingDevice` compute + `Texture2DArrayRD` cover 1–5;
`MultiMesh`/instance custom data + a vertex shader cover the CDLOD morph if we later replace
the clipmap; `Image.FORMAT_RH` / `R16` blobs cover height pages.

### 4.10 CDLOD geometry — not implemented, and maybe not needed

The existing clipmap already gives distance LOD. Hydra's CDLOD buys (a) a fixed 16×16 grid
with odd-vertex collapse + quadrant degenerate collapse instead of per-LOD index buffers,
(b) T-junction removal by splitting coarse patches, (c) height *pages* instead of resident
region height maps. Porting it means replacing `Terrain3DMesher`. The parts worth stealing
independently:

* The range/morph formulas (`visibilityRanges[lod] = V · ratio^lod / ratio^(n-1)`, LOD0 ×0.9;
  `morphStarts[lod] = prev + (end − prev) · 0.7`).
* The morph constant packing `(start, 1/(end−start), end/(end−start), 1/(end−start))`.
* Height pages: 259×259 `R16` (257 core + 1 texel halo), page table carrying
  `resolvedLod` / `previousSlice` / `transition` for 12-render cross-fades.

### 4.11 Far field: the AVT + SVT split — implemented now

The near field above is region aligned, which caps its mip chain at "one page = one region"
(`log2(pages_per_axis)` levels). A page bigger than a region cannot exist there, and a page that
spans several regions cannot either. Hydra solves this with two address spaces — AVT near
(global mips 0..8, per-sector virtual images) and SVT far (9+, a separate page format fed by
baked cell textures). The port now has the same split, minus the baked-cell source:

* **`Terrain3DVirtualTexture` gained a world-space mode** (`set_world_space(true)`). The page
  grid is a regular world grid centred on the origin, so a page's block origin is a pure
  function of its coordinate: no `VirtualImageAtlas`, no registration, no packing. CPU and
  shader share one formula, `virtual = (page + half) >> mip`
  (`world_page_to_virtual` / `get_world_page_virtual` / `surface_svt_sample`). `_request_virtual()`
  is the shared core of both modes.
* **`Terrain3DData::produce_sparse_surface_page()`** is world aligned: every page texel maps to a
  world position and takes whichever region owns it, so a page may span regions and its border
  texels come from the neighbours. The region-aligned producer now fills its border the same way
  (`_sample_payload_world`), so a page seam reads real neighbouring data instead of a clamped
  copy. Note this is a *producer* property: the shader point-samples (`texelFetch`) and resolves
  each corner in its own page, so it never reads the border today. The border matters for a
  future bilinear/`textureLod` sampler, not for the current one.
* **The mip chain is world-space.** One mip 0 page covers `surface_svt_page_world` metres and
  level `m` covers `2^m` times that, so a distant page is a handful of texels instead of a
  distance-limited window.
* **The level of a page is a distance, and both sides read the same table.**
  `Terrain3D::get_surface_svt_mip_for_distance()` is the single rule: with
  `surface_svt_mip_distances` set (one entry per level, in metres, the furthest camera distance
  that level is sampled at) level `m` owns the band up to entry `m`; with an empty table level `m`
  serves out to `2^(m+1) * surface_svt_page_world`, one level per doubling of the page size.
  `surface_svt_mip_for_distance()` in `main.glsl` mirrors it exactly, and the shader **starts its
  walk at that level and only walks coarser**. That is what makes the rendered level a pure
  function of distance: a missing page degrades to the next level up instead of exposing whatever
  finer page happens to still be resident, and the producer fills exactly the levels the shader
  will sample. The demand pass derives a page's levels from the span of its visible footprint
  (`level(nearest) .. level(farthest)`), so a page that straddles a band edge is published at
  every level a fragment inside it can resolve to.
* **Over-subscription raises a coarseness floor, it never rewrites a level.** When the
  distance-selected set does not fit the pool, the demand pass finds the *smallest* level floor
  that makes the visible set fit and coarsens only the pages finer than that floor: pages already
  coarser than it keep exactly the level the rule gave them, every visible chunk still resolves
  through some page, and the floor is a function of the visible set and the pool size alone
  (the search always starts at the finest level), so a settled view selects the same floor,
  levels and pages on every frame. The hierarchy is extended to cover whatever the rule and the
  floor use, and says so once (`WARN_PRINT_ONCE` with the two page counts). The previous
  selection derived every level from a screen-space density ratio and coarsened the whole set
  until it fit, which changed a page's level from frame to frame while pages published at the
  old level stayed resident — that is the far field's mip "jumping". An explicit table also
  raises the effective level cap to the levels it names, so a saved `surface_svt_max_mip` cannot
  silently truncate a table.
* **The root pyramid replaces the array as the fallback.** The coarsest
  `surface_svt_root_mips` levels are always resident and **protected**, so a miss resolves to
  coarse real data rather than nothing, and the near field's pages compete only among themselves
  for the remaining slots. A root page that gets evicted would leave a miss with nothing to show,
  which is why the protection exists.
* **`surface_array_enabled`** turns the region texture array's surface upload off. The array
  stays allocated (blank) so the material keeps a valid binding, but no payload is uploaded,
  which is what removes the `density²` cost — 2 MB per resident region at density 4. The debug
  views read the same lookup chain as the shaded path (`get_surface_value`), so they work with
  the array disabled too. The gate is `is_surface_array_upload_needed()`: with **both** virtual
  texture tiers off the array keeps carrying the channel regardless, because it is then the only
  source and a blank array would render every texel as material 0. **Default is still `true`**:
  the array-free path is implemented and verified (`vt_sparse.gd`), but flipping a default
  changes what every existing project renders, and the VRAM/FPS difference has not been measured
  on a real scene yet. Turning it off is the switch that completes the split.
* **Edits invalidate pages.** Both tiers cache a region's payload, so
  `Terrain3D::invalidate_surface_pages()` releases every page of every level that overlaps an
  edited region (plus one page of margin, because a page's border is filled from its
  neighbours). Without it an array-free configuration keeps rendering the material the page was
  produced with until the LRU happens to evict it. `change_surface_density()` drops both atlases
  outright, because page contents are resolution specific.

Defaults: near field page 256 texels / 4 pages per axis (1:1 at density 4) with
`surface_vt_page_count` 128 (the 512 m radius working set is roughly 50 pages, so 64 had no LRU
headroom); far field page 512 m / 256 texels (0.5 texel/m at mip 0), `surface_svt_page_count`
256, `surface_svt_root_mips` 2, `surface_svt_distance` 6144 m to the clipmap's reach,
`surface_svt_mip_distances` empty (automatic bands: 1024 m, 2048 m, 4096 m, … for a 512 m page).
The dock's SVT panel edits the table one level per row and can pin the automatic bands as a
starting point; the property also appears in the inspector's SVT group as a plain float array.

Tests: `native/tests/vt_sparse.gd` + `vt_sparse_runner.py`. It pins world addressing (a page is
a fixed world square), the neighbour-filled borders texel by texel, the world-space mip chain (a
page about 185 m out is published at mip 1 while the page under the camera stays at mip 0), the root
pyramid covering every texel of the coarsest levels, a page 6.4 km away resolving through it,
array-free rendering matching the array-backed frame pixel for pixel, and an edit with the array
off being re-produced instead of served stale.

`native/tests/vt_mip_bands.gd` + `vt_mip_bands_runner.py` pins the distance table itself on the
production path: the band edges, that the level the shader starts at is the level that was
produced for every probe distance, that a settled view neither moves a level nor churns the pool,
that a small camera move inside the bands moves no level, and that an over-subscribed pool keeps
the nearest pages and still settles instead of rewriting levels.

## 5. Traps found in Hydra — do not copy these

1. **7×7 sector request grid vs 16-sector atlas capacity** at the default density (§2).
2. **`DemandRetentionFrames` is dead code** — `demandedPages_` is cleared at the top of
   `SubmitPatchDemand` and only read by `AcquireSlot` in the same call, so the "retained
   pages" step protects nothing.
3. **Height decode uses `half`** (`TerrainCdlod.hlsl:150`) while the exporter stores 16-bit
   UNorm, so effective vertical precision is ~`range/2048`, not `/65535`. Use float.
4. **A page miss silently samples physical slot 0 at LOD0 raster** (`transition = 0` selects
   "previous"), which only works because slot 0 happens to hold a root fallback page. Make
   the fallback explicit.
5. **Exceeding `maxPatchCount` drops the whole frame's terrain**, not a graceful degradation.
6. **`HYDRA_TERRAIN_AVT_MAX_PHYSICAL_PAGE_COUNT 1200`** is declared in the shader and never
   read; the runtime capacity with default settings is 1405.
7. **`g_TerrainAVTPhysicalPageStorageLayout`** is written by C# and read by no shader.
8. `physicsLoadLevel` / `physicsLoadBudgetPerFrame` / `visualLoadBudgetPerFrame` are
   serialized, clamped and unit-tested, and consumed by nothing.
9. `TerrainVTLodTracker`'s color channel is vestigial at its only call site.

## 6. Verification

```powershell
# VT addressing contract (standalone, no engine)
cd misc/feng-addons/feng-idweight-terrain/native/tests/vt
scons && ./terrain_vt_contract_test.exe

# Region streaming (graphical driver required)
python misc/feng-addons/feng-idweight-terrain/native/tests/region_streaming_runner.py --driver d3d12

# Region layer slots: rendered multi-region layers + zero array reallocation
python misc/feng-addons/feng-idweight-terrain/native/tests/region_slots_runner.py --driver d3d12

# Surface VT runtime, page production, shader integration and per-page demand
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_runtime_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_surface_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_render_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_feedback_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_demand_runner.py --driver d3d12

# Surface density: dense payload, coarse array, migration and the render grid
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_density_runner.py --driver d3d12

# Existing terrain regressions
python misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/editor_dock_runner.py --test pairroles --driver d3d12
```

### Known flaky results — do not chase these as regressions

* `editor_dock_runner.py --test setup` fails roughly half the time at the Scene mesh brush
  step (`MESH_INSTANCES=0`, `PAINTED` between 95 and 108). Re-running it usually passes on the
  same binary. It is a camera/mouse-ray timing issue, the same class as the paint step in
  `--test input` and `--test dock`.
* The runners' `--headless --editor --import` step intermittently dies with `0xC0000005`
  (`EXIT=3221225477`), which makes a batch of runners look like a total failure while each
  runner passes on its own. Windows Application Error events put the fault in
  `godot.windows.editor.x86_64.exe` itself at a fixed offset, and the same offset was already
  crashing before the slot allocator existed. If a runner reports `EXIT=3221225477` with no
  script output in its log, re-run it alone before investigating.

## 7. Sources read

Hydra AVT runtime: `TerrainAVTConstants`, `TerrainAVTAddressProfile`, `TerrainAVTUtility`,
`TerrainVirtualImageAtlas`, `TerrainAVTFeedbackTexture`, `TerrainAVTFeedbackWriter`,
`TerrainAVTIndirectionTexture`, `TerrainAVTIndirectionWriter`, `TerrainAVTIndirectionProjection`,
`TerrainAVTPhysicalPageFormat`, `TerrainAVTPhysicalPageSlotAllocator`, `TerrainAVTPageStorage`,
`TerrainAVTPageScheduler`, `TerrainAVTPageContracts`, `TerrainAVTRuntime` (+`.PlanPageWork`,
`.RenderPageWork`, `.Feedback`, `.Readback`), `TerrainVTMgr`, `TerrainVTPass`,
`TerrainAVTRequestCulling`, `TerrainAVTWriteModeSelection`, `AVTReadbackRequestProvider`,
`ComputeTerrainAVTPageWriter`, `RasterTerrainAVTPageWriter`, `TerrainVTShaderPropertyIds`,
`TerrainVTKeywords`, `TerrainVTLodTracker`, `TerrainVTGenerator`, `TerrainSvtAddressing`.
Hydra ZTerrain: `TerrainHeightPageManifestAsset`, `TerrainHeightPagePackAsset`,
`TerrainSvtPageManifestAsset`, `TerrainCdlodHeightStore`, `TerrainChannel`,
`TerrainRuntimeSettings`, `TerrainIndexFile`, `TerrainIndexStructures`, `ZTerrainService`,
`TerrainSceneProcessor`, `ITerrainTextureSource`, the export builders.
Hydra ZRP CDLOD: `TerrainCdlodPatchPass`, `TerrainHeightPageCache`, `TerrainCdlodHeightData`,
`TerrainCdlodDrawPass`, `TerrainCdlodDrawUtility`.
Shaders: `TerrainVT/AVT/*`, `Terrain/TerrainCdlod.hlsl`, `TerrainVT/TerrainVTSurfaceSample.hlsl`,
`TerrainVT/TerrainVTSurfaceCodecFunctions.hlsl`.
