# GPU regression for per-sector AVT density and mip-chain reuse during growth.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const NEAR_REGION := Vector2i(0, 0)
const FAR_REGION := Vector2i(0, 2)

var scene: Node3D
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func add_assets() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = make_texture(Color(0.9, 0.04, 0.02, 1.0) if id == 0 else Color(0.02, 0.9, 0.04, 1.0))
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func set_region_material(location: Vector2i, material_id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := (material_id << 11) | (material_id << 6)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func classify(color: Color) -> String:
	var peak := maxf(color.r, maxf(color.g, color.b))
	if peak < 0.02:
		return "black"
	if color.r > color.g * 1.3 and color.r > color.b * 1.3:
		return "red"
	if color.g > color.r * 1.3 and color.g > color.b * 1.3:
		return "green"
	if color.b > color.r * 1.3 and color.b > color.g * 1.3:
		return "blue"
	return "mixed"

func screen_of(world: Vector2) -> Vector2i:
	var point := camera.unproject_position(Vector3(world.x, 0.0, world.y))
	return Vector2i(int(point.x), int(point.y))

func sample_area(image: Image, world: Vector2, radius: int = 5) -> String:
	var center := screen_of(world)
	var counts := {"red": 0, "green": 0, "blue": 0, "black": 0, "mixed": 0}
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var color := image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1))
			var key := classify(color)
			counts[key] = int(counts[key]) + 1
	var best := "mixed"
	for key in counts:
		if int(counts[key]) > int(counts[best]):
			best = key
	return best

func frame_image(wait_frames: int = 6) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func pyramid_page_count(size: int) -> int:
	return (4 * size * size - 1) / 3

func sector_pages(location: Vector2i) -> Array:
	var result: Array = []
	for record: Dictionary in terrain.get_vt_pages():
		if record.get("kind", "") != "AVT":
			continue
		for owner: Dictionary in record.get("owners", []):
			if owner.get("owner_type", "") == "avt" and owner.get("sector", Vector2i(-999, -999)) == location:
				var page := record.duplicate()
				page["_sector_mip"] = int(owner.get("mip", record.get("mip", -1)))
				result.push_back(page)
				break
	return result

func sector_page_summary(location: Vector2i) -> PackedStringArray:
	var result := PackedStringArray()
	for page: Dictionary in sector_pages(location):
		result.push_back("m%d:%s" % [int(page.get("_sector_mip", -1)), "ready" if bool(page.get("ready", false)) else "pending"])
	return result

func sector_pages_ready(location: Vector2i, expected: int) -> bool:
	var pages := sector_pages(location)
	if pages.size() != expected:
		return false
	for page: Dictionary in pages:
		if not bool(page.get("ready", false)):
			return false
	return true

func wait_until_ready(locations: Array[Vector2i], sizes: Dictionary, max_frames: int = 180) -> bool:
	for _i in max_frames:
		await process_frame
		await RenderingServer.frame_post_draw
		var all_ready := true
		for location: Vector2i in locations:
			var size := int(sizes[location])
			if not sector_pages_ready(location, pyramid_page_count(size)):
				all_ready = false
		if all_ready:
			return true
	return false

func has_ready_root(location: Vector2i, root_mip: int) -> bool:
	for page: Dictionary in sector_pages(location):
		if int(page.get("_sector_mip", -1)) == root_mip and bool(page.get("ready", false)):
			return true
	return false

func has_pending_fine_page(location: Vector2i, root_mip: int) -> bool:
	for page: Dictionary in sector_pages(location):
		var mip := int(page.get("_sector_mip", -1))
		if mip >= 0 and mip < root_mip and not bool(page.get("ready", false)):
			return true
	return false

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	# Terrain3D probes the cache directory while assigning it; pre-create an empty
	# isolated cache so the test starts without directory errors.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_adaptive_data"))

	scene = Node3D.new()
	terrain = Terrain3D.new()
	require(terrain.region_size == 512 and is_equal_approx(terrain.vertex_spacing, 1.0), "new region covers 512 x 512 metres")
	for page_size in [16, 48, 256, 1024]:
		for resolution in [512, 1024, 2048, 4096]:
			terrain.vt_page_size = page_size
			terrain.surface_vt_resolution = resolution
			require(terrain.surface_vt_resolution == resolution, "AVT resolution preset round trip")
			require(terrain.vt_page_size * terrain.surface_vt_pages_per_axis == resolution, "AVT preset matches physical page mapping exactly")
			require(terrain.surface_vt_pages_per_axis <= 64, "AVT preset respects block size limit")
	var packed := PackedScene.new()
	require(packed.pack(terrain) == OK, "pack AVT settings")
	var restored := packed.instantiate() as Terrain3D
	require(restored.surface_vt_resolution == 4096, "AVT resolution survives scene serialization")
	restored.free()
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 128
	terrain.vt_pages_per_update = 1
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_adaptive_enabled = true
	terrain.surface_vt_texels_per_pixel = 0.25
	terrain.surface_vt_selection_mode = 0
	terrain.surface_vt_region_grid = Vector2i(1, 5)
	terrain.surface_vt_distance = 4096.0
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_adaptive_data"

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 70.0
	camera.near = 0.1
	camera.far = 512.0
	camera.position = Vector3(32.0, 40.0, -40.0)
	camera.current = true

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	camera.look_at(Vector3(32.0, 0.0, 200.0), Vector3.UP)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	# Terrain3DData receives the parent's region size on tree entry; update the
	# node after that initialization and before constructing blank regions.
	await process_frame
	terrain.region_size = REGION_SIZE
	add_assets()

	for location in [NEAR_REGION, FAR_REGION]:
		terrain.data.add_region_blank(location)
		set_region_material(location, 0 if location == NEAR_REGION else 1)
	terrain.data.update_maps()
	await process_frame

	var near_world := Vector2(32.0, 48.0)
	var far_world := Vector2(32.0, 160.0)
	var baseline := await frame_image()
	baseline.save_png(output_dir.path_join("array-baseline.png"))
	print("VT_ADAPT_BASELINE near=", sample_area(baseline, near_world), " far=", sample_area(baseline, far_world))
	require(sample_area(baseline, near_world) == "red", "near source-array region should render red")
	require(sample_area(baseline, far_world) == "green", "far source-array region should render green")

	terrain.surface_vt_enabled = true
	var first_step := terrain.update_surface_vt(0)
	var near_initial := terrain.get_surface_vt().get_sector_block_size(NEAR_REGION)
	var far_initial := terrain.get_surface_vt().get_sector_block_size(FAR_REGION)
	var initial_sizes := {NEAR_REGION: near_initial, FAR_REGION: far_initial}
	print("VT_ADAPT_INITIAL produced=", first_step, " near_size=", near_initial, " far_size=", far_initial,
			" near_pages=", sector_pages(NEAR_REGION).size(), " far_pages=", sector_pages(FAR_REGION).size())
	require(terrain.get_surface_vt().has_sector(NEAR_REGION), "near visible region should register an AVT block")
	require(terrain.get_surface_vt().has_sector(FAR_REGION), "far visible region should register an AVT block")
	require(near_initial > far_initial, "projected density should allocate a larger near AVT block than far, got %d and %d" % [near_initial, far_initial])
	var initially_ready := await wait_until_ready([NEAR_REGION, FAR_REGION], initial_sizes)
	require(initially_ready, "initial coarse mip pyramids should finish baking")
	var old_mip := 0
	var old_size := near_initial
	while old_size > 1:
		old_mip += 1
		old_size >>= 1
	require(has_ready_root(NEAR_REGION, old_mip), "initial near AVT root should be ready before growth")

	# Change only the requested texel density. The array is then poisoned so any
	# missing AVT page is visible instead of silently sampling original materials.
	var material_rid: RID = terrain.material.get_material_rid()
	var source_array: Variant = RenderingServer.material_get_param(material_rid, "_texture_array_albedo")
	var blue_image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	blue_image.fill(Color(0.02, 0.05, 0.95, 1.0))
	blue_image.generate_mipmaps()
	var poison := Texture2DArray.new()
	poison.create_from_images([blue_image, blue_image])
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	var cached_image := await frame_image()
	cached_image.save_png(output_dir.path_join("cached-before-growth.png"))
	require(sample_area(cached_image, near_world) == "red", "ready near AVT pages should bypass the poisoned source array")
	require(sample_area(cached_image, far_world) == "green", "ready far AVT pages should bypass the poisoned source array")
	var cached_pages_before_preset := sector_pages(NEAR_REGION)
	terrain.surface_vt_resolution = 512
	require(sector_pages(NEAR_REGION) == cached_pages_before_preset, "compatible resolution preset must retain resident pages")

	terrain.surface_vt_texels_per_pixel = 0.5
	var growth_produced := terrain.update_surface_vt(1)
	var near_grown := terrain.get_surface_vt().get_sector_block_size(NEAR_REGION)
	var far_grown := terrain.get_surface_vt().get_sector_block_size(FAR_REGION)
	var near_root_mip := 0
	var root_size := near_grown
	while root_size > 1:
		near_root_mip += 1
		root_size >>= 1
	print("VT_ADAPT_GROW produced=", growth_produced, " near_size=", near_grown, " far_size=", far_grown,
			" near_pages=", sector_page_summary(NEAR_REGION), " far_pages=", sector_page_summary(FAR_REGION))
	require(near_grown > near_initial, "increased projected density should grow the near AVT block")
	require(far_grown < near_grown, "the farther sector should retain lower virtual resolution")
	require(has_ready_root(NEAR_REGION, near_root_mip), "growth must preserve a ready near ancestor while fine pages are produced")
	require(has_pending_fine_page(NEAR_REGION, near_root_mip), "one-page growth budget should leave asynchronous near fine work pending")

	var during_growth := await frame_image(1)
	during_growth.save_png(output_dir.path_join("during-growth.png"))
	print("VT_ADAPT_GROW_PIXELS near=", sample_area(during_growth, near_world), " far=", sample_area(during_growth, far_world))
	# The legacy block-table path starts at mip 0 and returns the missing-page diagnostic on the
	# first non-resident level instead of substituting the ready ancestor; that strict contract
	# is what vt_filtering and vt_fallback pin. What this step has to show is that the pending
	# fine pages do not drag the near terrain onto the poisoned source array, while the far
	# sector keeps sampling its ready chain.
	var during_near := sample_area(during_growth, near_world)
	require(during_near != "blue", "pending near AVT pages must not fall back to the poisoned source array")
	require(sample_area(during_growth, far_world) == "green", "far AVT mip chain should remain sampled during near refinement")

	# Change quality back to the same low target, then move the camera backward.
	# The camera change alone must resize the same sector block while retaining a
	# ready coarse page that keeps the source array out of the sampling path.
	terrain.surface_vt_texels_per_pixel = 0.25
	terrain.update_surface_vt(0)
	var low_sizes := {NEAR_REGION: terrain.get_surface_vt().get_sector_block_size(NEAR_REGION),
			FAR_REGION: terrain.get_surface_vt().get_sector_block_size(FAR_REGION)}
	var low_ready := await wait_until_ready([NEAR_REGION, FAR_REGION], low_sizes)
	require(low_ready, "coarse pyramids should settle before camera-motion demand")
	var near_before_motion := terrain.get_surface_vt().get_sector_block_size(NEAR_REGION)
	camera.position.z = -80.0
	await process_frame
	var moved_produced := terrain.update_surface_vt(1)
	var near_after_motion := terrain.get_surface_vt().get_sector_block_size(NEAR_REGION)
	var moved_root_mip := 0
	var moved_root_size := near_after_motion
	while moved_root_size > 1:
		moved_root_mip += 1
		moved_root_size >>= 1
	print("VT_ADAPT_CAMERA_MOVE produced=", moved_produced, " near_before=", near_before_motion,
			" near_after=", near_after_motion, " far_after=", terrain.get_surface_vt().get_sector_block_size(FAR_REGION))
	require(near_after_motion != near_before_motion, "camera movement should change the near sector's projected AVT size")
	require(has_ready_root(NEAR_REGION, moved_root_mip), "camera-driven resize should preserve a ready ancestor")
	var moved_image := await frame_image(1)
	moved_image.save_png(output_dir.path_join("during-camera-move.png"))
	require(sample_area(moved_image, near_world) == "red", "camera-driven resize should keep sampling the cached ancestor")
	require(sample_area(moved_image, far_world) == "green", "far sector should remain covered after camera movement")
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", source_array)

	# Stop terrain updates before freeing its camera so cleanup does not emit a
	# spurious missing-camera error after the assertions have completed.
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS per-sector AVT density and ready-ancestor refinement")
	quit()
