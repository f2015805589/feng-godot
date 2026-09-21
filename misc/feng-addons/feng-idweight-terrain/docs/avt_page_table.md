# AVT page table layout

Sector AVT (`surface_vt_selection_mode = 2`) uses a fixed 64 m world sector
grid around the editor or runtime camera. The world grid is independent of the
virtual image resolution allocated to each sector. A sector can therefore keep
the same 64 m `rect` while its virtual image and allocation block change with
projected screen density.

`surface_vt_mip_levels` controls the number of virtual resolution tiers. The
default three tiers are:

| tier | sector virtual image | maximum density |
| ---: | ---: | ---: |
| 0 | 64k x 64k | 1024 texels/m |
| 1 | 32k x 32k | 512 texels/m |
| 2 | 16k x 16k | 256 texels/m |

With ten tiers, the sequence continues through 2 texels per metre and a
128 x 128 sector image. Each sector chooses one tier from projected density,
which naturally decreases with distance. Explicit `surface_vt_mip_distances`
can override that distance selection. The setting counts these sector image
tiers; it does not truncate a sector's local page-table mip chain.

The visible sector candidates are prioritized from the camera view and its
projected density. The native bounded plan may retain up to eight nearby
invisible sectors as a turn or short backtrack buffer; this buffer is finite
and does not make every sector in the radius a high-resolution allocation. The
coarse fallback remains a dense ring around the camera so a fast turn has a
ready base while visible sectors refine.

Every virtual allocation has its own block size. The complete local chain has
`log2(block_size) + 1` levels, from the block's finest page to its whole-block
fallback. This chain is present independently of the configured resolution
tier count. A cold sector may have no allocated block yet, and a resident
sector may still be serving a fallback page while production catches up; the
resolution tier count is a layout choice, not a promise that every tier is
resident at startup.

The native preview reports `resolution_levels` as the available tier
descriptions. Each entry contains `level`, `resolution`, `texels_per_meter`,
and `block_size`. It reports `sectors` as fixed-world records with `rect`,
`level`, `resolution`, `block_size`, `logical_pages`, `visible`, and
`allocated`. An allocated record may also contain `allocation_rect`, which is
the actual page-table allocation in page-entry texel coordinates. That
rectangle must not be interpreted as a change to the 64 m world sector.

The independent coarse tier has its own budget and density. Coarse residency
is drawn separately from the colored 64 m sectors. Reducing coarse density or
coarse residency does not change the sector grid or the available fine
resolution tiers. Under pressure, a sector can fall back to a ready page; that
is a residency result, not a change to its selected virtual image definition.

`surface_vt_distance`, default **384 metres**, is the horizontal radius of the
whole AVT. Fine sectors and the coarse base are planned inside that radius.
Sampling outside the radius uses SVT. Storage rectangles can pad the circular
boundary, but that padding does not extend AVT shading into the outside region.

The shared physical pool limits coarse residency and the allocations that fine
sectors can receive. With **Automatic cache capacity** enabled (the default),
the pool may grow toward its native 1024-page ceiling to meet visible demand;
disabling that setting keeps the configured page count fixed. Camera movement
changes the bounded world window and replaces pages that leave it; it does not
allocate an unbounded image.

## Inspector preview

The Terrain3D Inspector's VT Page foldout contains a texture-free AVT preview
above **Open VT Page overview**. It calls
`get_avt_layout_preview(camera)` while visible and follows the editor camera
even when editor live-material preview pauses production.

The map draws the fixed 64 m world sectors with colors for their selected
resolution tier. Solid outlines indicate allocated sector blocks; dim outlines
show visible or proposed sectors without a current allocation. Coarse page
rectangles use a separate color family. A small inset shows one differently
sized square for every available virtual resolution tier; those squares are a
screen-space comparison of image resolutions and are not world cells.

When the native preview provides `camera_forward`, the map draws a heading
arrow from the camera marker. A missing horizontal heading is left blank so a
top-down camera does not receive a fabricated direction. The map view is
centered on the camera's AVT radius with a small SVT border; padded coarse
storage bounds do not shrink the near-field view.

The footer distinguishes the number of resolution tiers from the complete
local page-chain length. It also reports fine maximum density, independent
coarse density, allocation counts, the AVT radius, and the SVT area outside
that radius. It does not claim that all tiers are resident during cold start.

Previewing allocates no VT pages, reads no textures, and starts no bake.
