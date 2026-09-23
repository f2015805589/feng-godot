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
| **AVT** | Near-field adaptive virtual texture over 64 m world sectors | `native/src/terrain_3d_sector_avt.cpp`, `terrain_3d_surface_views.cpp`, `terrain_3d_avt.h` |
| **SVT** | Far-field sparse virtual texture on a world-aligned page grid | `native/src/terrain_3d_surface_views_far.cpp`, `terrain_3d_surface_views_far_walk.cpp`, `terrain_3d_vt_service*.cpp`, `terrain_3d_page_pipeline.{h,cpp}` |

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
| Page content / border / stored | 256 / 5 / **266** | `Terrain3DVTState`, `Terrain3DVirtualTexture` |
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
failing an allocation. Size the pool from the working set (the near field's 384 m radius
at density 4 is roughly 30 pages) and leave headroom for the LRU.

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

`Terrain3DVirtualTexture` (`native/src/terrain_3d_virtual_texture.{h,cpp}`) is one view's
indirection texture and addressing, and `Terrain3DVTPagePool`
(`native/src/terrain_3d_vt_page_pool.{h,cpp}`) is the physical page atlas and slot allocator the
two views share, both built directly on the contract-tested core in `terrain_vt.h`. Neither owns
terrain data, so both are constructible and testable on their own.

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

#### A page arrival is a ramp, not a rectangular step

A page resolves its texels at full weight the frame its content lands, so the view switches from the
level it replaced to the page itself in one frame. Because a page is a rectangle, that switch is a
rectangle: the view refines in the page grid, block by block, and a turning camera makes it obvious
because the working set moves and pages land continuously.

`vt_page_fade_frames` (default 12, 0 disables) turns that switch into a ramp. The mechanism is
deliberately not packed into the indirection texel:

* **One byte per physical slot**, in a `Texture2D` of `page_count` texels that the shader indexes by
  the slot the indirection lookup already decoded. One extra `texelFetch`, no address arithmetic, and
  a settled slot reads 255 (`fade = 1`, the page itself), which is what the whole texture holds when
  nothing is arriving — so a settled view uploads nothing at all.
* **The ramp is a countdown per slot**, decremented once per tick in the tick's `vt_fade` phase. A
  slot whose content is queued is marked pending from that moment (`_queue_vt_material_page()`, the
  one funnel every production goes through), and the tick a demand pass observes it ready is the tick
  its fade is *armed*. Marking at queue time rather than only from the demand pass's own observations
  is what makes a page re-produced into a *fresh* slot fade at all: that slot has no earlier unready
  reading to compare against.
* **Armed is not started.** An arrival is published at zero first — the level it replaces — and its
  countdown does not begin until the pass releases it, a few slots per tick, oldest first. This is the
  other half of the anti-flicker measure, and the half a turning camera needs: a turn makes arrivals
  *burst*, and a burst that started every ramp on the same tick sharpened a whole block on one tick
  however smooth each page's own ramp was. The release rate is at least two ramps a tick, and a
  backlog larger than the ramp's own length is spread over it, so a burst sharpens in about the time
  one ramp takes — an isolated arrival still starts the tick it lands. A held slot is neither blurry
  nor late: it shows the level its page replaces, which is what the shader resolves at `fade = 0`, and
  the hierarchy's terminal root never fades at all (`avt_filtered_sample()` returns it directly), so
  base coverage still arrives as fast as it is produced. `vt_page_fade_held_slots` is the blur this
  trades for smoothness and `vt_page_fade_starts_peak` is the flicker it removes — the second is the
  number to read when a view still refines in visible blocks.
* **The blend is against the level the page replaced.** The near field's `avt_filtered_sample()` and
  the far field's `surface_svt_material_sample()` both take the first resident level and then —
  only while that level's fade is incomplete — continue to the next resident level and mix by
  `1 - fade`, never weighting the arrival above the pixel footprint's own mip interpolation. With the
  fade off the first resident level is returned directly, exactly as before.
* **Where it cannot help, it does nothing.** Whether the ramp is *visible* is a property of the scene,
  and the scene has to be built for it: what matters is which mip of a page the shader selects, which
  the camera's orthographic size decides. At 192 m across, one screen pixel covers ~0.6 m and the page
  mip averages the checkerboard to nearly what the source array draws — the two paths differ by 0.0039
  in red — so invalidating the pages covering the view moves the image by less than any threshold, and
  three explanations for that were tested and are wrong (the payload/mip arithmetic, the fade leaving
  the shot mid-ramp, and the row not being virtual-texture resolved at all; it is, by that
  four-thousandth). At 4 m across one screen pixel covers ~0.013 m, the page mip shows the checkerboard
  and the level behind the page differs by 0.15 in red, which is what `vt_page_fade` now measures. It
  also asserts the *shape* of the ramp: where each frame sits between the two ends must be monotonic
  and must reach the page — a value that leaves one end and reaches the other in one frame is a step
  with extra bookkeeping, and one that goes backwards is the flicker this exists to remove. A 20-tick
  fade measures as `0.067 0.223 0.310 0.399 0.577 0.666 0.889 1.0 …`.
* **And a page whose level behind it is not resident** falls back to the missing-page diagnostic,
  which is not a level a fade can blend against: the fade blends coarse to fine, it does not fill a
  hole.

Tests: `native/tests/vt_page_fade.gd` + `native/tests/vt_page_fade_runner.py`. It drops a resident
page's content three times — once with the fade off, once at 20 ticks, once at 40 — and counts the
ticks the engine publishes a fading slot for. The fade must be absent when off, run over several
frames when on, be longer when asked for longer, and leave the view exactly where it started.
`debug_invalidate_vt_page()` is the render-side counterpart of `debug_lose_vt_page_readiness()`: the
latter clears only the CPU-side readiness the demand pass acts on, which the shader never sees.

`vt_turn_budget`'s transient readings show what it is worth, and they were stable across runs before
the fade existed: the settled view's diagnostic pixels after a warm turn fall from 528 to 247, an
isolated 180° turn's middle/bottom screen bands from 906/14 to 627/0 — the near-field band, which is
what the camera is looking at, goes to zero — and the diagnostic pixels left after a rebuilt pool
recovers from 560 to 269.

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
`surface_vt_page_count` 128 (the 384 m radius working set is roughly 30 pages, so 64 had no LRU
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

### 4.12 Page-array compression — per tier, encoded on the GPU, compressed once for SVT

`surface_vt_compression` (near field / AVT) and `surface_svt_compression` (far field / SVT)
select the storage format of the three material page arrays (`albedo_height`,
`normal_roughness`, `params`) over the one shared physical pool. The list is the same one the
layer texture arrays use (`Terrain3DAssets::TextureArrayCompression`), so the inspector shows one
vocabulary for every terrain array; the inspector shows both entries as `Compression` inside the
`AVT` and `SVT` groups, and `vt_atlas_compression` remains as the near field's pre-split name.

They are separate settings because the tiers produce at very different rates. An AVT page is
rewritten by every edit that invalidates it; an SVT page is assembled once from a baked cell and
then never rewritten, so compressing the far field is paid once and the memory is saved for the
rest of the session. A tier left uncompressed samples the staging arrays directly and costs
nothing extra.

Two rules bound what a page can be stored in, and together they leave exactly three settings —
Uncompressed, BC7 and BC3 RGBA — which is the whole list the page settings offer:

* **Alpha.** All three arrays carry an alpha value the shader reads: material height in
  `albedo_height.a`, roughness in `normal_roughness.a`, and the page validity bit in
  `params.a` (the sampler rejects a page whose `params.a` is not 1). A codec whose channel set
  drops alpha — BC1, BC4, BC5, BC6H, ETC1, ETC2 RGB, EAC R11/RG11 — cannot store a page at all.
  Making them usable means moving the alpha channels into their own array, which changes the
  material bindings.
* **A GPU encoder.** Page compression never runs a CPU block encoder — that is the whole point
  of the design, because a codec pass per page is what made the compressed path both slow and
  visibly late. `shaders/bc_encode.glsl` implements BC1/BC3/BC4/BC5/BC7, so a codec it has no
  encoder for (ETC2, EAC, ASTC, BC6H) has no producer at all. Combined with the alpha rule, the
  only codecs left are BC7 and BC3 RGBA.
* **An sRGB colour format.** The albedo page is a colour and is stored in the codec's *sRGB*
  format (`BC7_SRGB_BLOCK` / `BC3_SRGB_BLOCK`), while the normal and parameter pages — a
  direction, a ratio, a height — stay in the codec's linear one. A two-endpoint block codec
  spends its bits in whatever space it is handed, and its two colour channels are five bits wide,
  so they step by `8/255`: a **linear** channel below `8/255` has no representation other than
  zero. That is every dark but saturated colour, because the linear value of an authored colour is
  its sRGB value raised to roughly 2.2 — a blue of `0.04` authored is `0.003` linear. Encoding
  the linear value collapsed that channel to black and the page changed hue; the encoder therefore
  writes the sRGB encoding of the staging texel and the array is an sRGB format, which the hardware
  turns back into exactly the linear colour the uncompressed path samples. A codec with no sRGB
  renderer format is refused with that reason, in the same place as the other two rules.

The two lists are therefore separate, and deliberately so: the asset inspector's
`texture_array_compression` covers everything the engine's *CPU* encoders apply to an authored
texture array (BC1, BC4, BC5, BC6H, ETC2, EAC, ASTC included), while a page setting names only
what this build's GPU block encoder can produce. A value is translated rather than reinterpreted
by position: 1 is BC7 in both lists, 2 is BC3 here and BC1 RGB there while 3 is BC3 there — both
values mean BC3, because a page cannot be stored in BC1 at all — and every other entry resolves
to uncompressed, which is what it resolved to while the settings still listed it.

What remains after those two rules is a device question, and it is the only reason a page codec
can still be refused: the resolver asks the rendering device whether the resulting format can be
sampled *and* updated in place. A refusal is reported with its reason, and `available` falls back
to 0, so a tier never claims a format it is not stored in.

`get_vt_settings()` reports the outcome per tier: `surface_vt_compression*` /
`surface_svt_compression*` and, under the legacy keys, the near field as
`vt_atlas_compression`, `vt_atlas_compression_available` (the codec this device can store and
sample, 0 when refused), `vt_atlas_compression_applied` (what the arrays are stored in
**today**), `vt_atlas_compression_name` and `vt_atlas_compression_reason`.

**The encode runs on the GPU.** Page production writes RGBA16F into the staging arrays with
`imageStore`; a compressed format cannot be a storage image and no texture copy converts formats,
so the compressed arrays are separate sampling targets and a compute pass copies between them:

* The encoder reads the staging layer through a sampler and writes that layer's block words into
  one region of a small ring buffer, one region per channel per page in flight — a few hundred
  kilobytes per page at BC7, not another page-sized array per slot.
* The blocks then go straight into the tier's sampling array: an engine-side
  `RenderingDevice.texture_copy_from_buffer` (see `engine_patch_surface.md`) records a
  buffer→texture copy in the *same* submission as the dispatch that produced the blocks, with the
  encoder buffer's resource tracker, so the render graph orders it after the write and barriers it
  before the material that samples the page. A page is therefore resident in the frame it was
  produced in: `encode_readbacks=0` and a readiness latency of 0 frames, measured.
* Without that engine method — a stock engine, or a build whose signature changed — the extension
  falls back to `.buffer_get_data_async` and `texture_update`s the words from the render callback
  a couple of frames later. Nothing errors; the CPU cost of a compressed page is then the buffer
  copy of its block words (a sixteenth of the half-float page at BC7) instead of nothing, and the
  page becomes ready when its blocks arrive. Page production itself is unchanged either way.
* **The ring depth is derived, not fixed.** A page holds its regions until whatever consumes its
  blocks has consumed them: with the direct copy that is the submission that recorded it, so a
  burst holds one ring page per page in flight; with the readback fallback it is the frame that
  delivers them, about two frames after the recording that requested them. The depth is therefore
  `clamp(page_budget × 2, 8, 64)` bounded by `ENCODE_RING_BUDGET_BYTES` (96 MB) and by half the
  slot count, which is what an engine without the copy needs — the earlier fixed depth of eight
  under a sixteen page budget made the ring, not the budget, the page rate: a compressed tier
  became ready at four pages per frame however much the demand asked for. `get_stats()` reports the
  admitted depth as `encode_ring_capacity`, the depth the bundle allocated as
  `encode_ring_allocated`, and the regions in use as `encode_ring_pages`.
* A region is only handed out again once the page it held has consumed it, so a readback can never
  observe a later page's blocks. The request is refused rather than reused when the ring is full,
  and the page keeps its pending flag for a later frame.
* The completion callback of the fallback runs inside the frame stall, after the frame's draw graph
  was ended, so an upload issued from there was recorded into the finished graph and discarded —
  every upload reported success while the arrays stayed empty and the whole viewport showed the
  missing-page diagnostic. That path therefore only queues the words, and the render callback
  uploads them.

**The block words hold the sRGB encoding of a colour page.** `bc_load()` converts a texel with a
`srgb = 1` flag in the dispatch's push constant — set for the albedo channel only, because the
normal and parameter pages are not colours — and the albedo array is the codec's sRGB renderer
format. The hardware's sRGB decode then hands the material the same linear value the uncompressed
staging array holds, which is what makes a compressed page match its baseline instead of rendering
brighter or shifting hue. The renderer only samples the sRGB *view* of an array when the shader
uniform carries the `source_color` hint (`material_storage.cpp`: the sRGB view is selected per
uniform, not per texture), so `_surface_material_albedo` and `_surface_svt_material_albedo` are
declared with it. A tier left uncompressed is bound the RGBA16F staging array, which has no sRGB
twin, so the hint changes nothing there. `native/tests/vt_compressed_render.gd` compares the
rendered patch **per channel** and fails above 0.02: the failure this replaced moved the blue
channel by 0.047 — the whole of it — while the luminance-only comparison the test used before saw
0.007 and passed.

**Readiness is not cleared while an encode is in flight.** That was the bug behind the stutter and the far field that loaded on one run and not the next: clearing `is_page_ready()` for the duration
of a multi-frame CPU encode made `SVT_PAGE_RETRY_FRAMES` (30) elapse on a page whose encode was
still running, so the demand pass produced it again, and again — an endless re-production and
re-compression loop. A compressed page is now ready when its blocks arrive, and a failed encode is
the only thing that clears the flag, which restores the retry as a safety net instead of a loop.
A settled far field therefore stops encoding: `encode_requests`, `ready_pages` and `svt_requeues`
do not move while the view is still.

**The cached near-field plan verifies readiness before it calls itself idle.** The near field reuses
its last plan while the camera does not move and the pool's residency is unchanged, which is what
keeps a settled view at zero main-thread cost. That shortcut used to *infer* completeness: a pass
that produced nothing while nothing was listed as missing latched the pool's residency as idle, and
the passes after it re-marked their resident pages as demanded without classifying again. A page
whose content is lost *after* that point — an encode that failed, a production dropped by the bundle
rebuild that changes the producer's generation — keeps its indirection entry and its demand record,
so the shader samples an empty layer, the demand pass keeps reporting a complete plan, and nothing
repairs the page until the camera moves or the pool's residency changes for an unrelated reason.
That is exactly the "the hole filled in when I stood still / it never filled in" difference.

The shortcut now asks the producer whether every page it is about to call resident is still ready,
and falls through to the real classification when one is not: the page is inside its retry window,
so it is produced again, and the pass reports it instead of claiming a settled view.
`avt_sector_stats["idle_ready_lost"]` is the reading — 0 while a still view really is complete, and
the number of lost pages on any pass that had to classify because of them. The cost is one lookup
per resident slot, on a loop that already touches every one of them.
`native/tests/vt_recovery.gd` drives it: with the camera still it drops one produced page's
readiness and requires the demand pass to bring it back (`debug_lose_vt_page_readiness()`, which
leaves the address, the slot and the demand record untouched, exactly as a failed encode does).

**A settled tick asks each producer once, not once per page.** Three things used to be paid per
page on every tick of a still camera, and all three are now one read of the same state:

* The near field's readiness verification is a single `count_unready_pages()` call that takes the
  bake mutex once for the whole resident set, instead of `is_page_ready(slot)` per slot.
* The far field verifies its protected roots and its chosen detail set the same way, through
  `query_page_readiness()`: the addresses are resolved first, the producer answers for the whole set
  under one lock, and only the pages that are actually stale are re-produced. The detail loop was
  split into a request pass and an act pass so the verification can be batched without changing what
  the allocator is asked for.
* **One near-field production pass per tick, not two.** The near field runs once with half the page
  budget and the far field takes whatever the near field did not spend. The near field used to run
  first with half the budget *and again* from a `vt_topup` phase with the remainder; the second call
  re-derived the same classification, re-retained the same source queue, re-primed the same source
  workers and republished the same statistics to buy at most one more page, and on a moving view that
  bookkeeping cost about half a millisecond a tick — more than all the page production it paid for.
  `vt_topup` is still reported as a phase and is now always zero.
* **The far field's share is what the near field reported not spending, and the tiers keep their
  original order.** The near field runs first because its pass publishes the near-field addressing
  state the material reads — a scene that only uses the near field must not have its first frame
  decided by the far field's. The far field's share then comes from the near field's own production
  count, which is bounded by the share it was given. Two variations were tried and both changed
  behaviour that a test pins: running the far field first flipped `_surface_material_required` on
  before the source array had stopped serving the far range, and resizing the far field's share
  changed when the far field's startup grace ends. A far page with no baked cell also assembles its
  source on the main thread, so a share too small to give it a slot re-requests and re-assembles
  that page on the next tick: a smaller share is more work, not less.
* **A phase that stops between two units of work gets its own deadline.** `vt_frame_budget_ms` is
  re-armed at the start of every phase, so it bounds one pass rather than the whole section. A
  deadline shared by the section was spent by the service check, the far field's walk and the near
  field's planning chain before the near field produced anything, so on a moving view production
  found it expired on every tick, emitted its one-page floor and stopped. That is the shape that
  makes a turning view refine in visible blocks: pages arrive one every other tick while the view
  keeps moving. The far field's footprint walk and detail loop read the same deadline; its root
  pyramid deliberately does not, because a root plan cut short leaves `settled` false and the whole
  plan is thrown away and rebuilt next tick, which never settles.
* The statistics an idle pass publishes are constants of the settled state, so a run of idle ticks
  writes them once (`Terrain3DAVTSettled::stats_current`) instead of re-hashing the same String keys
  every frame.
* **The plan key quantizes the camera's orientation as well as its position.** An exact basis
  changes the key on every frame of a pan, so every tick submitted a plan that the next tick
  replaced before the worker had finished it: the worker time was thrown away and the working set
  churned instead of converging. Yaw is snapped to 2°, pitch to 1.5° and roll to 3° — under a third
  of a frame of yaw at a fast 6°/frame pan — and the pages are still selected from the exact
  predicted transform, so only the moment a selection is re-derived moves.
* **The lead turns the gaze, not only moves the eye.** The prediction used to be a translation
  only, which is why a straight run streamed less than a turn: a turn brings new world into the
  frustum at every distance at once — 20° is 70 m of terrain at 200 m — and a plan that keeps
  looking where the camera looks now names none of it, so those pages were demanded after they
  were already on screen. The rate is estimated from consecutive forward vectors (roll sweeps no
  new world into the frustum, so it is deliberately not predicted), smoothed and clamped like the
  linear velocity, and applied as the angle `rate × vt_motion_lead_ms` about the axis the camera is
  turning around. A rotation over 25° in one interval is a snap and not a turn — `snap()`, a
  teleport, a cut — and drops the estimate instead of aiming the plan at it. The angle is capped at
  15°, which is what a 60°/s turn covers in one default lead: the cap is the cost, because the
  pages a turn sweeps in are pages the pool must then hold, and `vt_turn_budget` reads 15° as the
  same near-field mean as no turn lead (0.101 ms, against a baseline that sits on the 0.1 ms budget
  on this machine) while 45° reads 2.7× it. The readings are published as `motion_turn_deg_s` and
  `motion_turn_lead_deg` beside `motion_speed`/`motion_lead_m`.
* **The source queue is retained once per plan, not once per pass.** What the queue should keep is
  the plan plus the prefetch plan, and that only changes when a plan is installed or the prefetch
  switch flips. A repeated retention is 250 map lookups that reach the state the previous one
  already reached (`Terrain3DAVTPlan::retained()`).
* **A completed page no longer wakes every source worker.** The workers wait on a count of
  claimable entries rather than on a walk of the queue, a batch wakes one worker per entry it added
  instead of the whole pool, and a worker that finishes a page notifies nobody because finishing
  does not add work. Waking the pool per finished page put every worker in the queue for the lock
  the demand pass needed, once per page.

Measured on a settled view with 99 resident near pages and 20 protected far roots
(`native/tests/vt_idle_cost.gd`, which asserts these): near field 0.020 ms, far field 0.033 ms,
top-up 0.0001 ms, service 0.005 ms — 0.058 ms for the whole section per tick, against the
per-phase budget the test states.

Measured on a moving view, a full revolution at 6° per frame
(`native/tests/vt_turn_budget.gd`): before the single-pass change the phases peaked at service
0.010 ms, near field 1.132 ms, far field 0.072 ms, top-up 0.800 ms, with the section at 1.616 ms
peak and 0.763 ms mean; they now peak at 0.013, 0.78–1.38, 0.036–0.056 and 0.001 ms, with the
section at 0.81–1.41 ms peak and 0.16–0.17 ms mean. The near field's peak is no longer overhead but
the pages it publishes — and it publishes them because the deadline is no longer already spent when
it runs, which is the fix for a turn refining one page at a time. It is still over the phase budget,
and `avt_sector_stats["allocation_ms"]` names why: ~70 µs per page in
`Terrain3DVTPagePool::acquire_slot()` / `touch_slot()`, both of which walk the whole LRU vector
(`mark_demanded()` goes through the same path, which is what `classify_ms` spends). An index from
slot to LRU position is the fix.

What is left over the budget after that is a cold sweep — a VT settings change destroys the shared
pool, so the near field peaks at ~1.5 ms rebuilding the address directory and republishing the
material (`scan_ms` / `hierarchy_ms` / `sync_ms` / `publish_ms` / `material_ms`) — and the far field's
root pyramid rebuild, which `svt_stats` attributes to `rootreq_ms`: a far page with no baked cell
crops its source from the density-scaled region data on the main thread. That crop belongs on the
source worker; until then it is gated by the phase deadline so a rebuilt pyramid ramps in over a few
ticks. A far-field detail page must not be cut by that deadline, and neither must the
visible-footprint walk: skipping a detail page loses its demand mark and the pool evicts it, and a
walk cut in a different place each tick changes the level window, which changes the root plan's
identity and rebuilds the pyramid every tick. Both were measured as regressions before being
removed.

**The staging pool becomes a scratch ring when nothing samples it.** The three RGBA16F outputs
and the R16/R32F sources are page sized only while a tier samples them by slot. Once *both* tiers
are compressed nothing does, so the pool shrinks to the encoder ring's depth: a produced page
takes a ring page, writes its half-float channels into that layer, and the encoder reads that same
layer and stores the blocks into the page's own slot of the tier's array. The ring page is held
until the page's three block readbacks have been delivered, which is what makes the reuse safe.
The resident pool therefore drops from 30 bytes per stored texel per slot (three RGBA16F outputs
plus the R16/R32F sources) to `ring_depth / page_count` of that — at 256 pages and a 264² stored
page with the default 16 page budget, ~535 MB becomes ~67 MB (32 ring layers), and each compressed
tier's own arrays add ~53 MB. Leaving one tier uncompressed restores the page-sized pool, because
that tier samples it by slot. `get_stats()` reports `staging_layers`, `staging_scratch` and
`staging_bytes`.

**What the pool costs is reported, per tier.** `get_vt_settings()` used to answer
`physical_cache_bytes` with `(page + 2·border)² × page_count × 32`, a formula over the slot count
that ignores compression: a compressed pool looked exactly as expensive as an uncompressed one, and
a single compressed tier — which really does cost *more*, because the other tier still samples the
page-sized pool and the compressed copy is pure addition — looked free. `physical_cache_bytes` is
now the real layout (staging pool plus one compressed copy per tier that resolved), the old formula
stays as `physical_cache_bytes_uncompressed` for comparison, and the per-tier numbers are
`surface_vt_compression_bytes` / `surface_svt_compression_bytes` with the pool occupancy each tier
holds as `surface_vt_compression_slots` / `surface_svt_compression_ready_slots`. The producer
reports the same figures as `staging_bytes`, `compressed_bytes`, `material_bytes`, `avt_bytes`,
`svt_bytes` and the matching `*_slots` / `*_ready_slots`.

**The terrain's cost carries a `terrain/` keyword.** The node runs as a GDExtension method, so the
engine's profiler cannot attribute its time. It publishes custom monitors named
`terrain/vt_cpu`, `terrain/vt_cpu_peak`, `terrain/avt_cpu`, `terrain/svt_cpu`, `terrain/cdlod_cpu`,
`terrain/material_bytes`, `terrain/pages_ready` and `terrain/pages_pending` (seconds, bytes and
counts, with the monitor types that make the editor format them), which the editor's monitor graph
groups under `terrain`. The same phases are emitted as profiler zones and plots — `terrain/vt`,
`terrain/vt_service`, `terrain/vt_avt`, `terrain/vt_svt`, `terrain/vt_topup`, `terrain/vt_bake`,
and plots `terrain/vt_cpu_ms`, `terrain/avt_cpu_ms`, `terrain/svt_cpu_ms`, `terrain/material_mb`,
`terrain/pages_ready`, `terrain/pages_pending` — through the profiler singleton the engine exposes,
and only while a profiler client is connected. A second terrain in one scene publishes under its
instance id (`terrain/<id>/...`) so the plain names never collide.

**Both tiers' peaks carry their own breakdown.** `avt_sector_stats` has always attributed the near
field's pass; the far field's cost had no attribution at all, so a peak in `svt_cpu_ms` could not be
told apart between the footprint walk, the level window and cap, the root pyramid plan and the
detail set. `get_vt_settings()["svt_stats"]` is the breakdown of the far field's **worst** pass —
`regions_ms`, `walk_ms`, `capacity_ms`, `mip_ms`, `rootlist_ms` / `rootunpin_ms` / `rootreq_ms` /
`rootcov_ms`, `detail_ms`, with `walk_visited`, `visible_pages`, `roots`, `roots_skipped`, `chosen`,
`detail_capacity`, `visited`, `produced` and `requeues`. `svt_worst_ms` and `svt_worst_frames_ago`
say how bad and how long ago, so a one-off reconfiguration is not read as a steady-state cost. It is
the worst pass rather than the last one because a running view's typical pass is a tenth of its worst
one, and the stages are collected in locals so only the pass that becomes the new worst writes the
dictionary — the instrumentation is not on the hot path it measures.

The near field's peak needs the same treatment for the same reason, and gets it:
`get_vt_settings()["avt_peak_stats"]` is a copy of `avt_sector_stats` as of the pass that produced
`vt_avt_peak_ms`, with `avt_peak_age_ms` saying how long ago. The live dictionary is overwritten by
every pass, and the peak is by definition not the last pass, so a peak read from the live one
describes something else entirely. That is what made the near field's remaining cost attributable
rather than guessed: its peak is the planning chain (0.125 ms, re-plan ticks only) plus a production
pass whose largest stage is `prime_ms`, and the stage timings inside a pass are split far enough to
say so (`stats_ms`, `worker_stats_ms`, `protect_ms`, `commit_ms`, `request_ms`, `invalidate_ms`,
`prime_insert_ms`, `prime_wake_ms`, `refill_ms`).

**A phase's wall time can contain a descheduled main thread.** The demand pass used to wake the
source workers inside the phase it was being timed in — `prime` measured 0.14–0.25 ms for seven
inserts, 20–35 µs per insert — because the workers it had just woken started assembling pages on the
same cores. `Terrain3DPagePipeline::flush_wakes()` now defers those wakes to the end of the producing
pass, so the workers start against the render instead of against the tick that submitted their work.
Nothing is lost: work submitted by a pass cannot be assembled within it, and the previous pass's work
has had a whole frame. Measured on the near field: peak 0.84 → 0.62 ms, `produce_ms` 0.54 → 0.31,
`finish_ms` 0.31 → 0.05, `prime_insert_ms` 0.136 → 0.050, painted result unchanged. The tick marks its
section active while it runs, so the passes do not flush inside it and the tick flushes once, after
`vt_cpu_ms` has been taken — the wake belongs to neither the phases nor the section.

**What is left of the near field's cost is in its source queue, and it does not respond to the
obvious fixes.** Recorded so they are not tried again:

* `prime_insert_ms` does not scale with the number of inserts (4 inserts measured 0.093 ms, 12
  measured 0.191 ms in one run and 0.117 in another), so the window is the queue's acquisition and
  being scheduled, not the insert loop.
* Replacing `std::map<Key, Entry>` + `std::set<pair<token, Key>>` with a flat `std::vector<Entry>` and
  a flat FIFO of keys — no node allocation per insert, one bookkeeping invariant instead of two —
  measured neutral on every phase. It is kept for being simpler, not for being faster.
* A spin-then-block acquisition measured no better: the spin does not shorten the wait, it *is* the
  wait, of the same magnitude as the wake latency it was meant to avoid. Removed.
* One worker instead of four still measured 8 µs per insert, so it is not worker contention.

Identical code then measured `avt_mean` 0.113–0.144 across runs, which is the same size as the gap to
the 0.1 ms budget. Closing it needs a quieter measurement before it needs another optimisation: the
release template rather than the debug one, or a pinned process. The two structural candidates are
named above the noise floor rather than chased through it — stop sharing one mutex between the demand
pass and the workers' claim/complete path, and stage the planning chain (only `scan` and `hierarchy`;
`sync` + `publish` + `submit` must stay in one tick).

**The geometry backend is named too, from where it actually runs.** AVT and SVT are tick phases, so
their zones sit inside the tick's `terrain/vt`. CDLOD is not a tick phase: the rendering server
calls it through `frame_pre_draw`, in the pass that draws the frame, so it opens its own zones from
there — `terrain/cdlod` for the pass, `terrain/cdlod_select` (quadtree selection, only when the eye
moved), `terrain/cdlod_cull` (the frustum classification pass), `terrain/cdlod_pack` (instance
packing) and `terrain/cdlod_upload` inside it (the RenderingServer buffer calls) — and plots
`terrain/cdlod_ms`, `terrain/cdlod_patches` and `terrain/cdlod_visible`. `terrain/cdlod_cpu` is the
same pass's cost for the editor's monitor graph. The profiler's zone stack is per thread, so a
backend that runs on the rendering thread publishes on the rendering thread's timeline rather than
beside `terrain/vt_*`; the names still group together in the profiler's own zone list, and the
profiler singleton lookup is cached per thread so two threads never share one cache entry.

Two consequences of the ring, both deliberate: a capacity growth re-produces every resident page
instead of migrating it (there is no per-slot half-float layer left to copy, and a block format
cannot be copied between arrays on D3D12), and `export_page()` / the dock preview read a page's
block words from its tier's array and decode them, because the layer it was produced in has long
been reused. An invalidation no longer clears a staging layer under the ring — nothing samples it,
and the layer it could name may belong to a page whose encode is still in flight.

Tests: `native/tests/vt_compression.gd` + `vt_compression_runner.py`. It walks every enum entry
and asserts the resolution invariants: an accepted request must equal `available` and carry no
reason, a refused one must fall back to 0 with a non-empty reason (naming alpha where that is
the cause), and at least one alpha-capable codec must be usable in the build under test. It then
compresses and decodes a probe image through the resolved codec and requires the error to be
non-zero but bounded (BC7 on the probe: max 0.0078, mean 0.00097), that the uncompressed round
trip is exact, and that a fixture which produced pages reports
`vt_atlas_compression_applied == available` — the arrays are actually built in the accepted
format. On this machine that is BC7 (`applied=1`) with BC3 RGBA accepted as well.

`native/tests/vt_compressed_render.gd` drives the real renderer through both tiers: BC7 and BC3
on the near field (patch means within 0.01 of the uncompressed frame, no magenta), the same two
codecs on the far field with the near field switched off so the patch can only come from the SVT
arrays, and the encode-once property above. It then compresses *both* tiers, which is the case
that puts the staging pool in scratch mode: it requires the pool to fall below the slot count
(`staging_layers < page_count`, `staging_scratch`), renders both tiers out of the ring, and
exports a resident page through the decode path the dock preview uses. It also measures that one
demand pass hands the producer the same number of pages with and without compression.

**Two traps this cost.** The compressed arrays are created with `SAMPLING | CAN_UPDATE |
CAN_COPY_FROM` and nothing else. `CAN_COPY_TO` also looks harmless, but on D3D12 it sets
`D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS`, which a block-compressed resource cannot carry, so
`texture_create` returns `CreateResource failed with error 0x80070057` — while
`texture_is_format_supported_for_usage()` (the capability probe) says the format is fine, because
it answers for the pair it was asked about. A device that refuses the real allocation now resets
`available` to 0 with a reason instead of claiming a format the pages are not stored in.
`CAN_COPY_FROM` is the opposite kind of flag: it needs no D3D12 resource flag at all, and it is
what lets a resident page be read back once the scratch pool has reused the layer it was decoded
from.

**A format change is not a reconfiguration.** The three arrays are rebuilt in place by the
producer (its own generation bump), so `set_surface_vt_compression()` /
`set_surface_svt_compression()` (and the legacy `set_vt_atlas_compression()`) must not call
`_reset_vt_configuration()`. Doing that detached both views from the shared pool, released
every resident page and then let the demand pass grow the pool back to the capacity it had
already published — which is what produced a user-visible
`WARNING: Virtual texture pool grew to N pages; resident pages were released ...` on a plain
property change in the inspector. The pages do have to be produced again, because the
rebuilt arrays start blank: the setter forces `invalidate_surface_pages(location, true)` for
every loaded region, which also skips the editor-preview deferral (a deferred refresh would
leave the material sampling arrays that no longer hold its content).

**A reconfiguration reuses the published capacity.** `Terrain3DVTPool::capacity` (the
`Terrain3DVTPool` struct in `terrain_3d_vt_state.h`) records what the views were actually configured
with, is raised by the auto-capacity publication and replaced by an explicit `vt_page_count`, and
`_configure_vt_service()` configures the views and the producer with
`MAX(vt_page_count, pool.capacity)`. Starting again from the setting would make the demand pass
re-grow the pool right after the rebuild, releasing every page a second time. `get_vt_settings()`
exposes `effective_page_count` and `pool_generation` (bumped once per pool build) so this is directly
assertable, and the pool's growth warning is emitted only when slots were actually released, with the
count.

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

**Where the red set stands now (2026-09-23).** The lists above describe the tree as each fix landed;
the tree has moved since. A full `run_all.py` pass on the rebuilt debug template and D3D12 ends at
**60 of 75** (`bin/suite-2026-09-23.json`); after the fixes recorded in
`avt_addressing_redesign.md` section 6.8 - the shader's resolve flag, two stale world-level probes and
`vt_near_arrival`'s fixture default - the suite is **64 of 75**
(`bin/suite-2026-09-23-round2.json`) and the remaining reds are `vt_adaptive:scale`, `:metric`,
`:ownership`, `:rotation`, `:blend`, `:sectors`, `vt_strict_coverage`, `vt_turn_budget`, `vt_render`,
`texture_compression` and `editor_dock:setup`. Per-test attribution with the A/B evidence is in
`avt_addressing_redesign.md` section 6.7. Five entries in that record were never assertion failures
and are now gone from the set:

* `vt_adaptive:navigation` was red on one engine `ERROR:` line - `_grab_camera: Cannot find clipmap
  target or active camera` - and both of its own assertions passed. Enabling VT delivery turns the
  terrain node's tick back on, so the tick after the test freed its camera had no camera to find.
  The four tests that free a camera now stop the tick first.
* Every other test was reported red partly by `ERROR: Failed to read the root certificate store.`,
  which this machine's engine prints once per launch. `fixture.ENVIRONMENTAL_ERRORS` and
  `fixture.log_errors()` exclude it from both the runners' `ERRORS=` count and `run_all.py`'s
  verdict; a clean runner now exits 0 with `ERRORS=0` again.
* `vt_near_arrival` was reported red with no script output at all: it exited 2 in 0.1 s because its
  default source project was the leftover `bin/terrain-project-lifetime-ke6fwkn0`, a directory
  `vt_project_lifetime_probe.py` names with a random suffix and `run_all.py --prune` deletes. It now
  defaults to the real project `vt_strict_coverage_runner.py` copies, runs in 51.6 s and passes.
* `vt_transition_parent` was red because `avt_resolve()` declared `bool allow_coarse`, was passed
  `_avt_feedback`, and never read it - so a missing fine page resolved through a resident ancestor
  even with coarse recovery off. The upgrade loop reports the miss when the flag is off now, which
  also cleared `vt_adaptive:filtering`.
* `vt_visibility` was two model assumptions: a fixture that never asked for the far field still got
  SVT demand from the shipped delivery matrix, and the engine's own tick produced the page its
  one-shot manual call was about to ask for.
* `vt_adaptive:filtering` additionally probed world levels with per-level owner keys
  (`0x40000000 + level * 0x100000`) that the redesign replaced with the coarse owner's mips, and
  derived a level count from the sector hierarchy rather than from the coarse block.

`vt_adaptive:sectors`' edit phase used to fail in a quarter of the runs in both plan orders - a
test-side race, not the plan: `settle_sectors()` waited for the producer to go quiet but not for the
view to have no missing pages, so it could take its "settled" verdict before the edit's 35 pages had
been refilled one per tick. It now requires `visible_missing_pages == 0` too, and 8 of 8 runs after
the change reach `VT_SECTORS_EDIT color=red` with 24 zero-producing ticks. The only stable line left
in that test is `512 m region contains independently addressed 64 m sectors`.

`texture_compression` is red again on the class section 6 records as fixed: two engine errors per run
(`Parameter "uniform_set" is null.`, `Uniforms were never supplied for set (0) at the time of
drawing`) while its own assertion passes, reproducible in 2 of 2 runs.

`vt_adaptive:ownership` is down to one assertion (section 6.9 of `avt_addressing_redesign.md`): the
near-field plan does not cover the cell under the camera. Measured - plan origin equal to the camera
origin, motion lead zero, the cell among the scan's 100 visible sectors, `denied=0`, and a plan of 18
pages all at local mip 2 on cells 356-484 m away in +X; 300 further frames (about 7 s) leave it that
way. An orthographic camera answers the same density for every cell, so the deficit key differs
between equally-sized cells only by sampler noise and the comparator tests it with `!=` before its
span and distance tie-breaks. That is the next thing to take, with the A/B section 6.4 was accepted on.

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
| Far-field demand, both tiers' settings and lifecycle | `native/src/terrain_3d_surface_views.cpp`, `terrain_3d_surface_views_far.cpp`, `terrain_3d_surface_views_far_walk.cpp` |
| Page table (indirection), per-view addressing | `native/src/terrain_3d_virtual_texture.{h,cpp}`, `terrain_3d_vt_indirection.{h,cpp}` |
| Shared physical pool: atlas, slots, LRU, ownership | `native/src/terrain_3d_vt_page_pool.{h,cpp}` |
| Producer worker, source snapshot, `.vtcell` contract | `native/src/terrain_3d_page_pipeline.{h,cpp}`, `terrain_vt_cell.h`, `terrain_3d_vt_service_bake.cpp` |
| Service settings, lifecycle, page plumbing, diagnostics | `native/src/terrain_3d_vt_service.cpp`, `terrain_3d_vt_service_pages.cpp`, `terrain_3d_vt_service_report.cpp` |
| Resident far-field cell sources (GPU arrays, budget, eviction) | `native/src/terrain_3d_vt_cells.{h,cpp}` |
| GPU page demand | `native/src/terrain_3d_vt_feedback.{h,cpp}` |
| Shader-side addressing and sampling | `native/src/shaders/main.glsl` |
| Geometry backend | `native/src/terrain_3d_cdlod.{h,cpp}` |

The per-test index, including what each script pins, is `native/tests/README.md`.
