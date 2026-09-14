# GPU regression for view-driven AVT focus and SVT page demand.
#
# Regions are inserted from far to near along +Z. AVT must follow the camera's
# visible 1x1 region even when the clipmap target is fixed at the terrain origin;
# SVT must request the nearest page visible to the camera, rather than the first
# region in storage order or the first world row.
extends SceneTree

const REGION_SIZE := 64
const REGION_COUNT := 13
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const TOP_POSITION := Vector3(32.0, 40.0, 32.0)
const FAR_LOOK_AT := Vector3(32.0, 0.0, 400.0)
const AWAY_LOOK_AT := Vector3(32.0, 0.0, -400.0)

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func make_texture(color: Color) -> ImageTexture:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = make_texture(Color(0.16, 0.42, 0.2) if id == 0 else Color(0.55, 0.42, 0.2))
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func add_flat_regions_far_to_near() -> void:
	terrain.region_size = REGION_SIZE
	for z in range(REGION_COUNT - 1, -1, -1):
		terrain.data.add_region_blank(Vector2i(0, z))
	terrain.data.update_maps()

func svt_records() -> Array:
	var records: Array = []
	for record: Dictionary in terrain.get_vt_pages():
		if record.get("kind", "") == "SVT":
			records.push_back(record)
	return records

func frame_barrier() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	# Terrain3D probes the configured directory while assigning it. Make the
	# isolated fixture's empty cache directory first so a clean test is warning-free.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_visibility_data"))

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = 8
	# The manual passes below are one-shot and authoritative, so the pool they budget against
	# has to be the pool they get: with auto capacity on, the first pass requests a larger pool
	# and (deliberately) produces nothing while that request is in flight.
	terrain.vt_auto_capacity = false
	terrain.surface_vt_pages_per_axis = 1
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	terrain.surface_vt_region_offset = Vector2i.ZERO
	terrain.surface_vt_selection_mode = 0 # Visible Terrain.
	terrain.surface_vt_distance = 1024.0
	terrain.surface_svt_page_world = float(REGION_SIZE)
	terrain.surface_svt_max_mip = 0
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_distance = 1024.0
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_visibility_data"
	add_materials()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 64.0
	camera.near = 0.1
	camera.far = 4096.0
	camera.position = TOP_POSITION
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	root.add_child(camera)
	camera.current = true
	terrain.set_camera(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	# Keep the clipmap anchor fixed at the terrain origin. Selection must come
	# from the active camera's frustum, not this unrelated anchor position.
	terrain.set_clipmap_target(terrain)
	terrain.set_physics_process(false)
	add_flat_regions_far_to_near()
	await frame_barrier()

	# AVT's one-region focus starts directly under the top-down camera.
	terrain.surface_vt_enabled = true
	terrain.set_surface_vt_force_mip(true, 0)
	var top_focus: Rect2i = terrain.get_surface_vt_region_rect()
	print("VT_VISIBILITY_AVT_TOP_FOCUS ", top_focus)
	require(top_focus.position == Vector2i.ZERO,
			"top-down AVT 1x1 grid should focus region (0,0), got " + str(top_focus))
	var top_pages := terrain.update_surface_vt(1)
	require(top_pages == 1, "top-down AVT should allocate one page, got " + str(top_pages))
	require(terrain.get_surface_vt().has_sector(Vector2i.ZERO),
			"top-down AVT demand should register region (0,0)")

	# The camera stays in place; only its view changes. The fixed clipmap target
	# remains terrain origin, while the visible AVT focus must move down +Z.
	camera.look_at(FAR_LOOK_AT, Vector3.UP)
	await frame_barrier()
	var far_focus: Rect2i = terrain.get_surface_vt_region_rect()
	print("VT_VISIBILITY_AVT_FAR_FOCUS ", far_focus)
	require(far_focus.size == Vector2i.ONE and far_focus.position.x == 0 and far_focus.position.y > 0,
			"looking toward +Z should move the AVT 1x1 focus to a visible positive-Z region, got " + str(far_focus))
	var far_avt_pages := terrain.update_surface_vt(1)
	require(far_avt_pages == 1, "far-view AVT should allocate one page, got " + str(far_avt_pages))
	require(terrain.get_surface_vt().has_sector(far_focus.position),
			"AVT should register the nearest visible region " + str(far_focus.position))
	require(not terrain.get_surface_vt().has_sector(Vector2i.ZERO),
			"AVT should release the region that left the visible 1x1 grid")

	# A fresh terrain and disabled physics make the manual SVT request deterministic.
	# No persisted tile exists, so the request is expected to be recorded as Missing
	# bake; page residency/order is the assertion, not material-channel readiness.
	# Move several regions beyond storage order before checking SVT priority. The
	# first request may use a coarser mip when the page budget requires it.
	# Look straight down: a tilted view puts the AVT visible-region rect and the
	# distance-picked SVT page in different regions, which the assertion below is not about.
	camera.position = Vector3(32.0, 40.0, 352.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	await frame_barrier()
	var svt_focus: Rect2i = terrain.get_surface_vt_region_rect()
	print("VT_VISIBILITY_SVT_FOCUS ", svt_focus)
	require(svt_focus.size == Vector2i.ONE and svt_focus.position.y >= 3,
			"SVT camera should select a region beyond the storage-first row, got " + str(svt_focus))
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = true
	terrain.set_surface_vt_force_mip(false)
	require(svt_records().is_empty(), "fresh fixture unexpectedly has SVT requests before the manual demand pass")
	var requested := terrain.update_surface_svt(1)
	var records := svt_records()
	print("VT_VISIBILITY_SVT_FIRST_REQUEST count=", requested, " records=", records)
	require(requested == 1, "manual visible SVT demand should request exactly one new page, got " + str(requested))
	require(records.size() == 1, "one-page SVT budget should create one SVT record, got " + str(records.size()))
	if records.size() == 1:
		var first: Dictionary = records[0]
		var page_rect: Rect2 = first.get("world_rect", Rect2())
		var nearest_center := (Vector2(svt_focus.position) + Vector2(0.5, 0.5)) * REGION_SIZE
		var storage_first_center := Vector2(0.5, 0.5) * REGION_SIZE
		require(page_rect.has_point(nearest_center),
				"first SVT page should cover nearest visible region center %s, got mip %d rect %s" %
				[str(nearest_center), int(first.get("mip", -1)), str(page_rect)])
		require(not page_rect.has_point(storage_first_center),
				"first SVT page should follow nearest visible demand instead of covering storage-first region center %s; got mip %d rect %s" %
				[str(storage_first_center), int(first.get("mip", -1)), str(page_rect)])
		require(int(first.get("mip", -1)) >= 0,
				"visible SVT page should report a valid mip, got " + str(first.get("mip", -1)))
		# No persisted bake exists for this cell, so the page is produced from the resident
		# region payloads. The record has to say it is still pending rather than claim a
		# page that does not exist yet.
		require(String(first.get("state", "")).begins_with("Pending"),
				"an uncached SVT page should report a pending production state, got " + str(first.get("state", "")))
		require(not bool(first.get("ready", false)), "an uncached SVT page must not be treated as ready")

	# Looking away from every loaded region must not add SVT requests. Look up and back:
	# a shallow backward tilt still grazes distant terrain at the frustum's bottom edge,
	# which is a legitimate page request rather than a failure to face away.
	camera.look_at(Vector3(32.0, 4000.0, -400.0), Vector3.UP)
	await frame_barrier()
	var before_away := records.size()
	var away_requested := terrain.update_surface_svt(1)
	var after_away := svt_records()
	for record: Dictionary in after_away:
		print("VT_VISIBILITY_SVT_AWAY_RECORD ", record.get("address", Vector2i.ZERO),
				" mip ", record.get("mip", -1), " rect ", record.get("world_rect", Rect2()))
	print("VT_VISIBILITY_SVT_AWAY requested=", away_requested, " records=", after_away.size())
	require(away_requested == 0, "camera facing away from loaded terrain should request no SVT pages")
	require(after_away.size() == before_away,
			"camera facing away should leave the SVT request set unchanged")

	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS camera-visible AVT focus and nearest SVT page demand")
	quit()
