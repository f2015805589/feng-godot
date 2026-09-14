# Run with a graphical rendering driver; see README.md in this directory.
#
# Surface density. The stored payload is surface_density texels per region texel while
# the region texture array deliberately stays at region_size, so this pins the four
# things that make the density real rather than just a bigger file:
#
#   1) sizes: payload region_size * density squared, array layer region_size squared
#   2) the brush writes whole density blocks (the editor authors one region texel)
#   3) resampling is block exact and never re-derives from the legacy control map
#   4) the shader evaluates the idweight cell on the density grid, so the render shows
#      the finer material where the array path can only show the block origin
extends SceneTree

const REGION_SIZE := 64
const DENSITY := 4
const SURFACE_SIZE := REGION_SIZE * DENSITY
const PAGES_PER_AXIS := 4
# span0 = region_size * density / pages_per_axis, so a 64 texel page is a 1:1 crop.
const PAGE := 64
const BORDER := 4
const STORED := PAGE + 2 * BORDER
# single(id) = (id << 11) | (id << 6)
const MAT_RED := 0
const MAT_GREEN := (1 << 11) | (1 << 6)

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var painter: Terrain3DEditor
var brush: Image
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# Undo plumbing: the editor calls these on the plugin.
func create_undo_action(_name: String) -> void:
	pass
func add_undo_method(_action: Callable) -> void:
	pass
func add_do_method(_action: Callable) -> void:
	pass
func commit_action(_execute: bool) -> void:
	pass

func frame_image() -> Image:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

# Red dominance rather than a pure-red test. A block origin is one dense texel wide
# (0.25 m at density 4), so at the 1:1 mip a pixel lands on a texel edge more often
# than not and the rendered pixel is a red/green blend whose red side still dominates.
# What the array path cannot do is show anything but the origin, and what the near
# field has to do is keep the origins on the payload grid; both are measured below.
func is_red_dominant(color: Color) -> bool:
	return color.r > color.g and color.r > 0.05

func red_dominant_fraction(image: Image) -> float:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if is_red_dominant(image.get_pixel(x, y)):
				count += 1
	return float(count) / float(image.get_width() * image.get_height())

func world_x_at(point: Vector2) -> float:
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(point), camera.project_ray_normal(point))
	return hit.x if hit != null else INF

# World x of the start of every red-dominant run on one row. The block pattern drew one
# origin every four dense texels, so the runs have to land one metre apart.
func origin_columns(image: Image, row: int) -> PackedFloat32Array:
	var columns := PackedFloat32Array()
	var inside := false
	for x in image.get_width():
		var dominant := is_red_dominant(image.get_pixel(x, row))
		if dominant and not inside:
			columns.append(world_x_at(Vector2(x, row)))
		inside = dominant
	return columns

func write_dense(loc: Vector2i, value: int, size: int = SURFACE_SIZE) -> void:
	var bytes := PackedByteArray()
	bytes.resize(size * size * 2)
	for i in size * size:
		bytes.encode_u16(i * 2, value)
	terrain.data.get_region(loc).set_surface_map(
			Image.create_from_data(size, size, false, Image.FORMAT_R16, bytes))

# A pattern where every payload texel is distinguishable, so a page's crop origin can
# be recovered from its content alone.
func write_pattern(loc: Vector2i) -> void:
	var bytes := PackedByteArray()
	bytes.resize(SURFACE_SIZE * SURFACE_SIZE * 2)
	for y in SURFACE_SIZE:
		for x in SURFACE_SIZE:
			bytes.encode_u16((y * SURFACE_SIZE + x) * 2, 1000 + x * 4 + y)
	terrain.data.get_region(loc).set_surface_map(
			Image.create_from_data(SURFACE_SIZE, SURFACE_SIZE, false, Image.FORMAT_R16, bytes))

# Block origins are one material, the fifteen finer texels per block another. The
# array path (block origins only) must therefore render the first, the virtual
# texture the second.
func write_block_pattern(loc: Vector2i) -> void:
	var bytes := PackedByteArray()
	bytes.resize(SURFACE_SIZE * SURFACE_SIZE * 2)
	for y in SURFACE_SIZE:
		for x in SURFACE_SIZE:
			var value := MAT_RED if (x % DENSITY == 0 and y % DENSITY == 0) else MAT_GREEN
			bytes.encode_u16((y * SURFACE_SIZE + x) * 2, value)
	terrain.data.get_region(loc).set_surface_map(
			Image.create_from_data(SURFACE_SIZE, SURFACE_SIZE, false, Image.FORMAT_R16, bytes))

func dense_texel(image: Image, x: int, y: int) -> int:
	return image.get_data().decode_u16((y * image.get_width() + x) * 2)

# Content edits reach the texture arrays through the edited flag, the same way the
# brush reports them.
func push_pattern(loc: Vector2i) -> void:
	terrain.data.get_region(loc).set_edited(true)
	terrain.data.update_maps()

func all_texels_equal(image: Image, value: int) -> bool:
	var bytes := image.get_data()
	for i in image.get_width() * image.get_height():
		if bytes.decode_u16(i * 2) != value:
			return false
	return true

# The producer's rule restated independently, at a 1:1 mip: page texel -> payload texel.
# A border texel lands outside the region, and region (0,0) is the only one with a
# payload here, so it is material 0 rather than a copy of the region's edge.
func check_page(loc: Vector2i, slot: int, px: int, py: int) -> void:
	var page := terrain.get_surface_vt().read_page(slot)
	require(page != null and not page.is_empty(), "page slot %d should be readable" % slot)
	if page == null or page.is_empty():
		return
	var bytes := page.get_data()
	var span := SURFACE_SIZE / PAGES_PER_AXIS
	var origin_x := px * span
	var origin_y := py * span
	var texel_world := 1.0 / float(DENSITY)
	var bad := 0
	var first := ""
	for y in STORED:
		var sy := origin_y + (y - BORDER)
		var world_z := float(sy) * texel_world
		for x in STORED:
			var sx := origin_x + (x - BORDER)
			var world_x := float(sx) * texel_world
			var want := 0
			if world_x >= 0.0 and world_z >= 0.0 and world_x < float(REGION_SIZE) and world_z < float(REGION_SIZE):
				want = 1000 + sx * 4 + sy
			var got := bytes.decode_u16((y * STORED + x) * 2)
			if got != want:
				bad += 1
				if first == "":
					first = "texel (%d,%d) at world (%.2f,%.2f) got %d want %d from payload (%d,%d)" % [x, y, world_x, world_z, got, want, sx, sy]
	require(bad == 0, "%s page (%d,%d): %d bad texels, first %s" % [loc, px, py, bad, first])

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	# Verify the ID/weight residency contract separately from material baking.
	terrain.set_vt_debug_direct_material(true)
	terrain.free_editor_textures = false
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
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)

	terrain.region_size = REGION_SIZE
	terrain.surface_density = DENSITY
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	await process_frame
	await process_frame

	require(terrain.surface_density == DENSITY, "surface density should be applied")
	require(terrain.get_surface_density() == DENSITY, "surface density should be readable")

	var loc := Vector2i.ZERO
	terrain.data.add_region_blank(loc)
	var region: Terrain3DRegion = terrain.data.get_region(loc)
	require(region.ensure_surface_map(), "a blank region should build a surface map")
	require(region.get_surface_density() == DENSITY, "the region should adopt the terrain density, got " + str(region.get_surface_density()))
	require(region.get_surface_map_size() == SURFACE_SIZE, "payload size should be region_size * density, got " + str(region.get_surface_map_size()))
	require(region.get_surface_map().get_width() == SURFACE_SIZE, "payload should be " + str(SURFACE_SIZE) + " squared")
	var array_image: Image = region.get_surface_map_array_image()
	require(array_image != null and array_image.get_width() == REGION_SIZE,
			"the array layer must stay at region_size, got " + str(array_image.get_width() if array_image else -1))
	if not failed:
		print("PASS surface density keeps the payload dense and the array coarse")

	# The brush authors one region texel per step, so it must write the whole block.
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 40.0, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 1,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	var center := Vector3(REGION_SIZE * 0.5, 0.0, REGION_SIZE * 0.5)
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()
	region = terrain.data.get_region(loc)
	var painted := dense_texel(region.get_surface_map(), 32 * DENSITY, 32 * DENSITY)
	require(painted == MAT_GREEN, "the brush should paint the selected pair, got " + str(painted))
	var block_uniform := true
	for by in DENSITY:
		for bx in DENSITY:
			if dense_texel(region.get_surface_map(), 32 * DENSITY + bx, 32 * DENSITY + by) != painted:
				block_uniform = false
	require(block_uniform, "the brush must write the whole density block")
	require(dense_texel(region.get_surface_map(), DENSITY, DENSITY) == 0,
			"a block outside the brush must stay untouched")
	if not failed:
		print("PASS surface density brush writes whole blocks")

	# Resampling must be block exact in both directions, and must never fall back to
	# re-deriving the payload from the legacy control map (which holds no material
	# bits after migration).
	var before := region.get_surface_map().get_data()
	terrain.change_surface_density(1)
	region = terrain.data.get_region(loc)
	require(region.get_surface_map().get_width() == REGION_SIZE,
			"density 1 should shrink the payload to region_size, got " + str(region.get_surface_map().get_width()))
	require(region.get_surface_map_array_image().get_width() == REGION_SIZE, "the array layer should stay at region_size")
	terrain.change_surface_density(DENSITY)
	region = terrain.data.get_region(loc)
	require(region.get_surface_map().get_width() == SURFACE_SIZE, "density 4 should grow the payload back")
	require(region.get_surface_map().get_data() == before,
			"a 4 -> 1 -> 4 round trip must be byte exact for block uniform data")
	if not failed:
		print("PASS surface density resampling is block exact and never re-derives the payload")

	# The load choke point: a region saved before surface_density existed carries a
	# region_size squared payload and no density, and must be migrated on entry.
	terrain.change_surface_density(1)
	region = terrain.data.get_region(loc)
	# A payload as an older file carries it: region_size squared and no density.
	write_dense(loc, MAT_GREEN, REGION_SIZE)
	region = terrain.data.get_region(loc)
	require(all_texels_equal(region.get_surface_map(), MAT_GREEN), "the legacy payload should hold one material")
	terrain.data.unload_region(loc, true)
	terrain.change_surface_density(DENSITY)
	terrain.data.add_region(region, true)
	var migrated: Terrain3DRegion = terrain.data.get_region(loc)
	require(migrated != null, "the region should be back in memory")
	require(migrated.get_surface_map().get_width() == SURFACE_SIZE,
			"an old payload must load at the terrain density, got " + str(migrated.get_surface_map().get_width()))
	require(all_texels_equal(migrated.get_surface_map(), MAT_GREEN),
			"migration must preserve the painted material instead of re-converting the control map")
	if not failed:
		print("PASS surface density migrates an old payload without re-deriving it")

	# The save format itself: a density 4 region must survive a real file round trip
	# with both its payload bytes and its density.
	var region_dir := "user://vt_density_regions"
	DirAccess.make_dir_recursive_absolute(region_dir)
	migrated.set_modified(true)
	terrain.data.save_region(loc, region_dir)
	var saved_bytes := migrated.get_surface_map().get_data()
	terrain.data.unload_region(loc, true)
	terrain.data.load_region(loc, region_dir, true)
	var reloaded: Terrain3DRegion = terrain.data.get_region(loc)
	require(reloaded != null, "the region should load back from disk")
	if reloaded != null:
		require(reloaded.get_surface_density() == DENSITY,
				"the file must carry the density, got " + str(reloaded.get_surface_density()))
		require(reloaded.get_surface_map().get_width() == SURFACE_SIZE,
				"the payload size must survive the round trip, got " + str(reloaded.get_surface_map().get_width()))
		require(reloaded.get_surface_map().get_data() == saved_bytes,
				"the payload bytes must survive the round trip")
	if not failed:
		print("PASS surface density survives a region file round trip")

	# Page production at density: mip 0 is now a 1:1 crop of the dense payload.
	terrain.surface_vt_page_size = PAGE
	terrain.surface_vt_page_border = BORDER
	terrain.surface_vt_page_count = PAGES_PER_AXIS * PAGES_PER_AXIS
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = 512.0
	# The 4x4 page grid asserted below is the legacy region view. Full AVT addresses 64 m
	# sectors and publishes through the asynchronous source pipeline, so one
	# update_surface_vt() call has no prepared page to publish yet.
	terrain.surface_vt_selection_mode = 1
	write_pattern(loc)
	push_pattern(loc)
	terrain.set_surface_vt_force_mip(true, 0)
	var produced := terrain.update_surface_vt()
	require(produced == PAGES_PER_AXIS * PAGES_PER_AXIS,
			"mip 0 should produce %d pages, got %d" % [PAGES_PER_AXIS * PAGES_PER_AXIS, produced])
	if not failed:
		for py in PAGES_PER_AXIS:
			for px in PAGES_PER_AXIS:
				var slot: int = terrain.get_surface_vt().lookup_page(loc, 0, px, py)
				require(slot >= 0, "page (%d,%d) should be resident" % [px, py])
				if slot >= 0:
					check_page(loc, slot, px, py)
	if not failed:
		print("PASS surface density pages are 1:1 crops of the dense payload")

	# And the render: the array path can only show the block origin, so the whole
	# region renders as that material, while the virtual texture reads the finer
	# payload and only a quarter of the frame is still the block-origin material.
	write_block_pattern(loc)
	push_pattern(loc)
	# Keep the frame inside the region: Godot's orthographic size is the frame height, so
	# at size = region_size the 4:3 frame is a third wider than the 64 m region and that
	# third would be background rather than terrain. One page spans PAGE / DENSITY metres.
	camera.size = float(PAGE) / float(DENSITY)
	# Both tiers have to be off for the region array to be what renders: the far field is on by
	# default and keeps serving the visible region from its own pages, which is a different image.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	var off_image := await frame_image()
	var off_red := red_dominant_fraction(off_image)
	require(off_red > 0.85, "the array path should render the block origin material, red-dominant fraction %.3f" % off_red)

	# Only the near field comes back: this phase measures the dense payload the *near* field
	# reads, and a far-field page over the same region would answer with its own level.
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = false
	# The atlas still holds the phase 5 pattern and a resident page is never rewritten,
	# so the atlas has to be dropped for the pages to come from the new payload.
	terrain.get_surface_vt().clear()
	terrain.set_surface_vt_force_mip(true, 0)
	var reproduced := terrain.update_surface_vt()
	require(reproduced == PAGES_PER_AXIS * PAGES_PER_AXIS,
			"a fresh atlas should re-produce %d pages, got %d" % [PAGES_PER_AXIS * PAGES_PER_AXIS, reproduced])
	var on_image := await frame_image()
	var on_red := red_dominant_fraction(on_image)
	require(on_red < 0.7, "the virtual texture should show the finer material, red-dominant fraction %.3f" % on_red)
	# The origins stay visible where the array path has nothing but origins: one
	# red-dominant column per metre, because the pattern drew one every four texels.
	var origins := origin_columns(on_image, on_image.get_height() / 2)
	require(origins.size() >= 15,
			"the block origins must still be visible, %d red-dominant columns on the centre row" % origins.size())
	var spacing := 0.0
	if origins.size() > 1:
		for i in range(1, origins.size()):
			spacing += origins[i] - origins[i - 1]
		spacing /= float(origins.size() - 1)
	require(absf(spacing - 1.0) < 0.15,
			"the block origins must sit on the payload grid, mean spacing %.3f m" % spacing)
	var differing := 0
	for y in on_image.get_height():
		for x in on_image.get_width():
			if off_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				differing += 1
	require(differing > 500, "surface density must be visible in the render, %d pixels differ" % differing)
	if not failed:
		print("PASS surface density changes the render, array coarse (red %.3f) and virtual texture fine (red %.3f, origins %.3f m apart)" % [off_red, on_red, spacing])

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS surface density")
	quit()
