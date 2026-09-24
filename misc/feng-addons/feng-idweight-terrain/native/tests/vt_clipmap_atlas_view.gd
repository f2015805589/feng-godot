# Run with a graphical rendering driver; see README.md in this directory.
#
# The clipmap *atlas* debug view's own evidence. `vt_clipmap_preview.gd` is the Control the Inspector's
# VT Page section and the Surface VT window both host; with the atlas implementation selected it draws
# the atlas instead of the LOD ring's level map - the **region** (every rect the packer placed, at its
# real position and size in the texture, coloured by unit, spares outlined, the one-time global block
# in its own colour) and the **grid** (each unit's own 3x3 arrangement of blocks, coloured by the unit
# that owns each one and numbered with the atlas index it reads this frame).
#
# This script renders that control at 1080p into a SubViewport and saves the PNG, so "the debug shows
# the atlas's region" is a picture rather than a claim, and it asserts the properties the picture is
# supposed to have: the layer's implementation payload carries the layout, one rect a slot, and nine
# cells a unit.
extends SceneTree

const MATERIAL := 0
const DIRECT := 0
# The implementation selector inside the one `Clipmap` delivery; the atlas is chosen here rather than
# as a delivery of its own.
const ATLAS := 1
const UNITS := 4
const VIEWPORT_SIZE := Vector2i(1920, 1080)

var terrain: Terrain3D
var camera: Camera3D
var scene: Node3D
var failed := false
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# The material layer's entry from `get_clipmap_layout_preview()`, which is the payload the debug view
# draws. It replaces `get_clipmap_atlas_layout()`; the atlas's own rect/cell table is `impl["layout"]`.
func atlas_layer() -> Dictionary:
	var preview := terrain.get_clipmap_layout_preview()
	for value: Variant in preview.get("layers", []):
		var layer: Dictionary = value
		if str(layer.get("group", "")) == "material":
			return layer
	return {}

func setup() -> void:
	root.name = "ClipmapAtlasView"
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
	terrain.vt_clipmap_size = 64
	terrain.vt_clipmap_base_world = 64.0
	# `vt_clipmap_levels` is the layer's unit count now; the atlas is selected as an implementation
	# inside the one `Clipmap` delivery rather than as a delivery of its own.
	terrain.vt_clipmap_levels = UNITS
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
	# Build the atlas and fill it, so the view has a full region and grid to draw rather than a first
	# frame. The loop reads the layer's own preview payload rather than the whole settings report,
	# because the report is a full VT scan and 120 of them would dominate the run.
	for _i in 120:
		var filled: Dictionary = atlas_layer()
		if int(filled.get("pending_jobs", 0)) == 0 and int(filled.get("produced_texels", 0)) > 0:
			break
		terrain.debug_update_vt_clipmap(MATERIAL)
	await process_frame

func poll(control: Control) -> void:
	control.set("_last_poll_sec", -1.0e9)
	control.call("_process", 0.0)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	await setup()

	var script: GDScript = load("res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd")
	require(script != null, "the clipmap preview script loads")
	if script == null:
		quit(1)
		return
	var control: Control = script.new()
	var viewport := SubViewport.new()
	viewport.name = "AtlasViewRender"
	viewport.size = VIEWPORT_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	root.add_child(viewport)
	viewport.add_child(control)
	control.size = Vector2(VIEWPORT_SIZE)
	control.set_terrain(terrain)
	poll(control)
	poll(control)

	var layer: Dictionary = control.get("_layer")
	var snapshot: Dictionary = control.get("_snapshot")
	print("VT_CLIPMAP_ATLAS_VIEW gate=%s layer=%s snapshot_keys=%d" % [
			str(control.call("is_available")), str(not layer.is_empty()), snapshot.size()])
	require(not layer.is_empty(), "the preview holds a layer snapshot when a clipmap layer exists")
	require(str(layer.get("group", "")) == "material", "and it is the material group's layer")
	var impl: Dictionary = layer.get("impl", {})
	require(str(impl.get("storage", "")) == "packed_block_atlas",
			"and the implementation payload is the packed block atlas")
	var layout: Dictionary = impl.get("layout", {})
	require(int(layout.get("width", 0)) > 0 and int(layout.get("height", 0)) > 0, "the snapshot carries the atlas")
	require((layout.get("rects", []) as Array).size() == int(layout.get("total_blocks", 0)),
			"the snapshot carries one rect a slot")
	require((layout.get("cells", []) as Array).size() == 9 * UNITS,
			"the snapshot carries the %d cells" % (9 * UNITS))

	for _i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var path: String = output_dir.path_join("clipmap-atlas-debug-1080p.png")
	var error := image.save_png(path)
	require(error == OK, "the debug view renders to a PNG (%d)" % error)
	# A picture of the atlas is not a blank one: count the pixels that are neither the panel background
	# nor the atlas's own dark fill.
	var width := image.get_width()
	var height := image.get_height()
	print("VT_CLIPMAP_ATLAS_VIEW image=%dx%d path=%s" % [width, height, path])
	require(width == VIEWPORT_SIZE.x and height == VIEWPORT_SIZE.y, "the picture is 1080p")
	var painted := 0
	for y in range(0, height, 4):
		for x in range(0, width, 4):
			var color := image.get_pixel(x, y)
			if absf(color.r - 0.082) + absf(color.g - 0.106) + absf(color.b - 0.129) > 0.06:
				painted += 1
	require(painted > 500, "the view draws the atlas rather than an empty panel: %d sample points" % painted)
	print("VT_CLIPMAP_ATLAS_VIEW painted=%d samples" % painted)

	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	if failed:
		print("REGRESSION: clipmap atlas debug view")
		quit(1)
		return
	print("PASS clipmap atlas debug view")
	quit(0)
