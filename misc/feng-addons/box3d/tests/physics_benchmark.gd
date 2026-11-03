extends SceneTree
var objects: Array[Node] = []
var frames := 0
var samples: Array[float] = []
var mode := "rigid"
var starters: Array[RigidBody3D] = []
var soft_bodies: Array[RID] = []
var solver_meshes: Array[ArrayMesh] = []
var actors: Array[CharacterBody3D] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="): mode = arg.trim_prefix("--case=")
	call_deferred("setup")

func setup() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(110, 0.2, 110)
	shape.shape = box
	ground.add_child(shape)
	ground.position.y = -0.1
	root.add_child(ground)
	objects.append(ground)
	if mode == "rigid":
		var domino := BoxShape3D.new()
		domino.size = Vector3(0.12, 1.2, 0.5)
		for ring in 30:
			var radius := 4.0 + ring * 1.15
			var count := int(TAU * radius / 0.65)
			for i in count:
				var angle := TAU * i / count
				var body := RigidBody3D.new()
				var collision := CollisionShape3D.new()
				collision.shape = domino
				body.add_child(collision)
				body.position = Vector3(cos(angle) * radius, 0.6, sin(angle) * radius)
				body.rotation.y = -angle - PI / 2
				root.add_child(body)
				objects.append(body)
				if i == 0: starters.append(body)
	elif mode.begins_with("ragdolls"):
		for i in 20:
			var actor: CharacterBody3D = load("res://addons/box3d/examples/ragdoll_actor.tscn").instantiate()
			actor.position = Vector3((i % 5) * 3.0, 3.0 + (i / 5) * 0.1, (i / 5) * 3.0)
			root.add_child(actor)
			actors.append(actor)
			objects.append(actor)
		for actor in actors:
			actor.set_ragdoll(true, Vector3(2, 0, 0))
	elif mode in ["soft_balls", "soft_rest"]:
		var sphere := SphereMesh.new()
		sphere.radial_segments = 16
		sphere.rings = 10
		for i in 8:
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
			solver_meshes.append(mesh)
			var rid := PhysicsServer3D.soft_body_create()
			soft_bodies.append(rid)
			PhysicsServer3D.soft_body_set_mesh(rid, mesh.get_rid())
			PhysicsServer3D.soft_body_set_transform(rid, Transform3D(Basis.IDENTITY, Vector3((i % 4) * 1.5, 1.2 + (i / 4) * 1.5, 0)))
			PhysicsServer3D.soft_body_set_simulation_precision(rid, 6)
			PhysicsServer3D.soft_body_set_linear_stiffness(rid, 0.6)
			PhysicsServer3D.soft_body_set_pressure_coefficient(rid, 1.0)
			PhysicsServer3D.soft_body_set_damping_coefficient(rid, 0.8)
			PhysicsServer3D.soft_body_set_total_mass(rid, 2.0)
			PhysicsServer3D.soft_body_set_space(rid, root.world_3d.space)
	else:
		for layer in (3 if mode == "soft_stack" else 1):
			var plane := PlaneMesh.new()
			plane.size = Vector2(6, 6)
			plane.subdivide_width = 14 if mode == "soft_stack" else 30
			plane.subdivide_depth = plane.subdivide_width
			var pose := Transform3D(Basis(Vector3.UP, layer * 0.22), Vector3(0, 2 + layer * 0.3, 0))
			var pins: Array[int] = [0]
			if mode in ["cloth4096", "cloth2048"]:
				plane.size = Vector2(3, 2)
				plane.subdivide_width = 62
				plane.subdivide_depth = 62 if mode == "cloth4096" else 30
				pose = Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 3.4, 0))
				pins.clear()
				var vertices: PackedVector3Array = plane.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
				for v in vertices.size():
					if vertices[v].z < -0.99 and absf(vertices[v].x) > 1.49:
						pins.append(v)
			# Use server RIDs: headless SoftBody3D has no render-time pin handoff.
			# This also avoids double-submitting a deferred Node3D transform.
			var solver_mesh := ArrayMesh.new()
			solver_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plane.get_mesh_arrays())
			solver_meshes.append(solver_mesh)
			var rid := PhysicsServer3D.soft_body_create()
			soft_bodies.append(rid)
			PhysicsServer3D.soft_body_set_mesh(rid, solver_mesh.get_rid())
			PhysicsServer3D.soft_body_set_transform(rid, pose)
			PhysicsServer3D.soft_body_set_simulation_precision(rid, 6)
			if mode in ["cloth4096", "cloth2048"]:
				PhysicsServer3D.soft_body_set_linear_stiffness(rid, 0.85)
				PhysicsServer3D.soft_body_set_damping_coefficient(rid, 0.3)
			for pin in pins:
				PhysicsServer3D.soft_body_pin_point(rid, pin, true)
			PhysicsServer3D.soft_body_set_space(rid, root.world_3d.space)
			if PhysicsServer3D.has_method("soft_body_configure"):
				PhysicsServer3D.call("soft_body_configure", rid, {
					"self_collision": mode in ["soft_contacts", "soft_stack", "cloth4096", "cloth2048"],
					"soft_collision": mode in ["soft_stack", "cloth4096", "cloth2048"],
					"collision_radius": 0.004 if mode in ["cloth4096", "cloth2048"] else 0.025})
	for i in (1800 if mode.ends_with("rest") else 60): await physics_frame
	for body in starters: body.apply_impulse(Vector3(0, 0, 0.65), Vector3(0, 0.55, 0))
	for i in 600:
		if i % 120 == 0 and mode == "ragdolls":
			for actor in actors:
				actor.physical_bones[1].apply_central_impulse(Vector3(1, 35, 0))
		if i % 120 == 0 and mode == "soft_balls":
			for body in soft_bodies:
				PhysicsServer3D.soft_body_apply_central_impulse(body, Vector3(0.2, 5, 0))
		var started := Time.get_ticks_usec()
		await physics_frame
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
	samples.sort()
	var total := 0.0
	for sample in samples: total += sample
	var contact_count := 0
	var particle_count := 0
	var sleeping_count := 0
	var soft_bounds := []
	# Outside the timed loop: compare every vertex, not just the bounding box,
	# when testing alternate worker counts or a scheduling/SIMD implementation.
	var positions_hash := HashingContext.new()
	positions_hash.start(HashingContext.HASH_SHA256)
	for body in soft_bodies:
		var stats: Dictionary = PhysicsServer3D.call("soft_body_get_statistics", body)
		var positions := PackedVector3Array()
		positions.resize(int(stats.visual_vertices))
		for i in positions.size(): positions[i] = PhysicsServer3D.soft_body_get_point_global_position(body, i)
		positions_hash.update(positions.to_byte_array())
		contact_count += int(stats.contacts_solved)
		particle_count += int(stats.particles)
		if PhysicsServer3D.soft_body_get_state(body, PhysicsServer3D.BODY_STATE_SLEEPING): sleeping_count += 1
		var measured_bounds := PhysicsServer3D.soft_body_get_bounds(body)
		soft_bounds.append(str(measured_bounds))
		if mode in ["cloth4096", "cloth2048"] and (absf(measured_bounds.end.y - 4.404) > 0.01 or measured_bounds.position.y < 2.1):
			push_error("Benchmark hanging-cloth pose/pins were not applied")
			quit(1)
			return
	var sleeping_bones := 0
	for actor in actors:
		for bone in actor.physical_bones:
			if PhysicsServer3D.body_get_state(bone.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING): sleeping_bones += 1
	print("BOX3D_PERF ", JSON.stringify({"case": mode, "objects": objects.size()+soft_bodies.size(), "headless_frame_median_ms": samples[samples.size()/2], "headless_frame_mean_ms": total/samples.size(), "headless_frame_p95_ms": samples[int(samples.size()*0.95)], "ticks_hz": Engine.physics_ticks_per_second, "workers": ProjectSettings.get_setting("physics/box3d/worker_count"), "backend": PhysicsServer3D.get_class(), "soft_particles": particle_count, "soft_sleeping": sleeping_count, "ragdoll_bones": actors.size()*11, "sleeping_bones": sleeping_bones, "soft_contacts_last_step": contact_count, "soft_bounds": soft_bounds, "soft_positions_sha256": positions_hash.finish().hex_encode()}))
	for body in soft_bodies: PhysicsServer3D.free_rid(body)
	quit()
