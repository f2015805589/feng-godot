extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position.y = -0.1
	root.add_child(floor_body)
	var actor: CharacterBody3D = load("res://addons/box3d/examples/ragdoll_actor.tscn").instantiate()
	root.add_child(actor)
	actor.position.y = 3
	await physics_frame
	actor.velocity = Vector3(1, -2, 0)
	actor.set_ragdoll(true, Vector3(1, 0, 0))
	var momentum_preserved := not actor.is_physics_processing()
	for i in actor.physical_bones.size():
		var expected: Vector3 = actor.velocity
		if i == 1:
			expected += Vector3(1, 0, 0) / actor.physical_bones[i].mass
		var actual: Vector3 = PhysicsServer3D.body_get_state(actor.physical_bones[i].get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		momentum_preserved = momentum_preserved and actual.distance_to(expected) < 0.001
	var start: Vector3 = actor.physical_bones[0].global_position
	for i in 240:
		await physics_frame
	var finish: Vector3 = actor.physical_bones[0].global_position
	var passed: bool = momentum_preserved and actor.physical_bones.size() == 11 and actor.ragdoll_active and finish.y < start.y-0.2
	for bone: PhysicalBone3D in actor.physical_bones:
		passed = passed and bone.global_position.is_finite() and bone.global_position.distance_to(finish)<3
		passed = passed and bone.global_position.y > -0.1
	actor.reset_actor()
	passed = passed and actor.is_physics_processing()
	for bone: PhysicalBone3D in actor.physical_bones:
		passed = passed and bone.linear_velocity.is_zero_approx() and bone.angular_velocity.is_zero_approx()
	await physics_frame
	passed = passed and not actor.ragdoll_active and not actor.capsule.disabled
	for i in 30:
		await physics_frame
	passed = passed and actor.position.length() < 0.2
	actor.free()
	floor_body.free()
	print("RESULT: ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
