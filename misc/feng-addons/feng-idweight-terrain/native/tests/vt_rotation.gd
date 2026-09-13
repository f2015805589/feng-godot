extends "res://vt_adaptive_base.gd"

func run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 1: output_dir = arguments[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 4
	terrain.surface_vt_texels_per_meter = 1024
	terrain.surface_svt_auto_bake = false
	camera = Camera3D.new()
	camera.position = Vector3(256, 4, 256)
	camera.rotation_degrees = Vector3(-35, 0, 0)
	camera.current = true
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	add_assets()
	var checker := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			checker.set_pixel(x, y, Color(0.9 if ((x / 8 + y / 8) as int) % 2 == 0 else 0.2, 0.02, 0.01))
	checker.generate_mipmaps()
	terrain.assets.get_texture_asset(0).albedo_texture = ImageTexture.create_from_image(checker)
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.surface_vt_enabled = true
	await frame_image(12)
	terrain.set_physics_process(false)
	terrain.snap()
	print("VT_ROTATION geometry=", terrain.get_cdlod_stats())
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var gpu_times := []
	var render_cpu_times := []
	var draws := []
	var totals := []
	var times := []
	var peaks := []
	var image_errors := []
	for angle in [0, 90, 0, 90, 0]:
		camera.rotation_degrees.y = angle
		terrain.snap()
		var produced := 0
		var usec := 0
		var peak_usec := 0
		var gpu_ms := 0.0
		var render_cpu_ms := 0.0
		var first: Image
		for frame in 80:
			var start := Time.get_ticks_usec()
			produced += terrain.update_surface_vt(4)
			var elapsed := Time.get_ticks_usec() - start
			usec += elapsed
			peak_usec = maxi(peak_usec, elapsed)
			await process_frame
			await RenderingServer.frame_post_draw
			if frame >= 20:
				gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
				render_cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
			if frame == 1: first = root.get_texture().get_image()
		gpu_times.append(gpu_ms / 60.0)
		render_cpu_times.append(render_cpu_ms / 60.0)
		draws.append(root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
		totals.append(produced)
		peaks.append(peak_usec / 1000.0)
		times.append(usec / 80000.0)
		var image := await frame_image(2)
		var error := 0.0
		for y in range(100, 230, 4):
			for x in range(10, 310, 4):
				error = maxf(error, absf(image.get_pixel(x, y).r - first.get_pixel(x, y).r))
		image_errors.append(error)
		image.save_png(output_dir.path_join("rotation_%d.png" % totals.size()))
		require(classify(image.get_pixel(160, 160)) == "red", "settled rotation retains material output")
	if OS.get_environment("TERRAIN_VT_REFERENCE") != "1":
		for turn in range(2, totals.size()):
			require(totals[turn] == 0, "warm camera turn must reuse resident pages")
			require(image_errors[turn] <= 1.0 / 255.0, "warm camera turn must not show material streaming")
	print("VT_ROTATION pages=", totals, " cpu_ms=", times, " cpu_peak_ms=", peaks, " turn_image_max_error=", image_errors, " upload_bytes=", terrain.get_surface_vt().get_stats().get("indirection_uploaded_bytes", -1))
	print("VT_ROTATION viewport_gpu_ms=", gpu_times, " viewport_cpu_ms=", render_cpu_times, " visible_draw_calls=", draws)
	terrain.surface_vt_enabled = false
	var direct := await frame_image(12)
	direct.save_png(output_dir.path_join("direct_material.png"))
	# The renderer replaces the whole shader in overdraw mode, including the
	# terrain vertex function. This measures flat clipmap overlap only.
	root.debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
	var overdraw := await frame_image(12)
	overdraw.save_png(output_dir.path_join("overdraw_flat_clipmap.png"))
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed: quit(1)
	else:
		print("PASS AVT camera rotation output and production measurements")
		quit(0)
