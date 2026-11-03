extends SceneTree
var meshes: Array[ArrayMesh] = []
var bodies: Array[RID] = []
var failed := false

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("SOFT_SLEEP ", message, " ", ok)
	failed = failed or not ok

func patch(y: float, pinned := false) -> RID:
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 4) if pinned else Vector2(1, 1)
	plane.subdivide_width = 6
	plane.subdivide_depth = 6
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plane.get_mesh_arrays())
	meshes.append(mesh)
	var body := PhysicsServer3D.soft_body_create()
	bodies.append(body)
	PhysicsServer3D.soft_body_set_mesh(body, mesh.get_rid())
	PhysicsServer3D.soft_body_set_transform(body, Transform3D(Basis.IDENTITY, Vector3(0,y,0)))
	PhysicsServer3D.soft_body_set_space(body, root.world_3d.space)
	if pinned:
		for i in 64: PhysicsServer3D.soft_body_pin_point(body,i,true)
	return body

func asleep(body: RID) -> bool:
	return PhysicsServer3D.soft_body_get_state(body,PhysicsServer3D.BODY_STATE_SLEEPING)

func run() -> void:
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20,0.2,20)
	collision.shape = box
	floor_body.add_child(collision)
	floor_body.position.y = -0.1
	root.add_child(floor_body)
	var body := patch(0.2)
	for i in 180: await physics_frame
	print("REST_STATS ", PhysicsServer3D.call("soft_body_get_statistics",body))
	check(asleep(body), "resting soft mesh sleeps automatically")
	var resting := PhysicsServer3D.soft_body_get_point_global_position(body,0)
	for i in 30: await physics_frame
	check(resting == PhysicsServer3D.soft_body_get_point_global_position(body,0), "sleep retains the solved pose")
	PhysicsServer3D.soft_body_apply_central_impulse(body, Vector3(0,1,0))
	check(not asleep(body), "impulse wakes immediately")
	for i in 6: await physics_frame
	check(PhysicsServer3D.soft_body_get_point_global_position(body,0).y > resting.y+0.02, "woken cloth responds to impulse")
	for i in 180: await physics_frame
	check(asleep(body), "cloth can sleep again")
	PhysicsServer3D.soft_body_set_state(body,PhysicsServer3D.BODY_STATE_CAN_SLEEP,false)
	for i in 80: await physics_frame
	check(not asleep(body), "can_sleep=false keeps simulation active")
	PhysicsServer3D.soft_body_set_state(body,PhysicsServer3D.BODY_STATE_CAN_SLEEP,true)
	for i in 80: await physics_frame
	check(asleep(body), "reenabling sleep works")
	# A newly arriving rigid body must wake a sleeping soft collision target.
	var ball := RigidBody3D.new()
	var ball_collision := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.15
	ball_collision.shape = sphere
	ball.add_child(ball_collision)
	ball.position = Vector3(0,0.15,0)
	root.add_child(ball)
	for i in 3: await physics_frame
	check(not asleep(body), "arriving rigid collider wakes sleeping cloth")
	ball.free()
	for i in 180: await physics_frame
	check(asleep(body), "cloth settles after rigid contact")
	floor_body.position.y = -1
	for i in 6: await physics_frame
	check(not asleep(body), "moving a static support wakes cloth")
	for i in 180: await physics_frame
	check(asleep(body), "cloth rests on moved support")
	floor_body.free()
	for i in 30: await physics_frame
	check(not asleep(body) and PhysicsServer3D.soft_body_get_point_global_position(body,0).y < -1.2, "removing support cannot leave cloth floating")
	PhysicsServer3D.free_rid(body); bodies.erase(body)
	# Retaining the same pin handoff must not reset the timer; moving it must.
	var pinned := patch(2,true)
	var anchor := PhysicsServer3D.soft_body_get_point_global_position(pinned,0)
	for i in 80:
		PhysicsServer3D.soft_body_move_point(pinned,0,anchor)
		await physics_frame
	check(asleep(pinned), "unchanged attachments do not prevent sleep")
	PhysicsServer3D.soft_body_move_point(pinned,0,anchor+Vector3(0,0.2,0))
	check(not asleep(pinned), "moving a pin wakes immediately")
	PhysicsServer3D.free_rid(pinned); bodies.erase(pinned)
	# The support may itself be a soft mesh. Its removal or collision-filter
	# change must invalidate sleep just as deleting a rigid floor does.
	var lower := patch(0,true)
	var upper := patch(0.2)
	for i in 240: await physics_frame
	print("STACK_STATS ", PhysicsServer3D.call("soft_body_get_statistics",upper))
	check(asleep(upper), "cloth supported by a soft mesh can sleep")
	PhysicsServer3D.free_rid(lower); bodies.erase(lower)
	for i in 30: await physics_frame
	check(not asleep(upper) and PhysicsServer3D.soft_body_get_point_global_position(upper,0).y < -0.1, "deleted soft support wakes its occupant")
	for rid in bodies: PhysicsServer3D.free_rid(rid)
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
