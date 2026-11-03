extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var anchor := StaticBody3D.new()
	root.add_child(anchor)
	var body := RigidBody3D.new()
	body.gravity_scale = 0.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.0
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	root.add_child(body)
	var joint := PinJoint3D.new()
	root.add_child(joint)
	joint.node_a = joint.get_path_to(anchor)
	joint.node_b = joint.get_path_to(body)
	await physics_frame
	body.angular_velocity = Vector3(0, 0, 2)
	for i in 120:
		await physics_frame
	var passed := body.angular_velocity.length() > 1.5 and body.position.length() < 0.01
	print("PIN_FREE_ROTATION angular_velocity=", body.angular_velocity)
	joint.free()
	body.free()
	anchor.free()
	print("RESULT: ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)
