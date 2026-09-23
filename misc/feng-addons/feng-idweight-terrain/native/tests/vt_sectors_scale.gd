extends "res://vt_adaptive_base.gd"

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 32
	terrain.vt_pages_per_update = 1
	terrain.surface_vt_selection_mode = 2
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 11000
	camera.far = 30000
	camera.position = Vector3(0, 10000, 0)
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
	for y in range(-10, 10):
		for x in range(-10, 10):
			terrain.data.add_region_blank(Vector2i(x, y), false)
	terrain.data.update_maps()
	terrain.surface_vt_enabled = true
	var elapsed := 0
	var warm_elapsed := 0
	for frame in 80:
		var start := Time.get_ticks_usec()
		var produced := terrain.update_surface_vt(1)
		var duration := Time.get_ticks_usec() - start
		elapsed += duration
		if frame > 55:
			warm_elapsed += duration
			require(terrain.get_vt_settings().avt_sector_stats.plan_reused, "stationary camera reuses demand plan")
		if frame > 55: require(produced == 0, "10 km AVT must settle with 32 physical slots")
		await process_frame
		await RenderingServer.frame_post_draw
	var stats: Dictionary = terrain.get_vt_settings().get("avt_sector_stats", {})
	print("VT_SECTORS_SCALE ", stats, " average_demand_ms=", float(elapsed) / 80000.0)
	require(int(stats.get("visible_sectors", 0)) == 25600, "10.24 km world exposes all 25600 visible 64 m sectors")
	var moving_elapsed := 0
	for i in 20:
		camera.position.x += 0.01
		var start := Time.get_ticks_usec()
		terrain.update_surface_vt(1)
		moving_elapsed += Time.get_ticks_usec() - start
		var moving: Dictionary = terrain.get_vt_settings().avt_sector_stats
		require(not moving.plan_reused, "moving camera recomputes demand")
		require(not moving.directory_rebuilt, "unchanged virtual allocations reuse GPU directory during motion")
		await process_frame
	print("VT_SECTORS_PERF warm_ms=", float(warm_elapsed) / 24000.0, " moving_ms=", float(moving_elapsed) / 20000.0)
	var image := await frame_image()
	# These probes lie within the finite clipmap mesh extent as well as the world.
	for z in [-3000.0, -1000.0, 1000.0, 3000.0]:
		for x in [-3000.0, -1000.0, 1000.0, 3000.0]:
			require(sample_area(image, Vector2(x, z), 1) == "red", "10 km runtime coarse coverage")
	# With SVT enabled, near work must depend on metric camera range, not world size.
	terrain.surface_svt_enabled = true
	terrain.surface_vt_distance = 512
	for i in 40:
		terrain.update_surface_vt(1)
		await process_frame
	var bounded: Dictionary = terrain.get_vt_settings().avt_sector_stats
	require(int(bounded.visible_sectors) < 400, "camera range bounds AVT sectors in a 10 km world")
	var bounded_elapsed := 0
	for i in 20:
		camera.position.x += 0.01
		var start := Time.get_ticks_usec()
		terrain.update_surface_vt(1)
		bounded_elapsed += Time.get_ticks_usec() - start
		await process_frame
	print("VT_SECTORS_PERF camera_range_sectors=", bounded.visible_sectors, " camera_range_moving_ms=", float(bounded_elapsed) / 20000.0)
	# Enabling VT delivery turns this node's own tick back on (`terrain_3d_surface_views.cpp`), so
	# stop it before the camera goes: a tick with the camera freed cannot find a clipmap target and
	# the engine logs that as an error, which the runner counts against the test.
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS 10 km AVT visibility and bounded residency")
	quit(0)
