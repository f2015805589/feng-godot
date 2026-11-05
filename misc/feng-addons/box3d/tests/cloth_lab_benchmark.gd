extends SceneTree
## Run with the playground project/FRP, fixed-fps=120. No render or collision feature is disabled.
var step_started := 0

func _initialize() -> void:
	physics_frame.connect(func(): step_started = Time.get_ticks_usec())
	call_deferred("run")

func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.physics_ticks_per_second = 120
	Engine.max_physics_steps_per_frame = 1
	var scene: Node3D = load("res://addons/box3d/examples/soft_ragdoll_lab.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var cloth: SoftBody3D = scene.get_node("SoftBodies/Cloth")
	var records: Array = []
	var events: Array = []
	var last_frame := Time.get_ticks_usec()
	var target := Vector3.ZERO
	var valid := PhysicsServer3D.get_class() == "Box3DPhysicsServer3D"
	for frame in 1600:
		await process_frame
		var now := Time.get_ticks_usec()
		var physics_ms := (now - step_started) / 1000.0
		var frame_ms := (now - last_frame) / 1000.0
		last_frame = now
		var stats: Dictionary = cloth.call("get_solver_statistics")
		var bounds := PhysicsServer3D.soft_body_get_bounds(cloth.get_physics_rid())
		valid = valid and bounds.position.is_finite() and bounds.size.is_finite()
		if frame >= 120:
			records.append({"frame": frame, "physics_ms": physics_ms, "frame_ms": frame_ms,
				"tears": stats.torn_seams, "particles": stats.particles, "contacts": stats.contacts_solved,
				"tests": stats.contact_tests, "sleeping": stats.sleeping})
		if frame == 120:
			scene.shoot_ray(Vector3(0, 3.3, 5), Vector3(0, 0, -1))
		if frame == 240:
			# Release the support, then allow 8 seconds of settling before reimpact.
			var pins: PackedInt32Array = cloth.pinned_points
			for pin in pins:
				cloth.set_point_pinned(pin, false)
		if frame in [1200, 1320, 1440]:
			# Torn scraps can fly off the platform and inflate the whole-body AABB.
			# Aim at an actual surface vertex on the floor, not that AABB's center.
			var floor_points: Array[Vector3] = []
			var center := Vector3.ZERO
			for vertex in range(0, int(stats.visual_vertices), 17):
				var point := PhysicsServer3D.soft_body_get_point_global_position(cloth.get_physics_rid(), vertex)
				if absf(point.x) < 10.0 and absf(point.z) < 8.0 and absf(point.y) < 0.1:
					floor_points.append(point)
					center += point
			valid = valid and not floor_points.is_empty()
			center /= max(1, floor_points.size())
			var closest := INF
			for point in floor_points:
				if point.distance_squared_to(center) < closest:
					closest = point.distance_squared_to(center)
					target = point
			target.y = 0.28
			var origin := target + Vector3(0.25, 2.5, 3.5)
			var started := Time.get_ticks_usec()
			var ball: RigidBody3D = scene.shoot_ray(origin, (target - origin).normalized())
			valid = valid and ball != null
			events.append({"frame": frame, "spawn_ms": (Time.get_ticks_usec() - started) / 1000.0, "target": str(target)})
	var path := "res://.godot/cloth-lab-benchmark.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--result="): path = arg.trim_prefix("--result=")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"valid": valid, "records": records, "events": events}, "\t"))
	file.close()
	print("CLOTH_LAB_BENCHMARK ", "PASS" if valid else "FAIL", " result=", path)
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
