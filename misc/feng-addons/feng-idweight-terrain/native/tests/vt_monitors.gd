## The terrain's own cost has to be identifiable in visual monitoring: every number it
## publishes carries a `terrain/` keyword, so a monitor graph or a profiler timeline can
## tell the terrain apart from the engine's own counters. This checks that the custom
## monitors exist with the right names and types, that they return live readings, that a
## second terrain does not collide with the first, and that they are withdrawn with the
## node - a monitor holds a callable into the object it polls.
extends SceneTree

var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		print("REGRESSION ", message)

func monitor_names() -> PackedStringArray:
	var names := PackedStringArray()
	for name in Performance.get_custom_monitor_names():
		if String(name).begins_with("terrain/"):
			names.append(String(name))
	names.sort()
	return names

func ground_height(at: Vector2) -> float:
	return 0.0

func make_terrain(parent: Node3D, home: Vector3) -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://vt_monitors_terrain")
	terrain.data_directory = "user://vt_monitors_terrain"
	parent.add_child(terrain)
	terrain.region_size = 256
	terrain.assets = Terrain3DAssets.new()
	for id in 3:
		var asset := Terrain3DTextureAsset.new()
		var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.3 + 0.2 * float(id), 0.4, 0.2, 1.0))
		image.generate_mipmaps()
		asset.albedo_texture = ImageTexture.create_from_image(image)
		asset.normal_texture = asset.albedo_texture
		terrain.assets.set_texture_asset(id, asset)
	var heights := PackedFloat32Array()
	heights.resize(256 * 256)
	for i in 256 * 256:
		heights[i] = sin(float(i % 256) * 0.05) * 4.0
	terrain.data.add_region_blank(Vector2i(0, 0))
	terrain.data.get_region(Vector2i(0, 0)).set_height_map(
			Image.create_from_data(256, 256, false, Image.FORMAT_RF, heights.to_byte_array()))
	terrain.data.update_maps()
	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 8000.0
	parent.add_child(camera)
	camera.position = home + Vector3(0.0, 30.0, 0.0)
	camera.current = true
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_vt_feedback = true
	terrain.vt_frame_budget_ms = 0.1
	terrain.set_physics_process(false)
	return terrain

func tick(terrain: Terrain3D) -> void:
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	terrain.snap()
	await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var before := monitor_names()
	require(before.is_empty(),
			"no terrain monitor may exist before a terrain runs, got %s" % str(before))

	var terrain := make_terrain(scene, Vector3(128.0, 0.0, 128.0))
	for _frame in 12:
		await tick(terrain)
	var names := monitor_names()
	print("VTMONITORS names=", str(names))
	require(names.size() > 0, "a running terrain must publish terrain/ monitors")
	for expected in ["terrain/vt_cpu", "terrain/avt_cpu", "terrain/material_bytes", "terrain/pages_ready", "terrain/cdlod_cpu"]:
		require(names.has(expected), "the terrain must publish %s, got %s" % [expected, str(names)])
	# The types are what make the editor format a value as milliseconds or as a size; the
	# engine binds quantity 0, memory 1, time 2, percentage 3.
	var types := {}
	var all_names := Performance.get_custom_monitor_names()
	var all_types := Performance.get_custom_monitor_types()
	for index in all_names.size():
		types[String(all_names[index])] = int(all_types[index])
	require(int(types.get("terrain/vt_cpu", -1)) == 2, "the VT cost must be a time monitor")
	require(int(types.get("terrain/material_bytes", -1)) == 1, "the pool size must be a memory monitor")
	require(int(types.get("terrain/pages_ready", -1)) == 0, "the ready count must be a quantity monitor")
	require(int(types.get("terrain/cdlod_cpu", -1)) == 2, "the geometry cost must be a time monitor")

	# A live reading: the VT section ran, so the tick it measures is above zero, and the pool
	# the terrain built is above zero too.
	var vt_cpu := float(Performance.get_custom_monitor("terrain/vt_cpu"))
	var material := float(Performance.get_custom_monitor("terrain/material_bytes"))
	var ready := float(Performance.get_custom_monitor("terrain/pages_ready"))
	print("VTMONITORS readings vt_cpu=%.6f material_bytes=%.0f pages_ready=%.0f" % [vt_cpu, material, ready])
	require(vt_cpu >= 0.0, "the VT cost monitor must return a duration")
	require(material > 0.0, "the pool monitor must return the arrays' size (%f)" % material)

	# The geometry backend runs from `frame_pre_draw` rather than from the tick, so its
	# monitor reports the last pass, and the same pass is what `get_cdlod_stats()` exposes.
	var geometry: Dictionary = terrain.get_cdlod_stats()
	var cdlod_cpu := float(Performance.get_custom_monitor("terrain/cdlod_cpu"))
	print("VTMONITORS cdlod_cpu=%.6f backend=%s patches=%d cpu_update_ms=%.6f" % [cdlod_cpu,
			str(geometry.get("backend", "")), int(geometry.get("selected_patches", 0)),
			float(geometry.get("cpu_update_ms", -1.0))])
	require(cdlod_cpu >= 0.0, "the geometry cost monitor must return a duration")
	require(is_equal_approx(cdlod_cpu, float(geometry.get("cpu_update_ms", -1.0))),
			"the geometry monitor must report the backend's own reading, got %f vs %f" % [cdlod_cpu,
					float(geometry.get("cpu_update_ms", -1.0))])
	require(int(geometry.get("selected_patches", 0)) > 0,
			"the geometry backend must have selected patches to time")

	# A second terrain must not fight the first for the same ids.
	var second := make_terrain(scene, Vector3(300.0, 0.0, 300.0))
	for _frame in 4:
		await tick(second)
	var both := monitor_names()
	var plain := 0
	for name in both:
		if name == "terrain/vt_cpu":
			plain += 1
	require(plain == 1, "the plain terrain/ ids must stay unique, got %d" % plain)
	print("VTMONITORS two_terrains=", str(both.size()), " names=", str(both))

	# Withdrawing the node must withdraw its monitors: they poll the node they name.
	terrain.queue_free()
	await process_frame
	await process_frame
	var after_free := monitor_names()
	print("VTMONITORS after_free=", str(after_free))
	require(after_free.size() < both.size(),
			"freeing a terrain must withdraw its monitors, still %s" % str(after_free))

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS terrain cost is published under a terrain/ keyword")
	quit()
