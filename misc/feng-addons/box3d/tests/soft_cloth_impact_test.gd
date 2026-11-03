extends SceneTree
const Soft = preload("res://addons/box3d/soft_body_3d.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	# Match the actual playground; smaller substeps must not amplify recovery.
	Engine.physics_ticks_per_second = 120
	var floor_body := StaticBody3D.new()
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(400, 0.2, 400)
	floor_collision.shape = floor_shape
	floor_body.add_child(floor_collision)
	floor_body.position.y = -0.1
	root.add_child(floor_body)
	var plane := PlaneMesh.new()
	plane.size = Vector2(3, 2)
	plane.subdivide_width = 62
	plane.subdivide_depth = 30
	var mesh := Soft.make_tearable_mesh(plane)
	var cloth := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_mesh(cloth, mesh.get_rid())
	PhysicsServer3D.soft_body_set_transform(cloth, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 3.4, 0)))
	PhysicsServer3D.soft_body_set_linear_stiffness(cloth, 0.85)
	PhysicsServer3D.soft_body_set_simulation_precision(cloth, 6)
	PhysicsServer3D.soft_body_set_total_mass(cloth, 1.0)
	PhysicsServer3D.soft_body_set_damping_coefficient(cloth, 0.3)
	PhysicsServer3D.call("soft_body_configure", cloth, {"tearing": true, "tear_ratio": 2.0, "collision_radius": 0.004})
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		if vertices[i].z < -0.99 and absf(vertices[i].x) > 1.49:
			PhysicsServer3D.soft_body_pin_point(cloth, i, true)
	PhysicsServer3D.soft_body_set_space(cloth, root.world_3d.space)
	for i in 120: await physics_frame
	var ball := RigidBody3D.new()
	ball.mass = 4
	ball.continuous_cd = true
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	var collision := CollisionShape3D.new()
	collision.shape = shape
	ball.add_child(collision)
	ball.position = Vector3(0, 3.3, 4)
	root.add_child(ball)
	ball.linear_velocity = Vector3(0, 0, -20)
	var valid := true
	var peak_extent := 0.0
	var peak_energy := 0.0
	var peak_speed := 0.0
	var initial_stats: Dictionary = PhysicsServer3D.call("soft_body_get_statistics", cloth)
	var initial_energy: float = initial_stats.kinetic_energy + 9.8 * initial_stats.center_of_mass.y + 0.5 * ball.mass * 400.0 + ball.mass * 9.8 * ball.position.y
	for i in 360:
		await physics_frame
		var box := PhysicsServer3D.soft_body_get_bounds(cloth)
		peak_extent = maxf(peak_extent, box.size.length())
		valid = valid and box.position.is_finite() and box.size.is_finite()
		var stats: Dictionary = PhysicsServer3D.call("soft_body_get_statistics", cloth)
		var energy: float = stats.kinetic_energy + 9.8 * stats.center_of_mass.y + 0.5 * ball.mass * ball.linear_velocity.length_squared() + ball.mass * 9.8 * ball.position.y
		peak_energy = maxf(peak_energy, energy)
		peak_speed = maxf(peak_speed, stats.maximum_speed)
		valid = valid and is_finite(energy) and is_finite(stats.maximum_speed)
		if i % 120 == 0:
			print("CLOTH_IMPACT frame=", i, " bounds=", box, " energy=", energy, " stats=", stats)
	# A 4 kg projectile at 20 m/s can throw light torn debris far. Check energy
	# and floor support, rather than imposing an arbitrary debris travel limit.
	var after := PhysicsServer3D.soft_body_get_bounds(cloth)
	valid = valid and after.position.y > -0.05 and peak_energy <= initial_energy * 1.05
	valid = valid and absf(float(PhysicsServer3D.call("soft_body_get_statistics", cloth).particle_mass_sum) - 1.0) < 0.001
	for i in vertices.size():
		if vertices[i].z < -0.99 and absf(vertices[i].x) > 1.49:
			var expected := Basis(Vector3.RIGHT, PI / 2) * vertices[i] + Vector3(0, 3.4, 0)
			valid = valid and PhysicsServer3D.soft_body_get_point_global_position(cloth, i).distance_to(expected) < 0.001
	print("CLOTH_IMPACT peak_extent=", peak_extent, " final=", after, " initial_energy=", initial_energy, " peak_energy=", peak_energy, " peak_speed=", peak_speed)
	PhysicsServer3D.free_rid(cloth)
	ball.free()
	floor_body.free()
	print("RESULT: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
