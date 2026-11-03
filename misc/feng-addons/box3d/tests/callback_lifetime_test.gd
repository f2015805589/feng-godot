extends SceneTree

var failed := false
var bodies: Array[RID] = []
var pair: Array[RID] = []
var shape: RID
var ordinal := 0
var sync_count := 0
var integration_count := 0
var deleted_count := 0
var replacement: RID

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("CALLBACK_LIFETIME ", message, " ", ok)
	failed = failed or not ok

func make_body() -> RID:
	var body := PhysicsServer3D.body_create()
	bodies.append(body)
	ordinal += 1
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis(), Vector3(ordinal * 4, 10, 0)))
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, false)
	PhysicsServer3D.body_set_space(body, root.world_3d.space)
	return body

func count_sync(_state: PhysicsDirectBodyState3D) -> void:
	sync_count += 1

func integrate_with_data(state: PhysicsDirectBodyState3D, data: int) -> void:
	integration_count += 1
	check(data == 73 and state is PhysicsDirectBodyState3D, "integration argument types and userdata")

func delete_in_integration(_state: PhysicsDirectBodyState3D, body: RID) -> void:
	PhysicsServer3D.free_rid(body)
	bodies.erase(body)
	deleted_count += 1

func delete_in_sync(_state: PhysicsDirectBodyState3D) -> void:
	# Free the current body and another RID still present in the callback batch.
	# Create a replacement immediately to exercise RID slot reuse as well.
	for body in pair:
		PhysicsServer3D.free_rid(body)
		bodies.erase(body)
		deleted_count += 1
	pair.clear()
	replacement = make_body()
	PhysicsServer3D.body_set_state_sync_callback(replacement, count_sync)

func run() -> void:
	shape = PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(shape, 0.25)
	var idle := make_body()
	PhysicsServer3D.body_set_state_sync_callback(idle, count_sync)
	for i in 8: await physics_frame
	check(sync_count >= 6, "awake stationary bodies still receive state sync")
	PhysicsServer3D.body_set_state(idle, PhysicsServer3D.BODY_STATE_SLEEPING, true)
	for i in 4: await physics_frame
	var sleeping_count := sync_count
	for i in 8: await physics_frame
	check(sync_count == sleeping_count, "sleeping bodies stop redundant state sync")
	PhysicsServer3D.body_set_force_integration_callback(idle, integrate_with_data, 73)
	for i in 3: await physics_frame
	check(integration_count >= 2, "sleeping custom integrator retains its callbacks")
	PhysicsServer3D.body_set_force_integration_callback(idle, Callable())
	PhysicsServer3D.body_apply_central_impulse(idle, Vector3.RIGHT)
	for i in 6: await physics_frame
	check(sync_count >= sleeping_count + 4, "waking a body resumes state sync")
	PhysicsServer3D.free_rid(idle)
	bodies.erase(idle)
	var self_deleting := make_body()
	PhysicsServer3D.body_set_force_integration_callback(self_deleting, delete_in_integration.bind(self_deleting))
	PhysicsServer3D.body_set_state_sync_callback(self_deleting, count_sync)
	var before_sync := sync_count
	for i in 3: await physics_frame
	check(deleted_count == 1 and sync_count == before_sync, "integration can free its own body before sync")
	for i in 2:
		var body := make_body()
		pair.append(body)
		PhysicsServer3D.body_set_state_sync_callback(body, delete_in_sync)
	for i in 6: await physics_frame
	check(deleted_count == 3 and pair.is_empty(), "sync can free itself and another queued body")
	check(replacement.is_valid() and sync_count > before_sync + 2, "new body callbacks survive RID recycling")
	for body in bodies: PhysicsServer3D.free_rid(body)
	PhysicsServer3D.free_rid(shape)
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
