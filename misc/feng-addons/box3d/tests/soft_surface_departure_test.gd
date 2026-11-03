extends SceneTree
## A particle already touching a floor must be able to move away (#32).
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position.y = -0.1
	root.add_child(floor_body)
	var cloth := SoftBody3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1, 1)
	plane.subdivide_width = 2
	plane.subdivide_depth = 2
	cloth.mesh = plane
	cloth.position.y = 0.2
	root.add_child(cloth)
	for i in 90: await physics_frame
	var rid := cloth.get_physics_rid()
	var start := PhysicsServer3D.soft_body_get_point_global_position(rid, 0)
	PhysicsServer3D.soft_body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3(1, 2, 0))
	for i in 6: await physics_frame
	var end := PhysicsServer3D.soft_body_get_point_global_position(rid, 0)
	var valid := end.y > start.y + 0.09 and end.x > start.x + 0.04
	print("SOFT_DEPARTURE start=", start, " end=", end)
	cloth.free()
	floor_body.free()
	print("RESULT: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
