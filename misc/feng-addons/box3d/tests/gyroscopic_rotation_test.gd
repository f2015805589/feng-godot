extends SceneTree
## Torque-free symmetric bodies keep angular velocity; asymmetric bodies precess.

var bodies: Dictionary = {}
var traces: Dictionary = {}
var initial_spin := Vector3(2.0, 3.0, 1.0)
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _box(size: Vector3) -> BoxShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	return shape

func _add(name_: String, shape: Shape3D) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = name_
	body.position = Vector3(bodies.size() * 5.0, 0, 0)
	body.rotation = Vector3(0.4, -0.7, 0.9)
	body.gravity_scale = 0.0
	body.can_sleep = false
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = 0.0
	body.collision_layer = 0
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	root.add_child(body)
	bodies[name_] = body
	traces[name_] = []
	return body

func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _run() -> void:
	_add("cube", _box(Vector3.ONE))
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	_add("sphere", sphere)
	_add("rod", _box(Vector3(0.2, 2.0, 0.3)))
	var near := _add("nearly_isotropic", _box(Vector3.ONE))
	near.inertia = Vector3(1.0, 1.001, 1.002)
	var compound := _add("compound", _box(Vector3(0.2, 2.0, 0.3)))
	var child := CollisionShape3D.new()
	child.shape = _box(Vector3(1.2, 0.3, 0.4))
	child.position = Vector3(0.6, 0.7, 0.4)
	child.rotation = Vector3(0.2, 0.3, 0.4)
	compound.add_child(child)
	_add("stationary", _box(Vector3(0.2, 2.0, 0.3)))
	await process_frame
	await process_frame
	for key in bodies:
		if key != "stationary": bodies[key].angular_velocity = initial_spin
	for frame in range(360):
		await process_frame
		if frame % 30 != 29: continue
		for key in bodies:
			var body: RigidBody3D = bodies[key]
			var w := body.angular_velocity
			var q := body.basis.get_rotation_quaternion()
			traces[key].append([w.x, w.y, w.z, q.x, q.y, q.z, q.w])
			_check(w.is_finite() and q.is_finite(), key + " finite spin and orientation")
	for key in ["cube", "sphere"]:
		var body: RigidBody3D = bodies[key]
		_check(body.angular_velocity.distance_to(initial_spin) < 0.005, key + " preserves torque-free angular velocity")
	_check(bodies.stationary.angular_velocity == Vector3.ZERO, "unforced stationary body stays stationary")
	for key in ["rod", "nearly_isotropic", "compound"]:
		var body: RigidBody3D = bodies[key]
		_check(body.angular_velocity.distance_to(initial_spin) > 0.001, key + " retains gyroscopic precession")
	# A tensor edited at runtime must leave the symmetric fast path immediately.
	var cube: RigidBody3D = bodies.cube
	cube.inertia = Vector3(0.1, 1.0, 1.0)
	cube.angular_velocity = initial_spin
	for frame in range(60): await process_frame
	_check(cube.angular_velocity.distance_to(initial_spin) > 0.01, "runtime inertia change takes effect")
	print("GYRO_TRACE ", JSON.stringify(traces))
	for body in bodies.values(): body.queue_free()
	bodies.clear()
	await process_frame
	print("RESULT: PASS" if failures == 0 else "RESULT: FAIL")
	quit(0 if failures == 0 else 1)
