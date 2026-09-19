extends SceneTree
## A stopped camera keeps rendering with TAA. Its native VT prediction must decay
## through tiny float values without constructing a non-unit rotation axis.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene := Node3D.new()
	var terrain := Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.vt_editor_preview = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://motion_decay")
	terrain.data_directory = "user://motion_decay"
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.region_size = 256
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.update_maps()
	var camera := Camera3D.new()
	camera.position = Vector3(128, 24, 128)
	camera.rotation_degrees = Vector3(-20, 0, 0)
	camera.current = true
	scene.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_vt_distance = 64.0
	terrain.set_physics_process(false)
	root.use_taa = true
	for i in 12:
		await _tick(terrain)
	# Establish a real turn in the native predictor, then hold the camera still.
	for i in 12:
		camera.rotation.y += 0.02
		await _tick(terrain)
	var peak := float(terrain.get_vt_settings().get("motion_turn_lead_deg", 0.0))
	assert(peak > 0.01, "the native motion predictor never saw the camera turn")
	for i in 400:
		await _tick(terrain)
	var remaining := float(terrain.get_vt_settings().get("motion_turn_lead_deg", 1.0))
	assert(remaining < 0.00001, "the stopped camera's prediction did not settle")
	print("PASS stopped TAA camera motion prediction decays without invalid rotation axes")
	scene.queue_free()
	await process_frame
	quit()

func _tick(terrain: Terrain3D) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
