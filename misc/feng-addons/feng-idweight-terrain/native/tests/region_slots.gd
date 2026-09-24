# Run with a graphical rendering driver; see README.md in this directory.
#
# Region layer slots. Two properties are checked, and both need the rendered
# image rather than a CPU readback:
#
#  1) A region's layer index (region_id) is a *slot* that stays put while the
#     region is in memory. The rendered image proves the region map, the four
#     texture arrays and the layer -> location table the shader reads all still
#     agree after a region is unloaded and another is added.
#  2) The four Texture2DArrays are not reallocated when the resident set changes.
#     get_map_stats() counts GPU array allocations vs. single layer uploads, so a
#     swap must show zero creates.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const GRID := 2 # regions (0,0)..(1,1); the swap adds (2,0)

# Distinct albedo colours that classify unambiguously by which channels survive
# relative to the brightest one.
const COLORS := [Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1), Color(1, 1, 0)]
const LABELS := ["r", "g", "b", "rg"]

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
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func region_center(loc: Vector2i) -> Vector3:
	return Vector3(loc.x * REGION_SIZE + REGION_SIZE * 0.5, 0.0, loc.y * REGION_SIZE + REGION_SIZE * 0.5)

# Which channels are lit relative to the brightest one, so the directional light's
# overall brightness does not matter.
func sample(image: Image, loc: Vector2i) -> Color:
	var screen := camera.unproject_position(region_center(loc))
	return image.get_pixel(clampi(int(screen.x), 0, image.get_width() - 1), clampi(int(screen.y), 0, image.get_height() - 1))

func check_region_color(image: Image, loc: Vector2i, asset_id: int, label: String) -> void:
	var got := sample(image, loc)
	require(classify(got) == LABELS[asset_id],
			"%s: region %s should render material %d (%s) but rendered %s" % [label, loc, asset_id, LABELS[asset_id], got])

func paint_region(loc: Vector2i, asset_id: int) -> void:
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 20.0, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": asset_id, "pair_overlay_id": asset_id, "pair_background_id": asset_id,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	var center := region_center(loc)
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()

func check_height_extrema() -> void:
	for format in [Image.FORMAT_RF, Image.FORMAT_RGBAF, Image.FORMAT_RGBA8]:
		var heights := Image.create(8, 4, false, format)
		heights.fill(Color(0.5, 0, 0))
		heights.set_pixel(2, 1, Color(-12.25, 0, 0))
		heights.set_pixel(7, 3, Color(200.75, 0, 0))
		var expected := Vector2(INF, -INF)
		for y in heights.get_height():
			for x in heights.get_width():
				var value := heights.get_pixel(x, y).r
				expected.x = minf(expected.x, value)
				expected.y = maxf(expected.y, value)
		heights.generate_mipmaps()
		require(Terrain3DUtil.get_min_max(heights) == expected, "height bounds preserve format decoding and base-level extrema")
	var special := Image.create(2, 2, false, Image.FORMAT_RF)
	special.fill(Color(NAN, 0, 0))
	special.set_pixel(0, 0, Color(-17.5, 0, 0))
	require(Terrain3DUtil.get_min_max(special) == Vector2(-17.5, -17.5), "NaN height holes do not affect bounds")
	special.set_pixel(1, 0, Color(INF, 0, 0))
	special.set_pixel(1, 1, Color(-INF, 0, 0))
	require(Terrain3DUtil.get_min_max(special) == Vector2(-INF, INF), "infinite height bounds retain existing semantics")
	if not failed:
		print("PASS height-map extrema across formats, mipmaps, holes and infinities")

func run() -> void:
	check_height_extrema()
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.assets = Terrain3DAssets.new()
	for id in COLORS.size():
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, COLORS[id])
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1, 1))
		terrain.assets.set_texture_asset(id, asset)

	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(96.0, 200.0, 64.0)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 240.0
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

	var locations: Array[Vector2i] = []
	for z in GRID:
		for x in GRID:
			locations.append(Vector2i(x, z))
	for i in locations.size():
		terrain.data.add_region_blank(locations[i])
		paint_region(locations[i], i)

	var image := await frame_image()
	image.save_png(output_dir.path_join("slots-grid.png"))
	for i in locations.size():
		check_region_color(image, locations[i], i, "initial grid")
	if not failed:
		print("PASS four regions render their own material from four distinct slots")

	# Slots are stable and the arrays are not reallocated across a resident set swap.
	var slots := {}
	for loc in locations:
		slots[loc] = terrain.data.get_region_id(loc)
	for i in locations.size():
		require(slots[locations[i]] >= 0, "region %s has no slot" % locations[i])
	var capacity := terrain.data.get_map_capacity()
	require(capacity >= locations.size(), "slot capacity %d must fit %d regions" % [capacity, locations.size()])
	# Guard against a runaway table: the capacity doubles from a small minimum, so a
	# handful of regions must never reserve many times their own count.
	require(capacity <= 2 * locations.size(), "slot capacity %d is far above the %d resident regions" % [capacity, locations.size()])
	var slot_locations := terrain.data.get_slot_locations()
	require(slot_locations.size() == capacity, "layer table must be capacity sized")
	for loc in locations:
		require(slot_locations[int(slots[loc])] == Vector2(loc), "layer table does not point back at region %s" % loc)

	# The public map arrays are slot indexed, so a free slot must still hold a real
	# image: callers iterate them (the editor setup test does exactly that).
	for maps in [terrain.data.get_height_maps(), terrain.data.get_control_maps(),
			terrain.data.get_color_maps(), terrain.data.get_surface_maps()]:
		require(maps.size() == capacity, "a map array is not capacity sized")
		for entry in maps:
			require(entry != null and not entry.is_empty(), "a map array holds a null layer for a free slot")
	print("PASS every map array layer is a real image, including free slots")

	terrain.data.reset_map_stats()
	var removed := locations[0]
	var freed_slot: int = slots[removed]
	terrain.data.unload_region(removed)
	require(terrain.data.get_region_id(removed) == -1, "unloaded region kept its slot")
	var added := Vector2i(GRID, 0)
	terrain.data.add_region_blank(added)

	# One region left and one arrived: no array reallocation, and exactly one layer
	# upload per slot map. The unload uploads nothing.
	var swap_stats := terrain.data.get_map_stats()
	require(int(swap_stats["map_create_count"]) == 0,
			"a region swap reallocated the texture arrays " + str(swap_stats["map_create_count"]) + " times")
	require(int(swap_stats["map_update_count"]) == 4,
			"a one region swap should upload one layer per map (4), got " + str(swap_stats["map_update_count"]))
	require(int(swap_stats["slot_grow_count"]) == 0, "a region swap grew the slot table")
	require(int(swap_stats["region_map_rebuild_count"]) == 0, "a region swap rebuilt the whole region map")
	require(int(swap_stats["slot_full_sync_count"]) == 0, "a region swap forced a full layer re-upload")

	paint_region(added, 3)
	var stats := terrain.data.get_map_stats()
	require(int(stats["map_create_count"]) == 0,
			"painting the new region reallocated the texture arrays " + str(stats["map_create_count"]) + " times")
	require(int(stats["map_update_count"]) > 4, "painting the new region uploaded no layers")
	require(terrain.data.get_map_capacity() == capacity, "a region swap grew the slot capacity")
	require(terrain.data.get_region_id(added) == freed_slot, "the freed slot was not reused for the new region")
	for i in range(1, locations.size()):
		require(terrain.data.get_region_id(locations[i]) == slots[locations[i]],
				"region %s changed slot when an unrelated region was swapped" % locations[i])
	print("SLOTS capacity=", capacity, " stats=", stats)
	if not failed:
		print("PASS slot reuse and stable slots with zero texture array reallocation")

	image = await frame_image()
	image.save_png(output_dir.path_join("slots-swapped.png"))
	for i in range(1, locations.size()):
		check_region_color(image, locations[i], i, "after swap")
	check_region_color(image, added, 3, "after swap")
	if not failed:
		print("PASS surviving regions still render their own layer after the swap")

	# The region map is patched in place, so residency queries are correct before the
	# next update_maps(). This used to lag until a full rebuild.
	var probe := Vector2i(GRID + 1, 1)
	terrain.data.add_region_blank(probe, false)
	require(terrain.data.has_region(probe), "add_region(update=false) did not publish the region")
	require(terrain.data.get_region_id(probe) >= 0, "add_region(update=false) left get_region_id at -1")
	terrain.data.unload_region(probe, false)
	require(not terrain.data.has_region(probe), "unload_region(update=false) left the region published")
	terrain.data.update_maps()
	if not failed:
		print("PASS region map is patched in place instead of waiting for update_maps")

	# The chunk -> layer map is a texture now, so the world grid is 128x128 (+-64)
	# instead of the 32x32 (+-16) the uniform int array forced. A region far outside
	# the old grid must be accepted, addressed and rendered.
	var far := Vector2i(40, -40)
	require(Terrain3DData.get_region_map_index(far) >= 0, "region %s should be inside the world grid" % far)
	require(Terrain3DData.get_region_map_index(Vector2i(20, 0)) >= 0, "region (20,0) should be inside the world grid")
	terrain.data.add_region_blank(far)
	paint_region(far, 0)
	camera.position = Vector3(far.x * REGION_SIZE + REGION_SIZE * 0.5, 200.0, far.y * REGION_SIZE + REGION_SIZE * 0.5)
	await frame_image()
	var far_image := await frame_image()
	far_image.save_png(output_dir.path_join("slots-far.png"))
	check_region_color(far_image, far, 0, "far chunk")
	if not failed:
		print("PASS a region outside the old 32x32 grid renders through the directory texture")

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS region layer slots")
	quit()
