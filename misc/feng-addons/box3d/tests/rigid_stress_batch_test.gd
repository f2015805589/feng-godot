extends SceneTree
## Direct states must remain live across stepping, reset, and batch recreation.

var failed := false

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		print("FAIL: ", message)

func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(46, 1, 38)
	collision.shape = shape
	floor_body.add_child(collision)
	floor_body.position.y = -0.5
	stage.add_child(floor_body)
	var batch: RefCounted = ClassDB.instantiate("FengPhysicsStressBatch")
	for count in [256, 17, 1000]:
		batch.call("create", stage.get_world_3d().space, count, false)
		var initial: Dictionary = batch.call("inspect")
		_check(initial.bodies == count, "Recreate count")
		for step in 30:
			await physics_frame
		await process_frame
		var moved: Dictionary = batch.call("inspect")
		_check(moved.highest_center < initial.highest_center - 0.1, "Bodies actually simulated")
		_check(moved.invalid == 0 and moved.escaped == 0, "Valid supported bodies")
		_check(moved.transform_mismatches == 0, "Typed states match current server poses")
		batch.call("reset")
		var reset: Dictionary = batch.call("inspect")
		_check(is_equal_approx(reset.highest_center, initial.highest_center), "Reset restores transforms")
		_check(reset.transform_mismatches == 0, "Direct states see the reset immediately")
		batch.call("set_sleep_enabled", true)
		batch.call("set_sleep_enabled", false)
		batch.call("agitate", 1)
		await physics_frame
		await process_frame
		var kicked: Dictionary = batch.call("inspect")
		_check(kicked.awake == count and kicked.transform_mismatches == 0, "Wake and impulse keep states valid")
		batch.call("clear")
		_check(batch.call("inspect").bodies == 0, "Clear releases the owned bodies and state pointers")
	batch = null
	stage.queue_free()
	await process_frame
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
