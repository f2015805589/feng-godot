extends SceneTree
## Material setters must affect existing shapes and persistent contacts.
var failed := false

func check(value: bool, message: String) -> void:
	print("MATERIAL_UPDATE ", message, " ", value)
	failed = failed or not value

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 0.2, 30)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position.y = -0.1
	var floor_material := PhysicsMaterial.new()
	floor_material.friction = 0.0
	floor_body.physics_material_override = floor_material
	root.add_child(floor_body)
	var body := RigidBody3D.new()
	var body_shape := CollisionShape3D.new()
	body_shape.shape = BoxShape3D.new()
	body.add_child(body_shape)
	body.position.y = 0.5
	body.can_sleep = false
	body.lock_rotation = true
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	var material := PhysicsMaterial.new()
	material.friction = 1.0
	body.physics_material_override = material
	root.add_child(body)
	for i in 45: await physics_frame
	body.linear_velocity = Vector3(2, 0, 0)
	for i in 30: await physics_frame
	check(body.linear_velocity.x > 1.8, "zero-friction floor slides")
	floor_material.friction = 1.0
	for i in 60: await physics_frame
	check(absf(body.linear_velocity.x) < 0.1, "changing live static material stops slide")
	# Neither assigning a material before entering the tree nor cached property
	# round-tripping tests the live-shape update needed here.
	material.bounce = 1.0
	body.position = Vector3(0, 2.0, 0)
	body.linear_velocity = Vector3(0, -2, 0)
	var rebound := 0.0
	for i in 90:
		await physics_frame
		rebound = maxf(rebound, body.linear_velocity.y)
	check(rebound > 3.0, "changing live restitution bounces")
	body.free()
	floor_body.free()
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
