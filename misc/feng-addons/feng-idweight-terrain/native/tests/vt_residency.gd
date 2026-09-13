extends "res://vt_adaptive_base.gd"

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_texels_per_meter = 1024
	terrain.surface_svt_auto_bake = false
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	terrain.data.add_region_blank(Vector2i.ZERO)
	var heights := PackedFloat32Array()
	heights.resize(512 * 512)
	for y in 512:
		for x in 512:
			heights[y * 512 + x] = 90.0 * exp(-pow((x - 300.0) / 55.0, 2.0) - pow((y - 210.0) / 65.0, 2.0))
	terrain.data.get_region(Vector2i.ZERO).set_height_map(Image.create_from_data(512, 512, false, Image.FORMAT_RF, heights.to_byte_array()))
	terrain.data.calc_height_range(true)
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.position = Vector3(256, 55, 256)
	camera.rotation_degrees = Vector3(-35, 0, 0)
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.surface_vt_enabled = true
	await frame_image(12)
	terrain.set_physics_process(false)
	var turn := 0
	for angle in [0, 90, 0, 90, 0]:
		camera.rotation_degrees.y = angle
		terrain.snap()
		var peak := 0
		var elapsed_total := 0
		for frame in 300:
			var start := Time.get_ticks_usec()
			terrain.update_surface_vt(16)
			var elapsed := Time.get_ticks_usec() - start
			peak = maxi(peak, elapsed)
			elapsed_total += elapsed
			await process_frame
			await RenderingServer.frame_post_draw
		var image := await frame_image(2)
		var missing := 0
		for y in image.get_height():
			for x in image.get_width():
				var c := image.get_pixel(x,y)
				if c.r > 0.1 and c.r > c.g * 1.5 and c.b > c.g * 1.5: missing += 1
		image.save_png(output_dir.path_join("residency_%d.png" % turn))
		print("VT_RESIDENCY turn=",turn," missing_pixels=",missing," cpu_average_ms=",elapsed_total / 300000.0," cpu_peak_ms=",peak / 1000.0)
		require(missing == 0, "settled slope demand must cover every rendered pixel after sector growth")
		turn += 1
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if not failed: print("PASS slope residency through repeated camera turns")
	quit(1 if failed else 0)
