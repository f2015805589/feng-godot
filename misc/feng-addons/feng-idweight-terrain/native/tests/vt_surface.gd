# Run with a graphical rendering driver; see README.md in this directory.
#
# Surface page production: the demand pass picks a mip per sector from its distance,
# asks the virtual texture for the pages of that mip, and fills the ones that were
# newly allocated by resampling the region's surface map. The pages are read back
# from the GPU atlas and compared texel by texel, so this pins the crop origin, the
# mip pyramid and the clamped border, not just "something got written".
extends SceneTree

const REGION_SIZE := 64
const PAGES_PER_AXIS := 4
const PAGE := 16
const BORDER := 2
const STORED := PAGE + 2 * BORDER
const INVALID := 65535

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
# Regions the pattern was written to; a border texel outside all of them is material 0.
var pattern_locs: Array = []

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# Every texel of a region's surface map is distinguishable, so a page's crop origin
# can be recovered from its content alone.
func region_base(loc: Vector2i) -> int:
	return 1000 + (loc.x + 8) * 100 + (loc.y + 8) * 10

func expected(loc: Vector2i, i: int, j: int) -> int:
	return region_base(loc) + i * 4 + j

func write_pattern(loc: Vector2i) -> void:
	var base := region_base(loc)
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	for j in REGION_SIZE:
		for i in REGION_SIZE:
			bytes.encode_u16((j * REGION_SIZE + i) * 2, base + i * 4 + j)
	terrain.data.get_region(loc).set_surface_map(
			Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))

# The producer's rule, restated independently: page texel -> region texel, nearest. A
# texel whose region coordinate falls outside the region belongs to a neighbouring
# region, so the expectation is that region's pattern at its own local texel -- the
# border is no longer a clamped copy of this region's edge.
func expected_world(world_x: float, world_z: float) -> int:
	var rx := int(floor(world_x / REGION_SIZE))
	var rz := int(floor(world_z / REGION_SIZE))
	var loc := Vector2i(rx, rz)
	if not pattern_locs.has(loc):
		return 0
	var i := int(floor(world_x)) - rx * REGION_SIZE
	var j := int(floor(world_z)) - rz * REGION_SIZE
	return expected(loc, i, j)

func check_page(loc: Vector2i, slot: int, local_mip: int, px: int, py: int) -> void:
	var vt := terrain.get_surface_vt()
	var page := vt.read_page(slot)
	require(page != null and not page.is_empty(), "page slot %d should be readable" % slot)
	if page == null or page.is_empty():
		return
	var bytes := page.get_data()
	var pages_at_mip := maxi(1, PAGES_PER_AXIS >> local_mip)
	var span := REGION_SIZE / pages_at_mip
	var origin_x := px * span
	var origin_y := py * span
	var base_x := loc.x * REGION_SIZE
	var base_z := loc.y * REGION_SIZE
	var bad := 0
	var first := ""
	for y in STORED:
		var ry := origin_y + ((y - BORDER) * span) / PAGE
		var world_z := float(base_z + ry)
		for x in STORED:
			var rx := origin_x + ((x - BORDER) * span) / PAGE
			var world_x := float(base_x + rx)
			var want := expected_world(world_x, world_z)
			var got := bytes.decode_u16((y * STORED + x) * 2)
			if got != want:
				bad += 1
				if first == "":
					first = "texel (%d,%d) got %d want %d from world (%.1f,%.1f)" % [x, y, got, want, world_x, world_z]
	require(bad == 0, "%s mip %d page (%d,%d): %d bad texels, first %s" % [loc, local_mip, px, py, bad, first])

func check_sector(loc: Vector2i, local_mip: int) -> void:
	var vt := terrain.get_surface_vt()
	var pages_at_mip := maxi(1, PAGES_PER_AXIS >> local_mip)
	for py in pages_at_mip:
		for px in pages_at_mip:
			var slot: int = vt.lookup_page(loc, local_mip, px, py)
			require(slot >= 0, "%s mip %d page (%d,%d) should be resident" % [loc, local_mip, px, py])
			if slot >= 0:
				check_page(loc, slot, local_mip, px, py)

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	# Verify the ID/weight residency contract separately from material baking.
	terrain.set_vt_debug_direct_material(true)
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(REGION_SIZE * 0.5, 40.0, REGION_SIZE * 0.5)
	terrain.region_size = REGION_SIZE
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame

	terrain.surface_vt_page_size = PAGE
	terrain.surface_vt_page_border = BORDER
	# Mip 0 needs one physical page per page of every sector, so the atlas has to be
	# at least sectors * pages_per_axis squared. Sizing it smaller makes the LRU
	# evict pages the test is about to look for.
	var sector_count := 3
	terrain.surface_vt_page_count = sector_count * PAGES_PER_AXIS * PAGES_PER_AXIS
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = 512.0
	require(terrain.surface_vt_page_size == PAGE, "page size should be applied")
	require(terrain.surface_vt_pages_per_axis == PAGES_PER_AXIS, "pages per axis should be applied")
	require(terrain.surface_vt_page_count >= sector_count * PAGES_PER_AXIS * PAGES_PER_AXIS,
			"the atlas must hold every mip 0 page of every sector")

	var locs := [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)]
	pattern_locs = locs
	for loc in locs:
		terrain.data.add_region_blank(loc)
		write_pattern(loc)
	terrain.data.update_maps()

	var vt := terrain.get_surface_vt()
	require(vt != null and vt.is_initialized(), "Terrain3D should own an initialized surface vt")
	require(vt.get_page_size() == PAGE and vt.get_page_border() == BORDER, "vt should carry the page settings")

	# Forced mip 0: 4x4 pages per sector, each a 1:1 crop of a 16 texel square of the
	# 64 texel region map, because span == page_size at this configuration.
	terrain.set_surface_vt_force_mip(true, 0)
	var produced := terrain.update_surface_vt()
	require(produced == locs.size() * 16, "mip 0 should produce 16 pages per sector, got " + str(produced))
	var dbg := terrain.get_surface_vt()
	var dox: int = dbg.get_sector_block_origin_x(Vector2i.ZERO)
	var doy: int = dbg.get_sector_block_origin_y(Vector2i.ZERO)
	print("VTSURF produced=", produced, " block=", dbg.get_sector_block_size(Vector2i.ZERO),
			" origin=(", dox, ",", doy, ") indirection=", dbg.get_indirection_size(),
			" levels=", dbg.get_level_count(),
			" ind0=", dbg.get_indirection_slot(dox, doy, 0),
			" lookup=", dbg.lookup_page(Vector2i.ZERO, 0, 0, 0),
			" stats=", dbg.get_stats())
	if not failed:
		for loc in locs:
			check_sector(loc, 0)
	if not failed:
		print("PASS surface vt mip 0 pages are exact 1:1 crops with a clamped border")

	# Forced mip 1: 2x2 pages per sector, span 32 region texels into 16 page texels.
	terrain.set_surface_vt_force_mip(true, 1)
	produced = terrain.update_surface_vt()
	require(produced == locs.size() * 4, "mip 1 should produce 4 pages per sector, got " + str(produced))
	if not failed:
		for loc in locs:
			check_sector(loc, 1)
	if not failed:
		print("PASS surface vt mip 1 pages downsample by two with the same crop origin")

	# The distance rule, on a fresh atlas. The target sits on region (0,0)'s centre:
	# (0,0) is at distance 0 so it wants mip 0, while (1,0) and (0,1) are 64 m away
	# and page_world_size is region_size / pages_per_axis = 16, threshold 32, so they
	# want mip 1.
	vt.clear()
	require(not vt.is_initialized(), "clear should release the atlas")
	camera.position = Vector3(REGION_SIZE * 0.5, 40.0, REGION_SIZE * 0.5)
	terrain.snap()
	terrain.set_surface_vt_force_mip(false)
	produced = terrain.update_surface_vt()
	require(produced == 16 + 4 + 4, "distance rule should produce 16 + 4 + 4 pages, got " + str(produced))
	vt = terrain.get_surface_vt()
	var near: Vector2i = Vector2i.ZERO
	var ox: int = vt.get_sector_block_origin_x(near)
	var oy: int = vt.get_sector_block_origin_y(near)
	require(vt.get_indirection_slot(ox, oy, 0) != INVALID, "the nearest sector should publish a mip 0 page")
	for far in [Vector2i(1, 0), Vector2i(0, 1)]:
		var fx: int = vt.get_sector_block_origin_x(far)
		var fy: int = vt.get_sector_block_origin_y(far)
		require(vt.get_indirection_slot(fx, fy, 0) == INVALID,
				"%s is 64 m away and must not publish a mip 0 page" % far)
		require(vt.get_indirection_slot(fx >> 1, fy >> 1, 1) != INVALID,
				"%s should publish a mip 1 page instead" % far)
	if not failed:
		print("PASS surface vt picks the mip from distance, fine near and coarse far")

	# A second pass with nothing changed must not re-produce or re-upload anything.
	vt.reset_stats()
	produced = terrain.update_surface_vt()
	require(produced == 0, "a settled pass should produce nothing, got " + str(produced))
	require(int(vt.get_stats()["page_write_count"]) == 0, "a settled pass should not rewrite pages")
	require(int(vt.get_stats()["commit_count"]) == 0, "a settled pass should not re-upload the indirection")
	if not failed:
		print("PASS surface vt is idle once the demand set is satisfied")
	vt.clear()
	var batch := terrain.update_surface_vt(2)
	require(batch > 0 and batch <= 2, "budgeted near-field update must produce at most two pages")
	var total := batch
	for step in 32:
		batch = terrain.update_surface_vt(2)
		require(batch <= 2, "each near-field update must respect its budget")
		total += batch
		if batch == 0:
			break
	require(total == 24, "budgeted demand must converge to the full working set")
	# Upsampled border coordinates are fractional and negative. Truncating them
	# to zero samples this region instead of the neighbour and creates VT seams.
	terrain.surface_vt_page_size = 64
	terrain.set_surface_vt_force_mip(true, 0)
	terrain.update_surface_vt()
	vt = terrain.get_surface_vt()
	var left_page := vt.read_page(vt.lookup_page(Vector2i(1, 0), 0, 0, 0))
	var top_page := vt.read_page(vt.lookup_page(Vector2i(0, 1), 0, 0, 0))
	require(int(round(left_page.get_pixel(BORDER - 1, BORDER + 32).r * 65535.0)) == expected(Vector2i.ZERO, 63, 8),
			"upsampled left border samples the adjacent region")
	require(int(round(top_page.get_pixel(BORDER + 32, BORDER - 1).r * 65535.0)) == expected(Vector2i.ZERO, 8, 63),
			"upsampled top border samples the adjacent region")

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS surface virtual texture page production")
	quit()
