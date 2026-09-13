extends "res://vt_adaptive_base.gd"

func measure(label: String, frames: int = 120) -> void:
	var gpu := 0.0
	var cpu := 0.0
	for frame in frames + 120:
		await process_frame
		# Keep asynchronous readiness/fades advancing while measuring residency.
		# Zero budget prevents new production from contaminating the steady phase.
		if terrain.surface_vt_enabled: terrain.update_surface_vt(0)
		await RenderingServer.frame_post_draw
		if frame >= 120:
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
	print("TERRAIN_PROFILE phase=", label, " gpu_ms=", gpu / frames, " render_cpu_ms=", cpu / frames,
		" draws=", root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		" primitives=", root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME))
	root.get_texture().get_image().save_png(output_dir.path_join(label + ".png"))

func run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 1: output_dir = arguments[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 4
	terrain.surface_svt_auto_bake = false
	camera = Camera3D.new()
	camera.position = Vector3(256, 100, 420)
	camera.far = 5000
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -25, 0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	camera.look_at(Vector3(256, 20, 180))
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	terrain.set_physics_process(false)
	add_assets()
	terrain.material.world_background = Terrain3DMaterial.NONE
	for z in range(-1, 2):
		for x in range(-1, 2):
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location, false)
			var heights := PackedFloat32Array()
			heights.resize(512 * 512)
			for y in 512:
				for column in 512:
					var wx := x * 512 + column
					var wz := z * 512 + y
					heights[y * 512 + column] = 40.0 * sin(wx * 0.018) * cos(wz * 0.023)
			terrain.data.get_region(location).set_height_map(Image.create_from_data(512, 512, false, Image.FORMAT_RF, heights.to_byte_array()))
	terrain.data.calc_height_range(true)
	terrain.data.update_maps()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	terrain.surface_vt_enabled = true
	var demand_usec := 0
	var produced := 0
	for frame in 180:
		var start := Time.get_ticks_usec()
		produced += terrain.update_surface_vt(4)
		demand_usec += Time.get_ticks_usec() - start
		await process_frame
		await RenderingServer.frame_post_draw
	print("TERRAIN_PROFILE warmup_pages=", produced, " demand_mean_ms=", demand_usec / 180000.0)
	await measure("avt")
	# Diagnostic only: isolate neighbour-feather queries without changing the
	# shipped shader. Restore the source before normal/direct comparisons.
	terrain.material.shader_override_enabled = true
	var feather_source: String = terrain.material.shader_override.code
	var no_feather := PackedStringArray()
	for line in feather_source.split("\n"):
		if line.contains("detail = min(detail, mix(avt_detail_availability("):
			continue
		no_feather.append(line)
	terrain.material.shader_override.code = "\n".join(no_feather)
	await measure("avt_without_edge_feather")
	terrain.material.shader_override.code = feather_source
	terrain.material.shader_override_enabled = false
	await measure("avt_restored")
	terrain.surface_vt_enabled = false
	await measure("direct")
	# snap() schedules recentering; the physics tick performs the mesh update.
	terrain.set_physics_process(true)
	var start_position := camera.position
	for step in [1.0, 2.0, 64.0, -512.0]:
		camera.position.x += step
		terrain.snap()
		await physics_frame
		await physics_frame
		print("TERRAIN_PROFILE moved_step=", step)
		var moved := await frame_image(8)
		moved.save_png(output_dir.path_join("move_%d.png" % int(step)))
	camera.position = start_position
	terrain.snap()
	# Keep the exact terrain vertex function, so height, holes and LOD morphing
	# survive. Only replace fragment shading for a geometry-overlap diagnostic.
	terrain.material.shader_override_enabled = true
	var original: String = terrain.material.shader_override.code
	var fragment := original.find("void fragment()")
	require(fragment >= 0, "generated terrain fragment can be instrumented")
	if fragment >= 0:
		var geometry := original.substr(0, fragment)
		var mode_start := geometry.find("render_mode")
		var mode_end := geometry.find(";", mode_start)
		geometry = geometry.substr(0, mode_start) + "render_mode blend_add, depth_draw_never, depth_test_disabled, cull_back, unshaded, fog_disabled, skip_vertex_transform;" + geometry.substr(mode_end + 1)
		RenderingServer.set_default_clear_color(Color.BLACK)
		terrain.material.shader_override.code = geometry + "void fragment() { ALBEDO = vec3(0.1); ALPHA = 1.0; }"
		await measure("overdraw_terrain")
		terrain.material.shader_override.code = original
	terrain.material.shader_override_enabled = false
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed: quit(1)
	else:
		print("PASS terrain rendering profile")
		quit(0)
