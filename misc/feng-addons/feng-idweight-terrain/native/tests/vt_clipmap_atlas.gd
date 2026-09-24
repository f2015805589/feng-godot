# Run with a graphical rendering driver; see README.md in this directory.
#
# The clipmap *atlas* implementation's regression. The clipmap is now **one delivery** with an
# implementation selector (`vt_clipmap_implementation`, `Atlas = 1`), so this drives the mechanism the
# way `vt_clipmap.gd` drives the LOD ring - through the layer's one entry, `debug_update_vt_clipmap()`,
# with every delivery cell `Direct` and the implementation set to `Atlas` - so what it measures is the
# structure rather than a rendering.
#
# What it asserts, one reading each:
#  1. **the structure**: every unit is a 3x3 arrangement of its own nine blocks (the header's
#     "9 a unit"), so `9 * units` blocks and `9 * units` cells in a grid three cells an axis, one spare
#     a unit and one global block (the structure changed from the old 9/16/24/32 ring ladder);
#  2. **the layout**: all three packing schemes (`shelf`, `ring_bands`, `quadtree`) are evaluated and
#     published, the default chosen one is the quadtree, and its bounding box, area and efficiency are
#     the layout's own;
#  3. **the upload unit**: the first fill publishes exactly one block rect a channel per frame and its
#     byte count is the sum of the blocks' own bytes - not one byte of atlas-wide transfer;
#  4. **rolling**: a move inside a block produces *nothing* (the phase turns and the content does not
#     move), and a move of exactly one block relabels the units it crosses - some cells keep the
#     content they had and only the blocks that entered are loaded;
#  5. **no gap**: at every frame of a fill or a relabel a cell is either serving a block or waiting
#     for one, and never neither, which is what the spare slot buys;
#  6. **the one-time global block**: it is produced once and never again.
extends SceneTree

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
# The implementation selector inside the one `Clipmap` delivery: `LOD = 0`, `Atlas = 1`.
const LOD := 0
const ATLAS := 1

const BLOCK_SIZE := 64
# `vt_clipmap_levels` is the layer's unit count for both implementations (LOD levels / atlas units).
const UNITS := 4
const BASE_WORLD := 64.0
const GLOBAL_TEXELS := 16

var terrain: Terrain3D
var camera: Camera3D
var scene: Node3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func settings() -> Dictionary:
	return terrain.get_vt_settings()

# The material group's entry. What only the selected implementation can say - the atlas's rect array,
# cell table and rolling counters - is nested under `layout`, which is now the implementation payload.
func group() -> Dictionary:
	return settings().get("clipmap", {}).get("material", {})

func impl_of(p_group: Dictionary) -> Dictionary:
	return p_group.get("layout", {})

func impl() -> Dictionary:
	return impl_of(group())

func layout_of(p_impl: Dictionary) -> Dictionary:
	return p_impl.get("layout", {})

func layout() -> Dictionary:
	return layout_of(impl())

func cell_table(p_impl: Dictionary) -> Array:
	return layout_of(p_impl).get("cells", [])

func count_current(p_impl: Dictionary) -> int:
	var count := 0
	for value: Variant in cell_table(p_impl):
		count += 1 if bool((value as Dictionary).get("current", false)) else 0
	return count

func count_pending_cells(p_impl: Dictionary) -> int:
	var count := 0
	for value: Variant in cell_table(p_impl):
		count += 1 if int((value as Dictionary).get("pending_slot", -1)) >= 0 else 0
	return count

# What the spare slot buys: every cell is either serving the block it wants or waiting for one.
func count_serving_or_loading(p_impl: Dictionary) -> int:
	var count := 0
	for value: Variant in cell_table(p_impl):
		var cell: Dictionary = value
		if bool(cell.get("current", false)) or int(cell.get("pending_slot", -1)) >= 0:
			count += 1
	return count

func ring_origins(p_impl: Dictionary) -> Array:
	var result: Array = []
	for value: Variant in p_impl.get("ring_reports", []):
		var report: Dictionary = value
		if int(report.get("ring", -1)) < 0 or int(report.get("ring", -1)) >= UNITS:
			continue
		result.append(report.get("origin", Vector2.ZERO))
	return result

func row(label: String, extra: String = "") -> void:
	var entry := group()
	var payload := impl()
	print("VT_CLIPMAP_ATLAS %s current=%d pending=%d jobs=%d uploads=%d bytes=%d scrolls=%d loaded=%d retained=%d %s" % [
			label, count_current(payload), count_pending_cells(payload),
			int(entry.get("pending_jobs", 0)), int(payload.get("block_uploads", 0)),
			int(entry.get("upload_bytes", 0)), int(payload.get("scroll_events", 0)),
			int(payload.get("blocks_loaded", 0)), int(payload.get("blocks_retained", 0)), extra])

func tick() -> int:
	return terrain.debug_update_vt_clipmap(MATERIAL)

func setup() -> void:
	root.name = "ClipmapAtlasProbe"
	scene = Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 20.0, 20.0)
	camera.current = true
	root.add_child(camera)
	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_size = BLOCK_SIZE
	terrain.vt_clipmap_base_world = BASE_WORLD
	# `vt_clipmap_levels` is the unit count; the atlas clamps it to MAX_RINGS = 12 (the ladder needs 11).
	terrain.vt_clipmap_levels = UNITS
	terrain.vt_clipmap_global_texels = GLOBAL_TEXELS
	terrain.vt_clipmap_blocks_per_frame = 1
	terrain.vt_clipmap_implementation = ATLAS
	terrain.assets = Terrain3DAssets.new()
	var asset := Terrain3DTextureAsset.new()
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.7, 0.2, 0.2))
	asset.albedo_texture = ImageTexture.create_from_image(image)
	asset.normal_texture = ImageTexture.create_from_image(image)
	terrain.assets.set_texture_asset(0, asset)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	for z in range(-1, 2):
		for x in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(x, z), false)
	terrain.data.update_maps()
	await process_frame

func run() -> void:
	await setup()
	var built := tick()
	require(built >= 0, "the material group builds an atlas")
	var entry := group()
	require(bool(entry.get("configured", false)), "the atlas is configured")
	require(str(impl().get("storage", "")) == "packed_block_atlas",
			"and reports the packed block atlas storage, got %s" % str(impl().get("storage", "")))

	# 1. The structure. Every unit is a 3x3 arrangement of its own blocks; the old 9/16/24/32 ladder
	# is gone with the old uniform grid.
	var report: Dictionary = layout()
	var total_cells := 9 * UNITS
	require(int(report.get("blocks", 0)) == total_cells,
			"%d blocks over %d units, got %d" % [total_cells, UNITS, int(report.get("blocks", 0))])
	var counts: Array = report.get("ring_blocks", [])
	require(counts.size() == UNITS, "%d units report a block count, got %d" % [UNITS, counts.size()])
	for value: Variant in counts:
		require(int(value) == 9, "every unit is 9 blocks, got %s" % str(counts))
	require(int(report.get("grid_side", 0)) == 3,
			"the grid is 3 cells an axis, got %d" % int(report.get("grid_side", 0)))
	# 9*UNITS cells, one spare a unit, one global block.
	require(int(report.get("total_blocks", 0)) == total_cells + UNITS + 1,
			"%d rects (%d + %d spares + 1 global), got %d" % [
				total_cells + UNITS + 1, total_cells, UNITS, int(report.get("total_blocks", 0))])
	require(cell_table(impl()).size() == total_cells,
			"%d cells, got %d" % [total_cells, cell_table(impl()).size()])

	# 2. The layout: all three schemes evaluated and published, the quadtree chosen. The structure
	# changed, so the old "chosen is the smaller of two" no longer holds: the quadtree is the form
	# requirement and the report publishes every scheme's cost beside it.
	var schemes: Array = report.get("schemes", [])
	require(schemes.size() == 3, "three packing schemes are evaluated, got %d" % schemes.size())
	require(str(report.get("chosen", "")) == "quadtree",
			"the default chosen scheme is the quadtree, got %s" % str(report.get("chosen", "?")))
	var chosen_scheme: Dictionary = {}
	for value: Variant in schemes:
		var scheme: Dictionary = value
		require(int(scheme.get("width", 0)) > 0 and int(scheme.get("height", 0)) > 0,
				"every scheme has a bounding box")
		require(int(scheme.get("area", 0)) == int(scheme.get("width", 0)) * int(scheme.get("height", 0)),
				"every scheme's area is its bounding box")
		require(float(scheme.get("efficiency", 0.0)) > 0.0, "every scheme has a packing efficiency")
		if bool(scheme.get("chosen", false)):
			chosen_scheme = scheme
	require(not chosen_scheme.is_empty(), "exactly one scheme is chosen")
	if not chosen_scheme.is_empty():
		require(int(chosen_scheme.get("area", 0)) == int(report.get("area", 0)),
				"the chosen scheme's area is the layout's")
		require(int(chosen_scheme.get("width", 0)) == int(report.get("width", 0)) \
				and int(chosen_scheme.get("height", 0)) == int(report.get("height", 0)),
				"and its bounding box is the layout's")
	require(float(report.get("efficiency", 0.0)) > 0.5,
			"the chosen layout is more than half packed, got %.3f" % float(report.get("efficiency", 0.0)))
	require(int(report.get("lower_bound_area", 0)) <= int(report.get("area", 0)),
			"the bounding box is not below the blocks' own area")
	print("VT_CLIPMAP_ATLAS_LAYOUT width=%d height=%d area=%d packed=%d lower_bound=%d efficiency=%.4f chosen=%s schemes=%s" % [
			int(report.get("width", 0)), int(report.get("height", 0)), int(report.get("area", 0)),
			int(report.get("packed_texels", 0)), int(report.get("lower_bound_area", 0)),
			float(report.get("efficiency", 0.0)), str(report.get("chosen", "?")), str(schemes)])

	# 3. The first fill: one block a frame, and the bytes are the blocks' own.
	var channels := int(entry.get("channels", 2))
	var previous_uploads := int(impl().get("block_uploads", 0))
	var previous_bytes := int(entry.get("upload_bytes", 0))
	var produced_frames := 0
	var monotonic := true
	var serving_identity := true
	while count_current(impl()) < total_cells and produced_frames < 400:
		var before_current := count_current(impl())
		var made := tick()
		var now := impl()
		produced_frames += 1
		var uploads := int(now.get("block_uploads", 0))
		# One block, one rect a channel: the unit is the block and not the atlas.
		if made > 0 and uploads - previous_uploads != channels:
			require(false, "a produced block publishes exactly one rect a channel: made %d, uploads %d -> %d" % [
					made, previous_uploads, uploads])
		previous_uploads = uploads
		previous_bytes = int(group().get("upload_bytes", 0))
		if count_current(now) < before_current:
			monotonic = false
		# 5. No gap: every cell is serving or loading, at every frame.
		if count_serving_or_loading(now) != total_cells:
			serving_identity = false
	row("first_fill", "frames=%d uploads=%d bytes=%d" % [produced_frames, previous_uploads, previous_bytes])
	require(count_current(impl()) == total_cells, "every cell serves a block after the first fill")
	require(int(group().get("pending_jobs", 0)) == 0, "no block is left queued after the first fill")
	require(monotonic, "a cell never stops serving a block during the first fill")
	require(serving_identity, "at every frame every cell is either serving or loading a block")
	# The byte count is the blocks' own: every unit is nine `block_size` squares now (the old
	# decreasing ladder is gone), plus the global block, times the channels and the four bytes a value.
	var block_texels := 9 * UNITS * BLOCK_SIZE * BLOCK_SIZE
	var expected_bytes := (block_texels + GLOBAL_TEXELS * GLOBAL_TEXELS) * channels * 4
	require(previous_bytes == expected_bytes,
			"the first fill uploads exactly the blocks' bytes (%d), got %d" % [expected_bytes, previous_bytes])
	require(previous_uploads == (total_cells + 1) * channels,
			"one rect a channel per block, %d expected, got %d" % [(total_cells + 1) * channels, previous_uploads])

	# 6. The global block is produced once: an update with nothing to do adds nothing.
	var idle_made := tick()
	require(idle_made == 0, "an update with nothing to do produces nothing, got %d" % idle_made)
	require(int(impl().get("block_uploads", 0)) == previous_uploads, "and publishes no rect")

	# 4. A phase turn: a move inside a block changes the offset and loads nothing.
	var texel := BASE_WORLD / float(BLOCK_SIZE)
	camera.position = Vector3(camera.position.x + texel * 2.0, camera.position.y, camera.position.z)
	var phase_made := tick()
	var after_phase := group()
	var phase_impl := impl_of(after_phase)
	require(phase_made == 0, "a move inside a block loads nothing, got %d" % phase_made)
	require(int(phase_impl.get("scroll_events", 0)) == 0, "a move inside a block is not a grid step")
	var scrolls_before := int(phase_impl.get("scroll_events", 0))
	var uploads_before := int(phase_impl.get("block_uploads", 0))
	var origins_before := ring_origins(phase_impl)

	# 4b. A whole block: the units it crosses relabel. Some cells keep their content and only what
	# entered loads. The entered blocks are placed as slots free up, so the count is read after the
	# drain - which is exactly the per-frame bound the mechanism claims.
	camera.position = Vector3(camera.position.x + BASE_WORLD, camera.position.y, camera.position.z)
	var relabel_made := tick()
	var after_relabel := group()
	var relabel_impl := impl_of(after_relabel)
	require(int(relabel_impl.get("scroll_events", 0)) == scrolls_before + 1,
			"a whole-block move is one grid step")
	require(int(relabel_impl.get("block_uploads", 0)) > uploads_before,
			"the entered blocks are published as their own rects")
	var origins_after := ring_origins(relabel_impl)
	var relabelled := 0
	for index in mini(origins_before.size(), origins_after.size()):
		if origins_before[index] != origins_after[index]:
			relabelled += 1
	require(relabelled > 0, "a whole-block move relabels at least the finest unit")
	# Drain and confirm the grid is whole again.
	var drain := 0
	while int(group().get("pending_jobs", 0)) > 0 and drain < 400:
		tick()
		drain += 1
	var drained := group()
	var drained_impl := impl_of(drained)
	var loaded := int(drained_impl.get("last_scroll_loaded", 0))
	var retained := int(drained_impl.get("last_scroll_retained", 0))
	print("VT_CLIPMAP_ATLAS relabel made=%d drain=%d loaded=%d retained=%d relabelled=%d cells=%d" % [
			relabel_made, drain, loaded, retained, relabelled, cell_table(drained_impl).size()])
	# The units the move crossed either entered or kept their block; a unit the move did not cross is
	# untouched and is not part of the count, which is the change the per-unit structure brought.
	require(loaded + retained == 9 * relabelled,
			"every cell of a relabelled unit either entered or kept its block: %d + %d over %d units" % [
				loaded, retained, relabelled])
	require(retained > 0, "a scroll keeps the content of the cells that did not move, got %d" % retained)
	require(loaded > 0, "a scroll loads the blocks that entered, got %d" % loaded)
	require(loaded < 9 * relabelled, "a scroll does not reload a unit, got %d of %d" % [loaded, 9 * relabelled])
	require(count_current(drained_impl) == total_cells, "every cell serves a block again after the drain")
	require(count_pending_cells(drained_impl) == 0, "nothing is left loading")
	row("after_scroll", "drain=%d" % drain)

	# The layout payload the debug view draws has a rect a slot and a cell a cell. It is the layer's
	# `impl` entry from `get_clipmap_layout_preview()`, replacing `get_clipmap_atlas_layout()`.
	var preview := terrain.get_clipmap_layout_preview()
	var layers: Array = preview.get("layers", [])
	var layer: Dictionary = {}
	for value: Variant in layers:
		if str((value as Dictionary).get("group", "")) == "material":
			layer = value
	require(not layer.is_empty(), "the preview publishes the material layer")
	var debug_layout: Dictionary = layer.get("impl", {})
	require(not debug_layout.is_empty(), "the atlas publishes a debug layout")
	var debug_report: Dictionary = debug_layout.get("layout", {})
	var rects: Array = debug_report.get("rects", [])
	var cells: Array = debug_report.get("cells", [])
	var rect_total := int(debug_report.get("total_blocks", 0))
	require(rects.size() == rect_total, "the rect array has one entry a slot: %d vs %d" % [rects.size(), rect_total])
	require(rects.size() == total_cells + UNITS + 1,
			"the rect array has %d entries, got %d" % [total_cells + UNITS + 1, rects.size()])
	require(cells.size() == total_cells, "the cell table has %d entries, got %d" % [total_cells, cells.size()])
	var spares := 0
	var globals := 0
	for value: Variant in rects:
		var item: Dictionary = value
		spares += 1 if bool(item.get("spare", false)) else 0
		globals += 1 if bool(item.get("global", false)) else 0
	require(spares == UNITS, "one spare a unit, got %d" % spares)
	require(globals == 1, "one global block, got %d" % globals)

	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		terrain.set_editor(null)
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	if failed:
		print("REGRESSION: clipmap atlas")
		quit(1)
		return
	print("PASS clipmap atlas")
	quit(0)
