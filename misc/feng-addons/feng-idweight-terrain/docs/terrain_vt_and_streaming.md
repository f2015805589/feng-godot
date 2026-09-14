# Terrain virtual texturing and chunk streaming

How the terrain surface channel is stored, addressed, produced and streamed in this
addon, why each piece is built the way it is, and how to verify it.

**Current implementation:** both virtual texture tiers share one physical residency
pool and one set of settings; the near field allocates adaptive per-sector blocks, the
far field persists baked material pages; geometry can run as a CDLOD quadtree. See
[current architecture](vt_architecture_review.md) for the subsystem map.

## 1. Three subsystems, three jobs

| System | Job | Entry points |
|---|---|---|
| **CDLOD** | Geometry quadtree, instanced patch meshes, GPU vertex morphing | `native/src/terrain_3d_cdlod.{h,cpp}`, `shaders/main.glsl` |
| **AVT** | Near-field adaptive virtual texture over 64 m world sectors | `native/src/terrain_3d_sector_avt.cpp`, `terrain_3d_vt_service.cpp`, `terrain_3d_avt.h` |
| **SVT** | Far-field sparse virtual texture on a world-aligned page grid | `native/src/terrain_3d_vt_demand.cpp`, `terrain_3d_surface_vt.cpp`, `terrain_3d_page_pipeline.{h,cpp}` |

They share the world cell grid and the physical page pool, but they have **separate
address spaces, separate demand passes and separate level rules**. They are not one
system and should not be folded into one.

Two properties shape everything below, so they are worth stating up front:

* **There is no disk page store for near-field pages.** They are baked on demand from
  the loaded regions by a worker that owns an immutable snapshot of the source bytes.
  The far field can serve a page from a persisted bake (`.vtcell`, section 4.11), but it
  never *needs* one: a page with no bake is produced from the resident region payloads, and
  a bake that is resident on the GPU (this session's cell store) is copied without touching
  the disk at all.
* **Near-field level selection is not a distance rule in the shader.** The fragment
  picks its level from the pixel footprint, and the CPU planner predicts that choice
  from projected screen density, so producer and sampler agree on the level without
  either one owning the other.

## 2. The addressing contract

`native/src/terrain_vt.h` holds the engine-independent half of it: the page record, the
indirection mip walk and the POT quadtree allocator. Everything else lives with the
runtime.

| Constant | Value | Where |
|---|---|---|
| Sector size | 64 m | `SECTOR_WORLD`, `terrain_3d_sector_avt.cpp` |
| Page content / border / stored | 256 / 4 / **264** | `Terrain3DVTState`, `Terrain3DVirtualTexture` |
| Physical slot bits | 11 (`slot & 0x7FF`) | `terrain_vt.h` |
| Invalid slot | 65535 | `terrain_vt.h` |
| Near-field page table | 2048×2048 entries, `R32F` | `_configure_surface_view()` |
| Far-field page table | `max(64, page_count · 4)` entries, `R32F` | `_configure_surface_view()` |
| Minimal virtual block | 1 page near field, 4 by default | `set_minimal_block()` |

### Indirection texel (`R32F`)

One float per virtual page per level, holding the physical slot or `65535`. The mip
chain is built by hand: averaging slot indices would be meaningless, so a coarser texel
either carries a real slot or the invalid marker. A lookup walks from the requested
level toward the coarsest, halving the page coordinate each step
(`TerrainVT::try_match_indirection_slot`), and *the level it succeeded at is the level
that was sampled*. `R32F` rather than an integer format keeps the texel readable with
`texelFetch` on every backend this addon targets.

### Sector directory (near field, `RGBA32F`)

Two texels per sector: `[key.x, key.y, level, 1]` and
`[block_origin_x, block_origin_y, block_size, logical]`. The shader hashes
`(key, level)` and probes linearly (`avt_find_sector()` in `main.glsl`), so finding a
block never depends on the region layer IDs the chunk directory hands out. That
decoupling is deliberate: the address space is the virtual texture's own, not a
side effect of which array layer a region happens to occupy.

### World page grid (far field)

`virtual = (page + half) >> mip`, with `page = floor(world / page_world)` and
`half = indirection_size / 2`. CPU (`world_page_to_virtual`) and shader
(`surface_svt_sample`) use that one formula, so the far field needs no per-sector table,
no registration and no packing — a page's block origin is a pure function of its
coordinate.

### Virtual page blocks (near field)

A sector's virtual image is a POT block of pages handed out by
`TerrainVT::VirtualImageAtlas`, a 4-ary tree over the page space. The block size is
chosen per sector from the resolution its screen footprint needs
(`wanted = base >> screen_mip`), and allocation is independent of physical residency, so
the address space is budgeted separately from the page pool. Blocks are released when
the camera leaves, and a resize that cannot be satisfied rolls the old node back
verbatim instead of leaving a hole.

### Address-space budgeting

The directory has to cover the visible set, so the planner budgets the page space
explicitly: the sum of the visible blocks must fit `2048² · 3/4` entries, and when it
does not, every sector's requested size is halved together (`virtual_bias` in
`_avt_build_hierarchy()`) until it does. Coarsening the request is always preferable to
failing an allocation, because a sector without a block has no pages at all. The bias is
reported in `avt_sector_stats`.

### The capacity question

Physical residency is the real limit, and it is a *pool* limit, not an addressing one:
`vt_page_count` slots are shared by both tiers, the near field reserves up to half of
them for the far field, and the far field protects its root pyramid. A configuration
whose working set does not fit therefore degrades in a defined order — demand is served
nearest-first, roots stay resident, and the coarsest levels keep real data — rather than
failing an allocation. Size the pool from the working set (the near field's 512 m radius
at density 4 is roughly 50 pages) and leave headroom for the LRU.

## 3. What the addon started from

Kept because the constraints it created explain the design in section 4.

| Concern | Status |
|---|---|
| Chunking | `Terrain3D::region_size` (64–2048, default 256) on a fixed **128×128 region grid** (`REGION_MAP_SIZE`, valid −64..63). Regions are the storage chunk *and* the texture-array layer. |
| Mesh LOD | Clipmap ring (`Terrain3DMesher`, `mesh_size` 48 + `mesh_lods` 7), snapped to the clipmap target. **Not** a CDLOD quadtree. Geometry is shader vertex displacement over instanced tiles, so there is **no per-chunk draw call** — chunking only affects data residency. |
| Region files | `terrain3d_{x}_{y}.res` in the data directory; `save_directory` / `load_directory` / `load_region` are synchronous. |
| GPU maps | Per-region `Image` → 4 `Texture2DArray`s (height, control/idweight R16, color, surface) rebuilt wholesale by `update_maps()` whenever the region set changes. |
| Streaming | **None.** No runtime load/unload around a moving centre. |
| Virtual texturing | **None.** Textures are a resident array indexed by the idweight control map. |

Two numbers make the chunking limits concrete at the default `region_size` 256:

* The clipmap's outermost ring reaches `2 × mesh_size 48 × 2⁶ = 6144 m`; the chunk
  directory reaches ±64 × 256 = **±16384 m**, so geometry is no longer the tighter of the
  two. (Before the directory grew from 32×32 it was: ±4096 m could not fill the clipmap.)
* A region's maps are `region_size²`, so the surface/control maps are **1 texel/m**.
  Detail density is welded to chunk size: going finer means bigger chunks, which costs
  memory per region *and* coarsens streaming granularity. This is the constraint the
  virtual texture exists to break.

## 4. Subsystem design and rationale

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

`native/src/terrain_vt.h` is the dependency-free half of the addressing contract. It once
carried a full descriptor-table design; the parts production never used — the
`AddressProfile` descriptor tables and their `TexelDensityPreset` selection, the
`PackPageId`/`UnpackPageId`/`TryResolveAvtPageAddress` helpers, the LRU key encoding, the
physical-page UV/world-rect math and the feedback sizing/Bayer dither — have been deleted.
What is left is what the runtime actually calls:

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
  entries that still publish the slot, using a per-slot reverse index — that check is what
  stops a stale reverse entry from clobbering an entry a later allocation already
  republished. A fully protected atlas fails the allocation instead of stealing a page.
  Recency is a real order, not a counter: `touch_slot()` moves the slot to the front of
  `lru`, and the two demand epochs (`begin_demand()`/`end_demand()` plus
  `slot_demand_epoch`) keep a pass from evicting a page another part of the same pass still
  needs. Protection is reference counted (`slot_protect_refs`), because several owners pin
  the same slot (the AVT visible plan and the far field's root pyramid).
* **The acquire path is a transaction.** `acquire_slot()` reserves a slot and only *chooses*
  an LRU victim (free-list slot, or `slot_evict_on_commit`); the victim keeps its content and
  its owners' indirection entries. `commit_slot()` — called by `_request_virtual()` once the
  new entry that names the slot has been written — evicts the victim and takes the slot for
  the new page in one step. `abort_slot()` drops the reservation: a free-list slot goes back
  to the list, a chosen victim is left exactly as it was, and the allocation counters are
  rolled back (`aborted_acquires` reports how often). Before this split the victim was
  destroyed at acquisition, so any caller that failed between acquiring and publishing had
  already thrown away a resident page for nothing. Recency is a real order, not a counter:
  `touch_slot()` moves the slot to the front of `lru`, and the two demand epochs
  (`begin_demand()`/`end_demand()` plus `slot_demand_epoch`) keep a pass from evicting a page
  another part of the same pass still needs, and a reserved slot is never picked as a second
  victim. Protection is reference counted (`slot_protect_refs`), because several owners pin
  the same slot (the AVT visible plan and the far field's root pyramid).
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
is the producer. It owns a `Terrain3DVirtualTexture` (`terrain.surface_vt`, on by default with
`surface_svt_enabled` and `cdlod_enabled`):

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
**1 texel/m** at the default 256 m region, so a page smaller than the region only *upsampled* —
at 64 m pages a 4× point upsample that added no detail. The producer was resolution-agnostic, so
raising the region's surface resolution is what turns this from "a correct paging layer" into
"more detail than the array can afford to keep resident".

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
density 1 that is bit-for-bit the old behaviour, and a denser payload follows the same per-cell
contract on a dyadically subdivided cell — the fixed BL-TR diagonal survives dyadic subdivision, so the
triangle selection stays consistent with the clipmap mesh. With the virtual texture **off** the
cell keeps the 1 m grid, so the array path renders exactly as it did before.

Tests: `native/tests/vt_density.gd` + `vt_density_runner.py`. It pins the two sizes, the brush's
block writes, a byte-exact 4 → 1 → 4 round trip, the `add_region()` migration of a legacy
payload, a real region file round trip at density 4 (payload bytes and stored density both
survive save → unload → load), mip 0 pages as 1:1 crops of the dense payload, and a render where
the array path shows the block-origin material while the virtual texture shows the finer one.

### 4.7 Surface VT shader integration — implemented now

`surface_vt_enabled` (on by default) switches the terrain fragment shader's surface id/weight
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
is a property of *fragment* feedback: the terrain pass would write one packed PageID for one
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

### 4.9 What is not implemented

* **Fragment-level page demand.** The projection pass (4.8) knows the field of view, the
  resolution and the view direction, but not occlusion and not the exact rendered
  coverage. Both need a per-fragment signal: the terrain fragment shader would write one
  packed page id per small screen tile into an integer target, which the CPU reads back.
  Godot's `RenderingServer` exposes no MRT hook for a scene shader and no integer viewport
  format, so a faithful version needs a second terrain draw into a `SubViewport` with the
  id packed into RGBA8. For a clipmap whose visible set is analytic, projected demand is
  nearly identical to rendered demand, so this is a deliberate omission rather than a
  pending task; `surface_vt_feedback_grid_chunks` and `_min_extent` already give the
  projection pass the same culling decisions.
* **GPU page production.** Pages are produced on a CPU worker from an immutable source
  snapshot, which keeps the producer free of renderer calls and thread-safe and keeps the
  cache signature on one side. A compute bake becomes worthwhile at higher
  `surface_density`, where resampling the payload per page starts to compete with the
  render thread.

### 4.10 CDLOD geometry — implemented

`Terrain3DCDLOD` (`native/src/terrain_3d_cdlod.{h,cpp}`) replaces the clipmap when
`cdlod_enabled` is on (default true):

* **Selection.** One quadtree per resident region, rooted at the region's world square and
  subdivided down to `cdlod_patch_size` (default 32) texels. A node splits while the
  camera's *horizontal* distance to its box is under `size · 0.5 · cdlod_lod_scale`
  (default 8). Horizontal rather than per-node centre distance, so neighbouring vertices
  cannot pick different morph levels and a shared edge cannot disagree with itself.
* **Geometry.** One regular `(patch_size+1)²` grid mesh, instanced, in two MultiMesh
  batches: visible patches, and off-screen shadow casters. No per-node mesh, no index
  stitching, no skirts — the vertex shader collapses a patch toward its parent's level
  over the last quarter of its range, which removes T-junctions and preserves the fixed
  BL-TR diagonal the IdWeight evaluator depends on.
* **Caching.** The quadtree rebuilds only when the camera position or a configuration
  value in the selection key changes; view rotation re-runs only the frustum
  classification, and an unchanged visibility set uploads nothing.
* **Heights.** There is no height page texture: displaced vertices read the region height
  array through the material, so height residency stays the region-streaming problem
  instead of becoming a second cache with its own eviction policy.

`docs/cdlod_and_capture.md` covers the geometry path and the capture tooling; the driver
is `native/tests/vt_adaptive_runner.py --cdlod`.

### 4.11 Far field: the two-tier split — implemented now

The near field above is region aligned, which caps its mip chain at "one page = one region"
(`log2(pages_per_axis)` levels). A page bigger than a region cannot exist there, and a page that
spans several regions cannot either. The far field is a second address space that fixes exactly
that — a world-aligned page grid with its own page format, fed by baked cell sources:

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
* **Over-subscription raises a coarseness floor; it never drops a page.** When the
  distance-selected set does not fit what the pool has left, the pass searches for the
  *smallest* level floor whose merged set fits, then publishes every page finer than that
  floor at the floor while pages already coarser keep the level the distance rule gave
  them. Every visible footprint still resolves through a page of some real level, and the
  floor depends only on the visible set and the remaining capacity (the search starts at
  the finest level), so a settled view selects the same floor, levels and pages on every
  pass. `svt_floor_level` in `get_vt_settings()` reports it. The hierarchy is extended to cover whatever the rule and the
  floor use, and says so once (`WARN_PRINT_ONCE` with the two page counts). The previous
  selection derived every level from a screen-space density ratio and coarsened the whole set
  until it fit, which changed a page's level from frame to frame while pages published at the
  old level stayed resident — that is the far field's mip "jumping". An explicit table also
  raises the effective level cap to the levels it names, so a saved `surface_svt_max_mip` cannot
  silently truncate a table.
* **The root pyramid is the fallback of last resort.** The coarsest
  `surface_svt_root_mips` levels covering the visible world are acquired *before* the detail
  set and **protected**, so a miss on a detail page resolves to real coarse data instead of
  the diagnostic material. They are capped at half the pool, and a root that leaves the
  visible set loses its pin — the page itself is left to the LRU, because a detail page can
  share its owner entry. `svt_root_pages` reports how many are pinned.
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

#### A far page has three sources, and none of them is required

Producing a far page used to mean reading its cells from the `.vtcell` bake files on a worker
thread, so a page existed only if an offline bake existed, and the record for it said
`Missing bake` until one did. The runtime no longer depends on that file at all. `_queue_vt_material_page()`
resolves a far page against, in order:

1. **The resident cell store** (`Terrain3DCellStore`, `terrain_3d_vt_cells.{h,cpp}`). A cell baked
   in this session (or imported) lives in three GPU arrays — one layer per cell, one array per
   channel, full mip chain — so `_resolve_svt_cell_pieces()` returns copy pieces that name a layer
   and a level, `_copy_cell_page()` binds that layer's mip view
   (`RenderingDevice::texture_create_shared_from_slice`) and the page is assembled entirely on the
   device. This is the only source that costs neither CPU time nor I/O, and it is why an offline
   bake is worth having: `bake_svt()` publishes into it.
2. **A persisted bake**, when one exists for a cell the store does not hold. The source worker
   reads the mip the page needs (not mip 0) and the page is copied from those channels.
   `_svt_cells_have_persisted_bake()` probes each cell once per session, so the frame path never
   stats the same file twice.
3. **The resident region payloads.** `produce_surface_rect_page()` crops the ID/weight payload and
   `make_vt_height_page()` the height, and the GPU bake turns them into material channels — the
   same production the near field uses. A far page is therefore produced on the frame it is
   requested, whether or not any bake exists anywhere.

A cell is reused only while its state key matches: the material signature, the far-field density
and a per-cell edit stamp that `_invalidate_vt_region()` bumps for the cell and its eight
neighbours (a page border reads them). The store is sized from a memory budget (192 MB across the
three channels, at least one layer) and evicts the least recently used cell when full, requeueing
the pages that sampled it. Every published page reports its state: `Pending cell copy` (store),
`Missing bake` (persisted bake being read), `Pending bake` (cropped from the payloads),
`No resident payload`, `Ready` (validity bit set).


`native/tests/vt_mip_bands.gd` + `vt_mip_bands_runner.py` pins the distance table itself on the
production path: the band edges, that the level the shader starts at is the level that was
produced for every probe distance, that a settled view neither moves a level nor churns the pool,
that a small camera move inside the bands moves no level, and that an over-subscribed pool keeps
the nearest pages and still settles instead of rewriting levels.

### 4.12 Atlas compression — selectable, probe-verified and actually applied

`vt_atlas_compression` selects the storage format for the three material page arrays
(`albedo_height`, `normal_roughness`, `params`). The list is the same one the layer texture
arrays use (`Terrain3DAssets::TextureArrayCompression`), so the inspector shows one vocabulary
for every terrain array. Two rules bound what can be selected, and a request is resolved —
not trusted — when it is set:

* **Alpha.** All three arrays carry an alpha value the shader reads: material height in
  `albedo_height.a`, roughness in `normal_roughness.a`, and the page validity bit in
  `params.a` (the sampler rejects a page whose `params.a` is not 1). A codec whose channel set
  drops alpha — BC1, BC4, BC5, BC6H, ETC1, ETC2 RGB, EAC R11/RG11 — would silently corrupt
  it, so those are refused with that reason. Making them usable means moving the alpha channels
  into their own array, which changes the material bindings.
* **Build and device.** Godot registers its image compressors as function pointers from
  whichever modules the engine binary enabled: etcpak (BC1/BC3/BC4/BC5, ETC, EAC) and astcenc
  (ASTC) ship in every build, while cvtt (BC7, BC6H) and betsy (GPU BC1/BC4/BC6H) are
  editor-only unless the export template sets `cvtt_export_templates` /
  `betsy_export_templates`. The resolver therefore compresses a real 4×4 block instead of
  assuming a codec exists, and then asks the rendering device whether the resulting format can
  be sampled *and* updated in place — which is what rules ETC2 and ASTC out on a desktop BC
  device.

`get_vt_settings()` reports the outcome: `vt_atlas_compression` (the request),
`vt_atlas_compression_available` (the codec this build and device can produce and sample, 0
when refused), `vt_atlas_compression_applied` (what the arrays are stored in **today**),
`vt_atlas_compression_name`, and `vt_atlas_compression_reason`.

**The encode.** Page production writes RGBA16F into staging arrays with `imageStore`, and a
compressed format cannot be a storage image, so the compressed arrays are separate sampling
targets and an encode step copies between them:

* The **cached path** already holds the channel images on the CPU, so it compresses them
  directly.
* The **bake and cell paths** only exist on the GPU, so the baker requests one
  `texture_get_data_async` per channel — a synchronous readback is not safe from inside the
  render callback — and the callback compresses and `texture_update`s the sampled layer.
* A page therefore becomes compressed a frame or two after it was produced. Readiness is
  deliberately unchanged: until the encode lands, the sampled layer holds zeros, which the
  sampler reads as "not written" (`params.a` is not 1) and resolves through a coarser page
  instead of showing a half-written one.
* Compressing costs a readback and a codec pass per page, so the per-frame page budget drops
  from 16 to 4 while compression is on.

Tests: `native/tests/vt_compression.gd` + `vt_compression_runner.py`. It walks every enum entry
and asserts the resolution invariants: an accepted request must equal `available` and carry no
reason, a refused one must fall back to 0 with a non-empty reason (naming alpha where that is
the cause), and at least one alpha-capable codec must be usable in the build under test. It then
compresses and decodes a probe image through the resolved codec and requires the error to be
non-zero but bounded (BC7 on the probe: max 0.0078, mean 0.00097), that the uncompressed round
trip is exact, and that a fixture which produced pages reports
`vt_atlas_compression_applied == available` — the arrays are actually built in the accepted
format. On this machine that is BC7 (`applied=1`) with BC3 RGBA accepted as well.

**Two traps this cost.** The compressed arrays are created with `SAMPLING | CAN_UPDATE` and
nothing else. `CAN_COPY_TO` also looks harmless, but on D3D12 it sets
`D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS`, which a block-compressed resource cannot carry, so
`texture_create` returns `CreateResource failed with error 0x80070057` — while
`texture_is_format_supported_for_usage()` (the capability probe) says the format is fine, because
it answers for the pair it was asked about. A device that refuses the real allocation now resets
`available` to 0 with a reason instead of claiming a format the pages are not stored in.

**A format change is not a reconfiguration.** The three arrays are rebuilt in place by the
producer (its own generation bump), so `set_vt_atlas_compression()` must not call
`_reset_vt_configuration()`. Doing that detached both views from the shared pool, released
every resident page and then let the demand pass grow the pool back to the capacity it had
already published — which is what produced a user-visible
`WARNING: Virtual texture pool grew to N pages; resident pages were released ...` on a plain
property change in the inspector. The pages do have to be produced again, because the
rebuilt arrays start blank: the setter forces `invalidate_surface_pages(location, true)` for
every loaded region, which also skips the editor-preview deferral (a deferred refresh would
leave the material sampling arrays that no longer hold its content).

**A reconfiguration reuses the published capacity.** `Terrain3DVTState::vt_effective_page_count`
records what the views were actually configured with, is raised by the auto-capacity
publication and replaced by an explicit `vt_page_count`, and `_configure_vt_service()` configures
the views and the producer with `MAX(vt_page_count, vt_effective_page_count)`. Starting again
from the setting would make the demand pass re-grow the pool right after the rebuild, releasing
every page a second time. `get_vt_settings()` exposes `effective_page_count` and
`pool_generation` (bumped once per pool build) so this is directly assertable, and the pool's
growth warning is emitted only when slots were actually released, with the count.

**The demand pass waits (briefly) for a capacity change to land.** Auto capacity requests the
larger arrays from the producer and the pool follows them a frame or two later; a page produced
in between is released by that growth. `_ensure_vt_capacity()` therefore skips production for at
most `MAX_CAPACITY_WAIT_FRAMES` (8) frames while the request is in flight: at 512 pages the editor
went from "grew to 512 pages; 16 resident pages were released" to growing while nothing was
resident, which removes both the wasted bakes and the warning. The wait is bounded on purpose — a
state that cannot build the larger arrays (no material arrays yet, a failed allocation) must
never stop page production for the session. Note this is *allocation*, not demand: the previous
residency keeps serving the renderer for those frames.

Tests: `native/tests/vt_format.gd` + `vt_format_runner.py`. It toggles between uncompressed and
the first codec this device accepts, and requires the pool generation and the capacity to be
unchanged, the requested codec to be applied, and the runner additionally rejects the pool
growth warning anywhere in the log. `editor_dock_runner.py --test vt_idle` does the same through
a real editor session (a live terrain, the editor's own viewport and its low-processor idle
mode), which is the path the user report came from:
`EDITOR_VT_FORMAT codec=1 pool=1 (was 1) capacity=512 (was 512) applied=1`.

**Replaced arrays are not freed on replacement.** Every format change, capacity change and
reconfiguration rebuilds the three arrays, and the virtual texture pass runs *before* the draws of
the frame that rebuilds them: a draw in that same frame still samples the previous RIDs. `free`ing
on replacement therefore produced `Uniforms were never supplied for set (3)` once per rebuild, and
left the material sampling freed textures. The baker retires each replaced bundle with its
generation and frees it only once `acknowledge_output()` has reported the material bound to a
newer published pair, which also had to compare against the *compressed* sampling RIDs once a
codec is applied. `retired_bundles` in the producer stats reports the pending set; the compression
test fails if it has not drained.


## 5. Rules this design is built around

Each of these is a pitfall that is easy to fall into and expensive to debug afterwards, so
they are stated as rules the implementation enforces:

1. **Residency pressure must never choose the sampled level.** The level is a pure
   function of the view (pixel footprint near, distance far) and the producer fills
   exactly that level. When the working set does not fit, the far field coarsens through
   an explicit floor applied to the whole set (4.11), and it never substitutes a page's
   level per page, because that is what makes levels jump between frames.
2. **A page-table entry must not outlive its slot.** Every eviction walks the reverse
   owner index and invalidates exactly the entries that publish that slot (4.5). A stale
   entry does not read "nothing" — it reads whatever page took the slot next.
3. **A miss must resolve to real coarse data.** Root levels are protected, the near field
   falls back to the region texture array, and the far field's shader walk starts at the
   distance-selected level and only goes coarser. "Nothing resident" is never answered by
   whatever finer page happens to be left.
4. **Everything the plan touches is pinned until the pass commits.** Pages already
   resident are pinned while missing ones are produced, so the pool cannot evict a page
   whose payload was just written (4.5, `protected_slots`).
5. **Demand is re-marked even when nothing is produced.** A stationary camera re-marks
   its resident slots on a repeated plan; without that the pool would evict the working
   set it is currently rendering (`_produce_sector_avt_pages()`).
6. **Budget exhaustion degrades; it does not drop a frame.** Page acquisition is
   best-effort per candidate, the previous residency keeps serving, and capacity growth is
   attempted once per change instead of per allocation.
7. **Height stays 32-bit float end to end** (`Image::FORMAT_RF`). Displacement and normals
   both differentiate height, so a 16-bit path would quantize the derivative, not just the
   value.
8. **Addressing constants have one definition and a test that pins the copies.**
   `SLOT_BIT_COUNT`, `INVALID_PHYSICAL_PAGE_SLOT` and the page layout live in
   `terrain_vt.h`; the shader carries its own literals, so `vt_runtime` reads the
   indirection back and `vt_render` compares the two paths pixel for pixel.

## 6. Verification

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

`native/tests/run_all.py` drives the whole set; `native/tests/README.md` documents what
each script pins and the flags that select a scenario.

### Known failing suites — they target the legacy region mode

`vt_render`, `vt_material` and the first phases of `vt_adaptive`/`vt_density` exercise the
**legacy region-AVT mode** and fail under the current default
`surface_vt_selection_mode = 2` ("Full AVT (64 m sectors)"):

* `vt_render`/`vt_material` call `terrain.update_surface_vt()` once and expect 16 pages
  synchronously, then resolve pages through the per-region API
  (`lookup_page(region_loc, mip, px, py)`). In sector mode `update_surface_vt()` returns
  `_update_sector_avt()`, which plans on a worker and legitimately returns 0 on the first call,
  and the per-region block table is not published at all — the shader reads the sector directory
  instead.
* `vt_adaptive` asserts that a ready *ancestor* covers the near terrain while finer pages are
  pending, which is the legacy block-table hierarchy, not the sector directory's.

`vt_render`, `vt_material`, `vt_svt_coverage` and `texture_compression` used to be listed here.
All four pass now, and none of them was a stale assertion:

* `vt_render` expected `update_surface_vt()` to produce its 4x4 mip 0 grid, but the fixture
  configured a 16-page atlas and then awaited frames before the call: the engine's own demand
  pass runs every physics tick, so the atlas was already full and an all-hit pass correctly
  produces nothing. It now applies the near-field settings after the baseline image, so the
  pass runs against a cold atlas in the same frame.
* `vt_material`'s runner ran `vt_render.gd` while requiring `vt_material.gd`'s marker, so the
  real test had never run. With that fixed, its sweep also had to stay inside one AVT grid cell
  (a region at `region_size` 64) and wait for the bake counter to go idle rather than for
  `producer.pending`, which is already zero between physics ticks.
* `vt_svt_coverage` had one product bug and two unreachable assertions: an automatic bake armed
  from inside an explicit one reset the job-scoped `bake_total`/`bake_done` counters (fixed in
  `_process_async_svt_pages`, which no longer marks cells dirty while an explicit job is queued
  or in flight), the turned camera could never see past the 992 m band edge that level 4 needs
  (`farthest == 989 m` at the old placement, so the hierarchy could not grow), and
  `has_persisted_mip()` asked the catalogue for a level when it reports cells (one file per cell,
  full mip chain). The turned view now looks across the grid from the far corner.
* `texture_compression` measured 67 engine errors per run, all from one addon defect: the bake
  uniform set bound a *cached* asset array RID, and an asset edit frees the previous pair before
  the render thread binds the snapshot, so the device rejected the binding and the same dead
  snapshot was retried every frame. The producer now validates the resolved RID against the
  device, forgets a pair it could not bind, and reports `materials_stale` so the terrain
  publishes the current pair (`producer.materials_stale` in the stats must return to false). The
  eager `free_rid` of the previous uniform set is also guarded, because freeing its arrays makes
  the device drop the set itself.

`vt_auto_bake`, `vt_density` and `texture_layers` are the remaining red tests. `vt_auto_bake`'s
first process now passes (the pressure phase waited on `bake_pending`, which excludes the cell
being baked, so it could break a frame before the job's last cell landed; it counts cells now),
which exposed its reload phase for the first time in a long while: the second process finds no
far-field demand at all. `vt_density`'s dense-payload render fractions and `texture_layers`'s
45-degree ramp slope overlay are still open.

`vt_sparse` and `vt_fallback` used to be listed here as well. They pass now: `vt_sparse` needed
the diagnostic far field to actually fill the pages it publishes (it read
`page_write_count: 0` with all-zero pages), and `vt_fallback` needed the far field to produce a
page without a bake file. Both are covered above.

`vt_visibility` and `vt_adaptive` are green now as well. `vt_visibility` was fixture drift: it
pins an eight-page pool but left auto capacity on, and a single manual pass that requests a
larger pool deliberately produces nothing while that request is in flight, so the pass returned
0 pages and 0 records. It now pins `vt_auto_capacity = false` and looks straight down in the SVT
phase, because a tilted view puts the AVT visible-region rect and the distance-picked page in
different regions. `vt_adaptive` asserted that a ready ancestor covers the near terrain while
finer pages are pending, which is the opposite of the strict-miss contract the legacy block-table
path implements and `vt_filtering`/`vt_fallback` pin; it now asserts that the pending pages do
not fall back to the poisoned source array while the far block keeps sampling its ready chain.

`texture_layers` (the 45-degree ramp slope overlay, plus the paint-timing flake below) and
`editor_dock:dock`/`editor_dock:setup` also
fail identically with the addon reverted to `HEAD`, so they are outside this document's contract
and were left alone rather than fixed blind.

### Known flaky results — do not chase these as regressions

* `editor_dock_runner.py --test setup` fails roughly half the time at the Scene mesh brush
  step (`MESH_INSTANCES=0`, `PAINTED` between 95 and 108). Re-running it usually passes on the
  same binary. It is a camera/mouse-ray timing issue, the same class as the paint step in
  `--test input` and `--test dock`, and the same class as `texture_layers.gd`'s "painted second
  layer was not rendered green" step.
* The runners' `--headless --editor --import` step intermittently dies with `0xC0000005`
  (`EXIT=3221225477`), which makes a batch of runners look like a total failure while each
  runner passes on its own. Windows Application Error events put the fault in
  `godot.windows.editor.x86_64.exe` itself at a fixed offset, and the same offset was already
  crashing before the slot allocator existed. If a runner reports `EXIT=3221225477` with no
  script output in its log, re-run it alone before investigating.

## 7. Where the contract lives

| Concern | File |
|---|---|
| Page record, indirection walk, POT block allocator | `native/src/terrain_vt.h` |
| Per-frame VT state and settings | `native/src/terrain_3d_vt_state.h` |
| Near-field planner, directory, production pass | `native/src/terrain_3d_sector_avt.cpp` |
| Far-field demand, both tiers' settings and lifecycle | `native/src/terrain_3d_vt_service.cpp`, `terrain_3d_vt_demand.cpp` |
| Page table, physical pool, page read/write | `native/src/terrain_3d_virtual_texture.{h,cpp}`, `terrain_3d_vt_indirection.{h,cpp}` |
| Producer worker, source snapshot, `.vtcell` contract | `native/src/terrain_3d_page_pipeline.{h,cpp}`, `terrain_vt_cell.h`, `terrain_3d_surface_vt.cpp` |
| Resident far-field cell sources (GPU arrays, budget, eviction) | `native/src/terrain_3d_vt_cells.{h,cpp}` |
| GPU page demand | `native/src/terrain_3d_vt_feedback.{h,cpp}` |
| Shader-side addressing and sampling | `native/src/shaders/main.glsl` |
| Geometry backend | `native/src/terrain_3d_cdlod.{h,cpp}` |

The per-test index, including what each script pins, is `native/tests/README.md`.
