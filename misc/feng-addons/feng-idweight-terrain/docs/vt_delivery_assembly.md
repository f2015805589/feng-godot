# Delivery assembly

A four-cell matrix selects how each surface channel reaches the shader. The same
selection controls service creation, scheduled work, resource families and shader variants.
The [architecture guide](vt_architecture_review.md) defines shared ownership;
[addressing and streaming](terrain_vt_and_streaming.md) defines paged delivery.

## 1. Channels and methods

| Cell | Default | Supported methods |
| --- | --- | --- |
| `vt_delivery_near_material` | AVT | Direct, AVT, Clipmap, SVT |
| `vt_delivery_far_material` | SVT | Direct, AVT, Clipmap, SVT |
| `vt_delivery_near_height` | Direct | Direct, Clipmap |
| `vt_delivery_far_height` | Direct | Direct, Clipmap |

Material means diffuse, normal and AO/roughness, evaluated from the R16 surface payload
and texture assets. Height means RF geometry height, used for displacement and normals.
Near/far select distance bands; support is a channel capability independent of the band.
The stored method values are stable: Direct 0, AVT 1, Clipmap 2, SVT 3.

`set_vt_delivery()` validates every write, including the four properties and legacy
booleans. Unsupported writes preserve the prior cell and report the reason.
`is_vt_delivery_supported()` and `delivery_supported` / `delivery_unsupported` provide
the same capability answer to scripts and the editor. Clipmap capability comes from the
channel-source registry, so it is available before a terrain's data resource is assigned.

`surface_vt_enabled` writes Near/Material as AVT or Direct; `surface_svt_enabled` writes
Far/Material as SVT or Direct. They are compatibility views of the matrix. The editor order
is VT Setting (matrix first), Clipmap, AVT, SVT, CDLOD, VT Page.

## 2. Service lifetime

`_resolve_vt_delivery()` applies the complete selection:

- Create a view/layer when first selected; an all-Direct terrain starts without VT services
- Stop deselected work and remove its shader arms/bindings; retain reusable cache objects
  until teardown and release reservations no longer needed by a selected field
- Configure the shared pool/producer for the views that exist, including AVT-only and SVT-only
- Allocate one Clipmap layer per selected channel group; near/far share that group's layer
- Create material bake resources for a material Clipmap even when neither paged field is selected
- Run only selected services. Re-enabling delivery on an initialized terrain enables its tick

Shader generation compiles only the selected channel/method arms. All-Direct uses the
direct source path. Custom shader overrides keep their declared interface. A cached but
stopped layer is distinct from an active service; reports expose both.

## 3. Clipmap storage interface

Clipmap is one delivery with two interchangeable storage implementations:

| Module | Contract |
| --- | --- |
| `terrain_3d_clipmap_common.h` | Implementation values, shape, density ladder, bake-rect identity and report schema |
| `terrain_3d_clipmap_impl.h` | Storage-independent update, sample, invalidation and publication interface |
| `terrain_3d_clipmap_layer*` | Owns the selected implementation and channel-source factory |
| `terrain_3d_clipmap*` | LOD: toroidal levels, strips and layer publication |
| `terrain_3d_clipmap_atlas*` | Atlas: nested block packing, rolling replacement and rect upload |
| `terrain_3d_clipmap_source*` | Channel payload, row production and baked output formats |

`vt_clipmap_implementation` chooses LOD (0, default) or Atlas (1). Switching replaces
storage through the layer owner. Both use
`unit_world_size = base_world * 2^unit` and `texel_world = unit_world_size / size`.
The shader and producer retain their storage-specific address/descriptor operations.

Height sources provide RF values. Material sources provide packed IDs and height inputs,
plus three canonical RGBA16F baked channels. Source methods produce logical rows; storage
owns physical placement. A new channel requires a source, its shader sampling arm and
capability/report tests, rather than another copy of the ring mechanism.

## 4. Quality profiles and saved resources

`vt_clipmap_quality` chooses the resolved shapes below. `clipmap_target` supplies focus.

| Quality | Group | Texels/axis | Units | Base extent | Finest → coarsest density |
| --- | --- | ---: | ---: | ---: | ---: |
| Standard | Material | 256 | 11 | 0.25 m | 1024 → 1 texel/m |
| Standard | Height | 128 | 7 | 2 m | 64 → 1 texel/m |
| Performance | Material | 128 | 11 | 0.5 m | 256 → 0.25 texel/m |
| Performance | Height | 64 | 9 | 1 m | 64 → 0.25 texel/m |

Performance lowers ring storage while retaining the material detail cache's 1024 texel/m
target. Neither profile changes channel meaning or turns a missing material sample into
Direct evaluation. The internal production budget is 65,536 channel texels per tick.
Atlas defaults use a 64-texel global block, one block per update, spare slots and quadtree packing.

Former global/group shape, budget, atlas and detail properties remain hidden storage aliases
for saved scenes. Non-default legacy values continue to apply. Selecting a Quality profile,
including the already-selected profile, clears global/group shape and Atlas layout overrides.
Legacy budget/detail overrides remain active; their callable setters can restore defaults.
Save the scene after migration.

Read `get_vt_settings().clipmap[group].resolved_shape` for effective profile/legacy settings.
`configured`, `units`, `unit_reports`, textures and queued jobs describe allocated runtime
state. An unallocated group reports `units = -1` while still describing its resolved shape.

## 5. Incremental updates and publication

LOD levels snap independently to their texel grid. Physical addressing is
`(logical + ring) mod size`; moving the origin changes offsets and produces newly exposed
strips. A teleport or first fill regenerates the level. Jobs resume under the channel-texel
budget, with coarse fills before fine fills and fine moving strips first. An edit queues its
intersecting logical rectangles. A stationary, unchanged layer produces nothing.

LOD source transfer publishes a completed whole layer even when CPU work was a strip.
Atlas transfer uses block rectangles. Compare `produced_texels` with `upload_bytes` when
measuring the two implementations. Frame scheduling and worker publication preserve job
identity; pending work cannot publish under a newer shape or source generation.

Material baking uses the shared surface producer and the layer's own output textures.
It consumes produced rectangles in stored coordinates, preserving untouched texels as the
ring rolls. Queued bake rectangles carry shape/content leases; only matching completion
acknowledges them. An outdated completion leaves current work pending. Offers have a
channel-texel budget and allow at least one rectangle so a full-level job can progress.
Source uploads reach the renderer before the dependent bake dispatch.

Outstanding source/bake rectangles are published to the shader. Readiness is checked for
the fragment's taps, allowing unaffected parts of a moving level to remain usable. If the
fixed table cannot express all outstanding rectangles, it conservatively marks the whole
unit unavailable. Material asset changes invalidate baked results while retaining unchanged
source payloads. Texture/configuration bindings and moving address state have separate
stamps; an address-only move updates only its own uniforms.

## 6. Sampling and near material detail

Height sampling uses half-open coverage and clamped explicit texel reads. Bilinear vertex
sampling reconstructs its four taps so a toroidal wrap cannot read the opposite world edge.
Normal reconstruction uses the serving level's texel step, at least the source height-grid
step. Invalid/out-of-range height coverage uses the direct height source.

Material sampling reads baked channels, including their canonical normal decode. Missing
detail tries coarser ready detail/layer coverage; if no selected material layer can answer,
the shader displays a missing-VT diagnostic. The source evaluator serves explicit Direct
regions rather than concealing a selected Clipmap miss. The near/far edge uses the existing
AVT reach and outer-quarter transition band.

The material detail cache accompanies Clipmap selection by default. It widens high density
beyond the finest ring's small footprint and owns independent arrays, directory and work:

| Setting | Default |
| --- | --- |
| Density ladder | 1024 / 512 / 256 / 128 texels/m |
| Tile / directory | 256 texels / 128×128 entries |
| GPU budget | 512 MiB |
| Demand radius | 12 m |
| Target footprint | 4 texels/pixel |

Screen demand is fitted to available slots, with overlap at level boundaries. Ready-directory
entries publish only completed current-generation tiles. Disabling detail allocates no detail
resources; ring/atlas coverage remains. A density target describes requested/resident detail,
not a promise that every visible point always reaches the maximum during movement.
`sample_vt_detail()` mirrors shader lookup for point-wise coverage checks.

## 7. Editor and diagnostic access

AVT and Clipmap previews inherit polling/weak ownership from `vt_layout_preview.gd`.
AVT gates on selected AVT delivery; Clipmap gates on an existing layer, including a stopped
cache or a diagnostic-created layer. Hidden/unavailable controls skip expensive scans.
`*_preview_calls` and `*_preview_computed` distinguish queries from actual layout work.

The Clipmap preview shows a per-unit strip plus a world map, including queued regions and
validity. `get_vt_clipmap_arm()` publishes the sampling state; `sample_vt_clipmap()` reads
it through the same address contract. `debug_update_vt_clipmap(group)` explicitly creates
and advances a layer without changing delivery selection, useful for mechanism-only tests.
`clipmap_service` / `selected` describe selection; `clipmap_layer` / `configured` describe objects.

## 8. Verification and recorded evidence

From the repository root:

```sh
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_delivery_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_render_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_debug_views_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_density_runner.py --driver d3d12 --resolution 1920x1080
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_clipmap_sharpness_runner.py --driver d3d12
```

Coverage includes refused cells, lazy allocation, deselection/reselection, isolated Clipmap
baking, source/height/material images, strip preservation, moving bake leases, edits,
profile migration, debug gating and point-wise near-detail density. The
[test guide](../native/tests/README.md) explains fixture setup and acceptance limits.

Historical implementation measurements, retained as context rather than a current pass:

- A 16² one-level fixture filled 256 texels; budget 4 drained in 64 ticks with 1024 upload bytes
- A 4×4 edit invalidated 16 source texels; a one-column material bake on a 64² level used
  192 channel texels versus 12,288 for the whole level
- Matched-density material images differed by mean 0.0018 with 3/76,800 visibly different
  pixels at a shadow edge; these were fixture tolerances, not universal pixel identity
- Rect-scoped bake identity accepted moving work where level-wide identity repeatedly rejected it

The [2026-09-23 pre-fix baseline](../native/tests/baselines/clipmap-material-baseline-2026-09-23.md)
records the former standalone-bake, density and material-invalidation gaps with binaries/logs.
Run the current suites to establish the status of later code.
