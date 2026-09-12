# Run with a graphical rendering driver; see README.md in this directory.
#
# A small, real-material pressure test for the unified AVT/SVT pool. The scene is
# deliberately larger than the eight-page physical cache: six loaded regions are
# inside the near-field reach while SVT roots reserve half of the shared pool. The
# test relies on Terrain3D's automatic physics tick, rather than calling either
# demand method directly, so a stationary camera exposes allocator churn that an
# explicit one-shot test cannot see.
extends "res://vt_render_base.gd"

const PRESSURE_PAGE := 512
const PRESSURE_BORDER := 4
const REQUESTED_PAGE_COUNT := 6 # The native minimum is eight; this mirrors the user scene.
const PHYSICAL_PAGE_COUNT := 8
const SVT_PAGE_WORLD := 64.0
const SVT_DISTANCE := 128.0
const SVT_ROOT_MIPS := 6
const WARMUP_LIMIT := 240
const WARMUP_IDLE_STREAK := 12
const FIXED_SAMPLE_FRAMES := 36
const ACTION_LIMIT := 180

const REGIONS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0),
]
const EDIT_REGION := Vector2i(1, 0)

# A uniform ID/weight payload is enough to exercise the material baker while
# keeping the source maps cheap to construct. The editor's packed single-material
# representation is (id << 11) | (id << 6).
func write_region(loc: Vector2i, asset_id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := (asset_id << 11) | (asset_id << 6)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(loc)
	region.set_surface_map(Image.create_from_data(
			REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func snapshot() -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	var producer: Dictionary = settings.get("producer", Dictionary())
	var residency: Dictionary = settings.get("residency", Dictionary())
	return {
		"alloc": int(residency.get("alloc_count", 0)),
		"evict": int(residency.get("evict_count", 0)),
		"writes": int(residency.get("page_write_count", 0)),
		"protected": int(residency.get("protected_count", 0)),
		"baked": int(producer.get("baked_pages", 0)),
		"source_uploads": int(producer.get("source_uploads", 0)),
		"cached_uploads": int(producer.get("cached_uploads", 0)),
		"pending": int(producer.get("pending", 0)),
		"ready": int(producer.get("ready_pages", 0)),
		"page_count": int(residency.get("page_count", settings.get("page_count", 0))),
	}

func print_snapshot(phase: String, adaptive: bool, stats: Dictionary) -> void:
	print("VTPRESSURE phase=%s adaptive=%s alloc=%d evict=%d writes=%d protected=%d baked=%d source_uploads=%d cached_uploads=%d pending=%d ready=%d pages=%d" % [
			phase, str(adaptive), stats.alloc, stats.evict, stats.writes, stats.protected,
			stats.baked, stats.source_uploads, stats.cached_uploads, stats.pending,
			stats.ready, stats.page_count])

func tick() -> void:
	# The native scheduler runs from __physics_process(). A process frame gives the
	# render-thread callback time to dispatch and retire the baker's pending jobs.
	await physics_frame
	await process_frame

func warmup(adaptive: bool) -> Dictionary:
	var idle_streak := 0
	for frame in WARMUP_LIMIT:
		await tick()
		var stats := snapshot()
		if frame >= WARMUP_IDLE_STREAK and stats.pending == 0:
			idle_streak += 1
		else:
			idle_streak = 0
		if idle_streak >= WARMUP_IDLE_STREAK:
			break
	var result := snapshot()
	print_snapshot("warmup", adaptive, result)
	return result

func wait_for_production(adaptive: bool, before: Dictionary, phase: String) -> Dictionary:
	var best := snapshot()
	for frame in ACTION_LIMIT:
		await tick()
		best = snapshot()
		# Allocation alone only says that a virtual address changed. Require the
		# render-thread baker counters to move so this phase proves material output
		# was actually produced and uploaded.
		if best.baked > before.baked or best.source_uploads > before.source_uploads:
			break
	print_snapshot(phase, adaptive, best)
	return best

func drain_pending() -> Dictionary:
	var best := snapshot()
	var idle_streak := 0
	for frame in ACTION_LIMIT:
		await tick()
		best = snapshot()
		if best.pending == 0:
			idle_streak += 1
		else:
			idle_streak = 0
		if idle_streak >= 4:
			break
	return best

func setup_case(adaptive: bool) -> void:
	scene = Node3D.new()
	root.add_child(scene)
	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	terrain.region_size = REGION_SIZE
	scene.add_child(terrain)

	terrain.assets = Terrain3DAssets.new()
	var colors := [Color.RED, Color.GREEN, Color.BLUE]
	for id in colors.size():
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, colors[id])
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)

	camera = Camera3D.new()
	camera.position = Vector3(32.0, 240.0, 32.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 96.0
	camera.near = 0.1
	camera.far = 2000.0
	camera.current = true
	scene.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)

	# Match the reported project: material pages are 512px, the requested six
	# physical pages clamp to the native minimum of eight, and both VT tiers share
	# that pool. No direct-material/debug fallback is enabled anywhere in this test.
	terrain.set_vt_page_size(PRESSURE_PAGE)
	terrain.set_vt_page_border(PRESSURE_BORDER)
	terrain.set_vt_page_count(REQUESTED_PAGE_COUNT)
	terrain.set_vt_pages_per_update(4)
	terrain.set_vt_adaptive_enabled(adaptive)
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = SVT_DISTANCE
	terrain.surface_vt_feedback_enabled = true
	terrain.surface_vt_feedback_interval = 1
	terrain.surface_vt_feedback_grid_chunks = 8
	terrain.surface_vt_feedback_min_extent = 1.0
	terrain.surface_svt_page_world = SVT_PAGE_WORLD
	terrain.surface_svt_distance = SVT_DISTANCE
	terrain.surface_svt_root_mips = SVT_ROOT_MIPS
	# Newer runtimes expose an explicit target-grid selector. Keep the old-DLL
	# before baseline usable through has_method(), while the final test pins a 4x4
	# grid so all six loaded regions are covered without relying on distance alone.
	if terrain.has_method("set_surface_vt_selection_mode"):
		terrain.set_surface_vt_selection_mode(1) # Target Grid
		terrain.set_surface_vt_region_grid(Vector2i(4, 4))
		terrain.set_surface_vt_region_offset(Vector2i.ZERO)
		terrain.set_surface_vt_forward_regions(0.0)

	# Wait until Terrain3D has made its data object before authoring regions. This
	# also lets the explicit camera references win over camera auto-discovery.
	await process_frame
	await process_frame
	# Region data is initialized from the node's settings on the first frame. Repeat
	# the settings after that handoff so a newly added region has a 64x64, density-1
	# surface payload rather than the Terrain3D default region dimensions.
	terrain.region_size = REGION_SIZE
	terrain.change_surface_density(1)
	for i in REGIONS.size():
		var loc: Vector2i = REGIONS[i]
		terrain.data.add_region_blank(loc)
		write_region(loc, (i % 2) + 1)
	terrain.data.update_maps()

	# Enable both tiers after all settings and source maps are in place. The next
	# physics tick then performs the complete automatic service setup and demand pass.
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	await process_frame

func run_case(adaptive: bool) -> void:
	await setup_case(adaptive)
	var settings: Dictionary = terrain.get_vt_settings()
	var cache_pages := int(settings.get("page_count", 0))
	var avt_capacity := cache_pages / 2 # SVT roots reserve the other half.
	var near_demand := REGIONS.size() if adaptive else REGIONS.size() * PAGES_PER_AXIS * PAGES_PER_AXIS
	print("VTPRESSURE demand adaptive=%s regions=%d near_pages=%d avt_capacity=%d physical_pages=%d feedback=%s" % [
			str(adaptive), REGIONS.size(), near_demand, avt_capacity, cache_pages,
			str(terrain.is_surface_vt_feedback_enabled())])
	require(not terrain.is_vt_debug_direct_material(), "pressure case must use real material baking")
	require(cache_pages == PHYSICAL_PAGE_COUNT,
			"requested page_count=%d should clamp to shared eight-page cache, got %d" % [REQUESTED_PAGE_COUNT, cache_pages])
	require(bool(settings.get("shared_pool", false)), "AVT and SVT must use one physical pool")
	require(bool(settings.get("callback_registered", false)), "automatic VT service must register its render callback")
	require(bool(settings.get("adaptive", false)) == adaptive,
			"native adaptive setting must match the pressure case")
	if terrain.has_method("get_surface_vt_selection_mode"):
		require(int(settings.get("avt_selection_mode", -1)) == 1,
				"pressure must use the explicit Target Grid AVT selector")
		require(settings.get("avt_region_grid", Vector2i.ZERO) == Vector2i(4, 4),
				"pressure Target Grid must cover four regions per axis")
	require(near_demand > avt_capacity,
			"the pressure case must demand more AVT pages than its shared-pool budget")

	var warm := await warmup(adaptive)
	var fixed_before := snapshot()
	print_snapshot("fixed_before", adaptive, fixed_before)
	for frame in FIXED_SAMPLE_FRAMES:
		await tick()
	var fixed_after := snapshot()
	print_snapshot("fixed_after", adaptive, fixed_after)
	# A stationary camera can legitimately leave misses unresolved when the working
	# set is larger than the cache; it must not repeatedly evict and bake the same
	# requests every physics tick.
	require(fixed_after.alloc == fixed_before.alloc,
			"stationary camera kept allocating pages (%d -> %d)" % [fixed_before.alloc, fixed_after.alloc])
	require(fixed_after.evict == fixed_before.evict,
			"stationary camera kept evicting pages (%d -> %d)" % [fixed_before.evict, fixed_after.evict])
	require(fixed_after.baked == fixed_before.baked,
			"stationary camera kept GPU-baking pages (%d -> %d)" % [fixed_before.baked, fixed_after.baked])
	require(fixed_after.source_uploads == fixed_before.source_uploads,
			"stationary camera kept uploading source maps (%d -> %d)" % [fixed_before.source_uploads, fixed_after.source_uploads])

	# Move far enough to change the distance window. Regions that leave the near
	# field are released; the remaining region at (1,0) is still visible and can be
	# used for the edit phase below.
	# Leave the working set first. Moving within already resident coverage must
	# not be required to rebake unchanged material pages.
	camera.position = Vector3(2048.0, 240.0, 32.0)
	for frame in 5: await tick()
	camera.position = Vector3(160.0, 240.0, 32.0)
	terrain.set_clipmap_target(camera)
	var move_before := snapshot()
	print_snapshot("move_before", adaptive, move_before)
	var move_after := await wait_for_production(adaptive, move_before, "move_after")
	require(move_after.baked > move_before.baked or move_after.source_uploads > move_before.source_uploads,
			"camera move did not trigger new material page production")
	await drain_pending()

	# Change a loaded region's source payload and explicitly invalidate its VT pages,
	# matching what the editor's paint path does. The blue asset makes the edit real,
	# while the counters prove the callback re-processed it.
	var edited_region := EDIT_REGION
	for page: Dictionary in terrain.get_vt_pages():
		if page.kind == "AVT" and page.ready:
			var center: Vector2 = page.world_rect.get_center()
			edited_region = Vector2i(floori(center.x / REGION_SIZE), floori(center.y / REGION_SIZE))
			break
	write_region(edited_region, 2)
	terrain.data.update_maps()
	terrain.invalidate_surface_pages(edited_region)
	var edit_before := snapshot()
	print_snapshot("edit_before", adaptive, edit_before)
	var edit_after := await wait_for_production(adaptive, edit_before, "edit_after")
	require(edit_after.baked > edit_before.baked or edit_after.source_uploads > edit_before.source_uploads,
			"editing a loaded region did not trigger new material page production")

	print_snapshot("final", adaptive, snapshot())
	scene.queue_free()
	await process_frame
	await process_frame
	terrain = null
	scene = null
	camera = null

func run() -> void:
	# Run both scheduler modes in one isolated process so a regression cannot hide
	# behind adaptive coarsening. Each case owns a fresh terrain and shared pool.
	await run_case(true)
	await run_case(false)
	if failed:
		quit(1)
		return
	print("PASS VT pressure remains stable for automatic real-material AVT/SVT and re-produces after move/edit")
	quit()
