extends "res://vt_adaptive_base.gd"

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.surface_vt_texels_per_meter = 8
	terrain.surface_svt_auto_bake = false
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8
	camera.position = Vector3(34, 30, 34)
	camera.rotation_degrees.x = -90
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_vt_enabled = true
	for frame in 160:
		await process_frame
	var pages := terrain.get_vt_pages()
	require(terrain.get_vt_settings().avt_sector_stats.retained_hierarchy, "scheduler retains a continuous hierarchy")
	var checked := 0
	for page: Dictionary in pages:
		if not page.ready or page.kind != "AVT": continue
		var rect: Rect2 = page.world_rect
		if rect.size.x >= 128: continue
		var parent_found := false
		for parent: Dictionary in pages:
			var parent_rect: Rect2 = parent.world_rect
			if parent.ready and parent_rect.size.x > rect.size.x * 1.01 and parent_rect.size.x <= rect.size.x * 2.01 and parent_rect.has_point(rect.get_center()):
				parent_found = true
		require(parent_found, "each fine page retains its immediate ready parent")
		checked += 1
	require(checked > 4, "exercise multiple refinement levels")
	terrain.set_process(false)
	terrain.set_physics_process(false)
	var vt := terrain.get_surface_vt()
	# Isolate one fine page over a coarse green background. The old shader made
	# a hard red rectangle; the new shader must keep its centre sharp and blend
	# its edges only where the neighbouring fine page is missing.
	for mip in 5:
		for y in (16 >> mip):
			for x in (16 >> mip):
				vt.release_page(Vector2i.ZERO, mip, x, y)
	var fine := vt.request_page(Vector2i.ZERO, 0, 8, 8)
	for mip in range(1, 5):
		require(vt.request_page(Vector2i.ZERO, mip, 8 >> mip, 8 >> mip) >= 0, "allocate probe parent")
	vt.commit()
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var param_images: Array[Image] = []
	for slot in 64:
		var albedo := Image.create(4,4,false,Image.FORMAT_RGBAF)
		albedo.fill(Color.RED if slot == fine else Color.GREEN)
		albedo_images.append(albedo)
		var normal := Image.create(4,4,false,Image.FORMAT_RGBAF)
		normal.fill(Color(0,1,0,1))
		normal_images.append(normal)
		var params := Image.create(4,4,false,Image.FORMAT_RGBAF)
		params.fill(Color(0,1,0,1))
		param_images.append(params)
	var albedo_array := Texture2DArray.new()
	var normal_array := Texture2DArray.new()
	var param_array := Texture2DArray.new()
	albedo_array.create_from_images(albedo_images)
	normal_array.create_from_images(normal_images)
	param_array.create_from_images(param_images)
	var rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(rid, "_surface_material_albedo", albedo_array.get_rid())
	RenderingServer.material_set_param(rid, "_surface_material_normal", normal_array.get_rid())
	RenderingServer.material_set_param(rid, "_surface_material_params", param_array.get_rid())
	var fades := PackedColorArray()
	fades.resize(256)
	fades.fill(Color(1,1,1,1))
	RenderingServer.material_set_param(rid, "_avt_slot_fade", fades)
	var shot := await frame_image(3)
	require(sample_area(shot, Vector2(34,34),0) == "red", "fine page interior stays sharp")
	var edge_inside := shot.get_pixelv(screen_of(Vector2(32.04,34)))
	var edge_outside := shot.get_pixelv(screen_of(Vector2(31.96,34)))
	require(Vector3(edge_inside.r,edge_inside.g,edge_inside.b).distance_to(Vector3(edge_outside.r,edge_outside.g,edge_outside.b)) < 0.12, "missing-neighbour page boundary has no hard colour jump")
	var transition := shot.get_pixelv(screen_of(Vector2(32.5,34)))
	require(transition.r > 0.1 and transition.g > 0.1, "page edge blends fine and parent levels")
	# A ready neighbour removes the fade from their shared boundary.
	var neighbour := vt.request_page(Vector2i.ZERO,0,7,8)
	vt.commit()
	albedo_images[neighbour].fill(Color.RED)
	albedo_array.update_layer(albedo_images[neighbour],neighbour)
	shot = await frame_image(3)
	require(sample_area(shot,Vector2(32.04,34),0) == "red", "equally detailed neighbours do not get blurred seams")
	for phase in [0.0, 0.5, 1.0]:
		var value := fades[fine >> 2]
		value[fine & 3] = phase
		fades[fine >> 2] = value
		RenderingServer.material_set_param(rid,"_avt_slot_fade",fades)
		shot = await frame_image(3)
		var pixel := shot.get_pixelv(screen_of(Vector2(34,34)))
		if phase == 0:
			require(classify(pixel) == "green", "new detail starts on the parent")
		elif phase == 1:
			require(classify(pixel) == "red", "ready detail finishes at full sharpness")
		else:
			require(pixel.r > 0.1 and pixel.g > 0.1, "arrival fades instead of popping")
	# Sampling footprints cross an integer mip boundary continuously.
	var previous := Color.RED
	for lod in [0.0, 0.25, 0.5, 0.75, 0.99, 1.01]:
		var pixel_world := camera.project_position(Vector2(161,120),1).distance_to(camera.project_position(Vector2(160,120),1))
		camera.size *= (pow(2.0,lod) / 8.0) / pixel_world
		shot = await frame_image(3)
		var pixel := shot.get_pixelv(screen_of(Vector2(34,34)))
		if lod > 0:
			require(pixel.r <= previous.r + 0.03 and pixel.g >= previous.g - 0.03, "fractional mip transition is monotonic")
		if lod == 1.01:
			require(Vector3(pixel.r,pixel.g,pixel.b).distance_to(Vector3(previous.r,previous.g,previous.b)) < 0.12, "integer mip boundary does not create a sharp ring")
		previous = pixel
	# Non-power-of-two density makes the sector's last texel 8/3 m, while
	# successive world parents use 4 m and 8 m. Their transition cannot use a
	# blindly doubled local threshold (16/3 m).
	terrain.surface_vt_texels_per_meter = 6
	terrain.vt_page_count = 32
	terrain.surface_vt_adaptive_enabled = false
	terrain.set_physics_process(true)
	for frame in 160:
		await process_frame
	terrain.set_physics_process(false)
	for slot in 64:
		albedo_images[slot].fill(Color.GREEN)
	for page: Dictionary in terrain.get_vt_pages():
		if is_equal_approx(page.world_rect.size.x,128): albedo_images[page.slot].fill(Color.RED)
		if is_equal_approx(page.world_rect.size.x,256): albedo_images[page.slot].fill(Color.BLUE)
	for slot in 64:
		albedo_array.update_layer(albedo_images[slot],slot)
	rid = terrain.material.get_material_rid()
	RenderingServer.material_set_param(rid,"_surface_material_albedo",albedo_array.get_rid())
	RenderingServer.material_set_param(rid,"_surface_material_normal",normal_array.get_rid())
	RenderingServer.material_set_param(rid,"_surface_material_params",param_array.get_rid())
	RenderingServer.material_set_param(rid,"_avt_fade_enabled",false)
	for target in [3.99,4.01,5.30,5.34]:
		var pixel_world := camera.project_position(Vector2(161,120),1).distance_to(camera.project_position(Vector2(160,120),1))
		camera.size *= target / pixel_world
		shot = await frame_image(3)
		var pixel := shot.get_pixelv(screen_of(Vector2(34,34)))
		if target == 4.01 or target == 5.34:
			require(Vector3(pixel.r,pixel.g,pixel.b).distance_to(Vector3(previous.r,previous.g,previous.b)) < 0.12, "non-power-of-two sector/world mip handoff stays continuous")
		previous = pixel
	scene.queue_free()
	await process_frame
	camera.queue_free()
	await process_frame
	if not failed:
		print("PASS AVT retained parents, seamless page boundaries and arrival blending")
	quit(1 if failed else 0)
