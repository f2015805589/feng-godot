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
		print("VT_OWNERSHIP block_at_height=", height, " block=", block)
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
		print("VT_OWNERSHIP probe_mip=", mip, " page=", Vector2i(8 >> mip, 8 >> mip), " slot=", slot,
				" block=", vt.get_sector_block_size(Vector2i.ZERO))
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
	# A camera on the 512 m terrain boundary owns near sectors on BOTH sides,
	# regardless of a saved 1x1 or offset legacy grid.
	terrain.surface_vt_region_offset = Vector2i(30, -30)
	camera.size = 1100
	camera.position = Vector3(512, 800, 256)
	await create_timer(1.0).timeout
	await settle_views()
	terrain.set_physics_process(false)
	var shot := await frame_image()
	require(sample_area(shot, Vector2(480, 256), 1) == "red", "left neighbour renders")
	require(sample_area(shot, Vector2(544, 256), 1) == "green", "right neighbour renders")
	var left_avt := false
	var right_avt := false
	var slot_colours := {}
	for page: Dictionary in terrain.get_vt_pages():
		if not page.ready: continue
		slot_colours[page.slot] = Color.RED if page.kind == "AVT" else Color.GREEN
		if page.kind == "AVT":
			left_avt = left_avt or page.world_rect.has_point(Vector2(480, 256))
			right_avt = right_avt or page.world_rect.has_point(Vector2(544, 256))
	require(left_avt and right_avt, "camera range retains AVT across terrain block boundary")
	# Distinguish tiers by colour, independent of the terrain's source material.
	for slot in terrain.vt_page_count:
		albedo_images[slot].fill(slot_colours.get(slot, Color.MAGENTA))
	colour_array = Texture2DArray.new()
	colour_array.create_from_images(albedo_images)
	var rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(rid, "_surface_material_albedo", colour_array.get_rid())
	RenderingServer.material_set_param(rid, "_surface_material_normal", normal_array.get_rid())
	RenderingServer.material_set_param(rid, "_surface_material_params", param_array.get_rid())
	RenderingServer.material_set_param(rid, "_avt_fade_enabled", false)
	shot = await frame_image(3)
	require(sample_area(shot, Vector2(480, 256), 0) == "red", "left side uses AVT")
	require(sample_area(shot, Vector2(544, 256), 0) == "red", "right side also uses AVT, despite legacy offset")
	# The AVT/SVT blend band is `smoothstep(reach * 0.75, reach, distance)` from the camera's ground
	# position, and `reach` is the shipped `surface_vt_distance = 384` (`terrain_3d_vt_state.h`), so
	# the band is 288-384 m and these probes have to sit inside it and beyond it. They used to be at
	# world 960 and 1016 - 448 and 504 m from a camera at x=512 - which are both fully outside the
	# band, so the "blends AVT with SVT" probe read pure SVT and its neighbour read the band edge.
	var blend := shot.get_pixelv(Vector2i(camera.unproject_position(Vector3(864, 0, 256))))
	var far_edge := shot.get_pixelv(Vector2i(camera.unproject_position(Vector3(960, 0, 256))))
	print("VT_OWNERSHIP outer_blend=", blend, " far_edge=", far_edge,
			" far_area=", sample_area(shot, Vector2(960, 256), 0),
			" distance=", terrain.surface_vt_distance, " reach=", terrain.get_vt_settings().avt_sector_stats.get("coverage_radius"))
	require(blend.r > 0.1 and blend.g > 0.1 and blend.b < 0.1, "outer camera range blends AVT with SVT")
	require(sample_area(shot, Vector2(960, 256), 0) == "green", "far edge approaches SVT smoothly")
	# After moving across a block, the same nearby geometry remains AVT.
	terrain.material.update()
	terrain.set_physics_process(true)
	camera.position.x = 540
	await settle_views()
	var near_blocks := {}
	for key in [Vector2i(7, 3), Vector2i(8, 3), Vector2i(7, 4), Vector2i(8, 4), Vector2i(9, 4), Vector2i(8, 5)]:
		near_blocks[key] = terrain.get_surface_vt().get_sector_block_size(key)
	var move_stats: Dictionary = terrain.get_vt_settings().avt_sector_stats
	var avt_owners := {}
	for page: Dictionary in terrain.get_vt_pages():
		if page.get("kind", "") != "AVT":
			continue
		for owner: Dictionary in page.get("owners", []):
			avt_owners[owner.get("sector", Vector2i(-999, -999))] = true
	print("VT_OWNERSHIP after_move camera=", camera.position, " blocks=", near_blocks,
			" visible_sectors=", move_stats.get("visible_sectors"),
			" independent=", move_stats.get("independent_sectors"),
			" retained=", move_stats.get("retained_sector_addresses"),
			" avt_owners=", avt_owners.keys(),
			" lead_m=", move_stats.get("motion_lead_m"), " speed=", move_stats.get("motion_speed"),
			" plan_origin=", move_stats.get("plan_origin"), " camera_origin=", move_stats.get("camera_origin"),
			" plan_reused=", move_stats.get("plan_reused"),
			" plan_selected=", move_stats.get("plan_selected"), " world_pages=", move_stats.get("plan_world_pages"),
			" new_sector=", move_stats.get("plan_new_sector"), " level_mips=", move_stats.get("plan_level_mips"),
			" denied=", move_stats.get("refinement_requests_denied"))
	var under_camera: int = terrain.get_surface_vt().get_sector_block_size(Vector2i(8, 4))
	if under_camera == 0:
		# Diagnostic only: it separates "the retained addresses expire later" from "the set never
		# recentres on the camera", which are different defects with different fixes.
		for _frame in 300:
			await process_frame
		var late: Dictionary = terrain.get_vt_settings().avt_sector_stats
		var late_blocks := {}
		for key in [Vector2i(7, 4), Vector2i(8, 4), Vector2i(9, 4)]:
			late_blocks[key] = terrain.get_surface_vt().get_sector_block_size(key)
		print("VT_OWNERSHIP after_extra_settle blocks=", late_blocks,
				" visible_sectors=", late.get("visible_sectors"),
				" independent=", late.get("independent_sectors"),
				" retained=", late.get("retained_sector_addresses"),
				" plan_origin=", late.get("plan_origin"), " reuse_ticks=", late.get("reuse_ticks"),
				" chain_ticks=", late.get("chain_ticks"))
	require(under_camera > 0, "camera movement retains automatic coverage")
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
	# Demand starts at mip 2 but exceeds the physical pool. Its coarser parents
	# must be aligned in mip-0 world units, not by the difference between mips.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_texels_per_meter = 2
	terrain.surface_svt_mip_distances = PackedFloat32Array([10, 20, 10000])
	await create_timer(1.0).timeout
	await settle_views()
	var coarse_pages := 0
	for page: Dictionary in terrain.get_vt_pages():
		if page.kind != "SVT": continue
		var span := 1 << int(page.mip)
		var address: Vector2i = page.address
		require(posmod(address.x, span) == 0 and posmod(address.y, span) == 0,
				"SVT pressure parent must have canonical world origin: %s" % str(page))
		if int(page.mip) > 2: coarse_pages += 1
	require(coarse_pages > 0, "SVT pressure probe must produce parents coarser than requested mip 2")
	shot = await frame_image()
	require(sample_area(shot, Vector2(256, 256), 1) == "red", "SVT pressure preserves left block material")
	require(sample_area(shot, Vector2(768, 256), 1) == "green", "SVT pressure preserves right block material")
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
	else:
		print("PASS AVT region ownership, automatic mip filtering and grouped SVT results")
		quit(0)
