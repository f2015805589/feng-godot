# Delivery assembly: near/far tiers, channel groups, and one method per cell

**Read before changing how a surface channel reaches the shader, before adding a delivery
method, or before touching `surface_vt_enabled` / `surface_svt_enabled`.**

This is the plan and the decision record for replacing "two booleans that each mean one
whole tier" with a **delivery matrix**: a method chosen per (tier, channel group) cell,
from which the set of services, the array families, the shader variant and the tick are
*assembled*. The point is not the extra choice; it is that **nothing is built, uploaded,
bound or ticked unless some cell selected it.** A configuration that uses no clipmap must
cost exactly zero clipmap shader code, zero clipmap resources and zero clipmap CPU.

---

## 1. What is wrong with the current shape

Today the VT layer has exactly two knobs that decide the whole architecture:

* `surface_vt_enabled` - the near field, a sectored adaptive virtual texture (AVT).
* `surface_svt_enabled` - the far field, a world-space sparse virtual texture (SVT).

Three properties of that shape are the reason for this document:

1. **A knob describes a service, not a need.** `_setup_surface_vt()` and
   `_setup_surface_svt()` are called unconditionally from `Terrain3D::_initialize()`, so
   both view objects, their allocators, their indirection images and their per-view state
   exist whether or not anything samples them. Disabling one releases its content but not
   its object. Measured before this change: a node with both disabled still owns two
   `Terrain3DVirtualTexture` instances.
2. **The channel is implicit in the service.** One near-field page pool serves the
   control/id-weight payload (`_surface_vt_atlas`, R16) *and* the baked material arrays
   (`_surface_material_albedo` / `_normal` / `_params`); the terrain height
   (`_height_maps`, the region array) has no delivery choice at all. So "which tier
   delivers the height" is not expressible, and an option like "height by clipmap" has
   nowhere to live.
3. **A service decision and a shader decision live in different places.** The uniform
   gate (`_surface_vt_enabled` in the material) and the service gate (`_vt.surface_vt_enabled`
   in the planner, the capacity path, the tick) are the same field read by code that means
   different things by it. The moment a second group can select the same service, that
   field stops answering either question correctly.

## 2. The channel inventory

What actually reaches a fragment today, and what each thing is:

| Channel group | Payload | Where it lives now | Producer |
| --- | --- | --- | --- |
| **Material** (diffuse + normal + AO/roughness) | three arrays: albedo `RGBA8`(sRGB), normal, params | `_surface_material_albedo` / `_normal` / `_params`, addressed by the near field's or the far field's indirection | `Terrain3DSurfaceBaker`, from the `R16` control payload and the texture assets |
| | its input: control (id + weight) | `_surface_vt_atlas` / `_surface_svt_atlas` (`R16`) | region surface maps, resampled per page |
| **Height** (displacement, normals, holes) | `R32F` texel | `_height_maps`, the region texture array, and the clipmap ring the height arm samples | region height maps, and the height clipmap source |

The **Material** group is the user-facing "diffuse + normal" group; it carries the control
payload with it because the two are one page pool and one indirection - producing the
material for a page *is* producing its control texels. The **Height** group is the second
group, and it has exactly **two** choices: `Direct`, the region array, and the clipmap ring.
AVT and SVT are the material group's methods and are not the height channel's - there is no
height arm of that kind to write - so the matrix is deliberately asymmetric (section 3.1).

Three delivery methods exist or are planned:

* **Direct** - sample the source (the region texture arrays). This is "pure RVT" in the
  panel: a runtime-produced surface with no indirection at all. It is what the height
  channel does by default, and it is the only method that always works.
* **AVT** - the sectored adaptive virtual texture: region-local addressing, a per-sector
  virtual image, a page table with its own mip chain, a coarse owner for the fallback.
* **SVT** - the world-space sparse virtual texture: one global page grid, a distance
  level rule, a pinned root pyramid.
* **Clipmap** - *new*. A toroidal ring of power-of-two levels in one `Texture2DArray`
  (slice = level), snap-to-texel centre, incremental strip updates. No indirection, no
  allocator, no LRU: an address is arithmetic. See section 6.

## 3. The matrix

The setting is one method per cell of a 2x2:

| | Material (diffuse+normal) | Height |
| --- | --- | --- |
| **Near** | `vt_delivery_near_material` | `vt_delivery_near_height` |
| **Far** | `vt_delivery_far_material` | `vt_delivery_far_height` |

Each cell is `Direct` / `AVT` / `Clipmap` / `SVT`. The two tiers are distance bands around
the clipmap target; the near band's radius is the existing `surface_vt_distance` and the
far band's reach is the existing `surface_svt_distance`, so the matrix does not add a
distance concept, it adds a *choice* to the two that exist.

Defaults, and what each default preserves:

| Cell | Default | Why |
| --- | --- | --- |
| Near / Material | `AVT` | the shipped near field |
| Near / Height | `Direct` | the shipped height path; the matrix must be behaviour-preserving on first load |
| Far / Material | `SVT` | the shipped far field |
| Far / Height | `Direct` | the shipped height path, and it stays there: the height channel has no `SVT` arm and is not going to get one |

The target configuration is `Near/Height = Clipmap`, with `Far/Height` left on `Direct`. The
mechanism and the arm are in (M2b, section 8), so the flip is a change of one default decided on a
measurement (M3, section 8), not a step the mechanism still needs. There is no `Far/Height = SVT` to
flip: the height channel's choices are `Direct` and the ring, and the two height cells name the
*same* ring - a ring is one object per channel group, not per distance band - so either cell selecting
`Clipmap` is the whole of the choice, and the cell that names it is the band the ring serves in.

### 3.1 What a cell may name

A cell may only name a method this build can **deliver**, and the two groups do not have the
same choices. `Terrain3D::is_vt_delivery_supported(group, method)` is the one place that is
decided, `set_vt_delivery()` refuses the pair through it, and `get_vt_settings()` publishes the
answer as `delivery_supported` (the methods each group may name) and `delivery_unsupported`
(the sentence for each one it may not, which is also the setter's log line and the dock's
tooltip):

| Group | Methods this build accepts | Refused, and why |
| --- | --- | --- |
| Material (diffuse + normal) | `Direct`, `AVT`, `SVT` | `Clipmap`: no clipmap source carries that channel yet (M4) |
| Height | `Direct`, `Clipmap` | `AVT`, `SVT`: not this channel's methods at all - they page the material group |

The rule is a refusal at the one door every write goes through (the four properties, the two
legacy booleans, the dock and a script), not a warning over a cell that was stored anyway. The
alternative - take the cell and render from the region arrays - produces a configuration that
reads as working while the picture is the fallback, which is the state the refusal exists to
make impossible; section 9 records it as a rejected alternative. A refused write leaves the
cell exactly as it was, so a scene authored against a later build loads into the method it can
actually render and a panel that re-reads the cells shows the truth rather than the click.

The two editors cover different halves of that, and the difference is worth stating because only
one of them can be made dynamic:

* The Surface VT window's four rows disable the items this build cannot deliver and put the reason
  in their tooltip, from the published `delivery_supported` / `delivery_unsupported` - not from a
  list the panel keeps.
* The node's own Inspector renders the four cells as `PROPERTY_HINT_ENUM` dropdowns, whose hint
  string is static per property: a per-instance list is not expressible there without moving the
  properties into a `_get_property_list()` override. A method chosen there is therefore refused by
  the setter and the property reads back as the method the cell still holds, with the reason in the
  log - the refusal is the authority, and the greyed row is the part a widget can add.

The tier does not enter: the two bands select *reach*, not capability. `Direct` is always
deliverable, being the fallback and the one method that is always correct.

**Where the setting is read.** Both editors read the group in the order the layer assembles, and the
order is pinned by `vt_debug_views` and `editor_dock` from the registered property list rather than
from a screenshot:

| Order | Native subgroup | What it holds |
| --- | --- | --- |
| 1 | `VT Setting` | the delivery matrix first (the four cells), then the shared atlas settings |
| 2 | `Clipmap` | the ring's size, level count, base extent and production budget |
| 3 | `AVT` | `surface_vt_*`: the near view's own settings |
| 4 | `SVT` | `surface_svt_*`: the far view's own settings |
| 5 | `CDLOD` | geometry, not delivery |
| 6 | `VT Page` | the shared physical residency, and one debug view per VT method |

The delivery matrix is the *first thing inside* `VT Setting` rather than a subgroup of its own
because it is what the rest of the group configures: a method no cell selects owns no view, no
array family, no uniform and no shader arm, so nothing below it is built for a method no row names.
The Surface VT window's hierarchy reads in the same order, with the ring's debug view listed under
`VT Page` beside the physical residency it explains.

## 4. The assembly rule

The matrix is the **only** input to what exists, and it is only read after the acceptance rule
of section 3.1 has refused every pair this build cannot deliver. Resolution produces three
booleans and one family set:

```
avt_service     = any cell == AVT
svt_service     = any cell == SVT
clipmap_service = any cell == Clipmap
```

Rules, in the order they matter:

1. **A service object is created iff its boolean is set, lazily, and freed at teardown.**
   `_setup_surface_vt()` / `_setup_surface_svt()` move out of `_initialize()`'s unconditional
   block and behind `if (has_avt_delivery())` / `if (has_svt_delivery())`, so a terrain that
   never selects a method never builds one: measured, an all-`Direct` terrain owns no view,
   no pool, no material arrays, no VT uniform, no shader arm and no pass.
   A *deselection* stops the service rather than freeing it - its pass stops, its uniform gate
   closes, its shader arms leave the generated code, its coarse protections are released and
   its capacity stops being reserved; the object stays. That is a decision with three parts
   that are one: the object is also a **residency cache**, so freeing it would make a toggle
   cost a full re-stream (four recorded scenarios toggle and then measure continuity across
   it); the pool and the producer are **shared** between views (rule 6), so a cell cannot
   decide their lifetime; and never freeing a view at runtime means `_vt.surface_vt` cannot
   become null under code written when it never could - which is what the first attempt at
   "free on deselect" measured, at five suites.
2. **A family is published iff some group at that tier samples it.** The material family
   is produced only when a Material cell selects that service; the height family only when
   a Height cell does. A tier whose only user is the height group therefore does not
   allocate three `RGBA16F` material arrays.
3. **The shader variant follows the matrix.** `Terrain3DMaterial::_needs_vt_shader()` is
   `any cell != Direct`, and the generated code carries one `#define` per selected cell
   (`VT_NEAR_MATERIAL_AVT`, `VT_NEAR_HEIGHT_CLIPMAP`, ...). A method no cell selected
   contributes no code: not a uniform, not a branch, not a texture fetch. `TERRAIN_NO_VT`
   becomes the all-`Direct` case of the same mechanism rather than a separate special case.
4. **The tick follows the services.** `update_surface_vt()` is entered iff the AVT service
   exists; the far field's pass iff the SVT service exists; the clipmap's budgeted update
   iff the clipmap service exists. A matrix with one non-`Direct` cell in one tier runs one
   pass.
5. **A legacy boolean is a view of a cell, not a second source of truth.**
   `surface_vt_enabled` reads and writes `Near/Material`, `surface_svt_enabled` reads and
   writes `Far/Material`. Existing scripts and 100+ tests keep working; the panel writes
   the matrix.
6. **The shared service outlives a single view.** The page pool and the material producer
   are one service that both views sample, so it is configured whenever *one* view exists -
   not when both do. `_configure_vt_service()` required both, which made "only the far
   field is selected" mean "no pool and no producer", and the field that *was* selected
   then had no arrays to sample. The views are configured as the list of those that exist,
   and the pool is reachable from whichever one does (the tick's demand pool used to be
   read from the near view alone).

The invariant a test can assert, and the one `vt_delivery` does assert: *the set of live
services is exactly the set the matrix selects, and a matrix with no non-`Direct` cell has
no services, no VT uniforms, no VT shader code and no tick.*

## 5. Shader variants

`_generate_shader_code()` already ends in an `//INSERT:` table plus one prepended define.
The matrix keeps that shape and extends it to a block:

```glsl
#define VT_NEAR_MATERIAL_AVT
#define VT_FAR_MATERIAL_SVT
```

and the shader's sampling entry points become `#if defined(...)` per cell. The direct
sample of each group (region array) stays the `#else` arm, so an all-`Direct` matrix is the
current `TERRAIN_NO_VT` build with the same code, and a partially selected matrix is that
build with only the selected arms compiled in.

Two properties this buys, both verifiable without reading a frame time:

* **No cost when unused.** A method's uniforms, samplers and fetches are absent from the
  compiled shader, not branched around at runtime.
* **No interface drift.** `_active_params` and the material's uniform upload loop walk the
  generated code, so a variant cannot bind a uniform its own variant does not declare.

## 6. The clipmap service

The fourth method. It is deliberately the simplest of the four: no indirection texture, no
allocator, no LRU, no page table - an address is `(level, texel)`, and the whole service is a
ring of levels.

### 6.1 One mechanism, one source per channel

The ring is not a height feature. It is a *mechanism* - levels, snapping, the toroidal wrap,
the strips, the budget, the upload - and it carries whatever channel its source produces. The
split is two files:

| File | What it is | What it knows |
| --- | --- | --- |
| `terrain_3d_clipmap.{h,cpp}` | `Terrain3DClipmap`: the ring | levels, texel size, snapping, `physical = (logical + ring) mod size`, strip rects, the budget, the layered texture, the counters. No terrain, no channel, no data. |
| `terrain_3d_clipmap_source.h` | `Terrain3DClipmapSource`: what a texel holds | one row of one channel of one level, in *logical* indices, and the world XZ of logical texel (0, 0). |
| `terrain_3d_clipmap_source_height.{h,cpp}` | the height source | `Terrain3DData::get_height_texel_nearest()`. |

A second channel group on `Clipmap` is therefore a *source* and one line in
`Terrain3D::_setup_vt_clipmap()` - not a second ring, and not a channel test inside the ring.
The material channel's source does not exist yet (M4), so a material cell naming `Clipmap` is
refused (section 3.1) and no ring is built for it. The height cell is delivered by the ring: the
shader arm `height_at_uv()` samples it (section 6.4), so there are **two doors** to a ring - the
cell a user selects, and the mechanism's own entry `debug_update_vt_clipmap()`, which builds and
steps a ring while every cell is `Direct`. The ring's own suite (`vt_clipmap`) drives the second
one deliberately, with no cell selecting anything: the mechanism is exercised with no view, no
pool and no shader
arm in the picture.

The interface is asked per *row*, not per texel: a source's cost is its own lookup (region
resolution, page or cell fetch), so a row gives it locality without a virtual call in the
innermost loop, while the ring still decides where every value lands - a source never sees a
physical index.

### 6.2 Shape, centre, update

**Shape.** One `Texture2DArray`, `size x size` per level, one slice per level per channel
(slice `level * channels + channel`); one value a texel, so a level's layer format is the
value's format (`FORMAT_RF` for height, normalised `FORMAT_R8` for a channel that is one byte).
Level `l` covers `base_world * 2^l` metres in `size` texels, so its texel is
`base_world * 2^l / size` metres. The array is the *whole* storage: no second copy, no atlas.

**Centre.** Each level snaps its centre to its own texel size independently
(`floor(centre / texel_world) * texel_world`). Snapping is what makes a stationary camera write
nothing and a moving one write only the strips that moved; a centre that followed the camera's
float position would rewrite every level every frame and swim. The focus is
`get_clipmap_target_position()` - the same point the mesh clipmap and the streamer already follow.

**Update.** `delta_texel = round((new_snapped - old_snapped) / texel_world)` per level. Zero
means no work and the tick is counted as idle. `|delta| >= size` - or a level that has never
been filled, or one the budget left invalid - is regenerated whole. Otherwise only the newly
exposed strips are produced: `delta.x` columns of full height and `delta.y` rows of full width,
with the corner written twice (correct first, cheaper after). The content does not move: the
ring offset (`ring = (ring + delta) mod size`) moves instead, which makes the cost proportional
to the *edge* rather than to the area. A job's rect is a rect of *logical* texels, so every
level is advanced (centre and ring both) before its rect is produced - producing against the old
mapping is the one way to get a strip that looks right for a frame.

**Budget.** A strip is at most `2 * size * |delta|` texels, but a level that moved past its own
coverage is a full `size * size`, so production is queued as rect jobs and drained under
`vt_clipmap_budget_texels` per tick, charged in channel texels. Fills are queued coarsest first
(the fallback a coarser read depends on exists soonest) and strips finest first (the ground under
the camera is right first). A job the budget cut short keeps its resume point, so the level's
content is the same whether it drained in one tick or sixty-four; the budget is *not* part of the
page budget, because no ring touches the shared pool. A terrain with no ring owns no levels, no
texture, no jobs and no budget - **and the tick does not enter the phase**: no focus read, no group
scan, no phase timing, the same rule the two demand passes follow, so a method nobody selected costs
nothing rather than costing a check. Both halves of that are readings now rather than statements
about the code: the phase follows the *cell*, so the same focus move that produces strips under a
selected cell produces nothing at all under a deselected one, and the `group_uses(…, Clipmap)` check
inside it is exactly the branch that says so (the ring object stays - it is a residency cache - while
the phase skips it). `vt_clipmap_render` takes that reading as the same move twice, and asserts that
the mechanism's own entry still produces into the ring the tick left alone.

**Uploading.** `RenderingServer::texture_2d_update()` replaces a whole layer, so a drained level
is published as one layer update per channel: the CPU side is incremental and the transfer is
not. Both numbers are published (`produced_texels`, `upload_bytes`) so the second half is a
measurement rather than an assumption. A level the budget left invalid is *not* published and is
*not* valid, which is what tells a reader it still holds the level it replaces.

**Reading it back.** `Terrain3D::sample_vt_clipmap(group, world_xz)` reads the ring through its
own addressing - the same level rule, snapping and ring the shader arm samples with - so a
test or the dock can compare what the ring holds against the height map it was produced from.
`get_vt_settings().clipmap[group]` carries the shape, the counters and one report per level
(centre, ring, `valid`), which is what says a level is *current* rather than approximate.
`Terrain3D::get_vt_clipmap_arm(group)` is the same state in the form the arm is bound from - the
per-level centres, rings and validity, the level rule and the texture - padded to the shader's fixed
array size. It is one publish read by both the uniform binder and the tests, so the shader's copy of
the ring's addressing cannot drift from the CPU's.

**The mechanism's own entry.** `Terrain3D::debug_update_vt_clipmap(group)` is the second half of
that read-back surface, and it exists because the delivery claim and the mechanism can still come
apart: a configuration with every cell `Direct` has no way to reach a ring through the matrix, and a
ring nobody can drive is a mechanism nobody can measure. The entry builds the group's ring if it
does not exist, runs the phase the tick runs for it - the same `Terrain3DClipmap::update()`, the
same focus (`get_clipmap_target_position()`) and the same `vt_clipmap_budget_texels` - publishes
`clipmap_produced_texels` / `vt_clipmap_ms` exactly as that phase does, binds the arm's uniforms as
that phase does, and returns the texels produced (`-1` when the group has no source, which is the
material group). It is deliberately a *measurement* door rather than a second selection path:
nothing in the matrix learns about it, and the tick enters its clipmap phase only for a cell that
selected the method - so a tick reports zero clipmap texels while the entry reports the ones it
produced. `vt_delivery` asserts both halves of that in one block, and `vt_clipmap_render` asserts
the two halves of the phase's own cell check by making the same focus move with the cell selected
and deselected.

The ring's report keeps the two answers apart rather than collapsing them: `clipmap_service` and
`clipmap[group].selected` are the matrix's claim, `clipmap_ring` and `clipmap[group].configured`
are the object. They differ for a ring the entry built with no cell naming the method, which is the
state a reader has to be able to tell from "no ring at all".

**An edit is a rect, not a ring.** `Terrain3D::invalidate_vt_clipmap_area()` is called from the one
place every editor edit reports itself to (`Terrain3DData::add_edited_area()`), and it queues the
texels the changed area covers per level, against the centre and ring the level has at that moment.
Converting to logical indices then rather than at drain time is sound because the mapping cannot move
while the queue is not empty: `update()` re-derives a new focus's jobs only from an empty queue, so
every level's centre stands still until the rect (and whatever was queued before it) has drained. The
levels that touch the rect stop being `valid` immediately, which is what makes the reader's fallback
correct without waiting for the re-production - and it is why the arm's gate is `valid` and not a
diagnostic. `invalidation_calls` and `invalidated_texels` are published, so "an edit pays for the rect
it covers rather than for the ring" is a number: `vt_clipmap` reads `1` call and `16` texels for a
4x4 m rect on a 16 m level.

### 6.3 The debug views, and why they are gated

Each VT method that has a layout has one debug view, and each view is gated on the same matrix the
services are:

| View | Script | Where it is hosted | What it draws |
| --- | --- | --- | --- |
| AVT layout | `vt_avt_layout_preview.gd` | the Inspector's `VT Page` section | the sector grid, the tier of each sector, the coarse pages and the camera's near radius |
| Clipmap ring | `vt_clipmap_preview.gd` | the Inspector's `VT Page` section **and** the Surface VT window's `VT Page` view | the ring as blocks (below) |

Both are Controls that extend the same base script, `vt_layout_preview.gd`: the terrain they hold
weakly, the one boolean that says whether there is anything to draw, the poll interval, and the
`availability_changed` signal their host listens to. What is left in each is the half that differs -
the question the gate asks (`_gate()`), what a new terrain resets (`_reset_preview_state()`), and the
drawing. It is a base *script* rather than a helper object because `visible` has to have one owner: a
control that consulted a helper for its own visibility would have two. `asset_dock_common.gd` is the
same shape for the two dock versions, and the duplication audit (`audit_gd.py dupes`) is what caught
the copy this replaced.

**A preview with nothing behind it is refused, not answered with an empty drawing.** The native
side is where that is enforced - `get_avt_layout_preview()` returns an empty dictionary before it
scans the visible grid when `has_avt_delivery()` is false, and `get_clipmap_layout_preview()`
returns one before it walks a ring when `has_vt_clipmap_ring()` is false - and each Control asks
its own one-boolean gate first so it can hide itself (and the heading and note around it, through
`availability_changed`) instead of asking at all.

The two gates are deliberately not the same question, because the two views do not have the same
subject:

| View | Its gate | Why that one |
| --- | --- | --- |
| AVT layout | `is_vt_delivery_used(AVT)` | a cell is the only door to the AVT view, so the matrix's answer and the object's are the same answer |
| Clipmap ring | `has_vt_clipmap_ring()` | a ring can exist without a cell naming the method (a ring the mechanism's entry built, or one a deselection left behind), and a picture of a ring is a picture of the ring that is there rather than of the setting that asked for it |

A terrain that never selects `Clipmap` and never lets the entry build a ring therefore has no clipmap
view at all for a user, which is the requirement's own rule ("show nothing where nothing is used")
applied to the object rather than to the setting. Once the height cell selects the method the view is
reachable both ways, and `vt_debug_views` asserts both: the entry-built ring keeps the view up while
every cell is `Direct`, and a selected `Near/Height` cell reaches it through the panel.

Both halves are counted in `get_vt_settings()`:

| Key | Meaning |
| --- | --- |
| `avt_preview_calls` / `avt_preview_computed` | how many times the AVT layout was asked for, and how many of those asks scanned |
| `clipmap_preview_calls` / `clipmap_preview_computed` | the same for the ring's layout |

The two differ exactly when the gate refused, which is what makes "the debug view costs nothing while
it has nothing to draw" a reading rather than a claim: `vt_delivery` and `vt_debug_views` both drive
the Controls and assert that the call counter moves while the computed counter does not - and, for a
hidden view, that the call counter does not move either. The gate is asked in one boolean per poll
*even while the view is hidden*, because the thing it names can change while a section is folded (a
cell can be selected, a ring can be built); what waits for visibility is the expensive call, which is
the rule the AVT preview has always followed.

**The clipmap drawing is two panels, because one picture cannot answer both questions.** A ring's
coarsest level covers `2^levels` times what its finest does, so a single world map is either a dot at
the centre or a smear at the edges:

* **The level strip** is the clipmap assembled out of blocks: one square per level, each cut into the
  texel blocks it is addressed in (a 256-texel level draws 16-texel blocks, and the step is bounded so
  the grid stays readable), coloured by level and drawn solid only while the level is `valid`. The
  queued rects are painted *under* the grid, so a level with work outstanding is still visibly made of
  blocks.
* **The world map** is where those levels stand: the coarsest level's square is the view, each finer
  level a nested square on the focus it snapped to, and the rects still queued drawn translucently on
  top (a whole level - what a teleport costs - stays see-through, which is when the picture matters
  most). A level that is not `valid` is drawn faint: it holds the level it replaces.

The payload behind both panels is `get_vt_settings()`'s `clipmap[group]` plus `pending_rects`, which
`Terrain3DClipmap::get_layout_reports()` builds per level in world space. It is deliberately a second
method beside `get_level_reports()`: this one builds the rects, so only a caller that draws them pays
for them.

### 6.4 The height arm

The ring was measurable before anything sampled it, which is why the arm is a section of its own
rather than a line in the mechanism. What it does is route the height channel's reads through the
ring: `height_at_uv()` is the one entry every height read in `main.glsl` goes through - the vertex
stage's point read and its sub-texel read, and the eight taps the terrain normal is reconstructed
from - and the region array is the `#else` arm of every branch, so a configuration with no height
cell on `Clipmap` compiles the read it always had.

**The variant is a define, not a branch.** `TERRAIN_HEIGHT_CLIPMAP` is prepended to the generated
shader when the height group names the ring (and never together with `TERRAIN_NO_VT`, which a matrix
with no non-`Direct` cell still gets). So a height group delivered `Direct` in both bands has no ring
uniform, no ring sampler, no level search and no branch - not a cheaper path, an absent one - and a
material-only VT configuration does not pay for the height arm either. The material's variant choice
is therefore two booleans rather than one: the material arms and the height arm move independently,
and `Terrain3DMaterial::update()` rebuilds the code when either changed.

**What the arm reads, and why it is the CPU's own addressing.** `get_vt_clipmap_arm()` publishes the
per-level snapped centre, the toroidal offset, the validity flag, the level rule and the texture;
the shader computes `local = (world - centre + half) / texel`, takes `floor()` of it as the logical
texel and applies `physical = (logical + ring) mod size` - the same three steps
`Terrain3DClipmap::sample()` takes. Two things in that are deliberate:

* **Every tap is an explicit, clamped `texelFetch`, never a filtered sample.** The ring is toroidal:
  a tap outside a level would land on the far edge of the *same* level, which is a different world
  position. The bilinear the vertex stage needs is rebuilt from four clamped taps for the same reason
  the array path is point-sampled - its regions are separate layers.
* **A level's range is half-open.** `clipmap_contains()` is not `abs(point - centre) <= half`: that
  includes the far edge, which is one texel *past* the last stored one, and the clamped read would
  answer it with the edge texel - the height of a world position one texel away. `level_for_world()`
  and `_contains_level()` on the CPU were changed with it, so the two agree at the edge as well as
  inside (section 8.4).

**The gate is `valid` plus the band plus the coverage.** A ring that is mid-fill, mid-strip or
mid-invalidation still holds the level it replaces, so serving it would put an old height under a
fragment the array can answer correctly; the same is true of a point outside the coarsest level's
range. Both therefore fall back to the region array, which makes `valid` a *rendering* input here and
not a diagnostic - and it is what lets an edit be answered by the array for the two ticks the rect
takes to re-produce. The band the ring serves in is the two cells': `Near/Height = Clipmap` serves
the near band, `Far/Height = Clipmap` the far one, both in the same ring, with the transition blended
across `_avt_coverage_distance`'s own edge - the reach the material split next door already uses. The
band is measured *horizontally* in both stages, because the vertex stage is computing the vertical
distance.

**The normal's taps follow the source's texel.** `height_tap_scale()` is how far apart the eight
normal taps are, in height-grid units: 1 while the array serves, and the serving level's texel while
the ring does, so a coarse level is differenced at its own resolution instead of reading the same
stored value eight times. It is never below 1 - a level finer than the height grid is still read at
the grid's step - so a ring at the height grid's own density reproduces the array's normals exactly.

**A ring that moved is a uniform rebind, and only then.** The ring's addressing is per-level state
that moves every tick a level is produced into, so the node rebinds those uniforms when the ring's own
*state stamp* changed - the shape, any level's centre or ring, any level's validity - and not on a
tick that produced nothing. The rebind is the ring's own uniforms rather than the whole VT uniform
pass, which would republish every VT uniform and the region tables with them. This is also the bug
the first render reading caught: with the uniforms bound only when a *cell* changed, the shader read a
ring whose validity uniform still said "not current", so every render was the array's and the
pixel-identical result was a fallback agreeing with itself. Section 8.4 records it.

## 7. Compatibility

* The two legacy properties stay, as views of `Near/Material` and `Far/Material`.
* `get_vt_settings()` publishes the four cells, the three service booleans, the ring's existence
  (`clipmap_ring`) and the acceptance rule (`delivery_supported` / `delivery_unsupported`), so a
  test or the dock reads the decision rather than inferring it from a service's presence.
* Existing native tests that drive `set_surface_vt_enabled()` keep their meaning, because
  the near field's material group is the only thing that ever selected AVT in them.
* A scene that wrote a height cell on `AVT` or `SVT` now logs one warning and keeps the method it
  had. It renders exactly as it did before, because no build has ever had a height arm for either:
  the write was inert rather than effective, and the setting says so instead of the picture. A scene
  that wrote `Clipmap` for the height group in a build *before* the arm existed loads with the cell on
  `Direct` (that build refused it) and now loads with the ring - which is the whole point of the
  change, and it changes the picture: the height comes from the ring wherever the ring is current and
  inside its coverage, and from the region array everywhere else.
* The shipped defaults are unchanged by the arm: `Near/Height` and `Far/Height` are still `Direct`
  until M3's measurement flips the near one, so an existing scene renders exactly as it did unless it
  selects the method itself.
* The dock's `AVT runtime material` / `SVT persisted material` check boxes are replaced by
  the matrix rows; the properties they wrote remain.

## 8. Milestones and acceptance

| # | Content | Accepted when |
| --- | --- | --- |
| **M1** | the matrix, the assembly rule, the legacy views, the panel rows, the reporting, the shader gate | a matrix with no non-`Direct` cell has zero services, zero VT uniforms, no VT shader code and no tick; a single non-`Direct` cell creates exactly that one service; the defaults reproduce today's behaviour. **Landed.** Cell acceptance was added after M2: a method this build cannot deliver is refused at the setter, published per group, and greyed out in the dock, so a cell can never claim a method nothing samples. |
| **M2** | the clipmap service, height group first: array, ring, strips, budget, deterministic tests | a stationary camera writes nothing; a one-texel move writes one strip per level; every physical texel maps to its own world texel after a ring wrap; a camera sweep shows no seam and no crawl. **Ring landed and measured** (section 8.2): the mechanism, the height source, the settings, the reporting and the mechanism's own entry (`debug_update_vt_clipmap()`) are in, with `vt_clipmap` pinning the addressing, the strip cost, the budget and the content. The editor's debug views landed with it and follow a gate of their own - a ring that does not exist has no layout to draw and asking for one costs nothing (section 6.3), pinned by `vt_debug_views`. |
| **M2b** | the height arm: `height_at_uv()` through the ring, the cell that turns it on, edit invalidation, the sweep | the height cell is deliverable and selecting it compiles the arm; a ring at the height grid's own density renders pixel-identical to the array; a coarser ring does not; an edit re-produces the rect it covers and the array serves until it has. **Landed and measured** (section 8.4), with `vt_clipmap_render` the suite that takes those readings and `vt_delivery` / `vt_clipmap` / `vt_debug_views` updated for the cell that is no longer refused. |
| **M3** | `Near/Height = Clipmap` as a default | measured against M2b's `Direct` baseline: resident bytes, per-frame texels, and the height error at the near band's edge. `Far/Height` stays `Direct`: the height channel has no `SVT` arm to write. |
| **M4** | `Material` on clipmap, and the per-cell shader variants | the material group renders identically through the clipmap at a matched density, and an all-`Direct` build is byte-identical to `TERRAIN_NO_VT` |

### M1, as measured

`vt_delivery` runs a terrain whose four cells are written before it enters the tree, then a
live terrain it takes through every case. The readings it prints:

| Configuration | `avt_service` / `svt_service` / `clipmap_service` | view objects | shader arms | array needed |
| --- | --- | --- | --- | --- |
| never selected (all `Direct`) | false / false / false | none | false | true |
| default | true / true / false | both | true | true |
| all `Direct` at runtime | false / false / false | both (policy) | false | true |
| every undeliverable write refused | false / false / false | both (policy) | false | true |
| restored | true / true / false | both | true | true |

### The acceptance rule, as measured

`vt_delivery` block 3 writes the two pairs this build cannot deliver in one step
(`far/height = AVT`, `far/material = Clipmap`) and reads the cells back: both keep the method they
had, no service is selected, no ring is built and the generated shader carries no VT arm. The
published capability is the same reading from the other side:

| Key | Reading |
| --- | --- |
| `delivery_supported.material` | `[0, 1, 3]` - `Direct`, `AVT`, `SVT` |
| `delivery_supported.height` | `[0, 2]` - `Direct` and the ring |
| `delivery_unsupported.height.SVT` | "the height channel is delivered directly or by the clipmap ring; AVT and SVT page the diffuse+normal group" |
| `delivery_unsupported.material.Clipmap` | "no clipmap source carries the diffuse+normal channel in this build (M4)" |

The height cell that *is* deliverable is read on the same live terrain, because it is the one write
that reaches the shader: selecting it selects the clipmap service, builds the ring, compiles the VT
arms and reports the height arm; deselecting it takes the height arm back out of the generated code
while the ring object stays, being a residency cache as much as a renderer.

The dock reads the same two keys rather than keeping a list of its own: `vt_debug_views` asserts,
from the widgets a click would hit, that the height row keeps `Direct` and `Clipmap` and disables
`AVT` and `SVT`, that the diffuse+normal row disables only `Clipmap`, and that a disabled item
carries the sentence as its tooltip.

The mechanism stays reachable with every cell `Direct`, and that door is measured too: the entry
fills a 16-texel level whole (`256` texels) and publishes the same number as
`clipmap_produced_texels`, the ring it built reports `configured` true with `selected` false, and
`clipmap_ring` is true - while the material group's entry returns `-1`, because no source carries
that channel. The tick is the other half: this terrain ticks normally, and the tick after the entry
reports `0` clipmap texels, because it enters no clipmap phase for a method no cell selected. The
never-selected terrain reads the same way with nothing built at all: `configured=false`, no levels,
no texture, no jobs, `clipmap_produced_texels=0`, `sample_vt_clipmap()` `NAN`, and a preview that
refuses.

Three findings worth keeping, all from the two rounds of regression:

* **The shared service was owned by "both views exist".** Rule 6 of section 4; the failure
  it caused is the last entry of section 9.
* **Two readers assumed the near view always exists.** The page-arrival fade and
  `get_vt_pages()`; both are now "whichever view exists", and the second is what made a
  far-only view report an empty page list.
* **`vt_mip_bands`' floor assertion had an unsound guard.** It asserted the coarseness floor
  was raised when `svt_visible_pages > 2`, but the pass raises it when the visible set does
  not fit `capacity - roots` - and with automatic capacity on, the pool grows to fit.
  Measured on the phase that asks: pool 16, roots 8, 7 visible pages, so 7 <= 8 and a floor
  of 0 was *correct*; with automatic capacity off the same phase reads pool 8, roots 4, 7
  visible pages against 4 detail slots and a floor of 3. The test now fixes the capacity for
  that phase and asserts against `svt_detail_capacity`, which the pass publishes beside the
  floor because the two are one decision.

### M2, as measured

`vt_clipmap` drives one ring update at a time through the mechanism's entry
(`debug_update_vt_clipmap()`), on a one-level ring of 16 texels an axis covering 16 m, i.e. exactly
one texel a metre. **Every cell is `Direct` in this suite**, so the entry is the door it drives and
the run has no AVT view, no SVT view, no page pool and no shader arm in it: the readings below are
the mechanism, not a render. The entry runs the same `Terrain3DClipmap::update()` with the same focus
and the same budget the tick's clipmap phase runs, so each row below is the cost that phase would pay
for the same move.

| Step | `update_calls` | `produced_texels` | `full_productions` | `upload_bytes` | level |
| --- | --- | --- | --- | --- | --- |
| never selected (all `Direct`) | no ring at all | - | - | - | no levels, no texture |
| first tick | 1 | 256 | 1 | 1024 | valid, centre (8, 8), ring (0, 0) |
| 3 stationary ticks | +3 | +0 | +0 | +0 | valid, unchanged |
| one texel in x | +1 | +16 | +0 | +1024 | centre (9, 8), ring (1, 0) |
| one texel back | +1 | +16 | +0 | +1024 | centre (8, 8), ring (0, 0) |
| one texel diagonally | +1 | +32 | +0 | +1024 | centre (9, 9), ring (1, 1) |
| teleport past the coverage | +1 | +4 (budget 4) | +1 | +0 | invalid, 1 job pending |
| the same job drained | +63 | +256 | +0 | +1024 | valid again |
| 8 one-texel moves, then a full regeneration | +74 | +256 each way | +2 | +1024 each | identical content, 0 of 256 texels differ |
| a 4x4 m edit, then the rect drained | +2 | +16, +0 | +0 | +16 KB once | one job, 16 texels, level not current until drained |

What the numbers say, each one a published number rather than an assumption:

* **A stationary focus writes nothing.** Three ticks produce zero texels and upload zero bytes, and
  the three are counted as idle: the snap is what buys this, and it is the reason the ring stores
  rather than re-produces.
* **A one-texel move is one strip: 16 texels of CPU production** (one column of a 16-texel level), and
  a diagonal is 32 (both bands, with the corner texel written twice by design). The cost is the
  *edge*, not the area - 16 against 256 is the difference this method exists for.
* **The transfer does not follow the CPU side.** Every drained level uploads a whole layer: 1024 bytes
  here (16x16 RF), *including* the strip moves that produced 16 texels. The CPU side is incremental
  and `texture_2d_update()` is not; publishing both numbers is what keeps that from being an
  assumption. At the shipped shape (256 texels, level 0 = 256 KB) a 10 m/s focus at 60 Hz would ask
  for about 5 MB/s of whole-layer uploads for 1/16th as much production, which is the number M3 is
  meant to answer with a real configuration.
* **The budget is exact and the resume point is exact.** With `vt_clipmap_budget_texels = 4` on a
  full level, one tick produces exactly 4 texels and leaves one job pending; 63 further ticks produce
  exactly the remaining 252, the level goes valid once and is uploaded once (1024 bytes, not once a
  tick). A budget that cut a rect and a level that resumed it produce the same content as one tick
  with budget enough - asserted through the ring's own `sample()` at all 256 texel centres.
* **Content is the height map, texel for texel.** Every texel centre is read back through the ring's
  addressing and compared against `Terrain3DData.get_pixel()` at the same world position: worst error
  0.000000 after a full fill, after each wrap direction, and after a level built out of eight strips
  versus the same level rebuilt whole (0 of 256 texels differ). The wrap is the failure this pins:
  a world position derived from the *physical* index instead of undoing the ring would fail here and
  nowhere else.
* **An edit pays for the rect it covers.** A 4x4 m rect on a 16 m level queues one job and 16 texels,
  the level stops being current at once, and the budget's zero tick produces nothing - then the drain
  produces exactly those 16 texels and the level is current again with worst error 0.000000, the
  edited texel included. The counter is what makes "a rect, not a ring" a reading: a whole-level
  refresh would be 256.

**What the ring's own test caught, and what it cost.** Two defects were found by these readings and
fixed before the suite was accepted, and both are worth keeping because each is a class of mistake:
* **A rect was read as "the first row is partial".** `_produce_rect()` treated the job's `x0` as the
  resume point, so every row after the first started at column 0. A one-texel move is a *column* rect
  (`[15, 16) x [0, 16)`), so it produced 241 texels (1 in the first row, 16 in each of the other
  fifteen) instead of 16, and a diagonal produced 256 with one job left pending - the content was
  correct throughout, because the extra work was redundant. The production counts were what exposed
  it; `sample()` agreed with the height map the whole time. The fix separates the two: a `Job` is a
  rect, and where production stopped is a cursor (`cursor_y`, `cursor_channel`, `cursor_x`) inside it.
* **`valid` stayed true while a level had work queued.** A level was only cleared when it *drained*,
  so between a teleport and the budget that finishes it, the level reported itself current while
  holding the previous focus's content. `_rebuild_jobs()` now clears it the moment the work is queued,
  which is what the invariant in section 6.2 always said.

**The debug views, as measured.** `vt_debug_views` drives the three-level 64-texel ring above through
the Controls the editors host, and renders one of them:

| Step | Reading |
| --- | --- |
| order | `get_property_list()` subgroups are `VT Setting`, `Clipmap`, ``, `AVT`, `SVT`, `CDLOD`, `VT Page`; the Surface VT window's hierarchy is `VT Setting`, `Clipmap`, `AVT`, `SVT`, `CDLOD`, `VT Page`, with `Resident pages`, `Baked cell sources`, `Clipmap ring` under `VT Page` |
| the dock's delivery rows | the height row keeps `Direct` and `Clipmap` and disables `AVT` and `SVT`; the diffuse+normal row disables only `Clipmap`; each disabled item carries its reason as the tooltip |
| no ring exists | the view reports unavailable, hides itself, and `clipmap_preview_calls` does not move: a hidden view does not even ask |
| the entry builds a ring | the view appears on the same poll, `calls` +1, `computed` +1, and the payload carries one ring of three levels |
| a teleport with no budget | the level is invalid and its one queued rect is the whole level (64 m) |
| a four-texel move with no budget | the queued rect is one column, 4 m x 64 m - a strip, not a level |
| a selected `Near/Height` cell | the cell takes `Clipmap`, so the panel reaches the view as well as the entry; the poll that follows does its work and the ring the entry built is kept |
| the render | 14 424 of 184 800 pixels painted, 1 138 of them the queued strips' own colour, 6 428 in the level strip and 7 996 in the world map: both panels are drawn, and the strips are drawn in the colour only they use |

The render is kept as `user://vt_clipmap_debug_view.png` in the fixture. Two drawing decisions came
out of looking at it rather than out of the code: the queued rects go **under** the block grid (a
solid fill drawn last hid the blocks the picture is of), and the world map draws them translucently
(a teleport queues a whole level, which as an opaque fill covered every nested square in the map).

**The verification run.** `scons platform=windows target=template_debug` reports the DLL,
`audit_code.py` reports no findings this step added, and `run_all.py --driver d3d12` is **57 of
73** - the 72 suites the milestone above ran plus `vt_debug_views`, which is new and green. Every
suite verified green before this step is still green (`vt_delivery`, `vt_clipmap`, `vt_mip_bands`,
`vt_cap_probe`, `vt_page_fade`, `vt_lifetime`, `vt_material`, `vt_fallback`, `vt_perf`, `vt_cells`,
`vt_demand`, `vt_svt_coverage`, `vt_anisotropy`, `vt_adaptive:cdlod` and the rest). The failures are
the same names the milestone above recorded, and none of them is new or names the matrix, the ring or
either debug view. (`audit_gd.py` is run in full in the next step's verification, and its `dupes` mode
found the copy recorded there: the claim "no new findings" in this line was made from the C++ audits
and the script audit's other modes.)

* `vt_visibility`, `vt_transition_parent` - page allocation and the missing-page diagnostic in the
  manual demand paths. Deterministic, and unchanged by the phase gate below.
* `vt_adaptive` in eight modes (`scale`, `metric`, `ownership`, `filtering`, `navigation`, `rotation`,
  `blend`, `sectors`) - the automatic-mip/pixel family. `ownership` was already recorded as
  un-triaged pre-existing, reproduced byte for byte with the previous step's change reverted.
* `vt_turn_budget` - per-phase *millisecond* thresholds on a debug template, missed by factors from
  1.6x to 4.5x and moving between runs (0.146-0.190 ms for the same warm turn). The clipmap phase was
  entered unconditionally in the first version of this step; gating it on `has_clipmap_delivery()`
  (section 6.2) removed the only cost this step added to a clipmap-free tick, and the suite still
  misses the same thresholds - so the numbers are the machine, not this method.
* `editor_dock:dock` (a synthetic mouse event missing a dock button at its screen position) and
  `editor_dock:setup` (`Add Region` not expanding with the background disabled) - editor UI geometry.
  The dock assertions this step added are in the same function, after that click, so they are pinned
  by `vt_debug_views` instead: it drives the Surface VT window directly, which is why the window's
  order, its Clipmap panel and its VT Page view are asserted where they can actually run.
* `texture_compression` - texture codecs, no VT involvement.
* `vt_near_arrival` and `vt_strict_coverage` exit before running under `run_all.py`: both take
  arguments (a project directory) that the aggregate runner does not supply.

**What the debug views' step caught.** Two defects, both found by driving the editors rather than by
reading them - and the second is the one the requirement is about:

* **The far-field band table asked a view that need not exist.** `vt_editor_svt_bands.gd` reached
  `get_world_max_mip()` through `get_surface_svt()`, which is null whenever no cell selects `SVT` -
  a configuration the matrix makes ordinary (all-`Direct`, or `Clipmap` on the far material group).
  Every refresh of the panel logged a script error and derived the table from nothing. The view is
  now asked only when it exists, and without one the configured ceiling is the number.
* **A debug view that started visible.** `_set_available(false)` returned early when the state was
  already "unavailable", so a Control whose initial state *was* unavailable never hid itself: the
  first poll of an unselected method left an empty view on screen. `visible` is now synced on every
  call, and `set_terrain()` answers the gate once so a host never sees the view before the first
  poll. `vt_debug_views` asserts both halves.

**The acceptance rule's verification run.** The same commands, on the final tree, with the sweep run
twice. `scons platform=windows target=template_debug` reports the DLL; `audit_code.py` (`dead`,
`undefined`, `sections`, `comments`, `params`, `indent`, `shape`, `dupes`, `structure`) reports the
same pre-existing entries as the milestone above and nothing new; `audit_gd.py` is clean in every mode
(the `dupes` entry above is the one it found and this step fixed). `run_all.py --driver d3d12` is
**57 of 73** and then **56 of 73** on the same tree, and the difference between the two runs is one
suite: `vt_idle_cost`, a per-tick *millisecond* threshold suite, which passed in the first sweep,
failed in the second (near 0.0690 / far 0.1232 / section 0.2156 ms against 0.050 / 0.080 / 0.150), and
then passed alone (20.2 s) and failed alone (near 0.0551 ms against 0.050). It is the same
machine-sensitive family as `vt_turn_budget`, and nothing in this step is on its path: the guard is a
write-time predicate, the mechanism's entry is called by a test, and the tick's clipmap branch is
unchanged (`has_clipmap_delivery()`, false on every tick in this build). The other 15 failures are the
names the milestone above recorded, and `vt_clipmap`, `vt_delivery` and `vt_debug_views` are green in
both sweeps.

**What the acceptance rule's step caught.** Three things, each from a reading rather than from
reading the code:

* **The duplicated preview plumbing.** `audit_gd.py dupes` reported `_set_available` and
  `_get_terrain` written twice - once in each layout preview - which is the copy the previous step
  made when the clipmap view landed beside the AVT one, and it is the same finding the two dock
  versions produced (`asset_dock_common.gd`). Both now come from one base script,
  `vt_layout_preview.gd`: it owns the weak terrain reference, the availability boolean, the
  `availability_changed` signal and the poll interval, while each preview keeps the question its gate
  asks (`_gate()`) and what a new terrain resets (`_reset_preview_state()`) - the half that differs.
  The audit is clean in that mode now.
* **A test that assumed an empty job queue.** Driving the ring through the mechanism's entry instead
  of through the tick exposed it. `vt_debug_views` builds the ring, teleports with the budget at zero
  and asserts a whole-level rect, then drains and moves four metres to assert a strip. The build's own
  fill was still queued when the teleport happened, and `Terrain3DClipmap::update()` deliberately
  re-derives jobs only from an empty queue - a partially produced level must not be discarded - so the
  teleport was never described and the four-metre move was measured against the build's focus: a jump
  past the level's coverage, i.e. a whole level. The suite now drains the ring in the same entry call
  that builds it, and nothing in the ring changed.
* **A counter with two writers.** The entry publishes `clipmap_produced_texels` for the group it ran,
  and the tick's clipmap branch *clears* that counter when no cell selects the method. Both are
  correct and they interleave: on a terrain that ticks normally the number is the entry's until the
  next tick and zero afterwards. `vt_delivery` asserts both halves in one block, because the
  alternative - publishing into a field a later phase rewrites - is the kind of reading that looks
  like a defect in whichever half a reader happens to see first.

### M2b, as measured

`vt_clipmap_render` is the arm's suite, and every claim in section 6.4 is one of its readings. The
scene is a 64 m region of a non-linear height profile, a focus at its centre, and an orthographic
camera whose visible square (53 m x 40 m at this window's aspect) is inside the ring's own coverage.
The material group stays `Direct` in every render, so the only difference between two images is the
height group's source.

| Step | Reading |
| --- | --- |
| all cells `Direct` | the generated code is the no-VT arm: no `_avt_coverage_distance`, no `_clipmap_atlas`, no `_clipmap_level_valid`, and `vt_shader_height_clipmap` false |
| `Near/Height = Clipmap` | the VT arms are in the compiled code, including the ring's sampler, its gate and the band edge; `vt_shader_height_clipmap` true; the tick's own phase produced into the ring before the entry was asked |
| settled at 64 texels / 64 m (one texel a metre) | the level is current, nothing queued, and the render is **pixel-identical** to the array's: 0 of 76 800 pixels differ |
| the same ring at 256 m base (four metres a texel) | the render differs in a large fraction of the frame: the pixel-identical result above is the ring's render, not a fallback agreeing with itself |
| 32 texels / 32 m (±16 m coverage) | the view reaches past the ring's coverage, and the render is still pixel-identical: outside a level's range the array serves |
| an editor height stroke, budget 0 | one invalidation, 256 texels queued (the brush's own area), the level not current, nothing produced, the ring still holding the pre-stroke height - and the picture already the edited one |
| the rect drained | exactly the queued texels produced, the ring holding the edited height, and the render pixel-identical to the array's |
| deselecting, then a focus move | the arm leaves the code and the render returns to the array; the *same* move produces nothing while deselected (no phase entered) and the mechanism's entry still steps the ring it kept |

**What the arm's step caught.** Three defects, and the first two are only visible in a render:

* **The uniforms were bound on a cell change, not on the ring's state.** The shader read a ring whose
  `valid` uniform still said "not current" from the moment the cell was selected - so the *array*
  served every fragment, and the first pixel-identical result was a fallback agreeing with itself.
  The suite's third check (a coarser ring must change the render) is what exposed it: 0 pixels
  differed where a different ring had to show. The node now rebinds the ring's uniforms when the
  ring's own state stamp changes, which is one integer comparison per ring per tick (section 6.4).
* **An inclusive coverage test disagrees with a clamped read at a level's far edge.** With
  `abs(point - centre) <= half` the point exactly on the edge was "inside", but `floor()` of it is
  exactly `size` - one texel past the last stored one - so the clamped read answered it with the edge
  texel, i.e. with the height of a world position one metre away. Measured: a 5 m band at the
  coverage edge, 4 269 pixels. `_contains_level()` and `clipmap_contains()` now test the half-open
  texel range on both sides, which is exactly the set of texels the level stores.
* **A function guarded out of the variant that calls it.** `height_tap_scale()` was declared inside
  `#ifdef TERRAIN_HEIGHT_CLIPMAP` while the fragment stage called it unconditionally, so the no-VT
  variant failed to compile - caught immediately, but it is the class of mistake a generated shader
  invites: the *call* and the *definition* have to be guarded by the same condition. It is now a
  function with an `#else` arm returning 1.

**The arm's verification run.** `scons platform=windows target=template_debug` reports the DLL, and
the four suites the change touches were run individually before the sweep: `vt_clipmap_render`,
`vt_clipmap`, `vt_delivery` and `vt_debug_views`, all green with no `ERROR:` line. `vt_clipmap`'s own
readings are unchanged by the arm - it drives the mechanism with every cell `Direct`, which is exactly
what the entry exists for - and the new invalidation block adds one row to the table above. The
acceptance the plan set for the sweep is a full `run_all.py --driver d3d12` on the final tree, whose
summary is recorded at the end of this section.

## 9. Rejected alternatives
* **A cell that is stored and published as inert.** The alternative to section 3.1's refusal is to
  accept the write, build whatever can be built, and publish "selected, but nothing samples this"
  (`clipmap_service` true, `clipmap[group].selected` true, a note in the panel, the mechanism's entry
  as the only producer). It was the shape M2 landed with, and it is honest in the report - but the
  setting still reads as a working configuration to anyone who does not open the report, and the
  height cell's ring *does* cost real CPU and a whole-layer upload per drained level while the picture
  is byte-for-byte the fallback. The requirement is stated the other way around ("a method nothing uses
  must not produce a shader branch, CPU/GPU cost or allocation"), and a cell nobody may write is the
  strongest form of it. What the refusal costs is measurable and small: the ring loses its matrix door
  and keeps `debug_update_vt_clipmap()`, so `vt_clipmap`'s addressing, strip and budget readings are
  the same numbers with one call site changed.
* **An `SVT` (or `AVT`) arm for the height channel.** The plan's original M3 target was
  `Near/Height = Clipmap`, `Far/Height = SVT`, which would have needed a height arm for the far
  field as well. The channel does not have one and is not going to: the height payload is a single
  `R32F` texel per metre (`_height_maps`, or a ring level), which a world-space page grid adds an
  indirection, an LRU and a bake to without adding a level rule it does not already have, and the
  height group's two real choices - the region array when the data is already resident, the ring when
  the address should be arithmetic - cover both ends. `Far/Height` therefore stays `Direct`, and the
  acceptance table refuses the pair with that sentence rather than with "not implemented yet".
* **A debug view that polls the preview anyway and hides the result.** The first shape of the clipmap
  view asked `get_clipmap_layout_preview()` on its timer and drew nothing when the answer came back
  empty. That is the cost the requirement names, paid by a view for a method nobody selected: the ring
  payload walks every level and builds the queued rects, and the AVT preview scans the visible grid and
  builds a record per sector. The gate is now both halves - the native preview refuses *before* its
  scan (`get_clipmap_layout_preview()` returns an empty dictionary while no ring exists,
  `get_avt_layout_preview()` on `!has_avt_delivery()`), and the Clipmap Control asks
  `has_vt_clipmap_ring()` (the AVT one asks `is_vt_delivery_used(AVT)`) first so the refused call is
  never made. `vt_delivery` and `vt_debug_views` read the difference from `*_preview_calls` against
  `*_preview_computed` rather than trusting it, and assert that a hidden view does not even ask.
* **The delivery matrix as a subgroup above the settings.** That is the shape this landed with first,
  and it read in *build* order rather than assembly order: `Delivery`, `Clipmap`, `VT Setting` put the
  choice and the ring's shape above the settings that configure them, and the Surface VT window listed
  `AVT`/`SVT` with no `Clipmap` node at all. The matrix is now the first thing inside `VT Setting`, the
  ring's shape follows it, and both editors read `VT Setting`, `Clipmap`, `AVT`, `SVT`, `CDLOD`,
  `VT Page`; the order is pinned from the registered property list by `vt_debug_views` and
  `editor_dock`, not by a screenshot.
* **A clipmap class that carries one channel.** The first shape of this milestone was
  `Terrain3DHeightClipmap`: the ring, the addressing and the budget with "read the height map" written
  into its producer and `Terrain3DData` as a parameter to its update. It made the height channel work
  and nothing else: a second channel group selecting `Clipmap` would have been a second copy of the
  levels, the snap, the strips and the budget, and the ring's own addressing tests would have needed a
  terrain and a channel to exist. The split that replaced it - `Terrain3DClipmap` as the mechanism,
  `Terrain3DClipmapSource` as what a texel holds, one source per channel - is section 6.1, and the
  test that proves the seam is `vt_clipmap` configuring no channel at all.
* **One boolean per channel group instead of one method per cell.** A bool cannot express
  *which* method and makes "AVT near, SVT far" - the shipped configuration - two booleans
  that must be kept consistent by hand.
* **Keeping the unconditional `_setup_*()` and only gating the passes.** That is what the
  addon does today, and it is exactly the cost the requirement names: the objects, their
  images and their state exist with no user.
* **A clipmap with a mip-chained slice per level.** The ring already provides the spatial
  LOD; a per-slice chain would have to be regenerated wholesale (`generate_mipmaps()` on a
  region-written array) and would destroy the incrementality that is the method's whole
  advantage.
* **Moving the array content instead of the ring offset.** Copying a ring is
  `size * size` texels per snap where the ring is `2 * size * delta`; the copy is what the
  ring exists to avoid.
* **Freeing a view when its last cell is deselected.** Implemented first and withdrawn on
  measurements in two rounds, because each round exposed a different cost of it:
  * Round one, shared service owned by "both views exist": a far-only configuration reported
    *"SVT material arrays were not created"* and failed six `vt_fallback` checks;
    `vt_material` died with an access violation; `vt_root_coverage`, `vt_avt_dense` and
    `vt_mip_bands` failed. Five suites, one cause, fixed by rule 6.
  * Round two, with rule 6 in place: `vt_avt_dense` went green, and the remaining failures
    were the *other* half of the same coupling - one crash and two reporting failures from
    code that reads `_vt.surface_vt`, `_vt.surface_svt` or the shared slot owners without a
    null check, which was safe only while a node always had both views. Fixed: the capacity
    growth, the page-arrival fade and `get_vt_pages()` now ask whichever view exists.
  * What settled it is not the diff size but the trade: freeing a view releases every page
    it holds, so a toggle costs a full re-stream, while the pool and the producer **cannot**
    follow a cell's lifetime at all. Rule 1 of section 4 is the resulting policy -
    selection-driven *creation*, service *stop* on deselect, freeing at teardown - and it
    keeps the requirement the section exists for (a method never selected is never built)
    without either cost.
* **Reporting pages from the near view only.** `get_vt_pages()` skipped every record when
  `_vt.surface_vt` was null, which was invisible while both views always existed. The owners
  of a slot are recorded by the shared pool, so the view to ask is whichever one exists; the
  near field is the only part that needs the near view, because it is the only one that
  records a non-world-space owner.
* **A filtered sample of the ring.** The arm's first shape read the ring with a linear sampler, which
  is what a `Texture2DArray` invites and what the array path's explicit bilinear exists to avoid. It
  cannot work here: the ring is toroidal, so a tap outside a level lands on the *far edge of the same
  level* - a different world position - and the bilinear the vertex stage needs has to be rebuilt from
  four clamped taps instead. The same reason makes the array path's region reads point samples.
* **An inclusive coverage test.** `abs(point - centre) <= half` is the obvious way to ask whether a
  level contains a point, and it is wrong at exactly one texel: the far edge is `floor() == size`,
  which is one past the last stored texel, so a clamped read answers it with the height of a world
  position one texel away. Measured as a 5 m band at a level's edge (4 269 pixels); the rule is now
  the half-open texel range on both the CPU and the shader (section 8.4).
* **Rebinding the whole VT uniform set on a ring change.** The first fix for the stale-uniform defect
  called `Terrain3DMaterial::update(REGION_ARRAYS)`, which is the established "something changed"
  path - and which also republishes every VT uniform and the region tables (a 1024-entry
  `PackedVector2Array` at the shipped `max_regions`) on a tick the camera merely walked. The ring's
  state stamp plus a rebind of the ring's own nine uniforms does the same job without the rest, and
  costs one comparison per ring on a tick that changed nothing.
* **A whole-ring refresh on an edit.** The alternative to `invalidate_rect()` is to invalidate every
  level and let the next update re-fill them: correct, and `size * size * levels` texels plus a
  whole-layer upload per level for a brush stroke that touched one region. The rect mechanism converts
  the edit's area against the level's *current* centre and ring, which is sound because the mapping
  cannot move while a job is queued, and it is measurable: 16 texels for a 4x4 m rect against 256 for
  the level it sits in.
* **Flipping `Near/Height` to `Clipmap` in the same step as the arm.** The arm makes the method
  usable; the default decides what every scene renders without asking, and it is a different kind of
  decision: it needs the resident bytes, the per-frame texels and the height error at the near band's
  edge measured against the `Direct` baseline (M3). Landing the arm without the flip also keeps the
  step's own acceptance clean - two renders that must be identical are compared with the only
  difference being the cell under test, not a changed world default.
