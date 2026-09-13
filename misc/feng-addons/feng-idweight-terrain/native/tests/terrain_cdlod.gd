extends "res://vt_adaptive_base.gd"

func run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 1: output_dir = arguments[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	require(terrain.surface_vt_enabled and terrain.surface_svt_enabled and terrain.cdlod_enabled, "AVT, SVT and CDLOD default on")
	# Establish an explicit regular-grid reference, independent of creation defaults.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.cdlod_enabled = false
	camera = Camera3D.new()
	camera.position = Vector3(0, 180, 340)
	camera.current = true
	camera.far = 4000
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	camera.look_at(Vector3.ZERO)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	add_assets()
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.collision.mode = Terrain3DCollision.DISABLED
	terrain.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_OFF
	for z in range(-1, 1):
		for x in range(-1, 1): terrain.data.add_region_blank(Vector2i(x, z))
	var controls = load("res://addons/feng-idweight-terrain/src/vt_editor.gd").new()
	root.add_child(controls)
	controls.initialize(null)
	controls.set_terrain(terrain)
	controls._refresh_cdlod_panel()
	require(controls.find_child("CDLODPatchSize", true, false) == null, "patch size is not a user control")
	var toggle = controls.find_child("CDLODEnabled", true, false)
	for enabled in [true, false, true, false]:
		toggle.button_pressed = enabled
		await frame_image(3)
		require(terrain.cdlod_enabled == enabled, "UI toggle changes native CDLOD state")
		require(terrain.get_cdlod_stats().active == enabled, "UI toggle changes actual geometry backend")
		require(bool(RenderingServer.material_get_param(terrain.material.get_material_rid(), "_cdlod_enabled")) == enabled, "shader CDLOD flag follows UI")
		var expected := "CDLOD" if enabled else "Region grid"
		require(controls.find_child("CDLODMode", true, false).text == "Current mode: " + expected, "UI mode label follows backend")
	controls.free()
	var before := await frame_image(12)
	before.save_png(output_dir.path_join("region_grid.png"))
	var regular_stats: Dictionary = terrain.get_cdlod_stats()
	require(regular_stats.get("backend", "") == "Region grid", "disabled CDLOD uses region grids, not clipmap strips")
	require(int(regular_stats.get("selected_patches", 0)) == 4, "four cells produce exactly four regular meshes")
	var regular_draws := root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	terrain.hide()
	await frame_image(6)
	var regular_hidden := root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	require(regular_draws - regular_hidden == 4, "CDLOD off draws four regions separately with no extra strip draws")
	terrain.show()
	terrain.cdlod_enabled = true
	var batched := await frame_image(12)
	batched.save_png(output_dir.path_join("cdlod.png"))
	var stats: Dictionary = terrain.get_cdlod_stats()
	require(stats.get("active", false), "CDLOD activates for finite terrain")
	require(int(stats.get("visible_patches", 0)) > 1, "multiple patches share the main batch")
	var visible_draws := root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	terrain.hide()
	await frame_image(6)
	var hidden_draws := root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	require(visible_draws - hidden_draws == 1, "CDLOD terrain must add exactly one main-view draw")
	print("CDLOD draws=", visible_draws - hidden_draws, " stats=", stats)
	terrain.show()
	# Inspect the terrain interior, including all four region boundaries.
	for point in [Vector2(-128,-128), Vector2(128,-128), Vector2(-128,128), Vector2(128,128), Vector2.ZERO]:
		require(sample_area(batched, point, 1) == "red", "CDLOD covers region interiors and shared boundaries")
	for value in [8, 64, 32]:
		terrain.cdlod_patch_size = value
		var resized := await frame_image(8)
		require(terrain.get_cdlod_stats().active, "patch size rebuild remains active")
		require(sample_area(resized, Vector2.ZERO, 1) == "red", "patch size rebuild preserves coverage")
	for yaw in [90, 180, 270, 0]:
		camera.rotation_degrees.y = yaw
		var turn := await frame_image(8)
		turn.save_png(output_dir.path_join("turn_%d.png" % yaw))
		if yaw == 0: require(classify(turn.get_pixel(160,160)) == "red", "turning back restores visible patches")
	terrain.material.world_background = Terrain3DMaterial.FLAT
	await frame_image(8)
	require(not terrain.get_cdlod_stats().active, "infinite background retains compatible clipmap")
	terrain.material.world_background = Terrain3DMaterial.NONE
	await frame_image(8)
	require(terrain.get_cdlod_stats().active, "finite background resumes CDLOD")
	terrain.surface_svt_auto_bake = false
	terrain.surface_vt_enabled = true
	for frame in 100:
		terrain.update_surface_vt(4)
		await process_frame
	var vt := await frame_image(12)
	vt.save_png(output_dir.path_join("cdlod_vt.png"))
	require(classify(vt.get_pixel(160,160)) == "red", "CDLOD uses existing AVT material cache")
	terrain.surface_vt_enabled = false
	terrain.cdlod_enabled = false
	var restored := await frame_image(12)
	require(restored.get_data() == before.get_data(), "disabling CDLOD restores original region-grid pixels")
	# A top-down interior mask detects gaps at mixed LOD/region boundaries on
	# a continuous heightfield, without replacing the terrain vertex shader.
	for location in terrain.data.get_region_locations():
		var heights := PackedFloat32Array()
		heights.resize(512 * 512)
		for z in 512:
			for x in 512:
				heights[z * 512 + x] = 24.0 * sin((location.x * 512 + x) * 0.015) * cos((location.y * 512 + z) * 0.013)
		terrain.data.get_region(location).set_height_map(Image.create_from_data(512, 512, false, Image.FORMAT_RF, heights.to_byte_array()))
	terrain.data.calc_height_range(true)
	terrain.data.update_maps()
	terrain.cdlod_enabled = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 900
	camera.position = Vector3(0, 1000, 0)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	var hills := await frame_image(12)
	hills.save_png(output_dir.path_join("hills.png"))
	var gaps := 0
	for y in range(20, 220):
		for x in range(35, 285):
			if classify(hills.get_pixel(x,y)) != "red": gaps += 1
	require(gaps == 0, "mixed-LOD hilly interior must have no exposed background cracks")
	# Exercise the ordinary clipmap path as well as CDLOD at the same seams.
	for use_cdlod in [false, true]:
		terrain.cdlod_enabled = use_cdlod
		# Move the LOD rings across the shared region corner and both boundary axes.
		# Fixed world samples remain inside the terrain for every camera position.
		for offset in [Vector2(-73, 41), Vector2(61, -87), Vector2(127, 95)]:
			camera.position = Vector3(offset.x, 1000, offset.y)
			var crossing := await frame_image(8)
			for z in range(-300, 301, 5):
				for x in [-2, -1, 0, 1, 2]:
					require(sample_area(crossing, Vector2(x,z), 0) == "red", "shared vertical edge stays covered while LOD rings move")
			for x in range(-300, 301, 5):
				for z in [-2, -1, 0, 1, 2]:
					require(sample_area(crossing, Vector2(x,z), 0) == "red", "shared horizontal edge stays covered while LOD rings move")
	
		print("PASS moving region boundaries cdlod=", use_cdlod)
	camera.position = Vector3(0, 1000, 0)
	for z in range(-16, 17):
		for x in range(-16, 17): terrain.data.set_control(Vector3(x,0,z), Terrain3DUtil.enc_hole(true))
	terrain.data.update_maps()
	var holes := await frame_image(8)
	holes.save_png(output_dir.path_join("holes.png"))
	require(classify(holes.get_pixel(160,120)) != "red", "CDLOD respects painted holes")
	terrain.data.remove_regionl(Vector2i(-1,-1))
	var unloaded := await frame_image(8)
	require(sample_area(unloaded, Vector2(-128,-128), 1) != "red", "removed region must leave no stale batched geometry")
	terrain.data.add_region_blank(Vector2i(-1,-1))
	var reloaded := await frame_image(8)
	require(sample_area(reloaded, Vector2(-128,-128), 1) == "red", "added region must invalidate the cached patch selection")
	terrain.cdlod_lod_scale = 16
	await frame_image(8)
	require(terrain.get_cdlod_stats().active, "LOD scale updates retain the active backend")
	terrain.cdlod_lod_scale = 8
	# Preserve offscreen shadow casters in a separate batch, not a second
	# visible terrain layer. Turning the camera does not remove those casters.
	terrain.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.position = Vector3(0,100,0)
	camera.rotation_degrees = Vector3(-25,0,0)
	var light := DirectionalLight3D.new()
	light.shadow_enabled = true
	light.rotation_degrees = Vector3(-35,-20,0)
	scene.add_child(light)
	await frame_image(12)
	require(int(terrain.get_cdlod_stats().shadow_only_patches) > 0, "offscreen terrain remains available to shadow passes")
	terrain.set_physics_process(false)
	camera.rotation_degrees.x = -45
	for tessellation in [0, 1]:
		terrain.tessellation_level = tessellation
		await frame_image(6)
		var builds := int(terrain.get_cdlod_stats().selection_builds)
		var total_ms := 0.0
		var peak_ms := 0.0
		for angle in range(0, 360, 15):
			camera.rotation_degrees.y = angle
			# No physics tick and no manual snap: the upcoming draw must use this camera.
			await process_frame
			await RenderingServer.frame_post_draw
			var current := root.get_texture().get_image()
			var timing := float(terrain.get_cdlod_stats().cpu_update_ms)
			total_ms += timing
			peak_ms = maxf(peak_ms, timing)
			require(classify(current.get_pixel(160,120)) == "red", "pre-draw geometry follows turns without physics updates")
			require(int(terrain.get_cdlod_stats().selection_builds) == builds, "pure rotation reuses the distance-selected quadtree")
		print("CDLOD rotation tessellation=", tessellation, " cpu_mean_ms=", total_ms / 24.0, " cpu_peak_ms=", peak_ms)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed: quit(1)
	else:
		print("PASS CDLOD batching and coverage")
		quit(0)

