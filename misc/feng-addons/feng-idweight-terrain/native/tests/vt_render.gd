# Run with a graphical rendering driver; see README.md in this directory.
#
# Surface virtual texture shader integration. Two things have to hold at once:
#
#  1) With the virtual texture on, the terrain must render exactly like the region
#     texture array path. The pages are produced from the same surface map, so any
#     addressing slip in the indirection walk, the page grid or the border shows up
#     as a different pixel.
#  2) The shader must actually be reading the atlas. Overwriting the pages that cover
#     the sample point with a different material and watching the rendered pixel
#     change is what proves it, rather than the shader silently falling back.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const PAGES_PER_AXIS := 4
const PAGE := 16
const BORDER := 2
const STORED := PAGE + 2 * BORDER

var painter: Terrain3DEditor
var scene: Node3D
var brush: Image
var undo_action: Callable
var redo_action: Callable
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func create_undo_action(_name: String) -> void:
	pass
func add_undo_method(action: Callable) -> void:
	undo_action = action
func add_do_method(action: Callable) -> void:
	redo_action = action
func commit_action(_execute: bool) -> void:
	pass

func frame_image() -> Image:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

# Screen position of a world XZ point.
func screen_of(image: Image, world: Vector2) -> Vector2i:
	var screen := camera.unproject_position(Vector3(world.x, 0.0, world.y))
	return Vector2i(clampi(int(screen.x), 0, image.get_width() - 1), clampi(int(screen.y), 0, image.get_height() - 1))

# The dominant colour in a small neighbourhood, so a single stray pixel at a texel
# boundary cannot decide the result.
func sample_area(image: Image, world: Vector2, radius: int = 3) -> String:
	var counts := {}
	var center := screen_of(image, world)
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := clampi(center.x + dx, 0, image.get_width() - 1)
			var y := clampi(center.y + dy, 0, image.get_height() - 1)
			var key := classify(image.get_pixel(x, y))
			counts[key] = int(counts.get(key, 0)) + 1
	var best := ""
	var best_count := 0
	for key in counts:
		if int(counts[key]) > best_count:
			best = key
			best_count = int(counts[key])
	return best

func make_page(value: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(STORED * STORED * 2)
	if value != 0:
		for i in STORED * STORED:
			bytes.encode_u16(i * 2, value)
	return Image.create_from_data(STORED, STORED, false, Image.FORMAT_R16, bytes)

func paint_region(loc: Vector2i, asset_id: int) -> void:
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 40.0, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": asset_id, "pair_overlay_id": asset_id, "pair_background_id": asset_id,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	var center := Vector3(loc.x * REGION_SIZE + REGION_SIZE * 0.5, 0.0, loc.y * REGION_SIZE + REGION_SIZE * 0.5)
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]

	scene = Node3D.new()
	terrain = Terrain3D.new()
	# Verify the ID/weight residency contract separately from material baking.
	terrain.set_vt_debug_direct_material(true)
	terrain.free_editor_textures = false
	# This case isolates the near atlas/array toggle. Far SVT shares the staging pool and
	# can asynchronously publish the deliberately blanked pages into the later readback.
	terrain.surface_svt_enabled = false
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, Color.RED if id == 0 else Color.GREEN)
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1, 1))
		terrain.assets.set_texture_asset(id, asset)

	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(REGION_SIZE * 0.5, 200.0, REGION_SIZE * 0.5)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = float(REGION_SIZE)
	camera.current = true
	terrain.set_camera(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)

	terrain.region_size = REGION_SIZE
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)

	var loc := Vector2i.ZERO
	terrain.data.add_region_blank(loc)
	paint_region(loc, 1)
	terrain.data.update_maps()

	# The whole region is material 1, so the array path renders green.
	var off_image := await frame_image()
	off_image.save_png(output_dir.path_join("vt-off.png"))
	var probe := Vector2(REGION_SIZE * 0.5, REGION_SIZE * 0.5)
	require(sample_area(off_image, probe) == "g", "the array path should render material 1 as green")
	if failed:
		quit(1)
		return
	print("PASS surface vt baseline: the array path renders the painted material")

	# The near-field settings are applied after the baseline image on purpose. These set a
	# page size and a page count, which rebuilds the atlas, and the frames awaited above run
	# the engine's own demand pass on every physics tick: a 16-page atlas armed before them is
	# already full when the deterministic mip 0 pass below asks for its pages, and a pass that
	# only sees hits correctly produces nothing.
	terrain.surface_vt_page_size = PAGE
	terrain.surface_vt_page_border = BORDER
	terrain.surface_vt_page_count = PAGES_PER_AXIS * PAGES_PER_AXIS
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = 512.0
	# The 4x4 page grid this test asserts is the legacy region view. Full AVT addresses
	# 64 m sectors and produces its pages through the asynchronous source pipeline.
	terrain.surface_vt_selection_mode = 1
	# Turn the virtual texture on and force mip 0 so the page grid is deterministic. Both and
	# the pass below run in this same frame, so the atlas is cold and every page is a miss.
	terrain.surface_vt_enabled = true
	terrain.set_surface_vt_force_mip(true, 0)
	var produced := terrain.update_surface_vt()
	require(produced == PAGES_PER_AXIS * PAGES_PER_AXIS,
			"mip 0 should produce %d pages, got %d" % [PAGES_PER_AXIS * PAGES_PER_AXIS, produced])
	var on_image := await frame_image()
	on_image.save_png(output_dir.path_join("vt-on.png"))
	var on_class := sample_area(on_image, probe)
	require(on_class == "g", "the virtual texture path should render the same green, got " + on_class)
	# Pixel-identical: the pages are produced from the same surface map, so any
	# addressing slip would show up here.
	var differing := 0
	for y in on_image.get_height():
		for x in on_image.get_width():
			if off_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				differing += 1
	require(differing == 0, "vt on and off must render identically, %d pixels differ" % differing)
	if not failed:
		print("PASS surface vt renders pixel-identical to the region array path")

	# Now prove the shader is reading the atlas. Blank the four pages covering
	# [16,48) squared, which contains the probe point, and the render must turn red.
	var vt := terrain.get_surface_vt()
	var blank := make_page(0)
	var cleared := 0
	for py in range(1, 3):
		for px in range(1, 3):
			var slot: int = vt.lookup_page(loc, 0, px, py)
			require(slot >= 0, "page (%d,%d) should be resident" % [px, py])
			if slot >= 0 and vt.write_page(slot, blank):
				cleared += 1
	require(cleared == 4, "four pages should have been blanked, got " + str(cleared))
	var blanked_image := await frame_image()
	blanked_image.save_png(output_dir.path_join("vt-blanked.png"))
	var blanked_class := sample_area(blanked_image, probe)
	require(blanked_class == "r",
			"blanking the atlas pages must change the render, proving the shader reads them (got " + blanked_class + ")")
	if not failed:
		print("PASS surface vt shader samples the physical atlas, not the fallback array")

	# Turning it back off must return to the array path, unchanged by any of this.
	terrain.surface_vt_enabled = false
	var restored := await frame_image()
	var restored_class := sample_area(restored, probe)
	# The class and the two cells are printed because this assertion is the one that races: the far
	# field may resolve through the *shared* staging pool inside the six frames the frame waits, and
	# that pool is where the pages blanked above were written - so a late SVT page renders the blank
	# as well. `docs/vt_delivery_assembly.md` section 8.5 records the counts.
	require(restored_class == "g", "disabling the virtual texture should restore the array path, got %s (near/material=%d far/material=%d)" % [
			restored_class, int(terrain.get_vt_delivery(0, 0)), int(terrain.get_vt_delivery(1, 0))])
	if not failed:
		print("PASS surface vt disable restores the array path")

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS surface virtual texture render integration")
	quit()
