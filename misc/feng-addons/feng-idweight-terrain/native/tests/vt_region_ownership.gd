extends "res://vt_adaptive_base.gd"

func settle_views() -> void:
	for i in 140:
		await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 4
	terrain.surface_vt_selection_mode = 2
	terrain.surface_vt_region_grid = Vector2i.ONE
	terrain.surface_vt_texels_per_meter = 8
	terrain.surface_vt_mip_distances = PackedFloat32Array([10, 20, 40])
	terrain.surface_svt_texels_per_meter = 0.0625
	terrain.surface_svt_mip_distances = PackedFloat32Array([10000])
	terrain.surface_svt_auto_bake = true
	DirAccess.make_dir_recursive_absolute("user://ownership")
	terrain.data_directory = "user://ownership"
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.2
	camera.position = Vector3(32, 5, 32)
	camera.rotation_degrees.x = -90
	camera.current = true
	var anchor := Node3D.new()
	anchor.position = Vector3(256, 0, 256)
	scene.add_child(anchor)
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(anchor)
	add_assets()
	for x in 2:
		terrain.data.add_region_blank(Vector2i(x, 0), false)
		var bytes := PackedByteArray()
		bytes.resize(512 * 512 * 2)
		for i in 512 * 512:
			bytes.encode_u16(i * 2, (x << 11) | (x << 6))
		terrain.data.get_region(Vector2i(x, 0)).set_surface_map(Image.create_from_data(512, 512, false, Image.FORMAT_R16, bytes))
	terrain.data.update_maps()
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	# Orthographic pixel footprint is unchanged by camera height: old distance
	# arrays must no longer discard detail.
	for height in [5.0, 15.0, 30.0, 60.0]:
		camera.position.y = height
		await settle_views()
		var block := terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO)
		require(block == 16, "automatic mip ignores old distance cutoffs for unchanged orthographic footprint")
	# Assign a different material colour to each resident mip, freeze CPU
	# scheduling, and check the actual GPU sample across all three cutoffs.
	terrain.surface_vt_adaptive_enabled = false
	await settle_views()
	terrain.set_physics_process(false)
	var vt := terrain.get_surface_vt()
	var colours := {}
	var mip_colours := [Color.RED, Color.GREEN, Color.BLUE, Color.RED]
	for mip in 4:
		var slot := vt.request_page(Vector2i.ZERO, mip, 8 >> mip, 8 >> mip)
		require(slot >= 0, "allocate shader mip probe")
		colours[slot] = mip_colours[mip]
	vt.commit()
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var param_images: Array[Image] = []
	for slot in terrain.vt_page_count:
		var albedo := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		albedo.fill(colours.get(slot, Color.MAGENTA))
		albedo_images.append(albedo)
		var normal := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		normal.fill(Color(0, 1, 0, 1))
		normal_images.append(normal)
		var params := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		params.fill(Color(0, 1, 0, 1))
		param_images.append(params)
	var colour_array := Texture2DArray.new()
	var normal_array := Texture2DArray.new()
	var param_array := Texture2DArray.new()
	colour_array.create_from_images(albedo_images)
	normal_array.create_from_images(normal_images)
	param_array.create_from_images(param_images)
	var probe_rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(probe_rid, "_surface_material_albedo", colour_array.get_rid())
	RenderingServer.material_set_param(probe_rid, "_surface_material_normal", normal_array.get_rid())
	RenderingServer.material_set_param(probe_rid, "_surface_material_params", param_array.get_rid())
	camera.size = 256
	camera.position.x = 34
	camera.position.z = 34
	camera.position.y = 500
	for test in [[0.0, "red"], [1.0, "green"], [2.0, "blue"], [3.0, "red"]]:
		# Calibrate actual world metres per viewport pixel, independent of aspect mode.
		var pixel_world := camera.project_position(Vector2(161, 120), 1).distance_to(camera.project_position(Vector2(160, 120), 1))
		camera.size *= (pow(2.0, test[0]) / 8.0) / pixel_world
		var probe := await frame_image(3)
		var actual := sample_area(probe, Vector2(34, 34), 0)
		print("VT_OWNERSHIP shader_auto_mip=", test[0], " colour=", actual)
		require(actual == test[1], "GPU mip follows screen footprint")
	var pixel_world := camera.project_position(Vector2(161, 120), 1).distance_to(camera.project_position(Vector2(160, 120), 1))
	camera.size *= (sqrt(2.0) / 8.0) / pixel_world
	var blended := await frame_image(3)
	var screen := camera.unproject_position(Vector3(34, 0, 34))
	var colour := blended.get_pixelv(Vector2i(screen))
	require(colour.r > 0.1 and colour.g > 0.1 and colour.b < 0.1, "fractional mip blends adjacent red and green levels")
	terrain.material.update()
	terrain.surface_vt_adaptive_enabled = true
	terrain.set_physics_process(true)
	# Both entire blocks are visible; selected block 0 remains AVT even though
	# its far edge is hundreds of metres away. Block 1 uses persisted SVT.
	camera.size = 1100
	camera.position = Vector3(512, 800, 256)
	await create_timer(1.0).timeout
	await settle_views()
	terrain.set_physics_process(false)
	var shot := await frame_image()
	require(sample_area(shot, Vector2(128, 256), 1) == "red", "selected block is AVT beyond previous distance boundary")
	require(sample_area(shot, Vector2(480, 256), 1) == "red", "entire selected block remains AVT")
	require(sample_area(shot, Vector2(768, 256), 1) == "green", "unselected block uses SVT")
	var green_slot := -1
	for page: Dictionary in terrain.get_vt_pages():
		if page.kind == "SVT" and page.ready and int(page.mip) == 0 and page.world_rect.has_point(Vector2(768, 256)):
			green_slot = page.slot
	require(green_slot >= 0, "outside block has a ready SVT page")
	# Make SVT resolve to green everywhere, then hide AVT lookup. An AVT miss
	# must show its missing-page diagnostic, never silently turn into SVT.
	var fake := Image.create(2, 2, true, Image.FORMAT_RF)
	fake.fill(Color(float(green_slot), 0, 0))
	var fake_texture := ImageTexture.create_from_image(fake)
	var rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(rid, "_surface_svt_indirection", fake_texture.get_rid())
	RenderingServer.material_set_param(rid, "_surface_svt_indirection_size", 2)
	RenderingServer.material_set_param(rid, "_surface_svt_page_world", 2048.0)
	RenderingServer.material_set_param(rid, "_surface_svt_max_mip", 0)
	RenderingServer.material_set_param(rid, "_avt_directory_mask", 0)
	shot = await frame_image(2)
	require(sample_area(shot, Vector2(128, 256), 1) != "green", "AVT missing page cannot fall through to SVT")
	require(sample_area(shot, Vector2(768, 256), 1) == "green", "synthetic SVT fallback is valid outside selected block")
	# Artist-facing SVT result summary is one row per terrain block, with pages
	# nested underneath. The texture resolution is not the physical page count.
	var window = load("res://addons/feng-idweight-terrain/src/vt_editor.gd").new()
	root.add_child(window)
	window.initialize(null)
	window.set_terrain(terrain)
	window.page_tree.clear()
	var tree_root: TreeItem = window.page_tree.create_item()
	window._add_baked_page_rows(tree_root)
	var row := tree_root.get_first_child()
	var grouped := false
	while row:
		if row.get_text(0).begins_with("Terrain block"):
			grouped = true
			require(row.collapsed and row.get_first_child() != null, "SVT pages are nested under collapsed block results")
		row = row.get_next()
	require(grouped, "SVT results are grouped by terrain block")
	window.free()
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
	else:
		print("PASS AVT region ownership, automatic mip filtering and grouped SVT results")
		quit(0)
