# Run with a graphical rendering driver; see README.md in this directory.
#
# Per-page demand. With GPU feedback on, the mip is chosen per mip 0 page instead of
# per sector, so one sector can hold pages at several levels at once and pages that
# are behind the camera or too small are not requested at all. The projection rule is
# restated in GDScript, then Terrain3D::update_surface_vt() is driven and the resident
# set is compared page by page through the indirection texture. That pins the wiring
# (feedback window origin, page coordinates, level grouping, production order) rather
# than the shader alone, and the page contents are read back so a page that is resident
# but filled from the wrong region texel still fails.
extends SceneTree

const REGION_SIZE := 64
const PAGES_PER_AXIS := 4
const PAGE := 64
const BORDER := 2
const STORED := PAGE + 2 * BORDER
const INVALID := 65535
# The feedback window is grid_chunks chunks per axis, centred on the camera's chunk.
const GRID_CHUNKS := 12
const MAX_LOCAL_MIP := 2
# A page whose screen extent falls below this is culled instead of requested. Set
# explicitly so the test states the value it verifies rather than assuming the default.
const MIN_EXTENT := 8.0
const PAGE_WORLD := float(REGION_SIZE) / float(PAGES_PER_AXIS) # 16 m
const PAGE_COUNT := 1024

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
# Regions the pattern was written to; a border texel outside all of them is material 0.
var pattern_locs: Array = []
# Read from the camera: the runtime measures extents in real viewport pixels, and the
# window size is not fixed (the runner passes --resolution).
var viewport_size := Vector2i(1280, 720)

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# The same rule the compute shader implements, written out separately. A page is
# culled (-1) when a corner is behind the camera, when it is off screen, or when its
# screen extent is below the floor; otherwise the mip is the one that puts about one
# page texel on one screen pixel.
func expected_mip(vp: Projection, origin: Vector2) -> int:
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for i in 4:
		var corner: Vector2 = origin + Vector2(float(i & 1), float((i >> 1) & 1)) * PAGE_WORLD
		var clip: Vector4 = vp * Vector4(corner.x, 0.0, corner.y, 1.0)
		if clip.w <= 0.0:
			return -1
		var uv := Vector2(clip.x, clip.y) / clip.w * 0.5 + Vector2(0.5, 0.5)
		mn = mn.min(uv)
		mx = mx.max(uv)
	if mx.x < 0.0 or mx.y < 0.0 or mn.x > 1.0 or mn.y > 1.0:
		return -1
	var extent_px := (mx - mn).max(Vector2.ZERO) * Vector2(viewport_size)
	var extent := maxf(extent_px.x, extent_px.y)
	if extent < MIN_EXTENT:
		return -1
	# GDScript has no log2(); the shader uses GLSL's log2, so restate it the same way.
	var mip := int(floor(log(maxf(float(PAGE) / extent, 1.0)) / log(2.0)))
	return clampi(mip, 0, MAX_LOCAL_MIP)

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
# region, so the expectation is that region's pattern at its own local texel.
func expected_world(world_x: float, world_z: float) -> int:
	var rx := int(floor(world_x / REGION_SIZE))
	var rz := int(floor(world_z / REGION_SIZE))
	var loc := Vector2i(rx, rz)
	if not pattern_locs.has(loc):
		return 0
	var i := int(floor(world_x)) - rx * REGION_SIZE
	var j := int(floor(world_z)) - rz * REGION_SIZE
	return expected(loc, i, j)

# Floor division for the page-to-world mapping: GDScript's `/` truncates toward zero,
# while the producer floors, and border texels sit at negative offsets from the origin.
func floor_div(p_value: int, p_divisor: int) -> int:
	return int(floor(float(p_value) / float(p_divisor)))

func check_page(loc: Vector2i, slot: int, local_mip: int, px: int, py: int) -> void:
	var page := terrain.get_surface_vt().read_page(slot)
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
		# Border texels sit before the page origin, so the producer's floor division and
		# GDScript's truncating `/` differ there. Floor explicitly, or every border row
		# and column of every page is reported as a mismatch.
		var ry := origin_y + floor_div((y - BORDER) * span, PAGE)
		var world_z := float(base_z + ry)
		for x in STORED:
			var rx := origin_x + floor_div((x - BORDER) * span, PAGE)
			var world_x := float(base_x + rx)
			var want := expected_world(world_x, world_z)
			var got := bytes.decode_u16((y * STORED + x) * 2)
			if got != want:
				bad += 1
				if first == "":
					first = "texel (%d,%d) got %d want %d from world (%.1f,%.1f)" % [x, y, got, want, world_x, world_z]
	require(bad == 0, "%s mip %d page (%d,%d): %d bad texels, first %s" % [loc, local_mip, px, py, bad, first])

# The exact level entry, not lookup_page: that one walks the mip chain, so it cannot
# tell "this level is resident" from "a finer level covers it".
func resident(loc: Vector2i, local_mip: int, px: int, py: int) -> bool:
	var vt := terrain.get_surface_vt()
	var bx: int = vt.get_sector_block_origin_x(loc) >> local_mip
	var by: int = vt.get_sector_block_origin_y(loc) >> local_mip
	return vt.get_indirection_slot(bx + px, by + py, local_mip) != INVALID

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
	camera.fov = 60.0
	camera.near = 0.1
	camera.far = 4000.0
	# Tilted rather than straight down, and looking along +Z at the grid: a top-down
	# camera only sees about 115 m of ground, so every visible page would legitimately
	# want mip 0 and there would be no gradient. A Godot camera looks down -Z, so
	# Y = 180 turns it toward the grid.
	camera.position = Vector3(REGION_SIZE * 0.5 * 8.0, 40.0, -120.0)
	camera.rotation_degrees = Vector3(-12.0, 180.0, 0.0)
	terrain.region_size = REGION_SIZE
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame

	terrain.surface_vt_page_size = PAGE
	terrain.surface_vt_page_border = BORDER
	terrain.surface_vt_page_count = PAGE_COUNT
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_feedback_enabled = true
	terrain.surface_vt_feedback_interval = 1
	terrain.surface_vt_feedback_grid_chunks = GRID_CHUNKS
	terrain.surface_vt_feedback_min_extent = MIN_EXTENT
	require(terrain.is_surface_vt_feedback_enabled(), "feedback should be enabled")
	require(terrain.get_surface_vt_feedback_interval() == 1, "the interval should be applied")
	require(terrain.get_surface_vt_feedback_grid_chunks() == GRID_CHUNKS, "the grid size should be applied")
	require(is_equal_approx(terrain.get_surface_vt_feedback_min_extent(), MIN_EXTENT),
			"the minimum screen extent should be applied")

	# A 5x5 block of regions, plus one behind the camera to check the cull.
	var locs: Array[Vector2i] = []
	for y in range(-2, 3):
		for x in range(2, 7):
			locs.append(Vector2i(x, y))
	locs.append(Vector2i(4, -6))
	pattern_locs = locs
	for loc in locs:
		terrain.data.add_region_blank(loc)
		write_pattern(loc)
	terrain.data.update_maps()

	# The camera's chunk and the window the runtime should derive from it.
	var camera_chunk: Vector2i = terrain.data.get_region_location(terrain.get_clipmap_target_position())
	var origin := camera_chunk - Vector2i(GRID_CHUNKS / 2, GRID_CHUNKS / 2)
	viewport_size = camera.get_viewport().get_visible_rect().size
	var vp: Projection = camera.get_camera_projection() * Projection(camera.global_transform.affine_inverse())

	# The demand the runtime should arrive at, computed independently. Keyed by sector
	# first: two sectors hold pages with identical page coordinates.
	var wanted := {}
	var per_sector := {}
	var wanted_count := 0
	var culled := 0
	for loc in locs:
		var pages := {}
		var levels := {}
		for py in PAGES_PER_AXIS:
			for px in PAGES_PER_AXIS:
				var page_origin := Vector2(loc.x * REGION_SIZE + px * PAGE_WORLD,
						loc.y * REGION_SIZE + py * PAGE_WORLD)
				var mip := expected_mip(vp, page_origin)
				if mip < 0:
					culled += 1
					continue
				levels[mip] = int(levels.get(mip, 0)) + 1
				var key := Vector3i(px >> mip, py >> mip, mip)
				if not pages.has(key):
					pages[key] = true
					wanted_count += 1
		wanted[loc] = pages
		per_sector[loc] = levels
	var mixed := 0
	for loc in locs:
		if per_sector[loc].size() > 1:
			mixed += 1
	# Without a sector that spans a mip boundary this test would pass on the old
	# per-sector rule too, so the configuration itself is checked.
	require(mixed > 0, "the configuration must put at least two levels inside one sector")
	require(culled > 0, "the configuration must cull at least one page")
	print("VTDEMAND sectors=", locs.size(), " mixed_level_sectors=", mixed,
			" culled_pages=", culled, " expected_pages=", wanted_count)
	print("VTDEMAND viewport=", viewport_size,
			" camera=", camera.global_position, " target=", terrain.get_clipmap_target_position(),
			" chunk=", camera_chunk, " origin=", origin)

	# First demand pass: every expected page is produced and filled.
	var produced := terrain.update_surface_vt()
	var feedback := terrain.get_surface_vt_feedback()
	require(feedback != null, "Terrain3D should own a feedback pass")
	if feedback == null:
		quit(1)
		return
	require(feedback.is_initialized(), "the feedback pass should be initialized")
	require(feedback.has_result(), "the first demand pass should have a readback result")
	require(feedback.get_grid_width() == GRID_CHUNKS * PAGES_PER_AXIS,
			"the grid should be grid_chunks * pages_per_axis, got " + str(feedback.get_grid_width()))

	# The mip the runtime reads for each page, through the same window it used.
	var mismatches := 0
	var first := ""
	for loc in locs:
		for py in PAGES_PER_AXIS:
			for px in PAGES_PER_AXIS:
				var page_origin := Vector2(loc.x * REGION_SIZE + px * PAGE_WORLD,
						loc.y * REGION_SIZE + py * PAGE_WORLD)
				var want := expected_mip(vp, page_origin)
				var got: int = feedback.get_mip_for_page(loc, PAGES_PER_AXIS, px, py, origin)
				if got != want:
					mismatches += 1
					if first == "":
						first = "%s page (%d,%d) got %d want %d" % [loc, px, py, got, want]
	require(mismatches == 0, "%d pages disagree with the expected mip, first %s" % [mismatches, first])
	if mismatches > 0:
		for loc in locs:
			var line := "%s:" % loc
			for py in PAGES_PER_AXIS:
				for px in PAGES_PER_AXIS:
					line += " %d" % feedback.get_mip_for_page(loc, PAGES_PER_AXIS, px, py, origin)
			print("VTDEMANDGOT", line)
	if not failed:
		print("PASS vt demand resolves a mip per page through the runtime's own window")

	# Every wanted page is resident at its own level, and nothing else is.
	var missing := 0
	var missing_first := ""
	var extra := 0
	var extra_first := ""
	for loc in locs:
		for mip in range(MAX_LOCAL_MIP + 1):
			var at := maxi(1, PAGES_PER_AXIS >> mip)
			for py in at:
				for px in at:
					var key := Vector3i(px, py, mip)
					var is_wanted: bool = wanted.has(loc) and wanted[loc].has(key)
					var is_resident := resident(loc, mip, px, py)
					if is_wanted and not is_resident:
						missing += 1
						if missing_first == "":
							missing_first = "%s mip %d page (%d,%d)" % [loc, mip, px, py]
					elif is_resident and not is_wanted:
						extra += 1
						if extra_first == "":
							extra_first = "%s mip %d page (%d,%d)" % [loc, mip, px, py]
	require(missing == 0, "%d demanded pages are not resident, first %s" % [missing, missing_first])
	require(extra == 0, "%d pages are resident without being demanded, first %s" % [extra, extra_first])
	require(produced == wanted_count, "the pass should produce %d pages, got %d" % [wanted_count, produced])
	if not failed:
		print("PASS vt demand keeps exactly the demanded pages resident, at their own level")

	# The region behind the camera is inside the window and inside the distance, so a
	# distance rule would have given it pages. The cull is the reason it has none.
	var behind := Vector2i(4, -6)
	var behind_pages := 0
	for mip in range(MAX_LOCAL_MIP + 1):
		var at := maxi(1, PAGES_PER_AXIS >> mip)
		for py in at:
			for px in at:
				if resident(behind, mip, px, py):
					behind_pages += 1
	require(behind_pages == 0, "a sector behind the camera must not get pages, got " + str(behind_pages))
	require(int(per_sector[behind].size()) == 0, "the expected rule must also cull that sector")
	require(terrain.data.get_region_id(behind) >= 0, "the sector behind the camera should still be resident")
	if not failed:
		print("PASS vt demand culls a sector behind the camera that a distance rule would keep")

	# Content, for the pages the levels above did not already pin: every resident page
	# must be the resample of its own region, at its own mip.
	if not failed:
		for loc in locs:
			for mip in range(MAX_LOCAL_MIP + 1):
				var at := maxi(1, PAGES_PER_AXIS >> mip)
				for py in at:
					for px in at:
						if resident(loc, mip, px, py):
							check_page(loc, terrain.get_surface_vt().lookup_page(loc, mip, px, py), mip, px, py)
	if not failed:
		print("PASS vt demand fills every page from its own region at its own level")

	# A second pass with nothing changed must not re-produce or re-upload anything,
	# even though the feedback runs again and returns the same demand.
	var vt := terrain.get_surface_vt()
	vt.reset_stats()
	produced = terrain.update_surface_vt()
	require(produced == 0, "a settled pass should produce nothing, got " + str(produced))
	require(int(vt.get_stats()["page_write_count"]) == 0, "a settled pass should not rewrite pages")
	require(int(vt.get_stats()["commit_count"]) == 0, "a settled pass should not re-upload the indirection")
	if not failed:
		print("PASS vt demand is idle once the per-page demand set is satisfied")

	# Turning the feedback off must fall back to the per-sector distance rule, so the
	# feature is not silently load-bearing for the existing path.
	terrain.surface_vt_feedback_enabled = false
	vt.clear()
	terrain.set_surface_vt_force_mip(true, 0)
	produced = terrain.update_surface_vt()
	require(produced == locs.size() * PAGES_PER_AXIS * PAGES_PER_AXIS,
			"forced mip 0 should produce 16 pages for every sector, got " + str(produced))
	if not failed:
		print("PASS vt demand falls back to the forced mip with the feedback off")

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS virtual texture per-page demand")
	quit()
