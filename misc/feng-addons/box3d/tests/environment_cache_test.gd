extends SceneTree
var failed := false
var body: RigidBody3D

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, text: String) -> void:
	print("ENVIRONMENT_CACHE ", text, " ", ok)
	failed = failed or not ok

func speed() -> float:
	body.linear_velocity = Vector3(10, 0, 0)
	for i in 20: await physics_frame
	return body.linear_velocity.x

func run() -> void:
	var space := root.world_3d.space
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_LINEAR_DAMP, 0.0)
	body = RigidBody3D.new()
	body.gravity_scale = 0
	body.can_sleep = false
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	body.add_child(shape)
	root.add_child(body)
	check(await speed() > 9.9, "initial zero damping")
	body.linear_damp = 4
	check(await speed() < 5, "body parameter invalidates cache")
	body.linear_damp = 0
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_LINEAR_DAMP, 4.0)
	check(await speed() < 5, "default area change invalidates cached defaults")
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	check(await speed() > 9.9, "damping mode change invalidates cache")
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_COMBINE
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_LINEAR_DAMP, 0.0)
	var area := Area3D.new()
	area.linear_damp_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.linear_damp = 8
	var area_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200,200,200)
	area_shape.shape = box
	area.add_child(area_shape)
	root.add_child(area)
	for i in 4: await physics_frame
	check(await speed() < 5, "area takes over cached defaults")
	area.free()
	check(await speed() > 9.9, "removing last area restores defaults")
	body.free()
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
