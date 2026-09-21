# Alignment with the HDRP adaptive virtual texture

## 1. Scope and status

The reference implementation at `D:\godot\HDRPVirtualTexture` (Unity 6000.1.11f1, HDRP,
UPM package `com.noovertime.virtual-texture`, author lifangjie / NoOvertime) was read
end to end. This document records what this addon takes from it, what it does not, in
which order the work lands, and how each step is verified.

**This is a plan. Nothing below describes current code unless it says so.** Every claim
about current behaviour cites a file and line.

**Status at the last revision of this document.** P0 through P0e are done, P0f is closed on the
measurement, **P3 (H2)** has landed as a mode with the default unchanged, **P4 (H3)** has landed twice
- the runtime raise (step 1) and the *setting* (section 7.7.9) - with the test corrected alongside step
1, **P5's probe is answered**, **P6 is measured and its 200 ms pass is attributed to one stage**, and
**P1's three seams have all landed** (section 5). Nine code changes: a behaviour-neutral diagnostic fix
(section 7.6.1); the plan's **rate term** (section 7.7.2), a measured 12-13% reduction in pool churn
and 76% less unsampled residency at unchanged CPU cost; the **churn counters** of P0e (section 7.7.3),
diagnostics only; the **fallback-policy seam** with HDRP's per-unit guarantee as its second strategy
(section 7.7.4); the **capability report** that answers the H4 probe on the running binary (section
7.7.5); **`VTMipRule` + `VTPageDemandSource`** (P1) - the far field's level arithmetic moved into the
engine-free contract surface and the two demand-source questions given one owner; the **cap change is
not a content change** (section 7.7.6), a whole-world re-bake deleted from the level-raise path; the
**per-owner depth counters** (section 7.7.7), which replaced a first attempt that could only read one
value; and **the cap setting's whole-pool rebuild deleted** (section 7.7.9), which the probe measures as
512 resident pages kept where the old path released them. Implemented and **rejected**, all kept in the
record: the demand-aware page split (section 7.7.1), P0e's first-revision counter that asked the wrong
question, and P2's first-revision counter that could not ask its question at all. **P2's premise is
corrected and its acceptance withdrawn as measuring the wrong mechanism** (section 7.7.7): the near
field's level rule is stable per owner and the churn is lateral. **P4 is now closed on all three
instances**: step 1 and the setting landed (sections 7.7.6, 7.7.9), and step 2 - the dynamic remap - is
*not applicable to this addressing*, on evidence rather than on a deferral (section 7.7.10: the grid is
derived from the capacity, the atlas is one `Texture2DArray` recreated blank when it grows, so `grow()`
evicts every slot and there is no capacity change that moves addresses without destroying content; HDRP
remaps because its physical table never grows). That section also corrects two comments that claimed
growth keeps residency, measures the wipe in a normal session (`evict` +355 with no generation bump),
and A/Bs `vt_auto_capacity` off (-4% `alloc`, +21% `evict`, deficit peak unchanged at 102). **No clause
of the objective is left unlanded**: H4 is closed in both of its forms (section 7.7.5 and its addendum),
H3's remap is closed structurally (section 7.7.10), and the two remaining items are measurements rather
than mechanisms - P2's boundary terms and the enabling engine patch a screen-driven source would need.
Section 1.1 is the per-clause table. Nothing is committed.

The agreed scope is:

* Adopt the mechanisms where HDRP AVT is genuinely stronger.
* Also fill the gaps where HDRP AVT has a mechanism this addon lacks -- dynamic remap of
  the resident set on a level-space change is the example.
* **Keep** the far-field SVT, the page-arrival fade, the motion/turn lead, the address
  budget, the diagnostics and the tests. These are extensions HDRP AVT does not have.
* Express the result as strategies behind existing seams, not as a rearrangement of the
  existing files (section 5).

Replacing the address space wholesale was considered and rejected; section 3 is why.

### 1.1 What the objective asked for, and where each part landed

One row per clause of the work this document was written for, so the state is auditable without reading
1700 lines. "Landed" means code plus a targeted self-test; "closed" means a measured or structural reason
not to write the code, recorded where the reason was found.

| Asked for | State | Evidence |
| --- | --- | --- |
| Plan/decision document first, then step-by-step implementation | **Landed** | this document; each phase in section 8 carries its measurements |
| Fragment-level feedback (H4) | **Closed, two engine-level reasons** | section 7.7.5 (no storage-image type in the shading language, so a `shader_type spatial` fragment cannot write a UAV) and section 7.7.5's addendum (the render-thread hook passes no frame context, and its FRP operation is ordered "before the G-buffer", so a compute pass cannot see the screen either). The enabling fork patch is named; no measurement asks for it |
| Pixel-footprint level rule (H1) | **Answered** | far-field form closed by section 7.3's arithmetic; the near field already has it and section 7.7.7 measures it stable per owner (`avt_depth_down` 0-2). The level rule is a value on the seam (`TerrainVT::MipRule`, pinned by `test_mip_rule()`) |
| Per-resident-unit coarsest page (H2) | **Landed as a mode, default unchanged** | `surface_svt_fallback_policy` with `_svt_global_root_pyramid()` / `_svt_per_unit_coarsest()`; measured in section 7.7.4 (20 -> 1 pinned page, `served` unchanged) |
| Far-field level remap (H3) | **Closed: the mechanism's case does not exist here** | step 1 (runtime raise) and the setting landed (sections 7.7.6, 7.7.9); the remap itself in section 7.7.10 (the grid is derived from the capacity and the atlas is recreated blank when it grows, so the address change and the content loss are one event; HDRP remaps because its physical table never grows) |
| Replace/complete the AVT+SVT demand and fallback logic | **Landed** | the demand-source seam (`CPURule` / `Projected`, section 5) and the fallback-policy seam; section 5's table records what each landed *as* |
| Keep feng's non-conflicting optimizations | **Kept** | far-field SVT coverage, page fade, motion/turn lead, address budget, diagnostics: all still present, and the far field's own miss rate stays ~1/frame in the phase E cruise; the plan's rate term *improved* churn 12-13% (section 7.7.2) |
| Collapse demand source / level rule / fallback policy into low-coupling strategy interfaces | **Landed** | section 5, all three seams, with the layer-not-alternative correction |
| Every step compilable (`scons platform=windows target=template_debug`) and self-tested | **Landed** | `scons: done building targets.` after every change; the targeted runner named in each row of section 8 |
| The agent never commits | **Honored** | nothing is committed; the working tree is the deliverable |

Two clauses - H4 and H3's remap - are closed rather than built, and both closures are *capability*
answers rather than deferrals: each is impossible or pointless in this renderer for a stated reason,
with the code path that would have to change named. Everything the objective could land, landed.

### 1.2 The two projects' shapes

| | HDRP AVT | This addon |
| --- | --- | --- |
| Language / host | C# + HLSL on Unity HDRP, 26 files, ~80 KB | C++ GDExtension + GLSL on a Godot fork, VT machinery ~10 kLOC |
| Sector / page / border | 64 m / 256 / 4 (264 stored) | 64 m / 256 / 9 (274 stored) |
| Indirection | 1024 x 1024 `R16_UINT`, 9 hand-written mips | near 2048 x 2048 `R32F`; far `max(64, page_count * 4)` entries, hand-written mips |
| Indirection payload | physical slot, 16 bit, 65535 = empty | physical slot, 11 bit, 65535 = empty |
| Physical pool | 1023 layers x 264 x 264 `R8G8B8A8`, two atlases (~570 MB) | configurable 8..1024 layers, same page shape, one atlas per tier's storage format |
| Max density | 1024 texel/m per sector (`HighestResolution` 65536) | near `surface_vt_texels_per_meter` 1024; far `surface_svt_texels_per_meter` 1.0 |
| Reach | camera sector +- 6 sectors (~384 m) | near 384 m (`surface_vt_distance`, section 7.7.14), far 6144 m (`surface_svt_distance`) |

## 2. Already HDRP AVT

The addressing core is a port, not a design that happens to resemble one. Rebuilding any
of the left column would be re-implementing what exists.

| HDRP AVT | This addon | Notes |
| --- | --- | --- |
| `Runtime/Core/VirtualImageAtlas.cs` | `TerrainVT::VirtualImageAtlas`, `terrain_vt.h:152-380` | Same 4-ary tree, same `parent = (index - 1) >> 2`, same child index `index << 2` + 1..4, same low-coordinate-first DFS push order (`push_children`, `terrain_vt.h:354`), same "a non-minimal node must have no occupied descendant". `occupied_area_` replaces HDRP's child count so the accounting stays valid with all 65536 leaf blocks allocated. |
| `InsertImage` / `RemoveImage` | `try_insert_avt_image` / `remove_image` | Same. |
| `ReallocateVirtualPagePass.ReallocateVirtualImage` (allocate the new block, remap, release the old) | `try_resize_avt_image` + `_remap_sector_pages`, `terrain_3d_virtual_texture_sector.cpp:85-144` | Same transaction, plus an explicit rollback of the old node when the new size cannot be placed. |
| `IndirectionTexture.RemapVirtualImage` (a page keeps its world footprint, so a doubling moves it one mip) | `new_mip = old_mip + new_max_mip - old_max_mip`, `terrain_3d_virtual_texture_sector.cpp:120` | Identical rule. |
| `Runtime/Core/IndirectionTexture.cs` (hand-written mip chain, per-mip writes, per-image clearing) | `Terrain3DVTIndirection`, `terrain_3d_vt_indirection.{h,cpp}` | Same idea; upload is coalesced into 16x16 tile patches and scattered by a compute shader instead of HDRP's separate mip0 / other-mip kernels. |
| `VirtualTexture.hlsl: MatchMipLevel` (walk coarser, `>>= 1`, until a resident slot) | `TerrainVT::try_match_indirection_slot`, `terrain_vt.h:59-89` | Same walk, same "the level it succeeded at is the level sampled". |
| `PhysicalPageAtlas` + `LRUCache` (miss evicts the least recently used slot, and the evicted page's indirection entry is cleared as it goes) | `Terrain3DVTPagePool` + `_request_virtual`, `terrain_3d_virtual_texture_lookup.cpp:32-73` | Same, plus an acquire/commit/abort transaction HDRP does not have: the victim is only *chosen* at acquire and actually evicted at commit, so a producer that fails destroys nothing. |
| `Constant.cs` page geometry | `Terrain3DVTState`, `terrain_3d_vt_state.h:491-500` | Same numbers, same stored-size-with-border arithmetic. |
| Address size from screen footprint | `terrain_3d_sector_avt_hierarchy.cpp:116-119` (`screen_mip = log2(texels_per_meter / required_density)`, `wanted = base >> screen_mip`) | Same idea as HDRP's `CalculateTargetImageSize`, driven by a required density rather than a switch distance. |
| `Sector2VirtualImageInfoTexture` (one uint per sector carrying image origin and size log) | `_avt_sector_directory` (`RGBA32F`, two texels per sector) read by `avt_find_sector`, `main.glsl:555-560` | Same job, different encoding (origin and size as floats rather than packed into one uint). |

Two additions of this addon's that HDRP AVT does not have and that must survive:

* **Address-space budgeting.** `virtual_bias` (`terrain_3d_sector_avt_hierarchy.cpp:209-216`)
  halves every sector's requested block until the visible set fits. HDRP lets `InsertImage`
  fail and asserts under `DEBUG_TERRAIN`. Keeping this is a deliberate divergence.
* **Residency policy under pressure.** A shared coarseness floor (`svt_floor_level`) plus a
  pinned root pyramid, rather than failing an allocation
  (`terrain_3d_surface_views_far_walk.cpp:453-473`).

## 3. Why the address space is not replaced

HDRP AVT is not "a far field too", it is **a 384 m near field with no outside**. Two
constants make that exact, and they are tuned against each other:

* `ReallocateVirtualPagePass.UpdateRequestSectors` (`ReallocateVirtualPagePass.cs:67-94`)
  walks the terrain quadtree only to enumerate a disc: a node is descended into while
  `sqrDistance < (halfSize + SectorPreloadDistance)^2`, and only 64 m leaves with
  `sqrDistance < SectorPreloadDistance^2` (`= 6^2`) enter `_requestSectors`. Everything
  else is removed from the atlas, its image released and its indirection entries cleared.
  So the active set is a disc of radius 6 sectors = **384 m**, capped by
  `MaxPreloadSector = 256`.
* `Utility.CalculateTargetImageSize` (`Utility.cs:36-48`) uses the **squared** distance,
  `t = |d|^2 / SwitchDistance` with `SwitchDistance = 64*64*1.5 = 6144`, and
  `size = 65536 >> ((int)log2(t) + 1)` for `t >= 1`. At 384 m that lands exactly on
  `MinimalVirtualImageSize` (2048 texels = 32 texel/m). Beyond the disc, the sector has no
  image, `Sector2VirtualImageInfoTexture` reads 0, `OutputPageID` writes 0 and `SampleVT`
  returns 0, so HDRP's terrain falls back to its own global map.

The fallback mechanism HDRP uses inside that disc is **one guaranteed coarsest page per
resident sector** (`DeduplicateJob` adds, for every resident virtual image, the page at
`mip = sizeLog`, i.e. a single physical page covering the whole 64 m sector). That
guarantee is what bounds HDRP's reach, because the pool must hold one page per sector:

| Pool | Detail pages | Guaranteed pages | Reach (one page per sector) |
| --- | --- | --- | --- |
| 256 (this addon's default) | ~200 | ~56 | `sqrt(200/pi)` ~= 8 sectors ~= **512 m** |
| 1024 (the dock's maximum) | ~800 | ~224 | `sqrt(800/pi)` ~= 16 sectors ~= **1024 m** |

512 m is exactly `surface_vt_distance`'s default. So at the default pool, HDRP's per-sector
guarantee reaches exactly as far as this addon's near field -- and this addon reaches
6144 m only because the SVT world grid lets **one page cover kilometres** instead of one
sector. A faithful port would therefore delete the far field, and with it:

* the 512 m .. 6144 m VT coverage (the region array at `region_size` 256 is 1 texel/m,
  so distance falls back to that),
* and nothing else: the fade (`vt_page_fade_frames`, `terrain_3d_vt_fade.cpp`), the
  motion/turn lead (`vt_motion_lead_ms`, `terrain_3d_sector_avt_motion.cpp`), the address
  budget and the diagnostics are all orthogonal to the address space and would survive.

Since the far field is the subsystem that exists to solve the far field, the work below
adopts HDRP's *mechanisms* without adopting its *reach*.

## 4. Adopted mechanisms

Each item states what HDRP does, what this addon does today, what changes, where it lands,
the risk, and how it is verified. H1-H3 are the substance; H4 is gated on a feasibility
probe; H5 is verification only.

### H1. The pixel-footprint level rule

**HDRP.** `VirtualTexture.hlsl: GetVirtualPageID` takes the fragment's level from
`MipLevelAnisotropy(positionWS.xz, MAX_TEXEL_DENSITY)`, a port of the D3D anisotropic LOD
specification with `maxAniso = 8`, and moves it into the sector's own virtual-image mip
space with `- 8 + virtualPageSizeLog`, clamped to `[0, virtualPageSizeLog]`. Demand is
therefore a function of the pixels the fragment actually covers.

**Today.** The near field already selects its block size from the screen footprint
(`terrain_3d_sector_avt_hierarchy.cpp:116-119`) and the shader already computes one
(`avt_pixel_footprint`, `main.glsl:466-479`, singular values of the world-XZ pixel
Jacobian with an anisotropy cap). The far field instead selects a level by distance:
`Terrain3D::get_surface_svt_mip_for_distance()` (`terrain_3d_surface_views_far.cpp:36-57`)
and its exact mirror `surface_svt_mip_for_distance()` (`main.glsl:347-363`), optionally
replaced by the user's explicit band table (`surface_svt_mip_distances`, edited in the
dock by `vt_editor_svt_bands.gd`).

**Change.** Add the footprint rule as a third mode of the far field's level selection, next
to the automatic distance bands and the explicit table. The rule itself goes into
`terrain_vt.h`, beside the addressing contract it belongs to and where the engine-free test
can pin it; the GLSL mirror goes beside `surface_svt_mip_for_distance()` in `main.glsl`.

**Why it addresses the reported far-field update traces.** A distance rule asks for the
level by how far a page is, so a page 3 km out is requested at the same level whether it
covers 2 pixels or 200. The requests therefore move whenever the *distance* changes, which
a turn changes constantly. A footprint rule asks for what the screen supports, so the
requested set is stable while the screen extent is, and it stops over-requesting at the
far end. It also removes the `maximum_mip` ratchet that triggers the global re-bake in
section 7.

**Where.** `native/src/terrain_vt.h`, `native/tests/vt/terrain_vt_contract_test.cpp`,
`native/src/shaders/main.glsl`, `native/src/terrain_3d_surface_views_far.cpp`,
`native/src/terrain_3d_surface_views_far_walk.cpp` (the `near_mip`/`far_mip` selection at
`:306-307` and the raise at `:425-431`), `native/src/terrain_3d_vt_state.h` (the mode), the
setter in `terrain_3d_surface_views.cpp`, the dock's band panel.

**Risk.** Medium. The two sides must agree exactly, which is the same discipline
`world_page_to_virtual()` / `surface_svt_sample()` already follow; the engine-free contract
test is where that is pinned. The CPU side must *model* the fragment's footprint (it
already does for the near field, through `avt_texels_per_pixel` and the required density);
under H1 alone the CPU model can be wrong where the GPU is right, which is the gap H4
closes. Switching the **near** field onto the same shared rule is a separate later step,
because the near field is tuned and its tests (`vt_turn_budget`, `vt_near_arrival`) are
sensitive.

**Verify.** `native/tests/vt/terrain_vt_contract_test.cpp` (the shared rule, engine-free),
then `vt_mip_bands`, `vt_anisotropy`, `vt_svt_coverage`, `vt_demand`, `vt_turn_budget`.

**Closed, in two different ways on the two sides.** The **far-field** form was closed by section 7.3's
arithmetic (a CPU-only footprint rule is the distance rule with a per-frame density offset) and H4's
fragment form is closed with it (section 7.7.5: the shading language cannot express a storage image, so
a fragment cannot author demand). The **near-field** form was carried by P2 on the assumption that the
near field's rule was unstable, and section 7.7.7 measured that assumption away: the near field already
has the footprint rule, and it is stable per owner (`avt_depth_down` 0-2 per generation). What the
section leaves behind is not a level rule but the *boundary*'s sensitivity to its discrete density
terms. So H1's remaining work in this document is one measurement, not a mechanism.

### H2. The per-unit coarsest-page guarantee

**HDRP.** `DeduplicateJob` de-duplicates the read-back page IDs and then adds, for every
resident virtual image, one additional page at `mip = sizeLog` -- the coarsest level that
image can express. Every unit is therefore always resolvable from a *local* fallback, and
`MatchMipLevel` can always stop inside the unit.

**Today.** The far field's fallback is a **global root pyramid**: `surface_svt_root_mips`
(default 2) pinned coarsest levels, planned and verified by `_svt_plan_roots()`
(`terrain_3d_surface_views_far_walk.cpp`), with the shader's coarser walk gated by
`_svt_feedback` (`main.glsl:384`, `:509`). It guarantees coverage of *every* world position
(asserted by `vt_root_coverage`) at a granularity of kilometres per page.

**Change.** Add HDRP's guarantee as a second **fallback policy** beside the root pyramid:
request each resident unit's coarsest level unconditionally, on every pass, so the
fallback's granularity is the unit (a band, or a mip-0 page neighbourhood) instead of the
whole world. Both policies publish into the same pinned set, so the existing protection
budget (`protected_limit`, `slot_protect_refs[]`) applies unchanged.

**Why.** It is the mechanism that makes the *size* of an update trace small: a fallback
page that lands or leaves changes its own unit's rectangle, not a continent. It is also the
only way to shrink the root pyramid without losing the "any position resolves" guarantee.

**What it is not.** It does not extend the reach (section 3's arithmetic applies to
whatever pool this addon uses), and it is not obviously better than the root pyramid for
this renderer, where the pyramid's job is to make the region array unnecessary. Adopt it as
a **measured alternative**, default off, and switch the default only on numbers.

**Where.** `_svt_plan_roots()` becomes a policy with two strategies; the records already
exist (`Terrain3DSVTRootPlan`, `terrain_3d_vt_state.h:759-766`).

**Risk.** Medium. Removing the root pyramid is a coverage regression if the guarantee set
does not fit the pool; keep both and measure.

**Verify.** `vt_fallback`, `vt_root_budget`, `vt_root_coverage`, `vt_svt_root_mips`,
`vt_near_arrival`, `vt_page_fade`.

**Landed as a mode, and rejected as a default - section 7.7.4 has the measurement.** The policy is
`surface_svt_fallback_policy` (0 = the root pyramid, the default; 1 = the per-unit guarantee), the
two strategies are `_svt_global_root_pyramid()` and `_svt_per_unit_coarsest()` behind
`_svt_fallback_pages()`, and `vt_root_coverage` now asserts each policy against its own contract.

### H3. Dynamic remap of the far field on a level change

**HDRP.** `IndirectionTexture.RemapVirtualImage` moves resident indirection entries when a
virtual image is resized, so no content is thrown away and no frame renders a hole. It is
the reason HDRP can reallocate on every camera move past
`CameraPositionSqrDeltaThreshold`.

**Today.** The **near** field has this: `try_resize_avt_image()` allocates or rolls back,
and `_remap_sector_pages()` (`terrain_3d_virtual_texture_sector.cpp:85-144`) moves every
resident page to the mip that keeps its world footprint, via
`Terrain3DVTPagePool::move_owner()`. The **far** field's equivalent event is a level-cap
change - `_update_visible_svt()` raises `maximum_mip` and calls `set_world_max_mip()`
(`terrain_3d_virtual_texture_lookup.cpp:144`) - and it did not have it: until H3 step 1 that
path marked **every region** in the world bake-dirty, reset `bake.edit_time` and rebuilt the
material's region arrays (`terrain_3d_surface_views_far_walk.cpp:433-438` at `HEAD`). That
was a whole-world re-bake for a change that, as far as the address space is concerned, is a
bound on which mips `request_world_page()` accepts.

**Change.** Split the two things that were one:

1. **A cap change is not a content change.** Resident indirection entries stay valid across
   it, because `virtual = (page + half) >> mip` is level-invariant -- raising the cap
   enables coarser *requests*, it does not move what is already published. So a raise
   publishes the new cap (a uniform) and nothing else; `bake.dirty_regions` and
   `material->update(REGION_ARRAYS)` are not part of it.
2. **A cap change that does invalidate entries gets the near field's remap.** If the cap
   ever *lowers* (the code is `MAX`-only today, so this is about not painting itself into a
   corner), each resident SVT owner must move to the new coarsest level **keeping its world
   footprint** -- the same rule as `_remap_sector_pages`, reached through the same
   `move_owner()`.

**The shared piece.** One transaction, two callers: "move every resident owner of this view
from an old level space to a new one, keeping the world footprint, and drop the ones whose
new level is out of range". The near field's implementation is the reference; the far
field's owner records already carry what it needs (`Terrain3DVTPageOwner::virtual_x/y/mip`,
`world_space`, and for SVT `sector_x/y` hold the mip-0 page coordinate,
`terrain_3d_virtual_texture_lookup.cpp:183-188`). It belongs in the view, not in the pool:
the pool owns slots and reverse ownership, the view owns the level space.

**Risk.** Medium, and asymmetric: step 1 is a deletion of a heavy hammer and is the part
that plausibly removes the visible trace on its own; step 2 is defensive and only matters
if a lowering path is ever added.

**Verify.** `vt_svt_coverage`, `vt_pressure`, `vt_root_coverage`, `vt_mip_bands`,
`vt_fallback`, plus a counter assertion that a level raise no longer dirties regions. (An earlier
revision of this list named `vt_residency`; no such test exists - the residency case is
`vt_adaptive:residency`, which is red at `HEAD` and recorded in section 9.)

**Step 1 landed, and the *setting* was a third instance of the same hammer.** The
cap-change block (`terrain_3d_surface_views_far_walk.cpp:492-522`) now calls `set_world_max_mip()` and
`_material->update(UNIFORMS_ONLY)`, and records `svt_cap_dirty_regions` as the **increase** in
`bake.dirty_regions` across the change rather than its size afterwards, so the counter measures the
change instead of whatever an unrelated edit had already queued. `vt_svt_coverage` asserts the pair
`svt_cap_changes > 0` and `svt_cap_dirty_regions == 0` at the point its own setup reaches the raise
(`native/tests/vt_svt_coverage.gd`, after the setup loop). Nothing was waiting on the deleted sweep:
the level's pages are requested by the pass's own walk like any other page and served from the
persisted catalogue, which already holds the cell's mip chain -- `svt_stats.produced` is the counter
that would contradict it, and the measurement is in section 7.7.6. Step 2's *stated* version - the
remap on a lowering cap - is measured in section 7.7.9, where lowering the cap on a 512-page view keeps
every page because the addressing is level-invariant; and **the remap's own case does not exist in this
renderer at all**, for the structural reason in section 7.7.10: the far field's grid size is derived
from the pool's capacity, the physical atlas is one `Texture2DArray` that `ensure_layers()` recreates
blank when its layer count changes, and `Terrain3DVTPagePool::grow()` therefore evicts every resident
slot - so the address change a remap would serve and the content loss it cannot prevent are the same
event. HDRP can remap because its physical table never grows at runtime; what answers the same pressure
here is the coarsening the planner already has (`capacity_mip_bias`).

### H4. Fragment-level feedback (gated, last)

**HDRP.** The terrain's GBuffer fragment writes its packed page ID into an `R32_UINT` UAV at
`register(u7)` through `OutputPageID`, but only at the one sub-texel of each 8x8 block that
the frame's `BayerDither8X8` entry selects, on a target 1/8 the depth buffer's size. The
result is read back asynchronously, de-duplicated in a Burst job, sorted coarse-to-fine and
consumed 16 pages per frame.

**Today.** Demand is CPU-predictive (the lead), with an optional GPU assist:
`Terrain3DVTFeedback` runs a compute pass that projects candidate pages, measures their
screen extent and writes the local mip that would put about one page texel on one pixel. It
runs on its **own local RenderingDevice** and reads back through
`texture_get_data_async`, which its own header documents as a synchronous stall in the
current caller (`terrain_3d_vt_feedback.h:22-33`). There is no fragment-level feedback, and
no way for a material to write a storage image at all - the shading language has no
storage-image type (`servers/rendering/shader_language.h:233-244` is `TYPE_SAMPLER*` only).
The addon's other GPU paths (`terrain_3d_vt_indirection.cpp`,
`terrain_3d_surface_baker_*`) only ever *write* from compute.

**Corrected while probing this: the main device's read-back is not missing.** This section used to
say there was "no read-back facility on the main RenderingDevice at all". There is:
`buffer_get_data_async` (`servers/rendering/rendering_device.cpp:1335`) and
`texture_get_data_async` (`:2792`) are deferred downloads on the frame's staging buffers with a
completion `Callable`, bound for GDExtension at `:9126` and `:9068`, and the running build reports
all three capabilities present. What is missing is the **write**, not the read. Section 7.7.5 has the
probe result in full.

**Why it is last.** It is the largest single piece (a pixel-shader UAV write, an output
texture owned by the view, a non-stalling read-back, an injection point in the render
pipeline, and the de-duplication and ordering that follow), it only pays off together with
H1, and it must not regress the property the lead exists for. Adopt it only after a probe
answers: does the fork's terrain material path expose a writeable storage binding and a
read-back that does not stall the frame? **The probe has been run and the answer is no to the first
half and yes to the second - section 7.7.5.** There is no storage-image type in the shading language,
so a material's fragment cannot write a UAV here and HDRP's form of this mechanism is a documented
gap; the two deferred read-backs and a per-frame render-thread hook are present, so the *effect* is
reachable as a demand-source strategy (`ScreenDrivenDemand`) rather than as a new subsystem.

**What is kept either way.** `Terrain3DVTFeedback` does not go away. The fragment source and
the projection pass become the two implementations of the demand-source seam (section 5),
with the CPU rule as the third.

### H5. Parity that needs no change (verify and record)

| Mechanism | HDRP | This addon | Action |
| --- | --- | --- | --- |
| Coarse-to-fine request order | `PackedPageIDComparer` sorts by `sizeLog - mip` ascending | `PageRequestPriority` sorts by `kind` (ROOT, CURRENT, OPTIONAL), then `distance_band`, then `span` **descending** (`terrain_vt_request_priority.h:61-76`) | Equivalent intent (a larger span is a coarser page). Confirm with a counter, then record -- no code change expected. |
| De-duplication | Burst job, `NativeHashSet<uint>`, skips 0, bounded by `MaxDeduplicatedPageCount` 256 | The plan de-duplicates per owner | Confirm with a counter; no change expected. |
| Indirection upload pacing | `UpdateIndirectionTexturePerFrame` 64 entries | 16x16 tile patches per submit, coalesced by mip/tile (`terrain_3d_vt_indirection.h:27-30`) | Different granularity, same purpose. No change. |
| Async read-back with a timeout | `ReadingBackTimeout` 8 frames, then back to `Waiting` | `Terrain3DVTFeedback` returns to a fresh dispatch on a failed read-back | No change; note the difference in the doc. |
| Address-space budget | none (assert on allocation failure) | `virtual_bias` | **Keep.** Deliberate divergence. |

## 5. The three seams

The low-coupling/high-cohesion requirement is met by naming three decisions that are
currently made implicitly, in three different places, behind three different flag
combinations, and giving each one interface and one owner. This is a refactor of *where a
decision lives*, not a rearrangement of files.

**All three have landed** (P1: `VTFallbackPolicy` with P3, `VTMipRule` and `VTPageDemandSource` in
their own step). What "landed" means for each is recorded in the table, because they are not the same
kind of seam and the difference is the useful part:

| Seam | Decides | Was expressed as | Implementations | Landed as |
| --- | --- | --- | --- | --- |
| **`VTMipRule`** | Which level a page is requested at | Near: screen footprint (`terrain_3d_sector_avt_hierarchy.cpp:116`). Far: distance bands (`surface_views_far.cpp:36-55`) or the explicit table, each call site re-testing `surface_svt_mip_distances.is_empty()`. Shader: two mirrors | `MipRule` with `AutomaticBands` / `ExplicitTable`; H1's footprint would be a third kind | **A value.** `TerrainVT::MipRule` in `terrain_vt.h` with `select_mip_rule()` as the one selector; the engine side has exactly two helpers (`_svt_mip_rule()` builds it, `_svt_mip_rule_cap()` resolves an unnamed cap) and the call sites hold the value. Pinned by `test_mip_rule()` in the engine-free contract test; the GLSL mirror keeps its own count test, which is that side's selector |
| **`VTFallbackPolicy`** | What answers when the selected page is not resident | Global root pyramid (`_svt_plan_roots`, `surface_svt_root_mips`) + shader coarser walk | `Terrain3DSVTGlobalRootPyramid` / `Terrain3DSVTPerUnitCoarsest` (H2) | **Two strategies behind one selector**, `_svt_fallback_pages()`, selected by `surface_svt_fallback_policy`; the pass publishes whatever the policy returned and branches on nothing. Section 7.7.4 |
| **`VTPageDemandSource`** | Which pages are wanted this tick | CPU lead (always) + `surface_vt_feedback_enabled` (projection) + `svt_feedback` (shader-side fallback) | `CPURule` (the lead), `Projected` (`Terrain3DVTFeedback`), later `ScreenDrivenDemand` (section 7.7.5 - H4's fragment form is closed) | **A named source and two predicates, not an interface.** See below |

**Corrected while landing it: the demand sources are layered, not alternatives.** The table this
section used to carry listed `CPURuleDemand`, `ProjectedDemand` and `FragmentDemand` as three
implementations, which implies one of them answers a tick. What the code does is different and worth
naming precisely: **the CPU rule always answers** - it is what the lead predicts, and the near field's
region addressing resolves a level from it whenever nothing else does - and the projection pass
*refines* that answer while it has a result. So a virtual interface with three interchangeable
implementations would be a fiction today, and what the seam actually owns is the two questions a
single boolean was being asked to answer at once:

* `_vt_projection_demand_enabled()` - the *setting*: may the pass run at all. The producer asks this.
* `_vt_demand_source()` - *this frame*: does it answer now. Returns `Projected` only when the pass is
  enabled **and** it holds a result; the demand pass asks this. Before the first pass, and on any
  frame where the read-back has not landed, the answer is `CPURule` rather than a third state.

Both used to be `surface_vt_feedback_enabled`, read in `_update_surface_vt_feedback()` and in
`_surface_vt_mip_for_page()` with those two different meanings, the second also re-testing
`has_result()`. `TerrainVTPageDemandSource` in `terrain_3d_vt_state.h` names them. An interface earns
its price when a second implementation that *replaces* the CPU rule exists; `ScreenDrivenDemand` is
that candidate (section 7.7.5), and the seam is what it will land behind.

Conventions this must follow, all already load-bearing in this codebase:

* **A rule that both C++ and GLSL evaluate lives once per side and is pinned by a test that
  compares them.** `world_page_to_virtual()` / `surface_svt_sample()` is the precedent;
  `terrain_vt.h` plus the engine-free `native/tests/vt/terrain_vt_contract_test.cpp` is
  where H1's rule goes.
* **One `*_internal.h` prologue per split family**, never a copied helper
  (`vt_architecture_review.md:100-109`).
* **Records in a `<family>.h` with no algorithm in it** (`terrain_3d_avt.h`, `terrain_3d_svt.h`).
* **The flags the seams replace are deleted, not left beside them.** A seam that a flag can
  bypass is not a seam.

## 6. Rejected

| HDRP mechanism | Why not |
| --- | --- |
| The unified sector-image address space | Section 3: it is a 384 m near field, and at this pool size its own per-sector guarantee reaches the same 512 m. Adopting it means deleting the far field. |
| Two fixed 1023 x 264 x 264 `R8G8B8A8` atlases (~570 MB) | This addon's pool is configurable (8..1024 slots) in the format the material already samples. A fixed larger atlas is a memory regression with no addressing benefit. |
| The eight-stage, one-stage-per-frame tick | This addon's tick already budgets production (`pages_per_update` 16, `vt_frame_budget_ms`) and its demand is predictive, so it does not need a read-back round trip to decide. Splitting the tick would add a frame of latency to the near field. |
| The packed 12+12+4+4 page ID | This addon's indirection is `R32F` with an 11-bit slot and a separate mip walk, so it has no packing overflow to work around (HDRP's README documents two workarounds for exactly that). |
| No fade, no lead | Both are this addon's, both are orthogonal to the address space, and the lead is the reason a fast turn no longer shows a rectangular refinement (`terrain_3d_vt_state.h:698-702`). |
| Falling back to a global map outside the VT reach | The region array is already the last fallback in `get_surface_value()`; the far field exists so that path is almost never taken. |

## 7. Phase P0: what the far-field trace is, and what it is not

The first draft of this document named one suspect: a change of the far field's world mip cap
is treated as a content change, so it re-bakes every region in the world.

```cpp
// native/src/terrain_3d_surface_views_far_walk.cpp:425-438
if (!regions.empty() && _vt.surface_svt_mip_distances.is_empty()) {
    used_mip = MAX(used_mip, get_surface_svt_mip_for_distance(farthest_distance, plan_limit));
}
const int maximum_mip = MIN(used_mip, plan_limit);
if (maximum_mip != configured_mip) {
    _vt.surface_svt->set_world_max_mip(maximum_mip);
    for (const Vector2i &location : _data->get_region_locations()) { _vt.bake.dirty_regions[location] = true; }
    _vt.bake.edit_time = 0;
    if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
}
```

**P0 is done, and the suspect is not the artifact. It is not merely rare: with the default
settings it is unreachable.**

### 7.1 Why it cannot fire

`_configure_surface_view()` configures the world-space view with `surface_svt_max_mip`, whose
default is `-1` (`terrain_3d_vt_state.h:756`, meaning "auto"), and `initialize()` resolves a
negative cap:

```cpp
// native/src/terrain_3d_virtual_texture.cpp:237-238
const int cap = MAX(0, _level_count - 2);
_world_max_local_mip = (_world_max_local_mip < 0) ? cap : MIN(_world_max_local_mip, cap);
```

`_level_count` is `log2(indirection_size) + 1`, so `cap = log2(indirection_size) - 1`. The
walk's bound is computed from the same field:

```cpp
// native/src/terrain_3d_surface_views_far_walk.cpp:392
const int coverage_limit = MAX(0, TerrainVT::log2_power_of_two(_vt.surface_svt->get_indirection_size()) - 1);
```

so `configured_mip == plan_limit` before the first pass. `used_mip` *starts* at
`configured_mip` and only ever grows (`:423`), and `maximum_mip = MIN(used_mip, plan_limit)`,
so `maximum_mip == configured_mip` on every pass. The branch survives only for a caller that
sets `surface_svt_max_mip` to an explicit cap below the coverage limit - there it fires once
per level the view grows through, then stops. It is a latent hazard worth removing; it is not
a per-frame or per-turn cost.

### 7.2 Three motion profiles, and a correction

`native/tests/vt_cap_probe.gd` (runner `vt_cap_probe_runner.py`) drives a 25-region (256 m) far
field through three profiles: **turns** (15 degree steps), a **teleport walk** (256 m in three
frames) and a **cruise** (200 m/s, about 3.33 m per frame, three 100-frame legs, each followed
by a stop). Phase A is the shipped configuration, where the near field covered its 512 m radius when
these readings were taken (the default is 384 m since section 7.7.14, and the probe now drives the
reach from `VT_PROBE_AVT_DISTANCE`); phases B and C set `surface_vt_distance = 64` so the far field
carries the view. For four fixed
distant world points the probe also reports the level the rule selects and the level a fragment
at that point *actually gets* - the first resident level at or above the selected one, which is
what the shader's coarser walk returns. Excerpt:

```
VTCAP A turn 60    visible_pages=0                 served 4>4,5>5,5>5,5>5 moved=0
VTCAP A turn 180   visible_pages=12                served unchanged        moved=0
VTCAP A move 768   requeues=37 fade_starts=86 fade_active=36 alloc=94   served 4>5,4>5 moved=1
VTCAP C settled    settle frames=1 worst_delta=0.0000
VTCAP C cruise1 f25   visible_pages=14 fade_starts=146 alloc=151 hit=3430 miss=58  free=210
VTCAP C cruise1 f100  visible_pages=29 fade_starts=257 alloc=258 hit=4890 miss=70  free=109
VTCAP C stop 1     settle frames=1 worst_delta=0.0000
VTCAP C cruise2 f25   requeues=104 fade_starts=450 fade_active=136 alloc=460 evict=189
                      hit=5455 miss=239 free=368 eff_pool=512
VTCAP C cruise3 f50   requeues=149 fade_starts=1368 fade_active=98 alloc=1385 evict=251
                      hit=9188 miss=284 free=0 svt_cpu_ms=4.984
VTCAP C cruise3 f100  visible_pages=39 requeues=189 fade_starts=1805 alloc=1817 evict=516
                      hit=9675 miss=324 free=24   served 3>8,4>8,4>4,4>4
VTCAP summary  alloc=1825 evict=516 hit=9675 miss=324 free=16 prot=20 writes=0
               eff_pool=512 pool_gen=1 fade_starts=1813 fade_active=94 per_update=16
               svt_cpu_ms=0.072 svt_worst_ms=199.956 served_level_changes=21
```

| Profile | The far field's own demand | The shared pool | A fixed distant point |
| --- | --- | --- | --- |
| Turns (15 degrees) | `miss` unchanged, no arrivals | unchanged | `moved = 0` on all twelve reports |
| Teleport walk (85 m per frame) | arrivals; `served` falls back coarser | grows | `4>5`, `3>5` |
| Cruise (3.33 m per frame) | **about one miss per frame** (`miss` 58 -> 324 over 300 frames), 97% hit rate | **churns**: `alloc` 151 -> 1825, `evict` 516, `free` 210 -> 0, `pool_gen` 1, peak `fade_active` 136 | at the end **`3>8` and `4>8`** |

| Question | Answer |
| --- | --- |
| Did the cap ever change? | **No.** `cap_changes = 0`, `root_cap_raises = 0`, `cap_regions = 0`, `cap_ms = 0` in every run. |
| Does turning produce page arrivals? | **No.** All twelve turn reports show `fade_starts`, `alloc` and `requeues` unchanged. |
| Does a fixed distant point's served level move while turning? | **No.** All twelve turn reports are `moved = 0`. |
| Is the far field's *demand* the churn? | **No.** Its own miss count is 324 over 300 cruise frames at a 97% hit rate. `alloc`, `evict` and the fade counters are **pool-wide**, shared with the near field, which section 7.4 attributes: about 83% of the allocations are the near field's. |
| Is the pool the constraint? | **Not on a settled view** (`evict = 0` through every turn and the whole teleport walk), **but yes under cruise**: `free` falls to 0, 516 evictions, and the pool auto-grows 256 -> 512 (`eff_pool = 512`, `pool_gen = 1`) without stopping the churn. |
| Is there a visible trace after the camera stops? | **No.** `settle frames=1 worst_delta=0.0000` on all four stops: the picture is stable one frame after stopping. Whatever the trace is, it happens *while* moving. |
| What does the far field show at distance under cruise? | At the end, `3>8` and `4>8`: a page of `32 * 2^8 = 8192 m` answering a point whose rule wants a 256 m page. That is a real far-field degradation and the best candidate yet for the reported trace - and its cause is pool pressure, not the level rule. |

### 7.3 Corrections to the earlier drafts

1. **The far field already has the motion lead.** `_update_visible_svt()` plans against
   `_vt_lead_camera_transform(camera->get_camera_transform())`
   (`terrain_3d_surface_views_far_walk.cpp:357`), exactly as the near field does. A first
   hypothesis that it had none was wrong.
2. **The teleport walk is a teleport profile.** 256 m in three frames is about 85 m per frame,
   which no 250 ms lead can cover; it shows how the system behaves when demand jumps, not what a
   moving camera sees. It stays in the probe as a stress profile; its numbers must not be read as
   the artifact.
3. **H1 needs H4 to mean anything on the CPU.** A footprint rule evaluated on the CPU has only
   the projection, the viewport and the distance, and the field-of-view and viewport terms are
   constant per frame - so the rule reduces to the distance rule with a per-frame offset, which
   `surface_svt_texels_per_meter` already expresses as a density. What H1 describes is the
   *fragment's* real footprint being authoritative, and that is H4. `vt_mip_bands` also pins the
   contract that the level the shader samples is the level that was produced, so both sides must
   evaluate the same closed form; a CPU model that disagrees with the shader's derivatives would
   break that contract rather than improve it. **H1 is re-scoped: it lands with H4, or it does
   not land.**
4. **The first far-field pass costs about 200 ms** (`svt_worst_ms` 199.96-232.56 across runs)
   against 0.02-0.12 ms settled, and the cruise shows `svt_cpu_ms` spikes of 4.0-5.0 ms. `writes = 0`
   confirms the far field's pages are produced on the GPU, not written from the CPU.

### 7.4 Attribution (measured)

Reading the near field's own counters in the same run settles where the churn comes from:

| View | Its own hits | Its own misses | Reading |
| --- | --- | --- | --- |
| Far field, `get_surface_svt()` | 9675 | 324 | 97% hit rate: it asks for a page, and usually finds it already published |
| Near field, `get_surface_vt()` | **0** | **1636** | not a hit rate at all - see below |

`alloc`, `evict` and `free` are the *shared pool's* counters, and the two views' misses
(324 + 1636 = 1960) account for the pool's 1825 allocations: the near field is the source of
about **83%** of the churn.

**The near field's zero hits are by construction, not a defect.** Its production pass looks a
page up first and only requests what the lookup says is missing
(`lookup_page_exact()` at `terrain_3d_avt_produce.cpp:182` and `:301`, then
`request_page_internal()` at `:322`), and `_hit_count` is incremented only inside
`_request_virtual()` (`terrain_3d_virtual_texture_lookup.cpp:44-49`). A request that follows a
miss therefore always misses again. Zero hits is what that call pattern produces; the counter
says nothing about the near field's residency.

**What is anomalous is the volume, and it is measurable per phase.** `n_miss` is 109 at phase
C's first report and 1628 at its last: **1519 near-field page productions during 300 cruise
frames, about five per frame**, in a configuration whose near-field reach was set to 64 m in a
flat 1.28 km world. That is the number to explain.

**Isolating it settles the attribution.** Phase D repeats phase C's cruise with
`surface_vt_enabled = false`:

| 100 cruise frames | Near field on (phase C) | Near field off (phase D) |
| --- | --- | --- |
| `alloc` (shared pool) | 723 and 836 across the two legs | **11** |
| `fade_starts` | about 200 per leg | **11** |
| `evict` | 189 and 252 | **4** |
| The far field's own `miss` | about 65 per leg | **11** |

**About 99% of the pool's churn is the near field's**, and the far field's own demand under
cruise is about 0.1 page per frame - it was never the problem. `n_miss` freezes at 1636 for the
whole of phase D, and the pool still reports `free = 0` because the near field's 1636 pages are
still resident.

That makes the far field's mip-8 fallback a symptom: the near field consumes the pool, and the
far field's pages are evicted out from under it. H2's per-unit guarantee would make the fallback
nicer without addressing that.

**The sharpened question for P0c.** 1519 productions in 300 frames at `surface_vt_distance = 64`
is not a plan-size effect: the reach test is applied in **both** halves of the near field's
planning chain - the sector scan only creates a cell within `reach + SECTOR_WORLD` of the focus
(`terrain_3d_sector_avt_hierarchy.cpp:71-107`) and the plan worker rejects a page out of the same
reach (`terrain_3d_avt_plan.cpp:69-75`) - and the reach is `MAX(64, surface_vt_distance)`
(`terrain_3d_sector_avt.cpp:156`). At `surface_vt_distance = 64` that is a working set of a few
64 m sectors, a handful of pages. **Producing five pages a frame from a handful-page working set
means those few pages are being re-requested every pass, not that new ones are entering the
view** - which is what the near field's own `avt_sector_stats` is instrumented to show:
`plan_key_dirty_component`, `plan_key_unchanged`, `retained_sector_addresses`, `chain_ticks`,
`virtual_budget_bias`, `sampled_missing`. The probe can report those keys as it stands.

The two readings section 7.4 distinguished collapse into one, then: the plan **is** bounded by the
setting, so a few pages are being produced five times a frame, and the candidate is whatever
invalidates them between passes - a block `resize_sector()` (which remaps every resident page of
the block), an `unregister_sector()` for a sector leaving the reach window (which releases all of
its pages, `terrain_3d_sector_avt_hierarchy.cpp:289`), or pool eviction (`evict` 516 over the
run).

*Section 7.5 supersedes the last two paragraphs*: the `avt_sector_stats` read shows the plan is
bounded by its **budget**, not by the reach, and at the shipped reach it saturates that budget and
the pool rather than re-requesting a handful of pages.

### 7.5 The reproduced defect: a saturated plan and a thrashing pool

Phase E cruises at the near-field reach the probe was started with (**512 m** when these readings were
taken; 384 m is the default since section 7.7.14, and `VT_PROBE_AVT_DISTANCE` drives it) with
`surface_vt_enabled = true` - what a project actually runs - for four 100-frame legs. Phase A
only settled and teleported; this drives that configuration the way a camera actually
moves:

```
VTCAP E settled      avt_pages=17  sampled=7   missing=0   retained=74  alloc=1862 evict=520  free=373
VTCAP E cruise1 f25  avt_pages=30  sampled=16  missing=0   retained=101 alloc=1875 evict=520  free=360
VTCAP E cruise1 f100 avt_pages=241 sampled=86  missing=1   retained=191 alloc=2060 evict=520  free=175
VTCAP E cruise2 f25  avt_pages=305 sampled=91  missing=2   retained=222 alloc=2191 evict=658  free=44
VTCAP E cruise2 f100 avt_pages=324 sampled=119 missing=0   retained=314 alloc=2751 evict=1036
VTCAP E cruise3 f50  avt_pages=357 sampled=136 missing=48  retained=371 alloc=3136 evict=1421
VTCAP E cruise3 f100 avt_pages=357 sampled=147 missing=97  retained=399 alloc=3544 evict=1829
VTCAP E cruise4 f100 avt_pages=300 sampled=100 missing=20  retained=307 alloc=4365 evict=2643 free=0
VTCAP summary        avt_pages=300 sampled=100 retained=307 sectors=59 budget=384 pool=512
                     alloc=4373 evict=2651 fade_starts=4361 fade_active=100 free=0 n_miss=4125
```

| Reading | Value | What it means |
| --- | --- | --- |
| The plan | 17 -> **241 -> 305 -> 357 -> 384**, then back to 300 | It does not grow without bound: it **saturates at its budget** (`budget = 384` of a 512-slot pool) |
| What the image samples | **100-147** of those 300-384 pages | **Half to two thirds of the plan is never sampled** |
| What is missing among the sampled | 0 -> 48 -> **97** -> 20 | The near field's own image is starved, not just wasteful |
| Retained addresses | 74 -> **399**, then settling near 307 | The retention window fills the plan and is not released as the camera leaves |
| The pool | `free` 373 -> **0** by leg 2, and never returns | The pool is completely full for the rest of the run |
| Eviction | `evict` 520 -> **2651**, `alloc` 1862 -> **4373** | A steady eviction/re-production loop: about 0.8 allocations and 0.8 evictions per frame, indefinitely |
| Pages mid-fade | `fade_active` **90-100 continuously** | About a hundred pages are ramping at all times, which is what a visitor sees as pages updating in the distance |
| The far field | served level collapses to `2>8`, `3>8`, `4>8` | Kilometre-scale pages answering points whose rule wants mip 2-4 |

**The regime is self-inflicted saturation.** The near field reserves and produces its whole
budget, its own pages then evict each other, the pool ends full, ~100 pages are perpetually
fading, and the far field is starved down to mip 8 - while two thirds of the near field's own
plan is never sampled by the image.

That is the gap the HDRP comparison is actually about. HDRP's demand source is the fragment: a
page is requested because a fragment sampled it, so "asked for" and "sampled" cannot diverge.
This addon's demand is computed, and this run has it asking for two to three times what the image
samples and spending every production slot on the difference.

**Methodology note, recorded because it has now happened four times in this work:** the regime
appears only after roughly 200 frames of continuous motion. The first 100-frame leg alone showed
`evict` unchanged and `missing = 1`, and this section was first written from that leg as "not
capacity, just over-asking". Four legs show the pool filling and the eviction loop starting. A
single short leg is not enough to answer a question about a steady state. The fourth instance is a
different shape and worth naming: section 7.7.3's first revision did not run too short, it *asked
the wrong question* - rect equality where only intersection can detect a level change - and a
structural zero read as a finding. A counter that can only ever read zero is not evidence about the
world; it is evidence about the counter.

### 7.6 The mechanism: the plan's unsampled pages take the residency its sampled pages need

The budget arithmetic is **correct**, which is worth stating because it was the first suspect:
`budget = MAX(4, pool_size - reserved)` with
`reserved = MAX(pool_size / 4, svt_root_pages + svt_detail_pages)`
(`terrain_3d_sector_avt_hierarchy.cpp:146-172`) is `512 - 128 = 384` in this run, and the probe
confirms `avt_budget = 384` against `avt_pool = 512`. The near field is not oversubscribing the
pool by arithmetic. The composition of that plan is where the problem is - same run, phase E legs
3 and 4:

| Part | Pages | Note |
| --- | --- | --- |
| Roots | `avt_roots` 18-25 | not the filler |
| Retained requests | `avt_retained_reqs` 96-128 | saturates `RETAIN_RESERVE = 128` (`terrain_3d_avt_plan.cpp:166`) |
| Sampled by the image | `avt_sampled` 95-147 | **a third to a half of the plan** |
| The rest (apron and optional refinement) | about 150-200 | |
| **The plan** | 300-384 | its whole budget |
| Producer waits | `avt_slot_wait = 0`, `avt_source_wait = 0`, `avt_denied = 0`, `avt_mip_bias = 0` | **the producer is not blocked by anything** |
| The pool | `free = 0`; `alloc` and `evict` both advance by about **6 a frame, equal** | every production takes an LRU victim, and there is no victim to spare |

So the pool holds the whole plan (384) plus the far field's residency (about 128 - exactly the
reserve), it is exactly full, and **roughly 200 of the plan's 384 pages are pages no fragment
samples**. The sampled set therefore never converges: `avt_missing` sits between 15 and 97 for the
rest of the run, the image renders from parents, and about a hundred pages stay mid-fade.

The priorities are not the problem: `PageRequestPriority` already orders ROOT, CURRENT, OPTIONAL
(`terrain_vt_request_priority.h:15-19`), and the producer reports no wait of either kind.

### 7.6.1 Where the residency pressure actually goes

`Terrain3DVTPagePool::acquire_slot()` will not choose a protected or recently-demanded slot as its
victim (`terrain_3d_vt_page_pool.cpp:190-204`), so what a pass protects and marks is what the pool
must keep. Both views mark, and by the same route: a hit in `_request_virtual()` calls
`_touch_slot()` (`terrain_3d_virtual_texture_lookup.cpp:47`), which sets the slot's demand epoch
while a demand pass is running (`terrain_3d_vt_page_pool.cpp:163-174`). The far field documents
this as the reason its detail loop is not cut on the deadline - "visiting a page is what re-marks
it as demanded" (`terrain_3d_surface_views_far_walk.cpp:514-515`) - and the near field protects and
marks its plan the same way (`terrain_3d_avt_produce.cpp:197`, `:222`).

So in the measured run: both views re-marked the pages they visited, the victim search always
found something (`avt_slot_wait = 0`), and the victims were therefore pages **neither view visited**
- the stale population left by earlier plans. `alloc` and `evict` advancing together at about 6 a
frame is that population being recycled, not a deadlock.

What is left unexplained by residency policy is the sampled deficit itself: `avt_missing` sits at
15-97 with `avt_slot_wait = 0`, `avt_source_wait = 0` and `avt_denied = 0`, and only about 8 pages
are produced per pass against a budget of `pages_per_update = 16`.

Neither the deadline nor the budget explains the 8. The near field's whole pass costs
`avt_cpu_ms` 0.33-0.99 ms against its 3 ms soft deadline, and its split is `allocation_ms`
0.07-0.21, `classify_ms` 0.03-0.09, `retain_ms` 0.00-0.18, `queue_ms` 0.02-0.04 and `payload_ms`
0.001-0.006 - nothing is near a limit. **The bound is the source pipeline, and the diagnostic did
not say so**, because the one path that means "this page's payload is not ready" was the one path
that did not count itself:

```cpp
// terrain_3d_avt_produce.cpp, _avt_produce_visible()
if (!ready.contains({ page.owner.x, page.owner.y, page.mip, page.x, page.y })) { continue; }
```

The walk advances `missing_next` past a page whose source is not ready, so a pass that produced 8
pages out of a 100-page miss set reported `source_wait = 0` and measured like a pass with nothing
left to do. Fixed: that branch now increments `r_pass.source_wait`, which is exactly what the
field documents ("its source job was not ready yet (the workers are behind)"). It is a
diagnostics-only change - the control flow is identical - and it is what makes the next section
readable: the counter stays near zero, so the source pipeline was never the bound either.

### 7.7 The suspected binding constraint: the plan is sized by residency and the tick pays a fixed eight pages

`terrain_3d.cpp:255-285` splits the tick's page budget by construction:

```cpp
int vt_remaining = _vt.vt_debug_direct_material ? 4 : _vt.vt_pages_per_update;      // 16
const int avt_share = _vt.surface_svt_enabled ? MAX(1, vt_remaining / 2) : vt_remaining;  // 8
...
avt_produced = update_surface_vt(avt_share);
```

With both tiers on - the shipped configuration - **the near field may produce eight pages a tick,
whatever its plan asks for**, and the far field gets the remainder. `vt_pages_per_update` is itself
clamped to 1..16 (`terrain_3d_bindings.cpp:365`), and `_produce_sector_avt_pages` clamps again to
16, so the ceiling for both views together is 16 a tick.

Against that supply, the plan is sized by **residency** (`budget = pool - reserved = 384`) and is
refreshed every `avt_plan_refresh_frames` ticks - seven, at the default 250 ms lead
(`terrain_3d_sector_avt_motion.cpp:208`) - and each refresh of a moving view adds on the order of a
hundred new sampled pages. Supply 8 a tick against demand on the order of 14 a tick is a
**structural undersupply**, and it is exactly what the measurements show:

* `avt_missing` oscillating 0 -> 48 -> 97 and back: the deficit is opened by each refresh and
  partly closed before the next one, so a sample every 25 frames catches it open about half the
  time;
* `avt_produced = 8` on pass after pass, with `avt_slot_wait = 0`, `avt_source_wait` 0 with a rare
  6, `avt_denied = 0` and the whole pass costing 0.33-0.99 ms against a 3 ms deadline - nothing is
  blocking; the pass simply runs out of allowance;
* `fade_active` pegged near 100: every one of those eight arrivals a tick starts a 12-tick fade,
  and the deficit is large enough that the set is never empty;
* `alloc` tracking `evict` at about 6 a tick once the pool is full: the arrivals are landing in a
  pool with no free slot, so each one takes a victim;
* the far field served at mip 8: it loses the victim search to a near field whose plan is 384
  pages and is re-marked as demanded every pass.

The plan has no term for the rate at which its pages can be produced. `budget` bounds how many
pages may be **resident**; nothing bounds how many may be **demanded per refresh** against eight
pages a tick. That is the divergence HDRP does not have: there, demand is the fragment set and the
frame renders 16 pages of it, so a plan cannot outrun production by two orders of magnitude.

*(The heading above says "suspected" because the section's second half did not survive its own
experiment. That the plan had no rate term is confirmed - fixing it removed 76% of the plan's
unsampled residency. That the missing rate term was the *binding constraint on the sampled deficit*
is false: section 7.7.1 raised the supply by 75% and the deficit did not move. Read 7.7.1 and 7.7.2
before acting on anything below.)*

Three candidate fixes were identified, in order of preference:

1. **Give the plan a rate term.** A page that cannot be produced within the ticks its refresh
   window has left should not be in this refresh's *required* set - the demand pass knows the
   refresh interval and the eight-page allowance, so it can size the required set to what the next
   window can fill and demote the rest to prefetch.
2. **Make the share demand-aware.** While the near field's sampled set is incomplete, let it take
   the whole `vt_pages_per_update` (with a floor reserved for the far field) instead of a fixed
   half. The far field's own demand is about 0.1 page a tick, so the split is currently giving it
   eight times what it asks for.
3. **Keep the plan smaller.** If neither of the above settles it, the retention window
   (`avt_retained_reqs` saturating its 128 reserve) and the apron are what make the plan 2.5-3
   times its sampled set, and they are `OPTIONAL` by construction - the plan does not have to name
   them.

Candidate 1 and candidate 3 turned out to be the same change, and it landed (section 7.7.2).
Candidate 2 was implemented, measured, and rejected (section 7.7.1) - and the way it failed is the
most informative measurement in this document, because it falsifies the premise the whole section
was written on.

### 7.7.1 The demand-aware split, measured and rejected

Candidate 2 says the supply is the binding constraint: the near field is given eight pages a tick
while it needs about fourteen. That is easy to implement and easy to check, so it was implemented
first, in `_avt_tick_allowance()` - the single home for the split - as "the far field keeps the even
share until its root pyramid is pinned, and a two-page floor after that". `svt_root_settled` was
added to `_report_svt()` so the run could be read, and the probe confirms the rule took effect:

```
VTCAP summary  avt_allowance=14  svt_settled=1  avt_produced=14  per_update=16
```

The near field did produce fourteen a tick instead of eight for the rest of the run. The sampled
deficit did not fall. Both runs are the same scripted cruise, the same fixture and the same build
except for this rule:

| Reading | Even split, rate term (7.7.2) | Demand-aware split (`avt_allowance=14`) | Change |
| --- | --- | --- | --- |
| `avt_missing` peak | 91 | 82 | -10% |
| `n_miss` (near-field misses, whole run) | 3588 | **5053** | **+41%** |
| `alloc` (shared pool) | 3850 | **5316** | **+38%** |
| `evict` (shared pool) | 2558 | **3946** | **+54%** |
| `fade_starts` | 3841 | **5299** | **+38%** |
| `fade_active` | 88 | 90 (peaks 159) | worse |
| far field served | `3>8`, `4>8` | `3>8`, `4>8` | unchanged |

**Producing more pages produced more churn and no more coverage.** The near field's miss rate
scales with its allowance: every page it adds evicts a page, and the evicted page is requested
again. The supply was never the binding constraint - `avt_slot_wait = 0` and `avt_source_wait = 0`
in every reading mean the pass is never blocked, it is *saturated*, and a saturated consumer whose
demand scales with its budget cannot be fixed by raising the budget.

The rule was reverted to the even split and the run reproduced the even-split numbers exactly
(`alloc` 3850, `evict` 2558, `fade_starts` 3841, `n_miss` 3588, `avt_tail_cap` 56): the probe is
deterministic, so those differences are the rule and not noise. The comment above the split now
carries the measurement, so the experiment is not repeated.

**What this falsifies.** Section 7.7's framing - "a structural undersupply that no residency policy
can fix" - is wrong in its second half. Residency policy *did* fix a measurable 12% of the churn
(section 7.7.2), and the undersupply is not what is left. What is left is a **rotation** problem:
the near field's address set is not stable, so pages leave the plan, lose their protection and their
demand mark, are evicted, and are requested again later. The deficit spikes of 40-82 pages are bulk
events - they arrive with `avt_dir_rebuilt` and with steps in `avt_retained_addr` (74 -> 399 over
the run) - not a steady drip that a wider allowance would outrun. The next measurement is therefore
not another supply change but an attribution of the evictions: which addresses leave the plan, how
many of them were in the previous plan's set, and whether the plan's *mip* selection for a page
changes as the camera moves. That is P0e, and it is a counter rather than a policy.

### 7.7.2 The rate term, landed

The change that landed is candidates 1 and 3 together, in the planner and the installer:

* `Terrain3D::_avt_tick_allowance()` is now the one spelling of the tick's page split. Both the tick
  (`terrain_3d.cpp`, which hands the pass the pages) and the planner (`_avt_submit_plan()`, which
  sizes the plan against the supply) call it, so the plan cannot be sized against a number the pass
  is not given.
* `PlanInput::tail_cap` carries the term: `_avt_tick_allowance() * avt_plan_refresh_frames`, the
  pages one plan generation can produce. In the shipped configuration that is `8 * 7 = 56`.
* `plan_pages_for_bias()` bounds the plan's **tail** - the pages no fragment samples, which is the
  speculative apron plus the retention window - by that term, split evenly between the two: the
  retention window covers a rendered frame the plan has already moved past, the apron is
  speculation, and neither may have the whole of one window. The pages the image *samples* are not
  bounded by it; they are what the plan is for. A `tail_cap` of zero means the caller derived no
  term and the historical residency-only bound stands.
* `Terrain3DAVTRefinement::retain_cap` carries what is left of the term for the installer's
  retention append, which is where the old fixed `MIN(128, budget - pages.size())` used to be. That
  fixed bound was residency-only, and it is what let the window keep a hundred addresses for
  `avt_retain_epochs` (22) generations.

Measured, against the phase E baseline in section 7.5, same cruise and fixture:

| Reading | Baseline (section 7.5) | With the rate term | Change |
| --- | --- | --- | --- |
| Plan size, peak | 384 (its whole budget) | **202** | -47% |
| Pages the image never samples | ~237 | **56** (`avt_apron` 28 + `avt_retained_reqs` 28) | -76% |
| `alloc` | 4373 | **3850** | -12% |
| `evict` | 2651 | 2558 | -4% |
| `n_miss` | 4125 | **3588** | -13% |
| `fade_starts` | 4361 | **3841** | -12% |
| `avt_cpu_ms` | 0.33-0.99 | 0.21-1.04 | unchanged |
| `avt_missing` peak | 97 | 91 | -6% |
| `free` at the end | 0 | 0 | unchanged |
| far field served | `2>8`, `3>8`, `4>8` | `3>8`, `4>8` | marginal |

So the term is a real but partial improvement: it removes about three quarters of the plan's
unsampled residency and about an eighth of the pool's churn, at no measurable CPU cost. It does not
meet the acceptance criteria written for P0d in section 8, and the measurements in 7.7.1 say why -
the remaining deficit is rotation, not supply. The counter that would have hidden this was the one
thing the probe could not see: `avt_missing` alone looked like a supply problem, and it took a
*failed* supply change to show that it is not.

#### Verification of the rate term

* Build: `scons platform=windows target=template_debug`, `scons: done building targets.`
* `vt_cap_probe`, twice, with the same numbers both times (`alloc` 3850, `evict` 2558, `fade_starts`
  3841, `n_miss` 3588, `avt_tail_cap` 56, `avt_allowance` 8): the probe is deterministic, which is
  what makes the rejections in 7.7.1 attributable to the rule rather than to noise.
* Green, unchanged: `vt_demand`, `vt_fallback`, `vt_pressure`, `vt_root_coverage`, `vt_svt_coverage`,
  `vt_svt_root_mips`, `vt_idle_cost`, `vt_recovery`, `vt_snap_turn`, `vt_motion_decay`,
  `vt_page_fade`, `vt_transition_parent`, `vt_root_budget`, `vt_cells`, `vt_lifetime`, `vt_sparse`,
  `vt_surface`, `vt_runtime`, `vt_perf`.
* Red before and after, same assertions and same messages, confirmed against a pristine build of
  `49bee0be7a` with the source changes stashed: `vt_adaptive:{sectors,metric,ownership,filtering}`
  (the legacy region mode), `vt_turn_budget` (timing overruns on this machine, and the baseline's
  numbers are *worse* than the patched ones: 0.449 vs 0.366 ms slow-turn streaming, 0.379 vs
  0.313 ms cold-turn near field), `vt_strict_coverage` and `vt_near_arrival` (infrastructure exits,
  2 in 0.0 s), `vt_visibility`, and `vt_pressure` (a fixture race: 3/6 baseline, 2/6 patched over
  six repetitions of the same three-test sequence - section 9 has the mechanism).

New diagnostics added with the term, all read by the probe: `plan_tail_cap` (the term as derived),
`plan_retain_share` (as spent on retention), `plan_apron_pages` (as spent on the apron) and
`avt_allowance` (the near field's share of `pages_per_update`, which is what the term is a multiple
of).

### 7.7.3 P0e: what the churn is, measured

Section 7.7.1 left one hypothesis standing - that the near field's address set *rotates*, a page's
selected level changing as the camera moves, so the same ground came back under a new address. P0e
was written as a counter set to test it, at the one point where two generations are both in hand:
`_avt_install_or_reuse_plan()`, where `_vt.avt_refinement->pages` is the selection the worker just
made and `_vt.avt_plan.pages` is still the plan standing until now. Every address in the first is
classified against the second:

| Counter | Meaning |
| --- | --- |
| `plan_carried` | the same address. No slot, no production - the share of a generation that is free. |
| `plan_overlapped` | a new address whose rect **intersects** a rect the previous plan had *for the same owner*. The same ground at the level the rule re-derived. |
| `plan_rescaled` | a new address in an owner the previous plan had, but at a **span** the previous plan did not have. |
| `plan_reselected` | a new address in an owner the previous plan had, at a span it had: the same scale, a different page. |
| `plan_new_sector` | no page of that owner was in the previous plan at all. |
| `plan_dropped` | the other direction: addresses the previous plan named that this one does not. |

**The first version of this counter set was wrong, and the way it was wrong is the finding.** It
tested rect *equality* for the relevel case and read a structural zero, and section 7.7.3's first
revision concluded from that zero that the level-rotation hypothesis was "unstateable". The zero was
an artefact: **another level means another span, and therefore a *different* rect** - a coarser page
that *contains* this ground, or a finer one contained by it. Equality can never hold for a level
change. The test had to be intersection, and with intersection the answer is the opposite of what
the first revision concluded: `plan_overlapped` is not zero, it is the largest of the three.

All values are per **one plan generation**; a generation is about six frames at the shipped lead.
The four-leg phase E cruise, with `sel` the size of the new selection:

```
                          sel  carried  overlapped  rescaled  reselected  new_sector  dropped  missing  size_grows
E settled                  17       17           0         0           0           0        0        0          0
E cruise1                  59       41           8         8           0          10        6        0         12
E cruise1                 114       91          22        19           3           1       46        9         13
E cruise2                 119       82          28        21           7           9       63       11         10
E cruise2                 122       96          20        10          10           6       55        0         15
E cruise2                 144      102          36        15          21           0       61       24         12
E cruise3                 144       86          55        16          39           3       85        2         15
E cruise3                 164       93          70        15          55           1       99       50         10
E cruise4                 144       34         102        27          75           8      145       80          9
E cruise3                 175       52         122        67          55           0      150       93         17
E cruise4                 141       68          68        24          44           5       98       15          6
E cruise4                 128       91          31        20          11           6       70       20          4
```

Four things follow.

**1. It is not new world.** `plan_new_sector` is 0-10 in every reading while `avt_sectors` grows
54 -> 134 across the run. Careful reading of that number: an "owner" is a level-0 64 m sector *or*
one of the 18-25 coarse roots above them, and most plan pages hang off a root, so this counter can
only ever reach the owner count and it under-counts new ground. What it does establish is that the
plan's *owner* set is stable and its *page* set inside those owners is not.

**2. The new addresses land on ground the previous plan already covered.** `sel - carried` is the
generation's new addresses and `plan_overlapped` is how many of them intersect a previous rect of
the same owner: **22 of 23** (cruise 1), **28 of 37**, **70 of 71**, **102 of 110**, **122 of 123**
(cruise 3's worst generation), 31 of 37 in the last. So 90-99% of the churn re-covers ground the
plan had one generation earlier, at a span or a position it did not use. This is the level rule
re-deriving a level for ground it already had, and it is the mechanism section 7.7.1 left standing.

**Corrected in section 7.7.7, and the correction is the opposite of the reading above.** A newly
refined page is a *child* of a page that was already in the plan, so "it intersects a previous rect of
the same owner" is true of every new page by construction: `plan_overlapped` measures the refinement
frontier moving, not ground being re-derived at another level. The direction counters P2 added to test
this were single-valued for exactly that reason - and so is the identity they are now provably bound
by, `plan_overlapped + plan_new_sector == plan_selected - plan_carried` in every generation. The
version of the question that can answer - the finest span each plan offers per owner - says the level
rule is **stable** (`avt_depth_down` 0-2 per generation, `avt_depth_up` 1-7). The churn is lateral.
Read this point's numbers as "the frontier moved", not as "the level was re-derived".

**3. It splits into two re-derivations.** `plan_rescaled` (a span the owner did not have) and
`plan_reselected` (a span it had, a different page) trade places across the run - 8 and 0 in cruise
1, 67 and 55 in cruise 3's worst generation, 27 and 75 in cruise 4's. The first is the walk choosing
another depth, and the second is its boundary decisions
(`projected > 1.f`, `minimum_density * span <= page_size * 2.f`, `terrain_3d_avt_plan.cpp:143-146`)
moving within one depth. Both are the same model re-derived.

**4. A separate, smaller, inherent source: the virtual resolution ladder.** `sector_size_grows` is
4-17 per generation: that many sectors have their virtual block size *raised*, and
`_avt_sync_address_directory()` only ever raises one (`previous_size < sector.size`; the only
shrink is `reclaim_addresses()` under address-space pressure). With ~130 sectors and a density that
changes about 4.5% a generation, each sector climbs one step about every sixteen generations, which
is exactly the 8 a generation this measures. A block-size step moves every page of that sector to a
different mip index, and there is no hysteresis that removes it: the virtual image genuinely has one
more mip this generation than it had last.

**And the deficit is the turnover minus production capacity.** A generation is about six frames, so
the near field can produce `8 x 6` about **50** addresses per generation, and the generation's new
addresses are `sel - carried`:

| Generation | New addresses | Capacity | `avt_missing` |
| --- | --- | --- | --- |
| cruise 1 (`sel` 114) | 23 | ~50 | 9 |
| cruise 2 (`sel` 122) | 26 | ~50 | 0 |
| cruise 2 (`sel` 144) | 42 | ~50 | 24 |
| cruise 3 (`sel` 164) | 71 | ~50 | 50 |
| cruise 3 (`sel` 175) | **123** | ~50 | **93** |
| cruise 4 (`sel` 144) | **110** | ~50 | **80** |
| cruise 4 (`sel` 128) | 37 | ~50 | 20 |

`avt_missing` is `max(0, new - capacity)` accumulated to a steady state. That is the complete,
quantified causal chain of the repro: not supply (7.7.1), and not new ground (above) - the level
rule and the boundary decisions re-deriving ground the plan already had, faster than production can
re-address it.

**What this rules out as a fix, measured rather than argued.** No amount of *carrying pages forward*
closes a 2.4x gap: the retention window is exactly that mechanism, and the tail-rebalancing in 7.7.2
already showed that holding more unsampled residency raises churn rather than lowering it
(`alloc` 4373 -> 3850 when the tail fell from 384 to 56). A page whose ground comes back at another
span has a **new address**, so it must be produced again whatever the plan carries; only a rule that
does not change the span removes the production. Sizing the tail differently moves a few percent of
123 addresses and cannot reach 50. That is why P0f is closed without a code change (section 8).

**And it is where the HDRP comparison becomes the mechanism.** HDRP's demand is the set of pages
fragments sampled *this frame*: a function of what is on screen, stable while the screen is, and its
pages persist in the atlas until its allocator recycles them. This addon re-derives the selection
from a thresholded footprint/density model every generation, and the counters above name the two
places it does so. So H1 - the pixel-footprint level rule, a *screen* function rather than a
re-derived threshold chain - and H4, fragment demand, are the fix and not merely the alignment. P2
and P5 carry them, and section 7.3's re-scope stands: H1's CPU-only form is worth less than H4, so
they land together or H1 is closed with the reason recorded.

### 7.7.4 H2, implemented and measured

`surface_svt_fallback_policy` selects the set that answers a far-field fragment whose selected page
is not resident. The decision has one owner - `_svt_fallback_pages()` - and two strategies, so the
call site no longer branches on anything:

* `_svt_global_root_pyramid()` (policy 0, the default): today's behaviour, one complete level window
  over the whole addressable domain, which is what makes any world position resolve and what lets the
  region array be unnecessary.
* `_svt_per_unit_coarsest()` (policy 1): HDRP's `DeduplicateJob` guarantee, literally - for every
  virtual image the visible set selected, one page at `mip = sizeLog`, the coarsest level the world
  grid can express for it, requested unconditionally. Both publish into the same `svt_roots.pages`, so
  the pin budget, the plan key, the reuse/verify path and the coverage accounting are shared.

Measured in `vt_root_coverage`'s fixture (a settled view, `PAGE_WORLD` 64 m, `MAX_MIP` 3, a 12x12
region grid), the same run:

```
VTROOTCOVER cam=(384,384) coverage=[P: (-8192,-8192), S: (16384,16384)] roots=20 levels=6..7 patch={magenta: 0.0, mean: 0.2945907665447}
VTROOTCOVER perunit      coverage=[P: (0,0),        S: ( 8192, 8192)] roots= 1           domain_covered=false patch={magenta: 0.0, mean: 0.2945907665447}
```

**Three findings, and the third is why the default does not change.**

**1. It pins 5% of the pages.** 20 -> **1** page. In the phase E/F cruise of the probe, at the same
pose, `free` is **443 against 365** - 78 more slots of a 512-page pool available to the near field.

**2. What is drawn is unchanged.** The far patch's mean luminance is identical to thirteen digits
(0.2945907665447) and its magenta fraction is zero under both, so the fallback a fragment lands on did
not change. The probe confirms it over the cruise: phase F's `served` sequence is line for line phase
E's - `4>4,5>5,5>5,5>5`, `3>3,4>4,5>5,5>5`, `2>3,4>4,4>4,5>5` - including the `>8` collapse in the
later legs, which reaches the same reading under both policies.

**3. It is a different contract, and the contract it gives up is load-bearing.** The pyramid's promise
is that *any* world position resolves; `domain_covered=false` above is the per-unit policy saying it
does not make that promise. That property is why the region array is not needed for the far field, and
§4/H2 records it as "worth more than the trace". So the mode stays, the default stays 0, and
`vt_root_coverage` now asserts the pyramid's domain contract and, in a second pass, the per-unit
policy's own weaker one - the domain it does not claim is printed, not asserted away, because
section 9 forbids relaxing an assertion to make a phase pass.

**Why H2 cannot do what HDRP's version does here.** HDRP's `mip = sizeLog` is *per virtual image*, so
the fallback page is as wide as the unit and a fallback arrival changes only that unit's rectangle.
In this addon the world grid has **one** cap, `svt_effective_max_mip`, which is global: the coarsest
level a grid page can express is the same for every unit, and at 32 m mip-0 pages it is **16 km** wide
(`svt_root_page_world` in the probe reports 16384 for policy 1). The per-unit set is therefore
*smaller* but not *finer* - which is exactly the outcome §4/H2 said was not obvious either way, and
§3's arithmetic is the same reason on the other side: at this pool size HDRP's per-sector guarantee
also reaches hundreds of metres.

Making the fallback level follow the *unit* would mean pinning, for each unit, a page at the level
whose span is the unit's extent - and then the shader's coarser walk has to find it, which is a change
to the walk's level chain rather than to the set. That is the same gap H4 closes from the other end: a
fragment that reports the level it actually sampled does not need a fallback chain at all. So H2's
stated purpose - a smaller update trace - is **not** achieved by the literal port, and the mechanism
that achieves it is H4's. Recorded so the literal port is not re-tried.

### 7.7.5 The H4 probe: fragment-authored demand is not available, its effect is

Section 4/H4 gates itself on one question - "does the fork's terrain material path expose a writeable
storage binding and a read-back that does not stall the frame?" - and says that until it is answered
H4 stays a documented gap. It is answered now, and the answer is split: **the write is not
available, the read-back is, and the injection point is.**

**1. A writeable storage binding from the terrain material: no.** Godot's shading language has no
storage-image type at all. Its data types are `TYPE_SAMPLER2D` and its relatives
(`servers/rendering/shader_language.h:233-244`) and there is no `TYPE_IMAGE`; `image2D`,
`imageStore` and `uimage` do not appear anywhere under `servers/rendering/`. The reflection a
`ShaderMaterial` builds therefore cannot produce a storage-image uniform, so a `shader_type spatial`
fragment **cannot write a UAV** in this fork. The RD layer below it can - `UNIFORM_TYPE_IMAGE` is a
first-class uniform type (`servers/rendering/rendering_device.h:1078`) and engine effects use it
(`servers/rendering/renderer_rd/effects/bokeh_dof.cpp:149`) - but that is reachable only from a pass
the engine or an extension records through `RenderingDevice`, not from a material.

This is the capability HDRP's H4 is made of, and it is the half that is missing. `OutputPageID`
writing a packed page ID into an `R32_UINT` UAV from the terrain's GBuffer fragment
(`VirtualTexture.hlsl`) has no equivalent here.

**2. A read-back that does not stall the frame, on the main device: yes.** The alignment document
previously stated there was "no read-back facility on the main RenderingDevice at all", and that is
**wrong** - it has been corrected in section 4/H4. `buffer_get_data_async`
(`servers/rendering/rendering_device.cpp:1335`) and `texture_get_data_async` (`:2792`) are both
implemented as genuine deferred downloads: they allocate into the frame's download staging buffers,
record the copy on the draw graph (`draw_graph.add_buffer_get_data(...)`) and deliver the caller's
`Callable` when it lands. They are bound for GDExtension (`:9126`, `:9068`), beside a synchronous
`buffer_get_data` whose own header comment is "This causes stall"
(`servers/rendering/rendering_device.h:268`), which is the contrast that makes the pair meaningful.

The addon's *current* GPU assist is synchronous, and `terrain_3d_vt_feedback.h:24-29` already says why:
it runs on its **own local** device, and a local device has no automatic frame advance, so `sync()`
submits, waits and delivers the callback inside the caller's update - "a synchronous stall despite the
readback API's name". That is a caller's choice, not an API limit, and it is the one thing a
main-device variant would not do.

**3. A per-frame injection point on the render thread: yes.** `virtual_texture_set_update_callback`
(engine patch 2, `docs/engine_patch_surface.md`) invokes the extension's callables once per frame as
one pass of the FRP frame, and the addon already registers its page baker there. Anything H4 needs to
record - a compute dispatch, a copy, a read-back request - can be recorded from that hook.

**Answered on the running binary, not only in the source.** `get_vt_settings()` reports the three
capabilities the way `rd_gpu_copy.cpp` resolves the direct page store, with `has_method()` so a stock
engine answers false and prints nothing:

```
VTCAP start  rd_store=1 rd_async_buf=1 rd_async_tex=1
```

so on this build the direct GPU page store and both deferred read-backs resolve, and the missing
capability is not a boolean because it is absent from the language rather than from the binding.

**Conclusion, and what it does to the phases.** HDRP's H4 cannot be ported in its form: there is no
fragment-authored demand buffer here. Its *effect* - a screen-space demand buffer produced on the
GPU and consumed without stalling the frame - **is** reachable, and the shape it has is exactly
`Terrain3DVTFeedback`'s minus its two accidents: it must be recorded on the **main** device (through
patch 2's hook) rather than a local one, and it must be **driven by the screen** (the pixels the
fragment covers) rather than by projecting every candidate. That is a **demand-source strategy**, not
a new subsystem: the third implementation of the section 5 seam, next to `CPURuleDemand` and today's
`ProjectedDemand`, and it is what HDRP's mechanism reduces to in this renderer.

So P5 closes H4's fragment form as a **documented gap** and re-scopes the seam's GPU strategy to
`ScreenDrivenDemand` with the two accidents fixed. §4/H4's "what is kept either way" holds: the
feedback class does not go away, it becomes one of the seam's implementations.

**And the re-scoped form is closed too, for a second engine-level reason plus a measurement.** The
re-scope assumed the screen-driven variant needed only the main device and a per-frame hook - both of
which exist. What it also needs is the *screen*: a demand pass has to know what the fragments actually
covered, which means the frame's depth (or GBuffer). Three facts close that door:

1. The hook takes no frame context. `RenderingServer::execute_virtual_texture_updates()`
   (`servers/rendering/rendering_server.cpp`) copies the registered callables under a mutex and invokes
   them with no arguments; `virtual_texture_set_update_callback(id, callback)` passes the callback and
   nothing else. There is no depth RID, no `RenderSceneBuffersRD`, no viewport.
2. Its engine call site is ordered before the only pass that produces that data.
   `FRPPassContext::execute_virtual_texture_updates()` is `_run_operation(OP_VIRTUAL_TEXTURE)`, and
   `render_frp_clustered.cpp:2191` says of that operation: **"Virtual texture updates. Must run before
   the G-buffer."** So at the moment the addon may record GPU work for demand, the current frame's
   depth does not exist yet - and the ordering is not incidental, it is what guarantees pages produced
   this frame reach this frame's terrain draw.
3. Making it reachable is a *fork-side* change with a *new subsystem* behind it: the operation would
   have to hand the callables the scene buffers (an extension of patch 2 at
   `frp_pass_context.cpp`/`rendering_server.cpp`), and the addon would then own a screen-space demand
   pass reading the previous frame's depth - HDRP's latency, which is acceptable, but a subsystem whose
   benefit nothing has measured.

**And nothing measured asks for it.** The residual difference between feng's `Projected` source and
HDRP's fragment feedback is *occlusion*: the fragment sees only visible ground, a page-level projection
sees all of it. Section 7.7.1 and 7.7.7 measured what the near field's churn actually is -
`avt_missing = max(0, new addresses - ~50)`, with the new addresses being laterally-new refined pages on
ground the plan already covered, and the level rule stable per owner. Over-requesting occluded ground is
not on that path. So the gap is recorded as *understood and bounded*, the enabling change is named (a
third engine patch that passes the scene buffers to the update callables), and it is not taken: building
a subsystem against a benefit that no measurement has shown would contradict the rule this document has
followed throughout (section 9).

**And that re-opens H1, on its own merits.** Section 7.3 re-scoped H1 ("a CPU-only footprint rule is
the distance rule with a per-frame density offset") and P2 deferred it to land with H4. With H4's
fragment form closed, the far-field form of H1 stays closed for exactly that reason. But P0e measured
something §7.3 did not know: **the level rule that is re-deriving ground every generation is the near
field's** (`plan_rescaled` 0-67, `plan_reselected` 0-75 per generation, 90-99% of new addresses on
ground the plan already had), and the near field's rule is *already* footprint-based. So the open
question is no longer "does the footprint rule beat the distance rule for the far field" - it is
"what makes a footprint rule stable across generations", which is a question about the near field and
is measured by P0e's counters. That is P2's new scope, recorded in section 8 - and **section 7.7.7
then falsifies the premise it rests on**: the `90-99%` above counts a parent-child tautology, and the
near field's per-owner refinement depth is stable. Read this paragraph as the state of the question
*before* that measurement.

### 7.7.6 H3 step 1, landed - and the test that had to be corrected with it

Section 4/H3's step 1 is a deletion: a cap change publishes the new cap and marks nothing. It is
landed (`terrain_3d_surface_views_far_walk.cpp:491-521`), and landing it produced the second finding
of this phase, which is about the *test* rather than about the code.

**What was deleted.** On a change of `maximum_mip` the path used to mark **every region** in the
world bake-dirty (`for (...) _vt.bake.dirty_regions[location] = true;`), zero `bake.edit_time` so the
auto-bake scheduler would pick the set up, and rebuild the material's region arrays. It now calls
`set_world_max_mip()` and `_material->update(UNIFORMS_ONLY)`. The counter
`svt_cap_change_regions` is renamed `svt_cap_dirty_regions` because it no longer reports the size of
a queue the change wrote; it reports the **increase** in `bake.dirty_regions` across the change
(`region_marks_after - region_marks_before`), so a regression that reintroduces the sweep shows up as
a non-zero value instead of being masked by whatever an unrelated edit had already queued.

**The measurement, on `vt_svt_coverage`'s turned phase - the only fixture that reaches a raise past
the initial bake.** The camera turns across the grid, the visible far field demands a level the
initial bake never published, and the cap goes `3 -> 4`:

```
VTSVTCOVER_BAKE     queued=144 max_mip=3
VTSVTCOVER_READY    phase=turned points=101 mip=4 generation=2 incremental=true
VTSVTCOVER_REPAIRED mip=4 generation=2 total=144 done=144 dirty_regions=0
```

with `svt_cap_changes=2`, `svt_cap_dirty_regions=0`, `bake_generation` frozen at 2 (no incremental
job ran at all), and every one of the 101 visible far points holding a **ready persisted SVT owner**
- including slot 12, an SVT page at `mip=4`, `world_rect` 1024x1024, `ready=true`. The `READY` line
is itself part of the result: before the correction below the same phase printed `TIMEOUT` with
`repair_seen=false`, because it was waiting for the deleted mechanism. `check_visible_frame` passes on
that view, and it is the assertion that has teeth: the source albedo binding is poisoned before the
phase, so a page that was not served from the persisted bake renders blue.

**Why the level is still produced, and why that was predictable.** The cap is a bound on which mips
`request_world_page()` accepts (`terrain_3d_virtual_texture_lookup.cpp`), not a statement about
content. The persisted catalogue holds a cell per region with the cell's mip chain, so the level the
raise makes reachable was already derivable; the walk requests it like any other page and the producer
serves it - in the run whose log is quoted above the far-field pass produced that page itself
(`svt_stats.produced=1`, `svt_requeues=16`). H3's own words were "enables coarser *requests*, it does
not move what is already published" - the deletion is what that sentence means.

**The correction, which is the part worth recording.** The test previously asserted
`has_incremental_bake(turned_settings, moved_generation)` - "turning the camera must launch an
incremental persisted SVT repair". That is an assertion about the **mechanism the old code used**, not
about the result: it can only be true while the whole-world sweep exists. With the sweep deleted it
failed while the served pixels were correct, and the 2400-frame wait it drove never satisfied itself:
the same test takes **63.5 s** before the correction and **24.0 s** after, so most of the phase's
runtime was the assertion waiting for a repair that no longer comes. It is replaced by what the phase
actually needs:

| Assertion | What it pins |
| --- | --- |
| `extended_mip > moved_mip` | the turned view really does demand a level the moved view did not |
| `svt_cap_dirty_regions == 0` | the raise that served that level marked no region |
| `not has_incremental_bake(...)` | no whole-terrain repair ran for it (the new negative assertion) |
| `check_visible_frame("turned", ...)` | the level is served, from the persisted bake, on poisoned source |

This is a self-correction in the same family as section 7.3's, and its lesson generalizes to the
section 9 rules: **a test that asserts the mechanism will block a mechanism change even when the
property it was standing in for still holds.** The correction also removed the dead generality the
old assertion had dragged in: `wait_for_visible_coverage()` took a `p_generation` parameter and a
`repair_seen` flag that existed only to wait for the bump, every call site passed `-1`, and the
parameter is now gone rather than defaulted to "no repair expected" - a caller that still wanted the
bump would be asserting the old code. `has_incremental_bake()` survives as the predicate of the new
*negative* assertion at the turned phase.

**Step 2 stays deferred, unchanged.** The remap on a *lowering* cap has no lowering path to exercise:
`maximum_mip` is `MAX`-composed against the saved cap and can only grow within a run, and
`set_world_max_mip()` is the only writer. Implementing a transaction that no code path can enter
would be unverifiable, which is the criterion section 9 uses. What it would need is already named:
`_remap_sector_pages()` plus `Terrain3DVTPagePool::move_owner()`, called from the view that owns the
level space.

**Cost, measured, because it is the reason the change is worth having.** `svt_cap_change_ms` 0.092 ms
total over two changes with a 0.059 ms worst case (`svt_cap_change_worst_ms`) - a uniform publish. The
deleted sweep wrote one dictionary entry per region, 144 in that fixture and one per loaded region in
any world, and rebuilt the material's region arrays. The change is small in milliseconds and large in
what it stops doing to a world's bake queue; the frame check above is what establishes that stopping
it costs no content.

### 7.7.7 P2: the level rule is stable, and the counter that said otherwise was a tautology

P2 was scoped by P0e's finding that "the level rule and the boundary decisions re-derive ground the
plan already had" - `plan_overlapped` 90-99% of every generation's new addresses, `plan_rescaled`
0-67, `plan_reselected` 0-75. The acceptance was written against that: make a footprint rule stable
across generations and `avt_missing`'s peak falls from 91 to under 20.

**The first attempt at measuring the direction of the level move was single-valued, and that is the
finding.** The counters added for it classified every new address by whether the previous plan's
rect over the same ground was *finer*, *equal* or *coarser* than the new page, plus "no rect covered
it". Across all seventeen reported generations of the phase E and F cruises:

* `overlap_coarser` equalled `overlapped` in **every** generation of the run, digit for digit;
* `overlap_finer`, `overlap_equal` and `overlap_none` never printed a value other than zero.

That is not a property of the world, it is what being a child *means*: **a page the refinement walk
just created is a child of a page that was already there, so its rect is contained in a rect the
previous plan held.** "The previous rect over this ground was larger" is true of every new page by
construction, and a counter that cannot take a second value cannot answer its question. It is the
same failure as P0e's first revision - a test whose inputs make the answer determined - and section 9
now carries it as a rule. The counters were **replaced, not kept**: `plan_overlap_*` is gone and
`plan_depth_deepened` / `plan_depth_receded` / `plan_depth_same` are what `get_vt_settings()` reports.

**Depth per owner is the version of the question that can take three values,** so that is what is
compared: the finest world span each plan offers for each owner both plans held (`avt_depth_up`,
`avt_depth_down`, `avt_depth_same` in the probe). World span rather than the mip index, because a
block-size step moves the mip index of an unchanged span.

**The record is the probe's `VTCAPPLAN` line, which prints the whole tuple.** It had to be added: the
probe's per-step line prints only the keys that *changed*, so a counter holding its value does not
appear and a table reconstructed from it is a guess - the first version of this section said `sel`
172/`overlapped` 120 for one generation where the values were 174/123, and the reconstruction could
not tell the difference. The four-leg phase E cruise, read from that line:

```
VTCAPPLAN                      sel carried overlapped rescaled reselected new_sector dropped missing depth_up depth_down depth_same size_grows
E settled                       17      17          0        0           0          0       0       0        0          0         17          0
E cruise1 f25                   30      26          0        0           0          4       0       0        0          0         22          8
E cruise1 f50                   59      41          8        8           0         10       6       0        2          0         24         12
E cruise1 f75                   96      80         16       14           2          0      39       0        5          0         59         14
E cruise1 f100                 114      91         22       19           3          1      46       9        6          0         60         13
E cruise2 f25                  118      81         28       21           7          9      64      11        7          2         44         10
E cruise2 f50                  122      96         20       14           6          6      54       0        5          0         53         16
E cruise2 f75                  144     102         36       15          21          6      61      24        5          1         52         13
E cruise2 f100                 147     105         33       15          18          9      67       0        6          0         49         11
E cruise3 f25                  142      86         53       16          37          3      85       0        3          1         48         15
E cruise3 f50                  163      93         69       15          54          1      98      48        5          2         42         10
E cruise3 f75                  155      92         62       18          44          1      97      22        4          1         39          7
E cruise3 f100                 174      50        123       77          46          1     147      91        3          1         32         17
E cruise4 f25                  144      34        102       26          76          8     145      81        1          1         28          9
E cruise4 f50                  143      69         69       25          44          5      97      16        6          2         32          6
E cruise4 f75                  123      64         50        6          44          9      93      15        3          0         36          6
E cruise4 f100                 128      91         31       20          11          6      70      20        6          0         41          4
```

Two identities hold in every one of those sixteen generations, and they are what makes the
`overlap_*` buckets' single-valuedness provable rather than merely observed:
`carried + new_area = sel`, `overlapped + new_sector = new_area`, and therefore
`reselected = overlapped - rescaled`. The middle one says **no new address ever lacked a covering
previous rect of its own owner** (a non-zero `overlap_none` would break it), and the last says every
new span is also an overlapping one - both are consequences of a new page being a child.

**`depth_down` is 0-2 in every generation, and `depth_up` is 1-7.** The number of owners both plans
held is `depth_up + depth_down + depth_same` (17 in the settled view, 28-60 while cruising), against
`avt_sectors` 54-134 for the whole working set. So for every owner the plan keeps, the refinement
depth it reaches is **the same as it was, or one level deeper - essentially never shallower**. There is
no level flip-flop to remove: the mechanism P2 was scoped to fix does not exist in the direction P0e's
`overlapped` reading implied.

**What the churn actually is, per the same numbers.** At a plan size of 123-174 addresses, 34-105 are
carried and the rest are new pages *within owners whose depth did not change*, with a matching number
dropped (`dropped` tracks `new_area` closely: 39/16, 46/23, 64/37, 85/56, 98/70, 147/124, 145/110,
97/74, 70/37). That is **lateral** churn - the boundary of the refined region moving within an owner
whose level is stable - plus `new_sector` 0-10 for owners the view reaches for the first time. The
level rule is not re-deriving; the *edge* of the walk is, and the edge is what a 20 m generation
moves. `avt_missing` is still `max(0, new - ~50)`, and the new addresses are lateral.

**Consequence for P2, and what the next step is.** P2's acceptance as written measured the wrong
mechanism, so this row does not close on a code change and does not close as "the far-field form did"
either - the defect it names is real (`avt_missing` peaking at 89), only its stated cause is corrected.
The next measurement is the one this result points at: the boundary decision is
`projected > 1.f` (`terrain_3d_avt_plan.cpp:143`), and `projected` is multiplied by discrete terms -
`density_margin` switching between `3.f` near a slope and `DEMAND_DENSITY_MARGIN` (`:126`, gated by
`heights.x != heights.y && farthest < exact_radius`), and `heights` itself coming from
`source->bounds()`, which **tightens as pages are produced**. A boundary whose terms step while the
camera moves smoothly is a boundary that moves without the camera, and that is the hypothesis the
lateral churn now has to be tested against: a per-generation counter for which of the two margin
branches each selected page took. Recorded here so it is not re-derived.

**Cost of the counters, because they run on the tick's classify path.** `avt_classify_ms` was
0.007-0.108 ms before the change and 0.007-0.108 ms after across the same phase E generations - the
extra work is one sort of ~170 `(owner, rect)` pairs and one binary search per owner, 28-60 of them.
They are diagnostics and are on the main thread, so the number is recorded rather than assumed.

### 7.7.8 P6: the ~200 ms first far-field pass is one stage, and it is the root request

P6 was "measure first, then decide", with the acceptance "a recorded breakdown of the worst pass, or
a recorded decision not to chase it". The far field already keeps the worst pass's own stage
dictionary (`_vt.svt_stats` is written only when a pass becomes the new worst, `svt_worst_ms` is its
total), but the probe never printed it, so the breakdown was in the settings and not in the record.
`vt_cap_probe.gd` now prints it as its own line. Phase A's first pass, latest run:

```
VTCAP worstpass svt_worst_ms=231.9 svt_worst_frames_ago=1560.0
  pass_ms=231.9 regions=25 regions_ms=0.04 walk_visited=144 visible_pages=12 walk_ms=0.023
  capacity_ms=0.003 mip_ms=0.0 roots=20 roots_skipped=false rootlist_ms=0.003 rootunpin_ms=0.001
  rootreq_ms=231.745 rootcov_ms=0.001 chosen=12 detail_capacity=236 visited=12 produced=16
  requeues=16 detail_ms=0.084
```

**231.745 of 231.9 ms is `rootreq_ms`.** The region gather is 0.04 ms, the walk 0.023 ms, the
capacity check 0.003 ms, the level decision under the timer's resolution, the detail stage 0.084 ms -
and requesting and pinning the twenty root pages is the whole spike. Three runs put the same stage at
207.034, 207.17 and 231.745 of 207.17, 207.17 and 231.9 ms, so the total varies and the attribution
does not. It happens once per session (`svt_worst_frames_ago` 1560) and only on the pass that first
plans the root pyramid (`roots_skipped=false`), which is exactly the pass a world's first frame runs.

That converts P6 from "a 200 ms pass somewhere" into **20 root pages costing ~10 ms each on the pass
that first requests them** - a bounded question with a bounded answer (amortize the first root request
across frames, or find what in the root request path is not the request). It is recorded as a
breakdown rather than chased, because the pass is once per session and P6 asked for the measurement
first; the next step, if it is chased, is to split `rootreq_ms` per root.

### 7.7.9 H3's third instance, and step 2's reachable trigger

Step 1 removed the heavy hammer from the far field's *runtime* cap raise. Reading the setter next to it
found the same hammer one level up: **`set_surface_svt_max_mip()` called `_reset_vt_configuration()`**,
which marks the shared setup stale, so the next tick rebuilt both views' pool, released every resident
page - the near field's 150-200 included - bumped `pool.generation` so the far field's root plan was
discarded, forgot the near field's plan and address directory, and cancelled a bake in flight whose
catalogue is indexed by cell and level rather than by this cap. All of that for a uniform.

It is the same argument step 1 made, so it got the same treatment, with the codebase's own pattern for
it (`set_surface_svt_root_mips()` and `set_surface_svt_fallback_policy()` beside it already only reopen
the strict-sampling gate): publish the cap on the live view - `_surface_svt_max_mip` is read from
`svt->get_world_max_mip()` when the material publishes its uniforms - reopen the gate, because the root
window is planned *inside* the new cap and `_update_visible_svt()`'s root key mixes `maximum_mip` and
`root_top` so the next pass re-pins by itself, and republish the material so both reach the shader.
`set_surface_svt_max_mip()` is now four lines and no reset.

**Measured, on the probe's phase G** (the setting changed on the settled view phase F leaves behind).
The setting and the published cap are two different numbers - the pass raises the live cap above the
setting whenever the visible field needs more - so the line prints both:

```
VTCAP G capsetting  setting -1->0 effective 9->8 resident 512->512 pool_gen 1->1 bake_generation 0->0 cap_changes 0->1 alloc 4547->4599
VTCAP G capsetting  settle frames=1 worst_delta=0.0000
```

The phase sets the *configured* cap from `-1` (auto, resolved on initialize) to `0`, i.e. it **lowers
the level space on a view that has 512 resident pages** - the case section 4/H3 called "the remap on a
lowering cap" and could not reach. Nothing resident is released (`512 -> 512`), the pool generation
does not move (a rebuilt pool would have discarded every pin), no bake generation is cancelled, and
`alloc` moves by 52 over the settle frames - ordinary cruising churn, not a rebuild. The published cap
drops to 8 in that snapshot and is then raised back past the old value by the pass
(`cap_last=0>5`, `cap_changes=2`, `root_cap_raises=2`, `max_mip=10` at the end), which is step 1's path
doing its job: **the entries did not need remapping, because `virtual = (page + half) >> mip` is
level-invariant** - the same sentence step 1's deletion rests on, now measured in the lowering
direction too. The picture does not change at all (`settle frames=1`, `worst_delta=0.0000`).

So the cap's *lowering* path is reachable after all, and it is the one H3 step 2 named - and it turns
out to need step 1's deletion rather than a remap. What does need a remap is a different level-space
change, and that one is reachable too:

**The remap's own trigger: a changed indirection grid, not a changed cap.** The general H3 mechanism is
"move every resident owner of a view from an old level space to a new one, keeping the world
footprint". The far field's level space is not only the cap: the indirection grid's centre offset is
part of the addressing (`virtual = (page + half) >> mip`, `half = indirection_size >> 1`,
`terrain_3d_virtual_texture_lookup.cpp:152-157`), and the indirection is sized from the capacity
(`_configure_surface_view()`), so **a runtime capacity change moves every resident page's virtual
coordinate while its content stays valid** - page size, border and the world grid are untouched. That
is exactly HDRP's `RemapVirtualImage` case, and it is reached by `set_surface_svt_page_count()` (also
`vt_page_count`), which goes through `set_vt_page_count()` -> `_reset_vt_configuration()`. The current
policy is the hammer: a new pool, every page released.

**Measured, on the probe's phase H** (the capacity doubled on the view phase G leaves behind):

```
VTCAP H pagecount  pages 512->1024 resident 512->172 pool_gen 1->2 bake_generation 0->0 alloc 4599->172 evict 2834->0 free 0->852
VTCAP H pagecount  settle frames=1 worst_delta=0.0000
```

`pool_gen 1 -> 2` is the rebuild, and `resident 512 -> 172` is its cost: **340 resident pages released
and re-produced from nothing**, with the pool's `alloc`/`evict` counters starting over (172 and 0) and
852 free slots in the new 1024-slot pool. The picture recovers inside the settle window, which is why
this is a *cost* measurement and not a visible defect - and it is the baseline a remap has to beat:
after one, `resident` should stay 512 and `pool_gen` should not move.

**Why the remap was still not implemented this round.** Making it real means keeping the pool across
`_configure_vt_service()` (`terrain_3d_vt_service.cpp:304-372`, which builds a new one unconditionally:
"the pool cannot be resized in place, so a rebuild releases every resident page") and republishing
entries for the world-space owners while deciding what to do with the *other* kind - the legacy region
AVT's owners, whose virtual coordinates come from a per-view atlas that `clear()` destroys. That is a
service-lifecycle change across four files, and its verification is the whole VT test set; it is its own
step, not a tail-of-round edit. What this round leaves is the correction of the trigger claim, the
mechanism's statement, and a measured baseline with a probe phase that reproduces it.

### 7.7.10 Step 2 closed structurally: this renderer cannot preserve a page across its own capacity change

Reading the pool to plan that service-lifecycle step turned up the answer, and it is not a remap. Three
facts, each in the code with its own comment:

1. **The physical atlas cannot be resized.** It is one `Texture2DArray`, and
   `GeneratedTexture::ensure_layers()` (`generated_texture.cpp:56-85`) frees the RID and recreates every
   layer from one blank image whenever the layer count changes. A slot's content cannot survive that.
2. **So growth evicts everything, by design.** `Terrain3DVTPagePool::grow()`
   (`terrain_3d_vt_page_pool.cpp:95-129`) calls `evict_slot()` on every used slot, clears `lru` and the
   whole reverse-owner index, and warns how many resident pages it released.
3. **The far field's grid size is derived from the capacity** (`_configure_surface_view()`:
   `MAX(64, surface_svt_page_count * 4)`, and `_update_vt_service()` overwrites `surface_svt_page_count`
   with the published capacity), so the grid change H3 step 2 wants to remap and the atlas rebuild that
   destroys the content are **the same event**. There is no capacity change that moves the addressing
   without moving the atlas.

HDRP's `RemapVirtualImage` exists because its physical page table is allocated once and never grows: a
*virtual* image can be resized inside a fixed physical table, so moving entries is enough. This addon
grows the table. **The mechanism that answers the same pressure here is not a remap - it is the
coarsening that already exists** (`capacity_mip_bias`, `refinement_requests_denied`: the planner picks a
coarser level when the hierarchy does not fit). Growth is the other response to that pressure, and it is
a feng extension HDRP does not have. So step 2 closes as *not applicable to this addressing*, with the
reason measured rather than argued, and the question that replaces it is the one section 7.7.1 already
opened: whether growing is worth what it costs.

**Two comments said growth keeps residency. It does not, and the generation is not bumped either.** The
`Terrain3DVTPool::grow()` comment read "No generation bump - nothing was released" and
`_ensure_vt_capacity()`'s read "Keep addresses, owners and source jobs, including an already completed
plan". Both are now corrected in place, because the half that is true is the useful half: what survives
is the **addresses, the source jobs and the completed plan** - the pages do not, and the generation stays
put on purpose, because the generation is what tells a consumer to throw its plan away and re-planning is
the expensive half of the loss (the far field's own root verification is what catches the released pins;
a bumped generation costs a root pass, ~200 ms, section 7.7.8).

**The measurement, in a normal session.** The probe's own log shows it happening without any phase
forcing it: the view's capacity grows `256 -> 512` between "A settled" and the C cruise while `pool_gen`
stays at 1, and `evict_count` jumps by **355** in the interval that contains the growth (174 -> 529) - a
wipe of the resident set that no generation counter announced. That event is also the first block of the
phase E/F `alloc` and `fade_starts` totals.

**And the A/B, because growth is a policy.** `vt_cap_probe.gd` now reads `VT_PROBE_AUTO_CAPACITY` from
the environment (`VTCAP knob auto_capacity=...`), and the runner passes the environment through, so the
same script runs with growth off. Readings at the end of phase F, before any phase forces a capacity
change, both runs identical up to that point:

| Reading at "F settled" | `auto_capacity=true` | `false` | Change |
| --- | --- | --- | --- |
| `alloc` | 3873 | 3717 | **-4%** |
| `fade_starts` | 3871 | 3716 | **-4%** |
| `evict` | 2552 | 3082 | **+21%** |
| `free` | 443 | 193 | -250 slots |
| `eff_pool` | 512 | 256 | half |
| `avt_missing` peak over A-F | 102 | 102 | **unchanged** |
| `max_mip`, `root_page_world` before phase G | 9, 16384 | 9, 16384 | unchanged |
| `served_level_changes` (whole run) | 52 | 48 | -4 |

**So growth costs about 4% of the session's allocations and buys headroom, not detail.** Turning it off
removes the wipe's re-production (-4% `alloc`, -4% `fade_starts`) but leaves the pool at half the size,
which raises LRU evictions 21% and cuts free slots from 443 to 193 - and it changes neither the deficit's
peak (102 both ways) nor the levels the far field serves before the scripted change. The trade is real
but small in both directions, so the default is left alone: this is a *measured* policy note, not a
reason to change one.

### 7.7.11 The shared page budget: the ceiling came off, and what the rate actually buys

Asked after the objective closed: one tick produces at most `vt_pages_per_update` pages, so can it be
32? The answer turned out to be a design correction rather than a number. The setting was clamped in
three places, and **the first fix - raising the ceiling from 16 to 32 - was the wrong fix**: a ceiling
nobody can see is worse than no ceiling, because it silently overrides the number the caller chose, and
a rate is exactly the kind of thing a caller sets in order to tune. The clamps are now **gone**:

| Gate | Before | Now |
| --- | --- | --- |
| `Terrain3D::set_vt_pages_per_update()` | `CLAMP(p, 1, 16)` | `MAX(1, p)` - no upper bound |
| the bound property's range hint | `"1,16,1"` (then `"1,32,1"`) | hint removed, so the inspector does not put the ceiling back |
| `Terrain3DSurfaceBaker::set_page_budget()` | `CLAMP(p, 1, 16)` | `MAX(1, p)` - the producer's copy, which is what `_frame_page_updates >= _page_budget` admits per frame |
| the dock's spin box | soft range, `allow_greater = false` | `allow_greater = true`, so a typed value is not clamped behind the user's back |

The only guard left is positivity: a budget of zero is not a rate, and the near field's share floors at
one page anyway, so zero would read as "one page" through one path and "none" through another.
`vt_resolution_controls.gd` now asserts the setting is the number that was set (64 -> 64, 1024 -> 1024,
0 -> 1) rather than that it clamps.

**What still bounds the effective rate, and it is the producer's ring, not this number.** The in-flight
encode ring is derived from the budget (`_derive_encode_ring_pages() = budget * ENCODE_READBACK_FRAMES`)
and clamped by the bytes the ring may hold and by `ENCODE_PAGES_MAX`, and a runtime increase only
re-admits up to what the bundle allocated. That is the thing to read when a large budget does not
produce a large rate: `get_vt_settings()["producer"]` reports `encode_ring_capacity` and
`encode_ring_allocated`.

**The measurement, at 16 / 32 / 64** (the probe's `VT_PROBE_PAGES_PER_UPDATE`; readings at the end of
phase F, before any phase forces a capacity change):

| Reading | 16 | 32 | 64 |
| --- | --- | --- | --- |
| `alloc` | 3872 | 5723 | 6008 |
| `evict` | 2551 | 4101 | 4383 |
| `fade_starts` | 3870 | 5718 | 6004 |
| `free` | 443 | 449 | 449 |
| far field's own `miss` | 429 | 315 | **277** |
| far field `hit` | 21805 | 21866 | 21906 |
| `n_miss` (near field) | 4452 | 6486 | 6848 |
| **`avt_missing` peak over A-F** | 102 | 101 | **101** |
| plan tail `avt_tail_cap` | 56 | 112 | 224 |
| plan size `avt_sel` | 144 | 172 | 191 |
| worst far-field pass `svt_worst_ms` | 236.9 | 307.3 | 291.7 |

**Sixteen times nothing, sixty-four times nothing: the deficit peak does not move (102 / 101 / 101).**
What moves is the churn - `alloc` 3872 -> 6008, `n_miss` 4452 -> 6848, `fade_starts` 3870 -> 6004 - and
the plan's unsampled tail, which *follows* this number (`tail_cap = _avt_tick_allowance() *
refresh_frames`, so it doubles and then doubles again: 56 / 112 / 224). The one real gain is the far
field's own miss count, 429 -> 277 (**-35%**), with most of it in the first doubling; that is also the
first evidence that the far field competes for the budget at all, against the code comment's "about 0.1
page a tick once its root pyramid is pinned".

Two things follow, and both are the caller's to decide:

1. **The knob now means what it says, but a bigger number is not a faster fill.** If the goal is far-field
   coverage, the number that improved is the far field's miss rate, and the price is paid by the near
   field (misses +54% at 64). If the goal is the near field's deficit, this is the wrong knob, as
   section 7.7.1 already found.
2. **The A/B still carries 7.7.1's confound**: the tail term follows the budget, so "supply" and
   "unsampled residency" moved together every time. Separating them (a 64-page tick with the tail pinned
   at the 56 the shipped basis derives) is the experiment that has not been run.

### 7.7.12 What the rate actually is: the ring is the ceiling, and the producer sits under it

Section 7.7.11 removed the clamps and named the producer's ring as the thing to read next. The probe now
reads it: `VTCAPRING` prints the producer's own limiters on every report and once for the session -
`encode_ring_capacity` and `encode_ring_allocated`, the regions in flight, `pending` (the pages a frame
deferred), and pages produced per frame, which is `baked_pages + cached_uploads + migrated_pages` over
`dispatch_count`, the frames the producer dispatched a bake in. Three runs, `VT_PROBE_PAGES_PER_UPDATE`
16 / 32 / 64, the budget set before the first bundle is built (so the ring's allocation follows it):

| Reading | 16 | 32 | 64 |
| --- | --- | --- | --- |
| ring `capacity` / `allocated` | 32 / 32 | 64 / 64 | 64 / 64 |
| session pages per frame | 7.55 | 12.48 | 12.73 |
| cruise interval peaks | 8.0 | 16.0 | 16.0 |
| `pending`, against the budget | 0-17 | 0-17 | 0-17 |
| near plan `carried` / `sel` | 136 / 144 | 164 / 172 | 181 / 191 |
| `produce_slot_wait` / `produce_source_wait` | 0 / 0 | 0 / 0 | 0 / 0 |
| near field `n_miss` | 4457 | 6490 | 6846 |
| far field `miss` | 481 | 356 | 318 |

Two of those rows moved when section 7.7.13 made the ring's allocation the ceiling instead of the
build-time budget: the depths are now `32 / 128`, `64 / 128` and `128 / 128`, and re-running the same
three budgets gives session rates of 7.56, 12.43 and **12.65** - the same numbers. A budget of 64 now
admits twice the ring it used to and produces the same pages a frame, which is the measurement that
says the ring was never what this probe ran into.

**The budget buys rate, but only up to a budget of 32.** The effective page rate is the ring's depth over
the frames a position is held (`ENCODE_READBACK_FRAMES` is 2), so it is
`min(budget x 2, ENCODE_PAGES_MAX, bytes) / 2` - with `ENCODE_PAGES_MAX = 64` the ceiling is **32 pages
per frame**, and 32 and 64 derive the same 64-position ring. The measurement says exactly that: 12.48 and
12.73 pages per frame are the same number, and both are twice the 7.55 that a 32-position ring gives. The
number to raise for a rate above 32 is `ENCODE_PAGES_MAX`, not `vt_pages_per_update`.

**And the producer is not the constraint at 12.7 pages per frame.** `pending` never passes 17 against a
64-page budget, `produce_slot_wait` and `produce_source_wait` are both 0, and the near field's plan is
94-95% pages it already holds (`carried` 181 of `sel` 191 at 64; 136 of 144 at 16). At this probe's scale
the near field has nothing left to load, which is why its own `avt_missing` peak could not move in 7.7.11
either: there is no backlog for a faster producer to drain. A rate raised for its own sake would spend
itself on `n_miss` (4457 -> 6846, +54%) and on `fade_starts` (4769 -> 7160), which is churn, not fill.

**A budget raised at runtime is served by the headroom the build-time budget left, and the shipped
default leaves none.** `_encode_ring_allocated` is decided when the bundle is built
(`bundle.cpp`: `CLAMP(MIN(_derive_encode_ring_pages(), MAX(page_count / 2, ENCODE_PAGES_MIN)), ...)`) and
`_refresh_encode_ring_capacity()` never admits more than it, whatever the budget becomes. The probe
cannot show this because it sets the budget before the first bundle; the dock's spin box can, and with
the default budget of 16 the allocation is 32 while the derivation is already 32 - so raising the setting
to 32 or 64 in a running session changes the tick's split and the plan's tail and **nothing about the
rate**. Until something rebuilds the bundle, the setting is a startup setting in that sense; either the
allocation has to be made for the largest budget the caller might ask for, or the two have to be
reconciled on a change.

**Compression moves the ceiling the other way.** These runs resolved uncompressed (`surface_vt_compression
= 0` is the default; `staging_layers` equals the page count and `encode_requests` is 0), where a ring
position is three encoded regions and the 96 MB `ENCODE_RING_BUDGET_BYTES` is nowhere near binding. With
BC7 or BC3 the same positions are also the staging pool, so `_encode_page_bytes()` adds `stored^2 x 30`
per position and the byte ceiling decides the depth before `ENCODE_PAGES_MAX` does - the same budget buys
*less* rate, not more.

**7.7.8's hitch is the one large stall left, and it is worth 15-30 frames of production.** This run's worst
far-field pass was `pass_ms=214.054`, of which `rootreq_ms=213.934`: queueing 20 root pages, 16 of them
produced and 16 requeued, in a single tick - at a measured 7-13 pages per frame, that one pass holds more
production than 15-30 frames of the same session, and it is the pass that first plans the pyramid
(`roots_skipped=false`). In this probe that pass happens once per session; it is the pass a *rebuilt* root
plan runs, so a large move or a flick into new terrain pays it again.

**What the ceiling means, restated in 7.7.13.** The ring's depth is
`min(budget x ENCODE_READBACK_FRAMES, ENCODE_PAGES_MAX, bytes)`, so the rate it implies is that over
the two frames a position is held: 16 pages a frame at a budget of 16, 32 at 32, and 32 at 64 while
`ENCODE_PAGES_MAX` was 64. The measured rates - 7.55 / 12.48 / 12.73 - are 47%, 39% and 40% of those
ceilings, so the ring was not what the session actually ran into at any of the three budgets: the near
field's allowance is half the budget, its plan is 94-95% pages it already holds, and the rate followed
*that*. The ring is worth reading anyway for the reason section 7.7.13 acts on: it is a ceiling the
caller cannot see and could not raise through the setting.

### 7.7.13 Three fixes: the ring's allocation, the rate ceiling, and the root pyramid's one-pass scan

Section 7.7.12 left three things that were the code's rather than the caller's: the ring's allocation
was derived from the budget of the frame the bundle happened to be built on, `ENCODE_PAGES_MAX` capped
the rate at 32 pages a frame with no way for the setting to reach past it, and a rebuilt root pyramid
queued its whole set in one pass. All three are fixed here.

**A. The ring's allocation is the ceiling, not the build-time budget.** The staging layers and the
encoder's output buffer are created when the bundle is built and `_refresh_encode_ring_capacity()`
never admits more than `_encode_ring_allocated`, so an allocation derived from that frame's budget
made the setting a startup setting in effect. One function now answers "how deep may the ring ever be"
- `_encode_ring_depth_ceiling()`: the byte ceiling, half the slot count and `ENCODE_PAGES_MAX`, the
same three bounds the derivation already used - and both the derivation and the bundle build ask it.
The allocation is that ceiling and the admitted depth is what the budget needs of it. What the
headroom costs is bounded by the same constants the derivation used, and it is paid only where the
ring exists: on a page-sized run the encoder's output buffer is built only when a tier is actually
stored sampled (`_compile_encode_pipeline()` is called from `_any_tier_uses_sampled(true)`), so a run
that compresses nothing reserves nothing; under the scratch regime the ceiling *is* the 96 MB byte
budget, which is what that constant is for. Measured by the probe's new phase I, which raises the
setting the way the dock's spin box does, at a 1024-slot pool:

```
VTCAP I latebudget     setting 16->64 ring cap 32->128 alloc 256->256 staging 1024
```

Before this the same raise reported `cap 32->32`: the ring kept what the build-time budget derived and
the session produced the rate of a 16-page budget however the setting was moved. `vt_compressed_render`
now asserts the property - a budget raised after the bundle must deepen the ring - next to the
assertions it already had for the admitted depth and the burst.

**C. `ENCODE_PAGES_MAX` 64 -> 256.** With the allocation taken care of, the next ceiling is the one
above 32 pages a frame, and it was `ENCODE_PAGES_MAX / ENCODE_READBACK_FRAMES`. At 256 a page-sized
run reaches 128 pages a frame, bounded by half the slot count, which is the same bound the ring always
had; a compressed run is still bounded by `ENCODE_RING_BUDGET_BYTES` (96 MB, about 46 positions at a
256-texel page) because under that regime the ring positions *are* the staging pool. That is the trade
the constant documents: a caller who wants a compressed run past 23 pages a frame raises the byte
budget, which is a memory decision, not a rate one.

**B. One home for a page's cell cover, and the pyramid queued under the pass's budget.** Two things
inside the root pass were wrong in the same place. `_resolve_svt_cell_pieces()` and
`_svt_cells_have_persisted_bake()` carried a copy each of the same geometry - `world`, the border
footprint, the first and last cell - and a copy each of the same "too many cells for a cell source"
limit, 4096. A 16 km root page is 63x63 = 3969 region cells, which passes that limit, so the far
field's twenty roots each scanned 3969 cells against the filesystem: `FileAccess::file_exists` a cell,
and on a hit a full `get_var` deserialization of a cell's mip chain. That is section 7.7.8's
`rootreq_ms` of 213.9 ms, and every one of those pages then took the region crop anyway, because a
page covering thousands of cells can never have all of them baked - the disk path could not have
produced a cell copy for any of them.

Both questions are now one file-local helper and one constant: `svt_page_cell_cover()` answers the
geometry and the limit, `SVT_CELLS_PER_PAGE = 1024`, and it is the same answer for the resident store
and for the disk. The second fault was the gate on the queue itself: the ramp it describes depended on
`_vt_tick_expired()`, which reads `vt_frame_budget_ms` - **zero by default**, so the gate never cut
and the floor of one page was the only bound. The queue is now bounded by the pass's own page budget as
well, `r_produced >= MAX(1, p_pass_budget)`, which is the number the pass already spends on its detail
pages: a root is a page like any other and a rebuilt pyramid ramps over the passes that budget allows.
Pinning stays unconditional and free, so the plan still settles on the first pass and only production
is spread. Two counters make both faults visible again if they return: `svt_persist_probe_cells` (cells
the disk probe examined) and `svt_persist_probe_skips` (pages it refused because no cell source can
serve them).

The measurement, the same probe script at the default budget, before and after:

| Reading | before | after |
| --- | --- | --- |
| worst far-field pass `svt_worst_ms` | 214.054 | **15.760** |
| `rootreq_ms` | 213.934 | **1.724** |
| worst pass `roots` / `produced` | 20 / 16 | 4 / 16 |
| disk probes at phase A (`probe_skips` / `probe_cells`) | - / - | 20 / 251 |
| session `svt_persist_probe_cells` | - | 2292 |
| `svt_root_passes` | 9 | 12 |
| `fade_starts` | 4769 | 4767 |
| far field `miss` | 481 | 473 |
| near field `n_miss` | 4457 | 4455 |
| `avt_missing` peak over A-F | 102 | 102 |
| pool `alloc` / `evict` / `free` at the end | 172 / 0 / 852 | 172 / 0 / 852 |
| session pages per frame at a budget of 16 | 7.55 | 7.56 |

**The pass that used to be 214 ms is 15.76 ms, and its dominant stage moved from the root request to
the detail loop** (`detail_ms` 13.973 of it). Everything that describes the outcome is unchanged:
`fade_starts`, both miss counts, the near field's deficit peak and the pool's own counters match the
before run, and the session rate at a budget of 16 is the same number. The pyramid costs twelve passes
instead of nine, which is what a ramp is. What these fixes buy is not rate at the default budget - the
budget is the budget - but the two things that were hidden behind it: a stall worth fifteen frames of
production, and a ceiling the setting could not reach.

### 7.7.14 The near field's reach default moved from 512 m to 384 m

Asked after 7.7.13's rate work: is the near field's *range* the reason an update is slow - the area
to refresh is the radius squared - and would 384 m be better than the shipped 512? Measured on one
script by adding `VT_PROBE_AVT_DISTANCE` to the probe and pointing phases A, E and F at it (they
used to pin 512, so the same script now measures any reach):

| Reading | 512 | 384 | 256 |
| --- | --- | --- | --- |
| settled plan at one fixed pose: `avt_sectors` / `avt_pages` | 54 / 15 | 30 / 9 | 11 / 3 |
| end of run: `avt_sectors` / `avt_pages` | 134 / 226 | 89 / 222 | 51 / 167 |
| one generation, cruise 3 f75: `new_area` / `overlapped` / `reselected` / `missing` | 124 / 124 / 112 / 112 | 124 / 124 / 112 / 111 | 125 / 124 / 112 / 111 |
| teleport 512 m: `new_area` / `missing` | 97 / 70 | 96 / 69 | 17 / 17 |
| far field `visible_pages` / `miss` | 19 / 487 | 25 / 520 | 28 / 549 |

**The settled plan follows the radius squared; the work a move costs does not follow it at all.** At
384 m the churn is the same line for line as at 512 (a 512 m teleport: 97/70 against 96/69), and at
256 m it only falls in the first cruise legs before converging on the same numbers by the third. The
reason is the churn's composition: `overlapped` and `reselected` - 124 and 112 of that generation -
are pages re-decided over ground the plan already covers, which is the lateral churn 7.7.7 recorded,
and a radius does not change how often a level decision moves. The probe's own `settle frames` metric
cannot answer the latency question at all: it reads 1 frame at every stop and every reach, because it
measures the distant band of the picture and saturates there.

So 384 m is not a way to make an update faster. It is a way to spend less residency on the ground
furthest from the camera, and its price is the band the near field gives up: the far field excludes
only `0.75 * reach` - 288 m instead of 384 m - so its own visible set grows 19 -> 25 and its miss
count 487 -> 520 in the same run. That is the band where the two tiers differ most, the near field
addressing 1024 texels a metre by default against the far field's one, so what leaves the near field
is resolved by a much coarser source rather than removed.

**The default is 384 m as a residency decision, not a rate one.** It is also where the reference
implementation's reach sits (HDRP's camera sector +- 6 sectors, section 3), while 512 m is what a
256-slot pool reaches under HDRP's *per-sector guarantee* - the two numbers answer different
questions, and the guarantee is a capability the plan does not have to spend. With the near field's
anisotropy at 8x in the same round (the sibling change, recorded in
[`vt_sampling_review.md`](vt_sampling_review.md)) the working set grew about 50%, and the reach is
the one part of it that can be given back without touching what the image samples: 54 sectors and 15
pages at the fixed pose become 30 and 9.

### 7.7.15 The fallback ladder's residency, and what a reused mip can buy

Asked after 7.7.14: the near field's blurry patches look like a mip problem - the reference terrain
this work is aligned with holds about ten mips, re-renders the two finest and *reuses* the rest - so
adding a level count and reusing finer levels for coarser ones should also take pressure off the AVT.
The question was answered from the code and from the arithmetic before anything was built, because
the two halves of it turn out to have opposite signs.

**Every near-field level is an independent production, and the far field's are not.** A page of the
near field is assembled by cropping the source at that page's own spacing (`pixel = rect.size.x /
request.size`, then a per-texel `ids_at`/`sample_height` walk in `Terrain3DPagePipeline::produce()`)
and baked by the GPU into a staging layer. Nothing derives a coarser page from a finer one. The far
field is the opposite: `load_cells()` crops a *mip of the cell's persisted bake*
(`requested_mip = floor(log2(pixel * density))`), a chain the baker builds once and the page then
reuses. So the reuse this question asks for is real and absent, and one codebase already contains
both schemes.

**Reuse buys production, not resolution, and not residency.** A coarse level downsampled from its
four children is the correct mip of them: it is not sharper than the same ground re-sampled from
source, and the fragment that samples it is still resolving at that level either way. What it buys
is that the page needs no source crop and no material evaluation - one four-tap average per channel
- plus level-to-level consistency. What it cannot buy is a smaller working set: the pages are the
same pages, resident for the same reason. This is why "reuse should reduce the pressure" does not
follow, and why the useful half of the request is the level count rather than the reuse.

**The resident set is the chain, and the chain's coarse half is bounded by a quarter.** A page's
four children sit one local mip finer, so each level holds at most a quarter of the pages of the
level below it. A plan whose image samples `N` pages at the mips its footprints select therefore
holds at most `N + N/4 + N/16 + ... = 4N/3` pages: **the whole fallback ladder above the sampled
band is at most a third of the sampled pages, so no chain change can give back more than about 25%
of the plan.** Nothing reported that split before, which is why the question had no answer: the new
`plan_level_mips` (a histogram of the local mip of every 64 m page the plan holds, index 0 = the
finest a block addresses) and `plan_world_pages` (the pages owned by a world node above the sectors)
are the readings that settle it on a real plan.

**And the ladder is what the blur is made of.** `avt_feedback` is on by default
(`terrain_3d_vt_state.h`), so a missing fine page resolves at the next resident level, and the world
nodes above the 64 m sectors are one 256-texel page each (`_avt_build_hierarchy()`'s `1, 1`): level
1 is 128 m over 256 texels (0.5 m a texel) and the root is 1 m a texel. Cutting the chain to buy the
residency back moves a fragment from its own sector's 0.25 m level straight to that, which is the
patch that reads as too blurry. So the level count is a residency setting paid for in fallback
sharpness, and automatic is what ships.

**Landed: the setting and the reading; the derivation is not landed.** `surface_vt_mip_levels`
(0 = automatic, the block's own chain; positive = a level count) with `get_avt_mip_level_cap()` as
its single reader, so the plan's chain start (`PlanInput::mip_level_cap`) and the shader's `top`
clamp (`_avt_mip_level_cap`) are one number rather than two spellings; the dock exposes it beside
the density, the gutter and the anisotropy, which are one decision between them, and
`get_vt_settings()` reports both the setting and the cap. `vt_resolution_controls` asserts the
pair's arithmetic and the dock round trip. The FC-style derivation - render the finest selected
level from source, then derive each coarser one from its four children instead of re-rendering it -
is **not** landed: it needs a baker job kind that reads the atlas and writes a staging layer, the
plan to mark a page derivable when its children are in the same page set, and the AVT production
order to become finer-first within an owner, because the ladder is submitted parent-before-child
today (`page_request_priority_before()`'s `span > span` tie-break). It is carried in section 11.

## 8. Phases and acceptance

Every phase ends with: the native build (`scons platform=windows target=template_debug`,
success marker `scons: done building targets.`; a non-zero exit with that marker is a
PowerShell `NativeCommandError` artefact, not a build failure), the targeted runners named
in the item, the audit scripts, and this document updated in the same step. Nothing is
committed by the agent.

| Phase | Work | Observable acceptance |
| --- | --- | --- |
| **P0** | *Done.* `svt_cap_changes`, `svt_cap_change_ms`, `svt_cap_change_worst_ms`, `svt_cap_last_*` and `svt_root_cap_raises` added to `_report_svt()`, plus the counter P4 renamed to `svt_cap_dirty_regions`; `native/tests/vt_cap_probe.gd` + `vt_cap_probe_runner.py` script turns, a teleport walk and a realistic cruise, and report every counter that could explain a trace, plus the selected and served level of four fixed distant points. | Done: section 7. The cap sweep is proven unreachable in the default configuration; turns cause no arrivals and no served-level changes; the cruise churns the shared pool (`alloc` 1825, `evict` 516, `free` 210 -> 0, `pool_gen` 1) while the far field's own miss rate stays near one per frame; and a fixed distant point ends up served at mip 8. |
| **P0b** | *Done.* The probe now reads the near field's `hit_count`/`miss_count` as well as the far field's, plus `effective_page_count`, `pool_generation`, `pages_per_update`, `free_count` and `protected_count`. | Done: section 7.4. The churn is attributed: the near field accounts for about 83% of the pool's allocations, and its zero hit count is explained by its lookup-then-request call pattern rather than by a defect. |
| **P0c** | **Done.** Read the near field's `avt_sector_stats` into the probe (`requested_physical_pages`, `sampled_pages`, `visible_missing_pages`, `produced`, `plan_reused`, `plan_key_dirty_component`, `chain_ticks`, `retained_sector_addresses`, `plan_budget`, `pool_pages`, `visible_sectors`, `coverage_radius`) and add a cruise at the shipped reach (phase E). | Done: section 7.5. The churn is not an invalidation bug and not plan size: at the shipped reach the plan grows 17 -> 241 pages in 100 cruise frames while the image samples 86 of them with 1 missing, and the producer spends about 2 pages a frame on the difference. |
| **P0d** | **Done, partially.** The plan's rate term, candidates 1 and 3 of section 7.7, as one change: `_avt_tick_allowance()` is the one spelling of the tick's page split; `PlanInput::tail_cap` carries `allowance * avt_plan_refresh_frames`; `plan_pages_for_bias()` bounds the plan's unsampled tail by it, split evenly between the apron and the retention window; the installer's fixed `MIN(128, budget - size)` retention bound is replaced by what the planner left. Candidate 2, the demand-aware share, was implemented first, measured, and **rejected** (section 7.7.1). | **Not met.** The term removes 76% of the plan's unsampled residency (237 -> 56 pages) and 12-13% of the pool's churn (`alloc` 4373 -> 3850, `n_miss` 4125 -> 3588, `fade_starts` 4361 -> 3841) at unchanged CPU cost, but `avt_missing` still peaks at 91, `free` still ends at 0 and the far field still collapses to `3>8`/`4>8`. Section 7.7.1 shows why: with fourteen pages a tick instead of eight the deficit did not fall and the churn rose 38-54%, so the supply is not the binding constraint. Section 7.7.2 records the measurements. |
| **P0e** | **Done, in two revisions.** The churn attributed at the one point where two generations are in hand: `_avt_install_or_reuse_plan()` classifies every address of the new selection against the standing plan as `plan_carried` / `plan_overlapped` / `plan_rescaled` / `plan_reselected` / `plan_new_sector`, plus `plan_dropped`, with `avt_page_span_key()` giving a page's world span an exact quantized key (1/64 m, finer than the finest page and coarser than float error at world scale) and a per-owner rect scan for the overlap test. `sector_size_grows` added to the directory sync. All read by the probe. | Done: section 7.7.3. The **first revision was wrong and is recorded as such**: it tested rect equality for a level change, and a level change produces a *different* rect (a coarser page contains the ground, it is never equal to it), so it read a structural zero and concluded the level hypothesis was unstateable. The overlap test answers it and says the opposite: **90-99% of a generation's new addresses intersect ground the previous plan already covered** (`sel - carried` 123, `plan_overlapped` 122 in the worst generation). The churn is the level rule and the boundary decisions re-deriving ground the plan already had - `plan_rescaled` (0-67) and `plan_reselected` (0-75) - plus a smaller inherent source, `sector_size_grows` 4-17 sectors a generation climbing the virtual-resolution ladder. And `avt_missing` is `max(0, new addresses per generation - ~50)` exactly. |
| **P0f** | **Closed without a code change, on the measurement.** The candidates were a hysteresis on the boundary thresholds, a hysteresis on the block-size ladder, and carrying more pages forward. Section 7.7.3 rules all three out: a page whose ground comes back at another span has a *new address*, so it must be produced again whatever the plan carries, and the tail-rebalancing experiment of 7.7.2 already showed that holding more unsampled residency raises churn (`alloc` 4373 -> 3850 when the tail fell from 384 to 56). A block-size step is not hysteresis-removable either: the virtual image genuinely has one more mip than it had. Sizing any part of a 384-page plan differently moves a few percent of 123 addresses and cannot reach a capacity of 50. | Closed: the fix is **H1 and H4**, which is why P2 and P5 are next. Recorded here so the local fixes are not re-tried. |
| **P1** | **Done.** The three seams, of which this phase's own step is `VTMipRule` and `VTPageDemandSource`: `TerrainVT::MipRule` with `AutomaticBands`/`ExplicitTable` and `select_mip_rule()` moves the far field's distance -> level arithmetic into `terrain_vt.h`, adds `test_mip_rule()` to the engine-free contract test, and leaves the node with exactly two helpers (`_svt_mip_rule()`, `_svt_mip_rule_cap()`); the demand-source seam names `CPURule`/`Projected` and splits the two questions the one flag was answering (`_vt_projection_demand_enabled()`, `_vt_demand_source()`). `VTFallbackPolicy` landed with P3. | **Met on the evidence it can have**: no behaviour change is allowed, so the acceptance is that every existing test is unchanged. `vt_mip_bands` (the explicit table), `vt_svt_coverage`, `vt_root_coverage`, `vt_fallback`, `vt_demand`, `vt_root_budget`, `vt_svt_root_mips`, `vt_anisotropy`, `vt_feedback`, `vt_perf`, `vt_idle_cost` and the rest of the far-field set green; the engine-free contract test green with `test_mip_rule()` added; `vt_pressure` (the fixture race) and `vt_visibility` (red at `HEAD`) red as recorded. The correction the landing produced - the demand sources are *layered*, not alternatives - is in section 5, and no flag was deleted: the settings became the seams' selectors, which is what section 5's "not left beside them" was protecting against. |
| **P2** | **Re-scoped a third time, by its own measurement - and this time the scope is falsified rather than moved.** The far-field form stays closed (§7.3) and H4's fragment form is closed (§7.7.5), so the near field is the case. P0e had put the near field's *level rule* there (`plan_overlapped` 90-99%, `plan_rescaled` 0-67, `plan_reselected` 0-75). Section 7.7.7 measures the direction of that level move and finds the premise was an artefact: `plan_overlapped` counts a newly refined child intersecting its parent, which is what being a child means, and per-owner depth never recedes (`avt_depth_down` 0-2, `avt_depth_up` 1-7, `avt_depth_same` 28-60). The churn is **lateral** - pages appearing and dropping inside owners whose depth is stable. | **Not met, and the acceptance it was written against is withdrawn as measuring the wrong mechanism.** No code change is claimed. What landed is the pair of counters that *can* answer the level question (`plan_depth_deepened`/`plan_depth_receded`/`plan_depth_same`, replacing the single-valued `plan_overlap_*`), and the next measurement is named: which density-margin branch each selected page takes, since `projected` is multiplied by discrete terms (`density_margin` 3 vs its default, and production-dependent bounds) and a boundary whose terms step while the camera moves smoothly is a boundary that moves without the camera. `avt_missing` still peaks at 89 and is still `max(0, new - ~50)`. |
| **P3** | **Done, and the default does not change.** H2 behind a mode: `surface_svt_fallback_policy` (0 = root pyramid, the default; 1 = per-unit coarsest), two strategies behind `_svt_fallback_pages()` so no call site branches on the flag, the policy in the scan hash and the root plan key, `svt_fallback_policy` and `svt_root_page_world` reported, a probe phase that drives policy 1 on phase E's exact pose and profile, and `vt_root_coverage` asserting each policy against its own contract. | Done, **"does not"**: section 7.7.4. The pool cost is reported - **20 -> 1 pinned page**, 78 more free slots of 512 - and the cruise's `served` sequence is unchanged line for line, `>8` collapse included. `vt_root_coverage` passes with either policy, the pyramid's domain assertions untouched and the per-unit policy's `domain_covered=false` printed rather than asserted away. Default stays 0 on the numbers: the policy gives up the "any world position resolves" property that makes the region array unnecessary, and buys a smaller *set* rather than a finer *fallback*, because this renderer's `sizeLog` is the world grid's global cap and not a per-unit one. |
| **P4** | **H3 done, and step 2 is closed as not applicable to this addressing.** Step 1: the runtime raise publishes the cap and refreshes the uniform only. The *setting* (`set_surface_svt_max_mip()`) was the same hammer and is now four lines. Step 2 (the remap) turned out to have no case here: the far field's grid size is derived from the capacity, the atlas is one `Texture2DArray` that `ensure_layers()` recreates blank when its layer count changes, and `Terrain3DVTPagePool::grow()` therefore evicts every slot - so the address change a remap would serve and the content loss it cannot prevent are the same event. HDRP remaps because its physical table never grows. The mechanism that answers the pressure here is the coarsening that already exists (`capacity_mip_bias`). | **Met, with the third part closed on evidence instead of implemented.** Section 7.7.6: the turned phase goes 3 -> 4 with `svt_cap_dirty_regions=0` and `bake_generation` frozen, 101 visible far points all hold ready persisted owners including a `mip=4` page, and the poisoned-source frame check passes. Section 7.7.9: the probe's phase G lowers the setting on a settled view and reads `resident 512->512`, `pool_gen 1->1`, `settle frames=1 worst_delta=0` where the old path rebuilt the pool. Section 7.7.10: the growth that cannot be remapped is measured in a normal session (`evict` +355 with no generation bump) and A/B'd against `vt_auto_capacity=false` (-4% `alloc`/`fade_starts`, +21% `evict`, same `avt_missing` peak of 102), with the two comments that claimed residency survives corrected. `vt_svt_coverage` green in 24.0 s (down from 63.5 s); `vt_mip_bands`, `vt_root_coverage`, `vt_auto_bake`, `vt_material`, `vt_fallback`, `vt_svt_root_mips`, `vt_demand`, `vt_perf`, `vt_idle_cost`, `vt_cells`, `vt_pressure`, `editor_dock:svt_inspector` all green on this revision. This row's own acceptance list named a `vt_residency` test that does not exist; corrected in section 4/H3. |
| **P5** | **Done in two steps, and H4 is closed in both of its forms.** Step 1: the gating question - a writeable storage binding from the material path, and a non-stalling read-back - is answered in section 7.7.5, from the engine source *and* on the running binary (`get_vt_settings()` reports `rd_direct_store`, `rd_async_buffer_readback`, `rd_async_texture_readback`, all resolved). The write is absent from the shading language, not from the binding; the two deferred read-backs and the per-frame render-thread hook are present. Step 2: the *re-scoped* form (`ScreenDrivenDemand`) is closed too, on the complementary evidence - the hook passes no frame context and its FRP operation is ordered "before the G-buffer" (`render_frp_clustered.cpp:2191`), so the screen is unreachable where the addon may record GPU work, and reaching it is a third engine patch plus a new subsystem whose benefit (occlusion-exact demand) is not on the measured critical path. | Closed as a documented gap, twice, with the gap now precise: "no fragment-authored demand buffer in this renderer" and "no frame context at the render-thread hook, by ordering". `vt_feedback` stays green (its four assertions are the working `Projected` source), and the enabling fork patch is named in section 7.7.5's addendum rather than taken. |
| **P6** | **Done: measured, and the decision is to record rather than chase.** `vt_cap_probe.gd` now prints the worst pass's own stage dictionary (`svt_stats` is written only when a pass becomes the new worst) as its own `VTCAP worstpass` line. | **Met, by the second half of its own acceptance.** Section 7.7.8: `pass_ms=231.9` is `rootreq_ms=231.745` - the region gather is 0.04 ms, the walk 0.023 ms, the detail stage 0.084 ms - so the ~200 ms first pass is the twenty root pages being requested on the pass that first plans the pyramid (`roots=20`, `roots_skipped=false`, `svt_worst_frames_ago=1560`). ~10 ms per root page, once per session; three runs give 207.0, 207.0 and 231.7 ms for that one stage and the attribution does not move. Not chased because it is once per session and the phase asked for the breakdown first; the follow-up if it is chased is to split `rootreq_ms` per root. |

P0 through P0e are done, P0f is closed on the measurement, P3 has landed as a mode, P4's H3 step 1 has
landed as a deletion, P5's probe has been answered, and P6 is measured. The work is aimed by
measurement rather than
by the comparison: the cap sweep is out, and the reproduced defect has a causal chain. The plan was
sized by **residency** (384 of a 512 pool)
while the tick pays the near field a fixed **eight pages** (`vt_pages_per_update / 2`), so the plan
held ~237 pages no fragment sampled and the pool churned (`alloc` 4373, `evict` 2651, `free` -> 0,
`fade_active` ~90-100, far field served at mip 8).

The rate term has landed and removes most of that residency (section 7.7.2), but the phase's
important results are two negative ones and two positive ones. Raising the near field's allowance to
fourteen pages a tick made the churn worse and did not move the deficit (section 7.7.1), so the
demand scales with the budget and the supply was never the binding constraint. A first attempt to
attribute the churn tested the wrong thing and read a zero (section 7.7.3, first revision, kept in
the record because the artefact is instructive). What the corrected measurement established is the
quantified chain: **90-99% of each generation's new page addresses intersect ground the previous
generation's plan already covered**, the level and the boundary decisions re-derive that ground
(`plan_rescaled` 0-67, `plan_reselected` 0-75 per generation), the new addresses reach 123 against a
production capacity of about 50, and `avt_missing` is that difference. A smaller inherent source is
the virtual-resolution ladder: 4-17 sectors a generation have their block size raised, one step
every ~16 generations each.

**The last link of that chain was then removed by a third measurement (section 7.7.7), and the way it
was removed is the phase's most useful result.** `plan_overlapped`'s 90-99% is a tautology - a newly
refined page is a child of a page the plan already had, so it intersects it by construction - and the
counter written to test the level direction could therefore only read one value. Per-owner depth,
which can read three, says the level rule is stable (`avt_depth_down` 0-2 a generation) and the churn
is lateral. So the churn is measured, the supply is ruled out, the level rule is cleared, and what is
left to measure is the *boundary*, not the level.

Eight code changes have landed: the diagnostic blind spot of section 7.6.1 (behaviour-neutral), the
rate term (a measured 12-13% churn reduction at unchanged CPU cost), P0e's counters (diagnostics
only), the fallback-policy seam with H2 as its second strategy (section 7.7.4), the capability report
that answers the H4 probe on the running binary (section 7.7.5), the two remaining seams of P1
(section 5), the deletion of the whole-world re-bake from the level-raise path (section 7.7.6,
together with the correction to the test that had been asserting that re-bake), and the per-owner
depth counters that replaced P2's single-valued first attempt (section 7.7.7). P0f - a local
stability fix - was **closed without a code change**, because a page whose ground comes back at
another span has a new address and must be produced again whatever the plan carries; no tail sizing
moves 123 addresses to 50.

This is the point at which the HDRP comparison becomes the mechanism rather than the diagnosis.
HDRP's demand is the set of pages fragments sampled this frame, so it is a function of the screen and
cannot re-derive the same ground differently; its pages persist until its allocator recycles them.
This addon re-derives the selection from a thresholded footprint/density model every generation, and
P0e names the thresholds and the rule that moves.

The probe of section 7.7.5 then removes the mechanism the comparison had been pointing at: there is no
fragment-authored demand buffer to be had here, because the shading language has no storage-image type.
So P5 is closed as a documented gap and **P2 was re-scoped onto the near field** - not "does a footprint
rule beat a distance rule" (the near field already has a footprint rule) but "what makes a footprint
rule stable across generations", with P0e's counters as the acceptance. Section 7.7.7 then measured
that scope and **falsified it**: the counters it was built on count a tautology, and the level rule is
already stable. P2 therefore stands as a measurement task - the boundary's discrete density terms,
named in section 7.7.7 - and not as a mechanism waiting to be written. P1 (the three seams) is what
any of it would land behind; **P4 is closed on all three instances** (step 1 and the setting landed, and
step 2's remap is not applicable to this addressing - section 7.7.10), leaving the screen-driven demand
source of section 7.7.5 as the one item that is feasible but not on any measured critical path
(section 11 item 4).

P3 (H2) has also landed, as a mode with the default unchanged, and its result belongs with the above
rather than beside it (section 7.7.4): the literal port pins 5% of the pages and changes nothing a
fragment lands on, because HDRP's `sizeLog` is per virtual image and this renderer's is the world
grid's global cap. The fallback-level question that H2 was meant to answer is the same one P2 now
carries, from the detail side instead of the fallback side.

## 9. Verification rules

* **A counter must be able to take more than one value.** Twice in this work a counter was written
  whose inputs made its answer determined, and both times the single value was read as a property of
  the world. P0e's first revision tested rect *equality* for a level change, and a level change always
  produces a different rect, so it read zero (section 7.7.3). P2's first revision classified new
  addresses by whether the previous plan's rect over the same ground was finer, equal or coarser, and
  a newly refined child always intersects its parent - so `coarser` equalled `overlapped` in every
  generation of that run and the other three buckets never moved (section 7.7.7). Before a counter is
  believed, ask what its *possible* values are: if one branch cannot occur, the counter is a
  tautology and the measurement is missing.
* **A test must assert the property, not the mechanism** - learned the hard way in P4. The
  `vt_svt_coverage` turned phase asserted `has_incremental_bake(...)`, "turning the camera must launch
  an incremental persisted SVT repair", which is a statement about the implementation the phase
  happened to be built around; the property it stood in for is "the new level is served from the
  persisted catalogue". Deleting the mechanism made the assertion fail while the property held
  (section 7.7.6), so the assertion blocked a valid change and, worse, spent 2400 frames a run waiting
  for a repair that no longer comes. When a phase changes a mechanism, the stand-in assertion is
  re-derived from the property and the property assertion is what stays.
* `python native/tests/run_all.py --driver d3d12 --only <name>` -- one test per run, substring
  filter. The full suite takes about 16 minutes and is not run without being asked for.
* **The measurement for this work is `vt_cap_probe`**: `--only vt_cap_probe`, or
  `python native/tests/vt_cap_probe_runner.py --driver d3d12` directly. It is a probe, not a
  regression: it asserts nothing about the numbers, so it passes while reporting a regression.
  Read its `VTCAP` lines, not its exit code. H1 and H2 are accepted or rejected against the
  numbers in section 7.2, not against a feeling.
* Known-failing or flaky suites are not to be "fixed" while doing this work:
  `vt_adaptive:{scale,metric,ownership,filtering,navigation,blend,sectors}` target the legacy
  region mode, `vt_turn_budget`'s near-field mean is a coin flip, and `vt_near_arrival` exits
  2 (`terrain_vt_and_streaming.md:1276-1296`, `terrain_optimization_audit.md:578`).
* **Two failures are red at `HEAD` and are not this work's.** `vt_strict_coverage` exits 2 in
  0.0 s (an infrastructure exit, the same shape as `vt_near_arrival`'s) and `vt_visibility` fails
  with three assertions ("far-view AVT should allocate one page, got 0", "fresh fixture
  unexpectedly has SVT requests before the manual demand pass", "one-page SVT budget should create
  one SVT record, got 7"). Both were confirmed byte-for-byte identical against a pristine build of
  `49bee0be7a` with the source changes stashed, so they are recorded as pre-existing rather than
  chased.
* **`vt_pressure` is intermittent at `HEAD` too, and its failure is a race in the fixture.**
  Run third in the sequence `vt_demand`, `vt_fallback`, `vt_pressure`, it fails with "AVT and SVT
  must use one physical pool" - `vt_shared_ready`, which only `_configure_vt_service()` sets.
  `setup_case()` enables both tiers and then awaits a **process** frame
  (`vt_pressure.gd:189-193`, "the next *physics* tick then performs the complete automatic service
  setup"), so the assertion at `:207` is reading the flag before the tick that sets it is guaranteed
  to have run. Six repetitions of that exact sequence give **3/6 failures on a pristine build and
  2/6 on this one**, so the patch is not the cause and is not worse; the same sequence through the
  raw runner (fresh fixture, slower startup) passed 4/4 on this build. This is a fixture bug to fix
  in the test, not a threshold to relax, and it is recorded here rather than fixed because section 9
  forbids changing tests to make a phase pass.
* **`editor_dock:dock` fails under `run_all.py` at `HEAD` too, on a synthetic mouse event.** Its
  failure is `EDITOR_DOCK_REGRESSION: mouse event did not reach <a dock button path>; hovered=<the
  widget that got it instead>`, at 28.8 s both with and without this work's source changes
  (A/B'd by stashing `native/src` and rebuilding), and the widget it lands on differs between runs
  (`@TabBar@...` once, `<Object#null>` once) - a coordinate/window-size race in the harness, not a
  behaviour. The same test through its own runner passes on both builds
  (`python native/tests/editor_dock_runner.py --driver d3d12` -> `EXIT=0 ERROR_LINES=0`, "PASS
  graphical Terrain3D asset dock layout and management menu actions"). `editor_dock:svt_inspector` is
  green under `run_all.py`. Not chased, for the same reason as the entries above.
* **`vt_cells_mix --mix` is red at `HEAD` too, and its cause is visible in one line.** The scenario
  (the `--mix` mode of `vt_cells_runner.py`, which `run_all.py` does not run - `--only vt_cells` takes
  the `bake`/`reload` modes) fails "one runtime page combines two independently baked cells" and
  "compositing does not rebake materials". Its diagnostic line says why: **no far-field page of any
  kind exists** in that fixture - `MIXDIAG ... roots=0 baked=17 pages=[...]` with 17 `AVT` records and
  **0 `SVT` records** - and a pristine build of `HEAD` (source changes stashed, rebuilt) produces the
  identical pair of errors and the identical 0-SVT/17-AVT signature. So the far field never produced a
  page in that scenario before this work either, and neither the cell-cover gate nor the root ramp is
  involved: the gate's own counters read `skips=0 cells=0`, i.e. it was never reached, because nothing
  asked it for a page. Recorded, not chased - fixing it means finding why a 240 m orthographic view
  over three 64 m regions leaves the far field with nothing to demand.
* **`editor_dock:dock` now fails through its own runner too, deterministically, and it is not the
  dock's content.** `python native/tests/editor_dock_runner.py --driver d3d12` reports
  `EDITOR_DOCK_REGRESSION: mouse event did not reach .../Terrain3D/Box/Buttons/MeshesBtn at
  (347.0, 1251.0); hovered=<Object#null>` - the same widget, the same coordinates and the same
  `hovered` on every run, where the `run_all.py`-only race recorded above varied both. It was
  A/B'd against a UI change that adds a settings row to the same dock (the near field's anisotropy
  spin): two runs with the row and one without it are byte-identical in that message, so the row is
  not the cause and the position the test clicks is not where the dock lays the button out in this
  environment. Recorded as an environment/fixture geometry problem, not chased.
* The same A/B confirms the whole `vt_adaptive:{sectors,metric,ownership,filtering}` family
  fails identically before and after the rate term - same assertions, same messages, same order -
  which is the evidence behind P0d's "`vt_adaptive:*` unchanged".
* No performance assertion or threshold may be relaxed to make a phase pass. A regression is
  reported, not absorbed.
* `native/audit_gd.py <shape|dead|params|dupes|state|indent|comments|outline>` and
  `native/audit_code.py` after every phase.
* **One more load-sensitive assertion, observed rather than baselined.** `vt_idle_cost` ("a settled
  view costs almost nothing") failed once inside a 24-test batch at 30.0 s, and its isolated runs
  take 21-24 s; it then passed 2/2 in isolation and in the same batch position. It is a CPU-cost
  assertion like `vt_turn_budget`'s, so it is recorded here as load-sensitive and not chased. Unlike
  the entries above, this one has **not** been A/B'd against a pristine build - the failure never
  recurred when it could be, so it is an observation, not a finding.
* Scratch measurement scripts go in the gitignored `bin/perf_probe/`.
* The real project at `C:\Users\xuyifeng\Documents\新建游戏项目` is not probed.

## 10. Documentation drift found while reading

Recorded, not fixed, so a future reader does not treat a stale document as current. These
are documentation tasks, not code changes:

1. `terrain_vt_and_streaming.md:718-724` states the far field defaults to a **512 m page at
   256 texels (0.5 texel/m)** with automatic bands of 1024/2048/4096 m. The code defaults are
   `surface_svt_page_world = 256` and `surface_svt_texels_per_meter = 1.0`
   (`terrain_3d_vt_state.h:751`, and `page_world = vt_page_size / texels_per_meter` in
   `terrain_3d_vt_service.cpp`), i.e. a **256 m page at 1 texel/m** and bands of
   512/1024/2048/4096 m.
2. `terrain_vt_and_streaming.md` section 4.7 (lines 451-516) still describes a staggered
   fade release. `terrain_3d_vt_fade.cpp` releases every armed queue entry in the same tick.
3. `vt_frame_budget.md` section "Strict residency policy (supersedes arrival/ancestor
   fallback above)" (lines 122-155) states that neighbour-availability coarsening and
   arrival-to-parent fading were removed. The current code has both and both default on:
   `vt_page_fade_frames = 12` (`terrain_3d_vt_state.h:702`), `svt_feedback = true`
   (`:525`), and `surface_svt_material_sample()` blends against the next resident level
   (`main.glsl:509-544`). That section is itself superseded now.

## 11. Open decisions

1. **H1's scope - answered in three steps.** Section 7.3 re-scoped it (a CPU-only footprint rule is the
   distance rule with a per-frame density offset, so H1 landed with H4 or not at all), and P5 has now
   closed H4's fragment form (section 7.7.5: no fragment-authored UAV in this renderer). So H1's
   **far-field** form is closed with it. Its **near-field** form was carried by P2 on the strength of
   P0e's reading that the level rule re-derives ground every generation; **section 7.7.7 measured that
   reading and it does not hold** - `plan_overlapped` is a parent-child tautology and per-owner depth
   never recedes (`avt_depth_down` 0-2 a generation). So the near field's level rule is already the
   stable footprint rule H1 asks for, and what is left of H1 here is not a level rule at all: it is the
   boundary's sensitivity to the discrete density terms (section 7.7.7's last paragraph). H1 is
   therefore **answered**: the footprint rule is in the near field already, and the far-field form is
   closed for a measured reason.
2. **H2's default - resolved.** The measurement is in (section 7.7.4): the per-unit guarantee pins 20
   -> 1 page and changes nothing that is drawn, and it does not cover the addressable domain. It stays
   a mode with the default 0, because the pyramid's "any world position resolves" property is what
   makes the region array unnecessary, and because `served` did not move. What is still open is the
   *other* reading of H2 - a fallback level tied to the unit's extent rather than to the grid's global
   cap - which needs the shader's coarser walk to find a pinned page at that level and is therefore
   the same work as H4. Closed as a default, open as H4's question.
3. **Whether the near field joins H1 in the same pass - resolved, and not in the way it was asked.**
   The near field is not "joining" H1; section 7.7.7 shows it already satisfies it, so there is no pass
   to join. The risk that made it its own phase is real but now attached to a narrower question (the
   boundary terms): `vt_turn_budget` and `vt_near_arrival` are sensitive and already partly red.
4. **Whether the screen-driven demand source is worth its cost - answered: not without a measurement
   that asks for it.** Section 7.7.5 re-scoped the seam's GPU strategy to `ScreenDrivenDemand`
   (`Terrain3DVTFeedback` on the main device, recorded through patch 2's per-frame hook, read back with
   `buffer_get_data_async`, driven by the screen instead of projecting every candidate) and confirmed the
   three capabilities it named. Its own addendum then closed it for the complementary reason: the hook
   hands the callback no frame context, and its FRP operation is documented as one that "must run before
   the G-buffer" (`render_frp_clustered.cpp:2191`), so the screen - the depth or GBuffer a screen-driven
   pass would read - is not reachable at the point the addon may record GPU work. Making it reachable is
   a third engine patch (pass the scene buffers to the update callables) plus a new screen-space demand
   subsystem. The residual difference from feng's working `Projected` source is *occlusion*, and the
   measured churn (sections 7.7.1, 7.7.7) is not occlusion-driven: `avt_missing` is
   `max(0, new addresses - ~50)` with the new addresses being laterally-new refined pages. So the
   enabling change is named and not taken; it is the one item that would need a new phase, and it needs a
   measurement to justify it first.
5. **The FC-style derivation chain, open and now scoped.** Section 7.7.15 lands the level count (as a
   residency setting, automatic by default) and the reading that says how much of a plan the fallback
   ladder is (`plan_level_mips`, `plan_world_pages`), and leaves the derivation itself unbuilt for the
   reason it states: it buys production and consistency, not residency, and it needs three things
   together - a baker job kind that reads the atlas's four child slots and writes the parent's staging
   layer, a `derive` mark on a page whose four children are in the same page set, and a finer-first
   production order within an owner, since `page_request_priority_before()` submits a parent before its
   child today. The first measurement that should precede it is `plan_level_mips` on a moving view: if
   the ladder is the ~25% the arithmetic bounds it to, the derivation's own saving is a quarter of the
   near field's production and the order change is what has to earn it.
