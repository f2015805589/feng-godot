# Full AVT: independent 64 m sectors within 512 m regions and bounded residency.
extends "res://vt_adaptive_base.gd"

func fill_region(location: Vector2i, solid: bool = false) -> void:
	var bytes := PackedByteArray()
	bytes.resize(512 * 512 * 2)
	for y in 512:
		for x in 512:
			var id := 0 if solid else ((x / 64 + y / 64) % 2)
			bytes.encode_u16((y * 512 + x) * 2, (id << 11) | (id << 6))
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(512, 512, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func tick() -> int:
	var count := terrain.update_surface_vt(1)
	await process_frame
	await RenderingServer.frame_post_draw
	return count

func settle_sectors() -> void:
	var quiet := 0
	for i in 600:
		var produced := await tick()
		var stats: Dictionary = terrain.get_vt_settings()
		if produced == 0 and int(stats.get("producer", {}).get("pending", 1)) == 0:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 12:
			return
	require(false, "Full AVT failed to settle within the bounded page budget")

func check_grid(image: Image) -> void:
	for z in [-416.0, -224.0, -96.0, 96.0, 224.0, 416.0]:
		for x in [-416.0, -224.0, -96.0, 96.0, 224.0, 416.0]:
			var id := posmod(int(floor(x / 64)) + int(floor(z / 64)), 2)
			require(sample_area(image, Vector2(x, z), 1) == ("red" if id == 0 else "green"), "AVT coverage at negative/positive world coordinate %s" % Vector2(x, z))

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 32
	terrain.vt_pages_per_update = 1
	terrain.surface_vt_selection_mode = 2
	terrain.surface_vt_texels_per_meter = 768
	terrain.surface_vt_texels_per_pixel = 4.0
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1000
	camera.far = 2400
	camera.position = Vector3(0, 800, 0)
	camera.rotation_degrees.x = -90
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	terrain.set_process(false)
	terrain.set_physics_process(false)
	add_assets()
	terrain.material.world_background = Terrain3DMaterial.NONE
	for location in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i.ZERO]:
		terrain.data.add_region_blank(location)
		fill_region(location)
	terrain.data.update_maps()
	check_grid(await frame_image())
	terrain.surface_vt_enabled = true
	await settle_sectors()
	var stats: Dictionary = terrain.get_vt_settings().get("avt_sector_stats", {})
	print("VT_SECTORS_PRESSURE ", stats)
	require(int(stats.get("visible_sectors", 0)) > 32, "all visible sectors must outnumber physical pages in pressure test")
	require(terrain.get_surface_vt().has_sector(Vector2i(3, 3)), "512 m region contains independently addressed 64 m sectors")
	check_grid(await frame_image())
	var material_rid := terrain.material.get_material_rid()
	var poison := Texture2DArray.new()
	var blue := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	blue.fill(Color(0.02, 0.05, 0.95))
	blue.generate_mipmaps()
	poison.create_from_images([blue, blue])
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	var image := await frame_image()
	image.save_png(output_dir.path_join("full-avt-pressure.png"))
	check_grid(image)
	for i in 24:
		require(await tick() == 0, "idle full AVT must not allocate or rebake")
	camera.position.x = 32
	await tick()
	check_grid(await frame_image(1))
	await settle_sectors()
	# A perspective camera creates unequal projection demand inside one region.
	terrain.vt_page_count = 128
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 70
	camera.far = 420
	camera.position = Vector3(96, 45, -100)
	camera.look_at(Vector3(96, 0, 200), Vector3.UP)
	terrain.surface_vt_texels_per_pixel = 0.25
	await settle_sectors()
	var before := {}
	for y in range(-2, 7):
		for x in range(-4, 7):
			var key := Vector2i(x, y)
			if terrain.get_surface_vt().has_sector(key):
				before[key] = terrain.get_surface_vt().get_sector_block_size(key)
	terrain.surface_vt_mip_distances = PackedFloat32Array([64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536])
	terrain.surface_vt_texels_per_pixel = 4.0
	await tick()
	var grown := false
	var sizes := {}
	for key: Vector2i in before:
		var size: int = terrain.get_surface_vt().get_sector_block_size(key)
		sizes[size] = true
		if size > int(before[key]):
			grown = true

	require(grown, "higher projection demand must grow a sector")
	require(sizes.size() > 1, "sectors within a region must have different adaptive resolutions")
	await settle_sectors()
	image = await frame_image()
	image.save_png(output_dir.path_join("full-avt-perspective.png"))
	print("VT_SECTORS_PERSPECTIVE ", terrain.get_vt_settings().get("avt_sector_stats", {}))
	# Repaint a region; all overlapping sector pages and coarse borders must update.
	fill_region(Vector2i.ZERO, true)
	terrain.data.update_maps()
	terrain.invalidate_surface_pages(Vector2i.ZERO)
	await settle_sectors()
	image = await frame_image()
	image.save_png(output_dir.path_join("full-avt-edited.png"))
	print("VT_SECTORS_EDIT color=", sample_area(image, Vector2(224, 160), 1))
	require(sample_area(image, Vector2(224, 160), 1) == "red", "region editing invalidates sub-sector and coarse AVT pages")
	for i in 24:
		require(await tick() == 0, "edited AVT must settle without repeated baking")
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS full procedural AVT sectors, pressure coverage, refinement and edits")
	quit(0)
