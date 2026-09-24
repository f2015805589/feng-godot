## GPU regression for strict AVT/SVT material residency.
##
## A VT-enabled terrain must use a ready material page.  A ready SVT page must
## reproduce the array result, while a missing page must be visible as the
## magenta checker diagnostic.  The test deliberately disables the source array
## after the baseline so a source fallback cannot hide a missing cache page.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const GRID := 4
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const NEAR_WORLD := Vector2(96.0, 96.0) # region (1, 1), material 1
const FAR_WORLD := Vector2(224.0, 224.0) # region (3, 3), material 1

var scene: Node3D
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func fill_region(location: Vector2i, id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(id)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func frame_image(wait_frames: int = 6) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func set_view(world: Vector2, height: float, size: float) -> void:
	camera.position = Vector3(world.x, height, world.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.size = size
	camera.current = true
	terrain.set_clipmap_target(camera)
	await process_frame

func screen_of(image: Image, world: Vector2) -> Vector2i:
	var screen := camera.unproject_position(Vector3(world.x, 0.0, world.y))
	return Vector2i(clampi(int(screen.x), 0, image.get_width() - 1), clampi(int(screen.y), 0, image.get_height() - 1))

func patch_stats(image: Image, world: Vector2, radius: int = 18) -> Dictionary:
	var center := screen_of(image, world)
	var black := 0
	var magenta := 0
	var total := 0
	var luminance := 0.0
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var pixel := image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1))
			var peak := maxf(pixel.r, maxf(pixel.g, pixel.b))
			if peak < 0.01:
				black += 1
			if pixel.r > 0.42 and pixel.b > 0.42 and pixel.g < 0.28:
				magenta += 1
			luminance += pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
			total += 1
	return {
		"black": float(black) / float(total),
		"magenta": float(magenta) / float(total),
		"mean": luminance / float(total),
	}

func compare_patch(baseline: Image, candidate: Image, world: Vector2, label: String) -> void:
	var expected := patch_stats(baseline, world)
	var got := patch_stats(candidate, world)
	var black_limit := maxf(0.04, float(expected["black"]) + 0.04)
	var delta := absf(float(expected["mean"]) - float(got["mean"]))
	print("VT_FALLBACK_PATCH ", label, " baseline=", expected, " candidate=", got, " delta=", delta)
	require(float(got["black"]) <= black_limit, label + " became black while VT was enabled")
	require(float(got["magenta"]) < 0.02, label + " displayed missing-page diagnostics")
	require(delta < 0.10, label + " changed too far from the array baseline")

func producer_stats() -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	return settings.get("producer", {})

func wait_material_resources(max_frames: int = 90) -> bool:
	for _i in max_frames:
		await process_frame
		var pages: Dictionary = terrain.get_vt_material_textures()
		var albedo: RID = pages.get("albedo_height", RID())
		if albedo.is_valid():
			return true
	return false

func wait_pending_empty(max_frames: int = 180) -> bool:
	for _i in max_frames:
		await process_frame
		var stats := producer_stats()
		if int(stats.get("pending", 1)) == 0 and int(stats.get("ready_pages", 0)) > 0:
			return true
	return false

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	var dark := Terrain3DTextureAsset.new()
	dark.albedo_texture = make_pattern(64, Color(0.035, 0.045, 0.055), Color(0.16, 0.10, 0.06))
	dark.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(0, dark)
	var bright := Terrain3DTextureAsset.new()
	bright.albedo_texture = make_pattern(64, Color(0.16, 0.72, 0.08), Color(0.95, 0.24, 0.04))
	bright.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(1, bright)

func configure_terrain() -> void:
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = 128
	terrain.vt_pages_per_update = 4
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_distance = 512.0
	terrain.surface_svt_page_world = float(REGION_SIZE)
	terrain.surface_svt_distance = 512.0
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	terrain.surface_vt_selection_mode = 1
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location, 1 if location == Vector2i(1, 1) or location == Vector2i(3, 3) else 0)
	terrain.data.update_maps()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://terrain")
	terrain.data_directory = "user://terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	add_materials()
	camera = Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	configure_terrain()

	# The two baseline views use the original region texture array, before any
	# material-page resources exist.
	await set_view(NEAR_WORLD, 180.0, 96.0)
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_array_enabled = true
	var baseline_near := await frame_image()
	baseline_near.save_png(output_dir.path_join("fallback-baseline-near.png"))
	var near_base_stats := patch_stats(baseline_near, NEAR_WORLD)
	require(float(near_base_stats["mean"]) > 0.03, "near baseline material is unexpectedly black")

	await set_view(FAR_WORLD, 220.0, 144.0)
	var baseline_far := await frame_image()
	baseline_far.save_png(output_dir.path_join("fallback-baseline-far.png"))
	var far_base_stats := patch_stats(baseline_far, FAR_WORLD, 14)
	require(float(far_base_stats["mean"]) > 0.03, "far baseline material is unexpectedly black")

	# The far field is produced from the resident region payloads, so a page with no bake on
	# disk and none resident still renders real material: the tier must never depend on a
	# bake file to draw. The strict-diagnostic contract is checked on the near field below,
	# where a page genuinely cannot be produced.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_enabled = true
	var cache_resources := await wait_material_resources()
	require(cache_resources, "SVT material arrays were not created")
	terrain.update_surface_svt(64)
	var produced_svt := await frame_image()
	produced_svt.save_png(output_dir.path_join("missing-svt.png"))
	require(float(patch_stats(produced_svt, FAR_WORLD)["magenta"]) < 0.02,
			"a far page must be produced from the resident payloads when no bake exists")
	require(float(patch_stats(produced_svt, FAR_WORLD)["mean"]) > 0.03,
			"the produced far page must carry material, not a blank page")
	var pending_records := 0
	for record: Dictionary in terrain.get_vt_pages():
		if String(record.get("kind", "")) != "SVT":
			continue
		var state := String(record.get("state", ""))
		if state.begins_with("Pending") or state.begins_with("Missing") or state == "Ready":
			pending_records += 1
	require(pending_records > 0, "VT Page must report the far field's production state")
	var bake_count := terrain.bake_svt()
	require(bake_count > 0, "SVT bake must queue terrain material pages")
	for frame in 360:
		await process_frame
		if terrain.get_vt_settings().bake_pending == 0: break
	require(terrain.get_vt_settings().bake_done == bake_count, "SVT bake must complete")
	terrain.surface_array_enabled = false
	require(await wait_pending_empty(), "SVT must have ready material pages")
	var cached_far := await frame_image()
	cached_far.save_png(output_dir.path_join("fallback-svt-cached-far.png"))
	compare_patch(baseline_far, cached_far, FAR_WORLD, "cached SVT far")

	# Normal AVT configuration: only the camera's one-region grid is selected. The
	# next frame intentionally has an uncached near region, so strict mode must show
	# the diagnostic instead of running the original material evaluator.
	await set_view(NEAR_WORLD, 180.0, 96.0)
	terrain.surface_svt_enabled = false
	terrain.surface_vt_region_offset = Vector2i(99, 99)
	terrain.surface_vt_enabled = true
	terrain.vt_pages_per_update = 1
	await wait_material_resources()
	var missing_near := await frame_image(1)
	missing_near.save_png(output_dir.path_join("fallback-avt-missing-near.png"))
	var missing_stats := patch_stats(missing_near, NEAR_WORLD)
	print("VT_FALLBACK_MISSING_PATCH ", missing_stats, " stats=", producer_stats())
	require(float(missing_stats["magenta"]) > 0.20,
			"uncached AVT page must show the magenta checker diagnostic")
	require(float(missing_stats["black"]) < 0.10,
			"uncached AVT page must not render black")

	# Move to the second material-bearing region with the normal AVT grid and allow
	# only a partial demand pass. This exercises a valid page beside pending pages.
	terrain.surface_vt_region_offset = Vector2i.ZERO
	terrain.surface_svt_enabled = true
	await set_view(FAR_WORLD, 220.0, 144.0)
	var partial := await frame_image(2)
	partial.save_png(output_dir.path_join("fallback-partial-far.png"))
	print("VT_FALLBACK_PARTIAL_STATS ", producer_stats())
	var partial_stats := patch_stats(partial, FAR_WORLD, 14)
	require(float(partial_stats["black"]) < 0.10,
			"partial AVT/SVT residency must not turn far terrain black")

	# Keep real SVT ready, but make the selected AVT table invalid. AVT feedback is its own
	# hierarchy and must never silently substitute an SVT page for an AVT miss.
	await frame_image(20)
	terrain.set_physics_process(false)
	var invalid_page_table := Image.create(512, 512, false, Image.FORMAT_RF)
	invalid_page_table.fill(Color(65535.0, 0.0, 0.0, 1.0))
	var invalid_texture := ImageTexture.create_from_image(invalid_page_table)
	var material_rid: RID = terrain.material.get_material_rid()
	RenderingServer.material_set_param(material_rid, "_surface_vt_indirection", invalid_texture.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_vt_max_local_mip", 0)
	var avt_missing_with_svt := await frame_image()
	avt_missing_with_svt.save_png(output_dir.path_join("missing-avt-with-valid-svt.png"))
	require(float(patch_stats(avt_missing_with_svt, FAR_WORLD)["magenta"]) > 0.20,
			"selected AVT miss must not cross into the independent SVT feedback hierarchy")

	print("VT_FALLBACK_FINAL_STATS ", terrain.get_vt_settings())
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS strict AVT/SVT material residency GPU regression")
	quit()
