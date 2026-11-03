extends SceneTree

var failed := false
var sync_count := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("BODY_SUBSCRIPTIONS ", message, " ", ok)
	failed = failed or not ok

func on_sync(_state: PhysicsDirectBodyState3D) -> void:
	sync_count += 1

func run() -> void:
	var shape := PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, Vector3(0.5, 0.5, 0.5))
	var floor_body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(floor_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_add_shape(floor_body, shape)
	PhysicsServer3D.body_set_state(floor_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, -0.5, 0)))
	PhysicsServer3D.body_set_space(floor_body, root.world_3d.space)
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, 0.6, 0)))
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, false)
	# Configure callbacks/contact reporting while detached, as scenes normally do.
	PhysicsServer3D.body_set_state_sync_callback(body, on_sync)
	PhysicsServer3D.body_set_max_contacts_reported(body, 4)
	PhysicsServer3D.body_set_space(body, root.world_3d.space)
	for i in 90: await physics_frame
	check(sync_count > 80, "callbacks configured before entering a space")
	check(PhysicsServer3D.body_get_direct_state(body).get_contact_count() > 0, "initial contact subscription")
	PhysicsServer3D.body_set_max_contacts_reported(body, 0)
	PhysicsServer3D.body_set_state_sync_callback(body, Callable())
	for i in 4: await physics_frame
	var paused_count := sync_count
	for i in 8: await physics_frame
	check(sync_count == paused_count, "callback removal takes effect")
	check(PhysicsServer3D.body_get_direct_state(body).get_contact_count() == 0, "disabled reports clear stale contacts")
	PhysicsServer3D.body_set_space(body, RID())
	PhysicsServer3D.body_set_max_contacts_reported(body, 4)
	PhysicsServer3D.body_set_state_sync_callback(body, on_sync)
	PhysicsServer3D.body_set_space(body, root.world_3d.space)
	for i in 12: await physics_frame
	check(sync_count > paused_count + 8, "callbacks resume after reattaching to a space")
	check(PhysicsServer3D.body_get_direct_state(body).get_contact_count() > 0, "contact reports resume after reattaching")
	PhysicsServer3D.free_rid(body)
	PhysicsServer3D.free_rid(floor_body)
	PhysicsServer3D.free_rid(shape)
	for i in 3: await physics_frame
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
