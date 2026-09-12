# Run with a graphical rendering driver; see README.md in this directory.
#
# Far field (sparse virtual texture): a world-space page grid that spans regions. This
# is the tier the region-aligned near field cannot express, so the test pins the three
# things that make it a real tier rather than a second copy of the array:
#
#   1) world addressing: a page covers a fixed world square, not a slice of one region,
#      and a page may span several regions
#   2) the border texels come from the *neighbouring* regions, not a clamped copy, which
#      is what a bilinear tap at a page seam needs
#   3) the mip chain is world-space: a distant page is published at a coarser level
#      while a near one stays at mip 0
extends SceneTree

const REGION_SIZE := 64
const PAGE_WORLD := 64.0
const PAGE := 64
const BORDER := 4
const STORED := PAGE + 2 * BORDER
const INVALID := 65535

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# single(id) = (id << 11) | (id << 6), the packed word for one material with no overlay.
func material_word(id: int) -> int:
	return (id << 11) | (id << 6)

func fill_region(loc: Vector2i, material_id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(material_id)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(loc)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

# The expectation, restated independently: every stored texel maps to a world position,
# and the material is whichever region owns that position. Texels outside every resident
# region stay material 0.
func expected_material(world_x: float, world_z: float) -> int:
	var rx := int(floor(world_x / REGION_SIZE))
	var rz := int(floor(world_z / REGION_SIZE))
	var region: Terrain3DRegion = terrain.data.get_region(Vector2i(rx, rz))
	if region == null or not region.get_surface_map():
		return 0
	var local_x := clampi(int(floor(world_x - rx * REGION_SIZE)), 0, REGION_SIZE - 1)
	var local_z := clampi(int(floor(world_z - rz * REGION_SIZE)), 0, REGION_SIZE - 1)
	var word: int = region.get_surface_map().get_data().decode_u16((local_z * REGION_SIZE + local_x) * 2)
	return (word >> 11) & 31

func check_page(page_x: int, page_y: int, local_mip: int) -> void:
	var vt := terrain.get_surface_svt()
	var slot: int = vt.lookup_world_page(page_x, page_y, local_mip)
	require(slot >= 0, "world page (%d,%d) mip %d should be resident" % [page_x, page_y, local_mip])
	if slot < 0:
		return
	var page := vt.read_page(slot)
	require(page != null and not page.is_empty(), "page slot %d should be readable" % slot)
	if page == null or page.is_empty():
		return
	var bytes := page.get_data()
	var mip_pages := 1 << local_mip
	var page_world := PAGE_WORLD * mip_pages
	var texel_world := page_world / float(PAGE)
	var origin_x := float(page_x >> local_mip << local_mip) * PAGE_WORLD
	var origin_z := float(page_y >> local_mip << local_mip) * PAGE_WORLD
	var bad := 0
	var first := ""
	for y in STORED:
		var world_z := origin_z + (float(y - BORDER) + 0.5) * texel_world
		for x in STORED:
			var world_x := origin_x + (float(x - BORDER) + 0.5) * texel_world
			var want := expected_material(world_x, world_z)
			var got := (bytes.decode_u16((y * STORED + x) * 2) >> 11) & 31
			if got != want:
				bad += 1
				if first == "":
					first = "texel (%d,%d) at world (%.1f,%.1f) got %d want %d" % [x, y, world_x, world_z, got, want]
	require(bad == 0, "page (%d,%d) mip %d: %d bad texels, first %s" % [page_x, page_y, local_mip, bad, first])

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

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	# Verify the ID/weight residency contract separately from material baking.
	terrain.set_vt_debug_direct_material(true)
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)
	# Materials 0..3 need distinct colours: the render checks compare the far field
	# against the array path and against a blanked page.
	terrain.assets = Terrain3DAssets.new()
	var colors := [Color.RED, Color.GREEN, Color.BLUE, Color.WHITE]
	for id in colors.size():
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, colors[id])
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1, 1))
		terrain.assets.set_texture_asset(id, asset)

	camera = Camera3D.new()
	root.add_child(camera)
	# The far field's level bands are measured from the camera, the same reference the
	# shader uses. Keep it close to the ground so the region under it stays in the level 0
	# band (mip 0 serves up to 2 x page_world = 128 m) and the frame compares 1:1 with the
	# array path.
	camera.position = Vector3(REGION_SIZE * 0.5, 40.0, REGION_SIZE * 0.5)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = float(REGION_SIZE)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)

	terrain.region_size = REGION_SIZE
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame

	# A 2x2 block of regions, each one uniform material, so a page border that reads its
	# neighbour is distinguishable from one that clamps its own edge.
	var locs := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var materials := [1, 2, 3, 4]
	for i in locs.size():
		terrain.data.add_region_blank(locs[i])
		fill_region(locs[i], materials[i])
	terrain.data.update_maps()

	terrain.surface_svt_page_world = PAGE_WORLD
	terrain.surface_svt_page_size = PAGE
	terrain.surface_svt_page_border = BORDER
	# Room for the distance window plus the protected root pyramid: 25 near pages and
	# 20 root pages at this configuration. Sizing it smaller makes the LRU evict the
	# pages the test is about to look for.
	terrain.surface_svt_page_count = 64
	terrain.surface_svt_distance = 256.0
	# The far field is the tier under test, so the near field stays off and the array
	# remains the last fallback.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = true

	var vt := terrain.get_surface_svt()
	require(vt != null and vt.is_initialized(), "Terrain3D should own an initialized far-field vt")
	require(vt.is_world_space(), "the far-field vt must be world space")
	require(vt.get_page_size() == PAGE and vt.get_page_border() == BORDER, "the far-field vt should carry its page settings")
	require(terrain.is_surface_svt_enabled(), "the far field should be enabled")

	var first_batch := terrain.update_surface_svt(2)
	require(first_batch > 0 and first_batch <= 2, "budgeted far-field update must produce at most two pages")
	var produced := terrain.update_surface_svt()
	require(produced > 0, "the far field should produce pages, got " + str(produced))
	print("VTSVT produced=", produced, " max_mip=", vt.get_world_max_mip(),
			" half=", vt.get_world_grid_half(), " stats=", vt.get_stats())

	# Mip 0 pages near the camera, and the page at (2,2) is about 185 m away: its centre
	# is past the 128 m level 0 band, so it must be published one level coarser.
	require(vt.lookup_world_page(0, 0, 0) >= 0, "the page under the camera should be resident at mip 0")
	var near_slot: Vector2i = vt.get_world_page_virtual(0, 0, 0)
	var far_slot: Vector2i = vt.get_world_page_virtual(2, 2, 1)
	var far_mip0: Vector2i = vt.get_world_page_virtual(2, 2, 0)
	require(vt.get_indirection_slot(near_slot.x, near_slot.y, 0) != INVALID,
			"the page under the camera must be published at mip 0")
	require(vt.get_indirection_slot(far_slot.x, far_slot.y, 1) != INVALID,
			"a page about 185 m away must be published at mip 1")
	require(vt.get_indirection_slot(far_mip0.x, far_mip0.y, 0) == INVALID,
			"that page must not hold a mip 0 entry")
	if not failed:
		print("PASS far-field pages use a world-space mip chain, fine near and coarse far")

	# Page content, texel by texel, border included: the border of page (0,0) has to read
	# the materials of regions (1,0) and (0,1), not a copy of region (0,0)'s edge.
	check_page(0, 0, 0)
	check_page(1, 0, 0)
	check_page(2, 2, 1)
	if not failed:
		print("PASS far-field pages are world crops with neighbour-filled borders")

	# Render: at 1:1 with the region grid the far field must agree with the array path
	# pixel for pixel, and blanking its pages must change the frame -- which is what
	# proves the shader is reading it rather than falling back.
	terrain.surface_svt_enabled = false
	var off_image := await frame_image()
	terrain.surface_svt_enabled = true
	terrain.update_surface_svt()
	var on_image := await frame_image()
	var differing := 0
	for y in on_image.get_height():
		for x in on_image.get_width():
			if off_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				differing += 1
	require(differing == 0, "the far field at 1:1 must match the array path, %d pixels differ" % differing)
	if not failed:
		print("PASS far-field render matches the array path at 1:1")

	var blank_bytes := PackedByteArray()
	blank_bytes.resize(STORED * STORED * 2)
	var blank := Image.create_from_data(STORED, STORED, false, Image.FORMAT_R16, blank_bytes)
	var slot: int = vt.lookup_world_page(0, 0, 0)
	require(slot >= 0 and vt.write_page(slot, blank), "the page under the camera should be writable")
	vt.commit()
	var blanked_image := await frame_image()
	var changed := 0
	for y in blanked_image.get_height():
		for x in blanked_image.get_width():
			if blanked_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				changed += 1
	require(changed > 500, "blanking the far-field page must change the render, %d pixels differ" % changed)
	if not failed:
		print("PASS far-field shader samples the sparse atlas, not the fallback array")

	# Invalidation is what makes an edit visible: dropping the page makes the demand pass
	# re-produce it from the payload, which must restore the frame exactly.
	terrain.invalidate_surface_pages(Vector2i(0, 0))
	var restored_produced := terrain.update_surface_svt()
	require(restored_produced > 0, "an invalidated page must be re-produced, got " + str(restored_produced))
	var restored_image := await frame_image()
	var restored_differing := 0
	for y in restored_image.get_height():
		for x in restored_image.get_width():
			if restored_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				restored_differing += 1
	require(restored_differing == 0,
			"re-producing an invalidated page must restore the frame, %d pixels differ" % restored_differing)
	if not failed:
		print("PASS invalidating a region's pages re-produces them from the payload")

	# Root pyramid: the coarsest levels are always resident, so a world position far
	# outside the distance window still resolves instead of falling through to the array.
	terrain.update_surface_svt()
	var max_mip := vt.get_world_max_mip()
	var root_first := maxi(0, max_mip - terrain.surface_svt_root_mips + 1)
	var root_missing := 0
	for mip in range(root_first, max_mip + 1):
		var level_size := maxi(1, vt.get_indirection_size() >> mip)
		for vy in level_size:
			for vx in level_size:
				if vt.get_indirection_slot(vx, vy, mip) == INVALID:
					root_missing += 1
	require(root_missing == 0, "every root level texel must be resident, %d missing" % root_missing)
	# Page (100,100) is 6.4 km from the target, far past the 256 m window: only the root
	# pyramid can serve it.
	require(vt.lookup_world_page(100, 100, 0) >= 0,
			"a page far outside the distance window must resolve through the root pyramid")
	if not failed:
		print("PASS far-field root pyramid covers the whole grid (levels %d..%d)" % [root_first, max_mip])

	# Array-free: with the surface array blank the far field must serve every surface
	# read, so the frame stays identical to the array-backed one.
	terrain.surface_array_enabled = false
	var array_free_image := await frame_image()
	var array_free_differing := 0
	for y in array_free_image.get_height():
		for x in array_free_image.get_width():
			if array_free_image.get_pixel(x, y) != on_image.get_pixel(x, y):
				array_free_differing += 1
	require(array_free_differing == 0,
			"array-free rendering must match the array-backed frame, %d pixels differ" % array_free_differing)
	var layers: Array = terrain.data.get_surface_maps()
	require(layers.size() > 0, "the surface array should stay allocated for a valid binding")
	var layer_bytes: PackedByteArray = layers[0].get_data()
	var non_zero := 0
	for i in layer_bytes.size():
		if layer_bytes[i] != 0:
			non_zero += 1
	require(non_zero == 0, "no surface payload should be uploaded with the array disabled, %d non-zero bytes" % non_zero)
	if not failed:
		print("PASS array-free rendering is served by the far field")

	# And an edit must still reach the screen: invalidating the region's pages makes the
	# demand pass re-produce them from the new payload.
	fill_region(Vector2i(0, 0), 3)
	terrain.data.update_maps()
	terrain.invalidate_surface_pages(Vector2i(0, 0))
	var reproduced := terrain.update_surface_svt()
	require(reproduced > 0, "an invalidated region must be re-produced, got " + str(reproduced))
	var edited_image := await frame_image()
	var edited_changed := 0
	for y in edited_image.get_height():
		for x in edited_image.get_width():
			if edited_image.get_pixel(x, y) != array_free_image.get_pixel(x, y):
				edited_changed += 1
	require(edited_changed > 500,
			"an edit with the array disabled must reach the render, %d pixels differ" % edited_changed)
	if not failed:
		print("PASS array-free edits are re-produced instead of served stale")

	# Safety: with no virtual texture tier enabled the array is the only source, so it must
	# carry the channel again -- a blank array would render every texel as material 0.
	terrain.surface_svt_enabled = false
	terrain.surface_array_enabled = false
	terrain.data.update_maps()
	var guarded_image := await frame_image()
	var guarded_differing := 0
	for y in guarded_image.get_height():
		for x in guarded_image.get_width():
			if guarded_image.get_pixel(x, y) != edited_image.get_pixel(x, y):
				guarded_differing += 1
	require(guarded_differing == 0,
			"the array must keep serving when both virtual texture tiers are off, %d pixels differ" % guarded_differing)
	terrain.surface_svt_enabled = true
	if not failed:
		print("PASS the array keeps serving when both virtual texture tiers are off")

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS sparse virtual texture far field")
	quit()
