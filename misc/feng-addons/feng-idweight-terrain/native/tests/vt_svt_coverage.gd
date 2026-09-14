# Real-material SVT coverage under a deliberately tiny shared AVT/SVT pool.
# The test bakes persisted pages, invalidates their resident copies, poisons the
# source texture array, then checks the material actually drawn at visible points.
extends "res://vt_render_base.gd"

const GRID_SIZE := 12
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_WORLD := 64.0
const INITIAL_MAX_MIP := 1
const PAGE_COUNT := 8
const PAGES_PER_UPDATE := 1
const OLD_WORLD_RADIUS := 64.0
const MIN_VISIBLE_POINTS := 12

var region_locations: Array[Vector2i] = []

func material_id(p_location: Vector2i) -> int:
	return posmod(p_location.x + p_location.y, 2)

func expected_class(p_location: Vector2i) -> String:
	return "r" if material_id(p_location) == 0 else "g"

func write_region(p_location: Vector2i) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var asset_id := material_id(p_location)
	var word := (asset_id << 11) | (asset_id << 6)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(p_location)
	region.set_surface_map(Image.create_from_data(
			REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func camera_region() -> Vector2i:
	return Vector2i(floori(camera.global_position.x / REGION_SIZE),
			floori(camera.global_position.z / REGION_SIZE))

func focus_avt_region(p_location: Vector2i) -> void:
	# Target Grid is anchored on the camera's region. Move the offset so exactly
	# one loaded AVT region remains selected even while the camera moves.
	terrain.surface_vt_region_offset = p_location - camera_region()

func tick() -> void:
	await physics_frame
	await process_frame

func ready_svt_slots() -> Dictionary:
	var result := {}
	for record: Dictionary in terrain.get_vt_pages():
		if record.get("kind", "") == "SVT" and bool(record.get("ready", false)):
			result[int(record.get("slot", -1))] = true
	return result

func visible_far_points() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var image_size: Vector2 = camera.get_viewport().get_visible_rect().size
	var target: Vector3 = terrain.get_clipmap_target_position()
	var near_vt: Terrain3DVirtualTexture = terrain.get_surface_vt()
	for z in GRID_SIZE:
		for x in GRID_SIZE:
			var location := Vector2i(x, z)
			if near_vt.has_sector(location):
				continue
			var world := Vector2((x + 0.5) * REGION_SIZE, (z + 0.5) * REGION_SIZE)
			var world_point := Vector3(world.x, 0.0, world.y)
			if camera.is_position_behind(world_point):
				continue
			var screen := camera.unproject_position(world_point)
			if screen.x < 6.0 or screen.y < 6.0 or screen.x >= image_size.x - 6.0 or screen.y >= image_size.y - 6.0:
				continue
			if Vector2(world.x - target.x, world.y - target.z).length() <= OLD_WORLD_RADIUS:
				continue
			result.push_back({"location": location, "world": world, "screen": screen})
	return result

func point_svt_slot(p_world: Vector2) -> int:
	var page_x := floori(p_world.x / PAGE_WORLD)
	var page_y := floori(p_world.y / PAGE_WORLD)
	return terrain.get_surface_svt().lookup_world_page(page_x, page_y, 0)

func all_visible_points_ready(p_points: Array[Dictionary]) -> bool:
	var ready := ready_svt_slots()
	for point: Dictionary in p_points:
		var slot := point_svt_slot(point["world"])
		if slot < 0 or not ready.has(slot):
			return false
	return true

func has_incremental_bake(p_settings: Dictionary, p_generation: int) -> bool:
	return int(p_settings.get("bake_generation", 0)) > p_generation and bool(p_settings.get("bake_incremental", false))

func wait_for_visible_coverage(p_phase: String, p_limit: int = 2400,
		p_generation: int = -1, p_required_mip: int = -1) -> Array[Dictionary]:
	var stable_frames := 0
	var points: Array[Dictionary] = []
	var repair_seen := p_generation < 0
	for frame in p_limit:
		await tick()
		points = visible_far_points()
		var settings: Dictionary = terrain.get_vt_settings()
		var producer: Dictionary = settings.get("producer", {})
		var idle := int(settings.get("bake_pending", 0)) == 0 and int(settings.get("auto_pending_regions", 0)) == 0 and int(producer.get("pending", 0)) == 0
		if has_incremental_bake(settings, p_generation):
			repair_seen = true
		var mip_ready := p_required_mip < 0 or terrain.get_surface_svt().get_world_max_mip() >= p_required_mip
		if points.size() >= MIN_VISIBLE_POINTS and all_visible_points_ready(points) and idle and mip_ready and repair_seen:
			stable_frames += 1
		else:
			stable_frames = 0
		if stable_frames >= 4:
			print("VTSVTCOVER_READY phase=%s points=%d mip=%d generation=%d incremental=%s producer=%s" % [
					p_phase, points.size(), terrain.get_surface_svt().get_world_max_mip(),
					int(settings.get("bake_generation", 0)), str(bool(settings.get("bake_incremental", false))),
					str(terrain.get_vt_settings().get("producer", {}))])
			return points
	var final_settings: Dictionary = terrain.get_vt_settings()
	print("VTSVTCOVER_TIMEOUT phase=%s points=%d mip=%d generation=%d incremental=%s repair_seen=%s settings=%s ready=%s pages=%s" % [
			p_phase, points.size(), terrain.get_surface_svt().get_world_max_mip(),
			int(final_settings.get("bake_generation", 0)), str(bool(final_settings.get("bake_incremental", false))), str(repair_seen), str(final_settings),
			str(all_visible_points_ready(points)), str(terrain.get_vt_pages())])
	return points

func check_visible_frame(p_phase: String, p_points: Array[Dictionary]) -> bool:
	var image := await frame_image()
	image.save_png(output_dir.path_join("svt-coverage-%s.png" % p_phase))
	var ready := ready_svt_slots()
	var valid := true
	for point: Dictionary in p_points:
		var location: Vector2i = point["location"]
		var world: Vector2 = point["world"]
		var slot := point_svt_slot(world)
		var has_ready_page := slot >= 0 and ready.has(slot)
		var actual := sample_area(image, world, 3)
		var expected := expected_class(location)
		if not has_ready_page or actual != expected:
			valid = false
			print("VTSVTCOVER_MISS phase=%s region=%s world=%s slot=%d ready=%s expected=%s actual=%s screen=%s" % [
					p_phase, str(location), str(world), slot, str(has_ready_page), expected, actual, str(point["screen"])])
			require(has_ready_page, "%s visible non-AVT region %s has no ready persisted SVT owner" % [p_phase, location])
			require(actual == expected, "%s visible non-AVT region %s expected %s material, got %s" % [p_phase, location, expected, actual])
	print("VTSVTCOVER_FRAME phase=%s points=%d all_valid=%s max_mip=%d" % [
			p_phase, p_points.size(), str(valid), terrain.get_surface_svt().get_world_max_mip()])
	return valid

func work_snapshot() -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	var producer: Dictionary = settings.get("producer", {})
	var residency: Dictionary = settings.get("residency", {})
	return {
		"baked": int(producer.get("baked_pages", 0)),
		"cached": int(producer.get("cached_uploads", 0)),
		"source": int(producer.get("source_uploads", 0)),
		"pending": int(producer.get("pending", 0)),
		"alloc": int(residency.get("alloc_count", 0)),
		"evict": int(residency.get("evict_count", 0)),
	}

func wait_for_bake(p_total: int) -> void:
	var idle_frames := 0
	for frame in 1200:
		await tick()
		var settings: Dictionary = terrain.get_vt_settings()
		if int(settings.get("bake_pending", 1)) == 0 and int(settings.get("bake_done", 0)) >= p_total:
			idle_frames += 1
		else:
			idle_frames = 0
		if idle_frames >= 4:
			return
	require(false, "full SVT bake did not complete within 1200 frames: %s" % str(terrain.get_vt_settings()))

func wait_for_hierarchy_growth(p_previous_mip: int, p_limit: int = 360) -> int:
	for frame in p_limit:
		await tick()
		var mip := terrain.get_surface_svt().get_world_max_mip()
		if mip > p_previous_mip:
			return mip
	require(false, "the moved view did not extend SVT hierarchy beyond mip %d" % p_previous_mip)
	return terrain.get_surface_svt().get_world_max_mip()

# A persisted bake is one file per cell holding the full mip chain, so the catalogue reports a
# cell (mip 0), not a level: asking it for "mip 4" is always false. The pixel checks below are
# what prove the served pages came from the persisted bake.

func poison_source_albedo() -> void:
	var material_rid: RID = terrain.material.get_material_rid()
	var source_albedo: Variant = RenderingServer.material_get_param(material_rid, "_texture_array_albedo")
	var poison := Texture2DArray.new()
	var blue := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	blue.fill(Color.BLUE)
	blue.generate_mipmaps()
	poison.create_from_images([blue, blue])
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	set_meta("_coverage_source_albedo", source_albedo)
	set_meta("_coverage_poison_albedo", poison)

func restore_source_albedo() -> void:
	var material_rid: RID = terrain.material.get_material_rid()
	var source_albedo: Variant = get_meta("_coverage_source_albedo", null)
	if source_albedo is RID:
		RenderingServer.material_set_param(material_rid, "_texture_array_albedo", source_albedo)

func prepare_camera(p_position: Vector3, p_target: Vector3, p_avt_region: Vector2i) -> void:
	camera.position = p_position
	camera.look_at(p_target, Vector3.UP)
	focus_avt_region(p_avt_region)
	terrain.set_clipmap_target(camera)
	terrain.snap()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute("user://svt-coverage")

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = REGION_SIZE
	terrain.vt_debug_direct_material = false
	terrain.free_editor_textures = false
	terrain.data_directory = "user://svt-coverage"
	terrain.surface_svt_auto_bake = false
	terrain.set_vt_page_size(PAGE_SIZE)
	terrain.set_vt_page_border(PAGE_BORDER)
	terrain.set_vt_page_count(PAGE_COUNT)
	terrain.set_vt_pages_per_update(PAGES_PER_UPDATE)
	terrain.set_vt_adaptive_enabled(true)
	terrain.surface_vt_pages_per_axis = 4
	terrain.surface_vt_selection_mode = 1 # Target Grid; exactly one AVT region.
	terrain.surface_vt_region_grid = Vector2i.ONE
	terrain.surface_vt_region_offset = Vector2i(0, 5)
	terrain.surface_vt_distance = OLD_WORLD_RADIUS
	terrain.surface_svt_page_world = PAGE_WORLD
	terrain.surface_svt_max_mip = INITIAL_MAX_MIP
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_distance = OLD_WORLD_RADIUS
	scene.add_child(terrain)
	root.add_child(scene)

	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, Color.RED if id == 0 else Color.GREEN)
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)

	camera = Camera3D.new()
	camera.position = Vector3(160.0, 320.0, -160.0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 320.0
	camera.near = 0.1
	camera.far = 10000.0
	root.add_child(camera)
	camera.look_at(Vector3(160.0, 0.0, 160.0), Vector3.UP)
	camera.current = true
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -20.0, 0.0)
	scene.add_child(light)
	for frame in 3:
		await process_frame
	terrain.region_size = REGION_SIZE
	terrain.change_surface_density(1)

	for z in GRID_SIZE:
		for x in GRID_SIZE:
			var location := Vector2i(x, z)
			region_locations.push_back(location)
			terrain.data.add_region_blank(location)
			write_region(location)
	terrain.data.update_maps()
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	await process_frame

	require(int(terrain.get_vt_settings().get("page_count", 0)) == PAGE_COUNT,
			"test must use the minimum eight-page shared cache")
	require(bool(terrain.get_vt_settings().get("shared_pool", false)), "AVT and SVT must share one physical pool")
	require(terrain.get_surface_vt_region_rect() == Rect2i(Vector2i(2, 2), Vector2i.ONE),
			"AVT must cover only center region (2,2), got %s" % str(terrain.get_surface_vt_region_rect()))

	# Keep the serialized cap at mip 1. Runtime view demand may grow it to cover all
	# visible terrain within the four-page SVT share.
	var configured := false
	for frame in 360:
		await tick()
		if terrain.get_surface_vt().has_sector(Vector2i(2, 2)) and \
				terrain.get_surface_vt().get_sector_block_size(Vector2i(2, 2)) == 1 and \
				terrain.get_surface_svt().get_world_max_mip() > INITIAL_MAX_MIP:
			configured = true
			break
	require(configured, "scheduler did not shrink AVT to one page and extend SVT beyond configured mip 1")
	print("VTSVTCOVER_SETUP regions=%d cache=%d budget=%d avt_block=%d initial_mip=%d active_mip=%d view=%s" % [
			region_locations.size(), PAGE_COUNT, PAGES_PER_UPDATE,
			terrain.get_surface_vt().get_sector_block_size(Vector2i(2, 2)), INITIAL_MAX_MIP,
			terrain.get_surface_svt().get_world_max_mip(), str(terrain.get_vt_settings().get("avt_region_rect"))])

	var initial_points := visible_far_points()
	require(initial_points.size() >= MIN_VISIBLE_POINTS,
			"the first camera view must include many visible non-AVT regions beyond %dm, got %d" % [OLD_WORLD_RADIUS, initial_points.size()])
	# Enable auto-bake for the whole regression, then immediately launch the initial
	# full bake. bake_svt() consumes the setter's initial dirty set; later hierarchy
	# extensions must be handled by automatic incremental jobs.
	terrain.surface_svt_auto_bake = true
	var queued := terrain.bake_svt()
	require(queued > 0, "full SVT bake should queue actual world pages")
	print("VTSVTCOVER_BAKE queued=%d max_mip=%d" % [queued, terrain.get_surface_svt().get_world_max_mip()])
	await wait_for_bake(queued)
	var after_bake: Dictionary = terrain.get_vt_settings()
	require(int(after_bake.get("bake_done", 0)) == queued, "manual full bake must persist every queued page")
	require(int(after_bake.get("bake_failed", 0)) == 0, "manual full bake should not fail: %s" % str(after_bake.get("bake_error", "")))
	var initial_generation := int(after_bake.get("bake_generation", 0))
	var tiles: Array = terrain.get_svt_baked_pages()
	require(tiles.size() >= queued, "all manually baked SVT pages should be persisted and catalogued, got %d for %d" % [tiles.size(), queued])
	print("VTSVTCOVER_BAKED tiles=%d stats=%s" % [tiles.size(), str(terrain.get_vt_settings().get("producer", {}))])

	# Force runtime to restore tiles from disk rather than merely retaining the bake
	# render targets. A blue source binding is deliberately wrong for every test region;
	# only a valid cached SVT page can produce the authored red/green checkerboard.
	for location: Vector2i in region_locations:
		terrain.invalidate_surface_pages(location)
	poison_source_albedo()
	var cache_before := work_snapshot()
	var first_view := await wait_for_visible_coverage("first")
	require(first_view.size() >= MIN_VISIBLE_POINTS, "first view lost visible non-AVT sample points")
	var cached_after_first := work_snapshot()
	require(cached_after_first.cached > cache_before.cached,
			"runtime demand should upload previously persisted SVT material pages from disk")
	await check_visible_frame("first", first_view)

	# A resident set that fits the camera's coarsened coverage must become quiet. If
	# pages keep getting evicted/reloaded every frame, this interval catches the
	# repeating checker/missing-page flicker seen under small-cache pressure.
	var stable_before := work_snapshot()
	for frame in 72:
		await tick()
	var stable_after := work_snapshot()
	require(stable_after.baked == stable_before.baked, "stationary SVT view recomputed material pages")
	require(stable_after.cached == stable_before.cached, "stationary SVT view kept re-uploading persisted pages")
	require(stable_after.alloc == stable_before.alloc and stable_after.evict == stable_before.evict,
			"stationary visible set churned the eight-page pool: %s -> %s" % [str(stable_before), str(stable_after)])
	await check_visible_frame("stationary", first_view)

	# The initial full bake used the first view's hierarchy. Move to a distant corner,
	# then turn across the terrain. The wider footprint and changed angle demand a new
	# parent mip that was absent from the initial bake; auto-bake must repair it.
	var initial_mip := terrain.get_surface_svt().get_world_max_mip()
	prepare_camera(Vector3(720.0, 480.0, 480.0), Vector3(720.0, 0.0, 720.0), Vector2i(10, 10))
	camera.size = 640.0
	var moved_points := await wait_for_visible_coverage("moved")
	require(moved_points.size() >= MIN_VISIBLE_POINTS, "moved view must retain many visible non-AVT regions")
	await check_visible_frame("moved", moved_points)
	var moved_settings: Dictionary = terrain.get_vt_settings()
	var moved_generation := int(moved_settings.get("bake_generation", 0))
	var moved_mip := terrain.get_surface_svt().get_world_max_mip()
	require(moved_generation >= initial_generation,
			"moving the camera should preserve the initial SVT bake generation")
	require(moved_mip >= initial_mip,
			"moving the camera should retain at least the initial hierarchy")
	# The turned view has to *see* past the next distance band to demand a level the initial
	# bake did not cover: with a 64 m page the bands double from 128 m, so level 4 needs a
	# visible point past 992 m. Looking across the grid from the far corner with the extra
	# camera height puts the near corner at ~1080 m; the previous placement kept its whole
	# footprint under 990 m and could never raise the hierarchy.
	prepare_camera(Vector3(720.0, 700.0, 480.0), Vector3(160.0, 0.0, 320.0), Vector2i(10, 10))
	var extended_mip := await wait_for_hierarchy_growth(moved_mip)
	var turned_points := await wait_for_visible_coverage("turned", 2400, moved_generation, extended_mip)
	require(turned_points.size() >= MIN_VISIBLE_POINTS, "turned view must retain many visible non-AVT regions")
	var turned_settings: Dictionary = terrain.get_vt_settings()
	require(has_incremental_bake(turned_settings, moved_generation),
			"turning the camera must launch an incremental persisted SVT repair: %s" % str(turned_settings))
	# The catalogue names cells (one file each, holding the full mip chain), so it cannot be
	# asked for "the pages of mip 4", and a repair that finds the same content on disk rewrites
	# nothing. What has to hold is that the incremental job for the new level *completed*, and
	# the frame check below is what proves the served pixels came from it: the source albedo is
	# still poisoned, so a page that was not produced from the persisted bake renders blue.
	var turned_done := int(turned_settings.get("bake_done", 0))
	var turned_total := int(turned_settings.get("bake_total", 0))
	require(turned_total > 0 and turned_done >= turned_total,
			"automatic repair for mip %d must finish before coverage is accepted (%d/%d cells, generation %d)" % [
					extended_mip, turned_done, turned_total, int(turned_settings.get("bake_generation", 0))])
	print("VTSVTCOVER_REPAIRED mip=%d generation=%d total=%d done=%d" % [
			extended_mip, int(turned_settings.get("bake_generation", 0)),
			int(turned_settings.get("bake_total", 0)), int(turned_settings.get("bake_done", 0))])
	await check_visible_frame("turned", turned_points)

	restore_source_albedo()
	terrain.set_physics_process(false)
	terrain.set_clipmap_target(null)
	terrain.set_camera(null)
	scene.queue_free()
	camera.queue_free()
	for frame in 5:
		await process_frame
	if failed:
		quit(1)
		return
	print("PASS persisted SVT covers visible non-AVT regions under eight-page shared-pool pressure")
	quit()
