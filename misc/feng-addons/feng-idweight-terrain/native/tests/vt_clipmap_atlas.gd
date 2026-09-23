# Run with a graphical rendering driver; see README.md in this directory.
#
# The clipmap *atlas* mechanism's regression. It drives the mechanism the way `vt_clipmap.gd` drives
# the ring - through the mechanism's own entry, `debug_update_vt_clipmap_atlas()`, with every delivery
# cell `Direct` - so what it measures is the structure rather than a rendering.
#
# What it asserts, one reading each:
#  1. **the structure**: four rings of 9, 16, 24 and 32 blocks (the user's `(2n+1)*4-4 = 8n` plus the
#     first ring's centre), 81 blocks in a 9x9 grid, one spare a ring and one global block, so 86
#     rects in the atlas;
#  2. **the layout**: the two packing schemes are both evaluated and both published, the chosen one's
#     bounding area is the smaller of the two, and it is within the reported efficiency of the area
#     the blocks actually need;
#  3. **the upload unit**: the first fill publishes exactly one block rect a channel per frame and its
#     byte count is the sum of the blocks' own bytes - not one byte of atlas-wide transfer;
#  4. **rolling**: a move inside a block produces *nothing* (the phase turns and the content does not
#     move), and a move of exactly one block relabels the grid - some cells keep the content they had
#     and only the blocks that entered are loaded;
#  5. **no gap**: at every frame of a fill or a relabel a cell is either serving a block or waiting
#     for one, and never neither, which is what the spare slot buys;
#  6. **the one-time global block**: it is produced once and never again.
extends SceneTree

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2

const BLOCK_SIZE := 64
const RINGS := 4
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

func atlas() -> Dictionary:
	return settings().get("clipmap_atlas", {}).get("material", {})

func row(label: String, extra: String = "") -> void:
	var entry := atlas()
	print("VT_CLIPMAP_ATLAS %s current=%d pending=%d jobs=%d uploads=%d bytes=%d scrolls=%d loaded=%d retained=%d %s" % [
			label, int(entry.get("current_cells", 0)), int(entry.get("pending_cells", 0)),
			int(entry.get("pending_jobs", 0)), int(entry.get("block_uploads", 0)),
			int(entry.get("upload_bytes", 0)), int(entry.get("scroll_events", 0)),
			int(entry.get("blocks_loaded", 0)), int(entry.get("blocks_retained", 0)), extra])

func tick() -> int:
	return terrain.debug_update_vt_clipmap_atlas(MATERIAL)

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
	terrain.vt_clipmap_atlas_rings = RINGS
	terrain.vt_clipmap_atlas_global_texels = GLOBAL_TEXELS
	terrain.vt_clipmap_atlas_blocks_per_frame = 1
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
	var entry := atlas()
	require(bool(entry.get("configured", false)), "the atlas is configured")

	# 1. The structure.
	var layout: Dictionary = entry.get("layout", {})
	require(int(layout.get("blocks", 0)) == 81, "81 blocks over four rings, got %d" % int(layout.get("blocks", 0)))
	var counts: Array = layout.get("ring_blocks", [])
	require(counts.size() == 4 and int(counts[0]) == 9 and int(counts[1]) == 16 and int(counts[2]) == 24 and int(counts[3]) == 32,
			"ring block counts are 9/16/24/32, got %s" % str(counts))
	require(int(layout.get("grid_side", 0)) == 9, "the grid is 9 cells an axis, got %d" % int(layout.get("grid_side", 0)))
	# 81 cells, one spare a ring, one global block.
	require(int(layout.get("total_blocks", 0)) == 86, "86 rects (81 + 4 spares + 1 global), got %d" % int(layout.get("total_blocks", 0)))
	require(int(entry.get("cells", 0)) == 81, "81 cells, got %d" % int(entry.get("cells", 0)))

	# 2. The layout: both schemes evaluated, the chosen one the smaller of the two.
	var schemes: Array = layout.get("schemes", [])
	require(schemes.size() == 2, "two packing schemes are evaluated, got %d" % schemes.size())
	if schemes.size() == 2:
		var first: Dictionary = schemes[0]
		var second: Dictionary = schemes[1]
		require(int(first.get("area", 0)) > 0 and int(second.get("area", 0)) > 0, "both schemes have an area")
		var smallest := mini(int(first.get("area", 0)), int(second.get("area", 0)))
		require(int(layout.get("area", 0)) <= smallest, "the chosen layout is the smaller of the two")
		require(float(layout.get("efficiency", 0.0)) > 0.5,
				"the chosen layout is more than half packed, got %.3f" % float(layout.get("efficiency", 0.0)))
		require(int(layout.get("lower_bound_area", 0)) <= int(layout.get("area", 0)),
				"the bounding box is not below the blocks' own area")
	print("VT_CLIPMAP_ATLAS_LAYOUT width=%d height=%d area=%d packed=%d lower_bound=%d efficiency=%.4f chosen=%s schemes=%s" % [
			int(layout.get("width", 0)), int(layout.get("height", 0)), int(layout.get("area", 0)),
			int(layout.get("packed_texels", 0)), int(layout.get("lower_bound_area", 0)),
			float(layout.get("efficiency", 0.0)), str(layout.get("chosen", "?")), str(schemes)])

	# 3. The first fill: one block a frame, and the bytes are the blocks' own.
	var channels := int(entry.get("channels", 2))
	var previous_uploads := int(entry.get("block_uploads", 0))
	var previous_bytes := int(entry.get("upload_bytes", 0))
	var produced_frames := 0
	var monotonic := true
	var serving_identity := true
	while int(atlas().get("current_cells", 0)) < 81 and produced_frames < 400:
		var before_current := int(atlas().get("current_cells", 0))
		var made := tick()
		var now := atlas()
		produced_frames += 1
		var uploads := int(now.get("block_uploads", 0))
		# One block, one rect a channel: the unit is the block and not the atlas.
		if made > 0 and uploads - previous_uploads != channels:
			require(false, "a produced block publishes exactly one rect a channel: made %d, uploads %d -> %d" % [
					made, previous_uploads, uploads])
		previous_uploads = uploads
		previous_bytes = int(now.get("upload_bytes", 0))
		if int(now.get("current_cells", 0)) < before_current:
			monotonic = false
		# 5. No gap: every cell is serving or loading, at every frame.
		if int(now.get("serving_or_loading", 0)) != 81:
			serving_identity = false
	row("first_fill", "frames=%d uploads=%d bytes=%d" % [produced_frames, previous_uploads, previous_bytes])
	require(int(atlas().get("current_cells", 0)) == 81, "every cell serves a block after the first fill")
	require(int(atlas().get("pending_jobs", 0)) == 0, "no block is left queued after the first fill")
	require(monotonic, "a cell never stops serving a block during the first fill")
	require(serving_identity, "at every frame every cell is either serving or loading a block")
	# The byte count is the blocks' own: the ladder's texels plus the global block, times the channels
	# and the four bytes a value - with nothing for the atlas's own rectangle.
	var block_texels := 9 * BLOCK_SIZE * BLOCK_SIZE \
			+ 16 * (BLOCK_SIZE / 2) * (BLOCK_SIZE / 2) \
			+ 24 * (BLOCK_SIZE / 4) * (BLOCK_SIZE / 4) \
			+ 32 * (BLOCK_SIZE / 8) * (BLOCK_SIZE / 8)
	var expected_bytes := (block_texels + GLOBAL_TEXELS * GLOBAL_TEXELS) * channels * 4
	require(previous_bytes == expected_bytes,
			"the first fill uploads exactly the blocks' bytes (%d), got %d" % [expected_bytes, previous_bytes])
	require(previous_uploads == (81 + 1) * channels,
			"one rect a channel per block, %d expected, got %d" % [(81 + 1) * channels, previous_uploads])

	# 6. The global block is produced once: an update with nothing to do adds nothing.
	var idle_made := tick()
	require(idle_made == 0, "an update with nothing to do produces nothing, got %d" % idle_made)
	require(int(atlas().get("block_uploads", 0)) == previous_uploads, "and publishes no rect")

	# 4. A phase turn: a move inside a block changes the offset and loads nothing.
	var texel := BASE_WORLD / float(BLOCK_SIZE)
	camera.position = Vector3(camera.position.x + texel * 2.0, camera.position.y, camera.position.z)
	var phase_made := tick()
	var after_phase := atlas()
	require(phase_made == 0, "a move inside a block loads nothing, got %d" % phase_made)
	require(int(after_phase.get("scroll_events", 0)) == 0, "a move inside a block is not a grid step")
	var scrolls_before := int(after_phase.get("scroll_events", 0))
	var uploads_before := int(after_phase.get("block_uploads", 0))

	# 4b. A whole block: the grid relabels. Some cells keep their content and only what entered loads.
	# The entered blocks are placed a frame at a time as slots free up, so the count is read after the
	# drain - which is exactly the per-frame bound the mechanism claims.
	camera.position = Vector3(camera.position.x + BASE_WORLD, camera.position.y, camera.position.z)
	var relabel_made := tick()
	var after_relabel := atlas()
	require(int(after_relabel.get("scroll_events", 0)) == scrolls_before + 1, "a whole-block move is one grid step")
	require(int(after_relabel.get("block_uploads", 0)) > uploads_before,
			"the entered blocks are published as their own rects")
	# Drain and confirm the grid is whole again.
	var drain := 0
	while int(atlas().get("pending_jobs", 0)) > 0 and drain < 400:
		tick()
		drain += 1
	var drained := atlas()
	var loaded := int(drained.get("last_scroll_loaded", 0))
	var retained := int(drained.get("last_scroll_retained", 0))
	print("VT_CLIPMAP_ATLAS relabel made=%d drain=%d loaded=%d retained=%d cells=%d" % [
			relabel_made, drain, loaded, retained, int(drained.get("cells", 0))])
	require(loaded + retained == 81, "every cell either entered or kept its block: %d + %d" % [loaded, retained])
	require(retained > 0, "a scroll keeps the content of the cells that did not move, got %d" % retained)
	require(loaded > 0, "a scroll loads the blocks that entered, got %d" % loaded)
	require(loaded < 81, "a scroll does not reload the grid, got %d of 81" % loaded)
	require(int(drained.get("current_cells", 0)) == 81, "every cell serves a block again after the drain")
	require(int(drained.get("pending_cells", 0)) == 0, "nothing is left loading")
	row("after_scroll", "drain=%d" % drain)

	# The layout payload the debug view draws has a rect a block and a cell a cell.
	var debug_layout := terrain.get_clipmap_atlas_layout(MATERIAL)
	require(not debug_layout.is_empty(), "the atlas publishes a debug layout")
	var rects: Array = (debug_layout.get("layout", {}) as Dictionary).get("rects", [])
	var cells: Array = (debug_layout.get("layout", {}) as Dictionary).get("cells", [])
	require(rects.size() == 86, "the rect array has 86 entries, got %d" % rects.size())
	require(cells.size() == 81, "the cell table has 81 entries, got %d" % cells.size())
	var spares := 0
	var globals := 0
	for value: Variant in rects:
		var item: Dictionary = value
		spares += 1 if bool(item.get("spare", false)) else 0
		globals += 1 if bool(item.get("global", false)) else 0
	require(spares == 4, "one spare a ring, got %d" % spares)
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
