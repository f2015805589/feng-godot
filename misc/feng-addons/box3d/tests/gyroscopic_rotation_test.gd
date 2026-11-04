extends SceneTree
## Torque-free symmetric bodies keep angular velocity; asymmetric bodies precess.
## G3 adds numeric invariants for the gyroscopic torque: no gravity, no damping, no sleep.

var bodies: Dictionary = {}
var traces: Dictionary = {}
var initial_spin := Vector3(2.0, 3.0, 1.0)
var failures := 0

const DT := 1.0 / 60.0
const LONG_FRAMES := 1200 # 20 s of simulated time at 60 Hz

func _initialize() -> void:
	_run.call_deferred()

func _box(size: Vector3) -> BoxShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	return shape

func _add(name_: String, shape: Shape3D) -> RigidBody3D:
	return _add_free(name_, [shape], Vector3(0.4, -0.7, 0.9))

func _add_free(name_: String, shapes: Array, rotation := Vector3.ZERO) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = name_
	body.position = Vector3(bodies.size() * 5.0, 0, 0)
	body.rotation = rotation
	body.gravity_scale = 0.0
	body.can_sleep = false
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = 0.0
	body.collision_layer = 0
	body.collision_mask = 0
	root.add_child(body)
	for shape in shapes:
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
	bodies[name_] = body
	traces[name_] = []
	return body

func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _quat(body: RigidBody3D) -> Quaternion:
	return body.basis.get_rotation_quaternion()

func _local_omega(body: RigidBody3D) -> Vector3:
	return _quat(body).inverse() * body.angular_velocity

func _world_L(body: RigidBody3D, inertia: Vector3) -> Vector3:
	var q := _quat(body)
	var w := q.inverse() * body.angular_velocity
	return q * Vector3(inertia.x * w.x, inertia.y * w.y, inertia.z * w.z)

func _rot_ke(body: RigidBody3D, inertia: Vector3) -> float:
	var w := _local_omega(body)
	return 0.5 * (inertia.x * w.x * w.x + inertia.y * w.y * w.y + inertia.z * w.z * w.z)

func _rel_err(a: float, b: float) -> float:
	return absf(a - b) / maxf(absf(b), 1e-9)

## RigidBody3D.inertia is the node cached property (zero means "auto"), so read
## the tensor the physics server actually uses.
func _server_inertia(body: RigidBody3D) -> Vector3:
	return PhysicsServer3D.body_get_param(body.get_rid(), PhysicsServer3D.BODY_PARAM_INERTIA)

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

	# --- G3 numeric sections -------------------------------------------------
	await _run_axial_control()
	await _run_precession()
	await _run_intermediate_axis()

	print("GYRO_TRACE ", JSON.stringify(traces))
	for body in bodies.values(): body.queue_free()
	bodies.clear()
	await process_frame
	print("RESULT: PASS" if failures == 0 else "RESULT: FAIL")
	quit(0 if failures == 0 else 1)

## A: spin about the symmetry axis of a symmetric rod. The gyroscopic term is
## identically zero, so omega must not change at all (no precession).
func _run_axial_control() -> void:
	var rod := _add_free("gyro_axial", [_box(Vector3(0.2, 2.0, 0.2))])
	await process_frame
	await process_frame
	var inertia: Vector3 = _server_inertia(rod)
	_check(inertia.y < inertia.x and inertia.y < inertia.z,
			"axial rod: Iyy is the smallest (%.6f < %.6f, %.6f)" % [inertia.y, inertia.x, inertia.z])
	var w0 := Vector3(0, 5, 0)
	rod.angular_velocity = w0
	var L0 := _world_L(rod, inertia)
	var ke0 := _rot_ke(rod, inertia)
	var max_dw := 0.0
	var max_dL := 0.0
	var max_dke := 0.0
	for frame in range(240):
		await process_frame
		max_dw = maxf(max_dw, (rod.angular_velocity - w0).length())
		max_dL = maxf(max_dL, (_world_L(rod, inertia) - L0).length())
		max_dke = maxf(max_dke, absf(_rot_ke(rod, inertia) - ke0))
	print("GYRO_NUMERIC_A ", JSON.stringify({
		"omega_drift": max_dw, "L_drift": max_dL, "ke_drift": max_dke,
		"Ixx": inertia.x, "Iyy": inertia.y, "Izz": inertia.z}))
	_check(max_dw < 1e-3, "axial spin keeps omega (drift %.6f)" % max_dw)
	_check(max_dL / maxf(L0.length(), 1e-9) < 1e-3, "axial spin keeps |L|")
	_check(max_dke / maxf(ke0, 1e-9) < 1e-3, "axial spin keeps rotational KE")

## B: symmetric top (rod + centred hub). Tilted omega must precess in the body
## frame at Omega = omega_axial * (C - A) / C while the invariants of the
## midpoint scheme hold: |L| and KE. The world direction of L is carried by the
## quaternion integration, so it can only be bounded, not bitwise constant.
## Bound the direction error by 2 * |omega| * h_sub (h_sub = DT / 4, 4 substeps)
## and require that it does not grow with time.
func _run_precession() -> void:
	var hub := SphereShape3D.new()
	hub.radius = 0.15
	var body := _add_free("gyro_precess", [_box(Vector3(0.2, 2.0, 0.2)), hub])
	await process_frame
	await process_frame
	var inertia: Vector3 = _server_inertia(body)
	var axial := inertia.y
	var trans := 0.5 * (inertia.x + inertia.z)
	_check(absf(inertia.x - inertia.z) / maxf(trans, 1e-9) < 1e-3,
			"symmetric top: Ixx == Izz (%.6f vs %.6f)" % [inertia.x, inertia.z])
	_check(axial < trans, "symmetric top: axial moment is the smallest")
	var w0 := Vector3(0.0, 1.0, 0.5).normalized() * 6.0
	body.angular_velocity = w0
	var L0 := _world_L(body, inertia)
	var ke0 := _rot_ke(body, inertia)
	var axis0 := (body.basis * Vector3.UP).normalized()
	var angle0 := rad_to_deg(acos(clampf(w0.normalized().dot(axis0), -1.0, 1.0)))
	var pos0 := body.global_position
	var omega_axial := _local_omega(body).y
	var prev_phi := atan2(_local_omega(body).z, _local_omega(body).x)
	var phase := 0.0
	var max_dL := 0.0
	var max_dlen := 0.0
	var max_dir := 0.0
	var dir_sum_early := 0.0
	var dir_sum_late := 0.0
	var dir_count_early := 0
	var dir_count_late := 0
	var max_dke := 0.0
	var max_dangle := 0.0
	var max_dpos := 0.0
	var max_domega := 0.0
	for frame in range(LONG_FRAMES):
		await process_frame
		var l_now := _world_L(body, inertia)
		max_dL = maxf(max_dL, (l_now - L0).length())
		max_dlen = maxf(max_dlen, absf(l_now.length() - L0.length()))
		var dir := acos(clampf(l_now.normalized().dot(L0.normalized()), -1.0, 1.0))
		max_dir = maxf(max_dir, dir)
		if frame < LONG_FRAMES / 4:
			dir_sum_early += dir
			dir_count_early += 1
		elif frame >= LONG_FRAMES * 3 / 4:
			dir_sum_late += dir
			dir_count_late += 1
		max_dke = maxf(max_dke, absf(_rot_ke(body, inertia) - ke0))
		var axis := (body.basis * Vector3.UP).normalized()
		var angle := rad_to_deg(acos(clampf(body.angular_velocity.normalized().dot(axis), -1.0, 1.0)))
		max_dangle = maxf(max_dangle, absf(angle - angle0))
		max_dpos = maxf(max_dpos, (body.global_position - pos0).length())
		max_domega = maxf(max_domega, absf(body.angular_velocity.length() - w0.length()))
		var phi := atan2(_local_omega(body).z, _local_omega(body).x)
		phase += wrapf(phi - prev_phi, -PI, PI)
		prev_phi = phi
		if frame % 240 == 239:
			print("GYRO_SAMPLE_B t=%.1f L_len=%.6f L_angle_deg=%.3f omega_len=%.6f omega_axis_deg=%.3f" % [
				(frame + 1) * DT, l_now.length(),
				rad_to_deg(acos(clampf(l_now.normalized().dot(L0.normalized()), -1.0, 1.0))),
				body.angular_velocity.length(),
				rad_to_deg(acos(clampf(body.angular_velocity.normalized().dot((body.basis * Vector3.UP).normalized()), -1.0, 1.0)))])
	var omega_measured := absf(phase) / (LONG_FRAMES * DT)
	var omega_predicted := absf(omega_axial) * (trans - axial) / trans
	var changed := body.angular_velocity.distance_to(w0)
	var h_sub := DT / 4.0
	var dir_bound := 2.0 * w0.length() * h_sub
	var dir_early := dir_sum_early / float(maxi(dir_count_early, 1))
	var dir_late := dir_sum_late / float(maxi(dir_count_late, 1))
	var dir_growth := absf(dir_late - dir_early)
	print("GYRO_NUMERIC_B ", JSON.stringify({
		"frames": LONG_FRAMES, "seconds": LONG_FRAMES * DT,
		"L0": L0.length(),
		"L_vec_drift_rel": max_dL / maxf(L0.length(), 1e-9),
		"L_len_drift_rel": max_dlen / maxf(L0.length(), 1e-9),
		"dir_max_deg": rad_to_deg(max_dir), "dir_bound_deg": rad_to_deg(dir_bound),
		"dir_mean_early_deg": rad_to_deg(dir_early), "dir_mean_late_deg": rad_to_deg(dir_late),
		"ke0": ke0, "ke_drift_rel": max_dke / maxf(ke0, 1e-9),
		"angle0_deg": angle0, "angle_drift_deg": max_dangle,
		"com_drift": max_dpos, "omega_drift": max_domega,
		"omega_axial": omega_axial, "omega_measured": omega_measured,
		"omega_predicted": omega_predicted,
		"precession_rel_err": _rel_err(omega_measured, omega_predicted),
		"omega_world_changed": changed}))
	_check(max_dlen / maxf(L0.length(), 1e-9) < 0.005,
			"symmetric top conserves |L| modulus (rel drift %.6f)" % (max_dlen / maxf(L0.length(), 1e-9)))
	_check(max_dir <= dir_bound,
			"world L direction error bounded by 2*|omega|*h (max %.4f deg <= %.4f deg)" % [rad_to_deg(max_dir), rad_to_deg(dir_bound)])
	_check(dir_growth <= 0.25 * dir_bound,
			"world L direction error does not grow (early mean %.4f deg, late mean %.4f deg)" % [rad_to_deg(dir_early), rad_to_deg(dir_late)])
	_check(max_dke / maxf(ke0, 1e-9) < 0.01, "symmetric top conserves rotational KE (rel drift %.5f)" % (max_dke / maxf(ke0, 1e-9)))
	_check(max_dangle < 0.5, "axis/omega angle is constant (drift %.4f deg)" % max_dangle)
	_check(max_dpos < 1e-3, "COM stays fixed (drift %.6f m)" % max_dpos)
	_check(omega_measured > 0.5 and changed > 0.05, "omega visibly precesses (world change %.3f)" % changed)
	_check(_rel_err(omega_measured, omega_predicted) < 0.05,
			"precession rate matches omega_ax*(C-A)/C (measured %.4f, predicted %.4f)" % [omega_measured, omega_predicted])

## C: intermediate-axis (tennis-racket / Dzhanibekov) test. The body-frame
## intermediate component must change sign. |L| modulus and KE are the exact
## invariants; the world L direction is only bounded by the quaternion
## integration (same 2 * |omega| * h_sub bound as B).
func _run_intermediate_axis() -> void:
	var body := _add_free("gyro_intermediate", [_box(Vector3(2.0, 1.0, 0.4))])
	await process_frame
	await process_frame
	var inertia: Vector3 = _server_inertia(body)
	_check(inertia.x < inertia.y and inertia.y < inertia.z,
			"intermediate axis is Y (%.6f < %.6f < %.6f)" % [inertia.x, inertia.y, inertia.z])
	var w0 := Vector3(0.08, 1.0, 0.0).normalized() * 8.0
	body.angular_velocity = w0
	var L0 := _world_L(body, inertia)
	var ke0 := _rot_ke(body, inertia)
	var last_sign := signf(_local_omega(body).y)
	var flips := 0
	var flip_frame := -1
	var max_dL := 0.0
	var max_dlen := 0.0
	var max_dir := 0.0
	var dir_sum_early := 0.0
	var dir_sum_late := 0.0
	var dir_count_early := 0
	var dir_count_late := 0
	var max_dke := 0.0
	for frame in range(600):
		await process_frame
		var s := signf(_local_omega(body).y)
		if s != last_sign:
			flips += 1
			if flip_frame < 0: flip_frame = frame
			last_sign = s
		var l_now := _world_L(body, inertia)
		max_dL = maxf(max_dL, (l_now - L0).length())
		max_dlen = maxf(max_dlen, absf(l_now.length() - L0.length()))
		var dir := acos(clampf(l_now.normalized().dot(L0.normalized()), -1.0, 1.0))
		max_dir = maxf(max_dir, dir)
		if frame < 150:
			dir_sum_early += dir
			dir_count_early += 1
		elif frame >= 450:
			dir_sum_late += dir
			dir_count_late += 1
		max_dke = maxf(max_dke, absf(_rot_ke(body, inertia) - ke0))
	var flip_time := -1.0
	if flip_frame >= 0: flip_time = (flip_frame + 1) * DT
	var h_sub := DT / 4.0
	var dir_bound := 2.0 * w0.length() * h_sub
	var dir_early := dir_sum_early / float(maxi(dir_count_early, 1))
	var dir_late := dir_sum_late / float(maxi(dir_count_late, 1))
	var dir_growth := absf(dir_late - dir_early)
	print("GYRO_NUMERIC_C ", JSON.stringify({
		"frames": 600, "flips": flips, "flip_time_s": flip_time,
		"L_vec_drift_rel": max_dL / maxf(L0.length(), 1e-9),
		"L_len_drift_rel": max_dlen / maxf(L0.length(), 1e-9),
		"dir_max_deg": rad_to_deg(max_dir), "dir_bound_deg": rad_to_deg(dir_bound),
		"dir_mean_early_deg": rad_to_deg(dir_early), "dir_mean_late_deg": rad_to_deg(dir_late),
		"ke_drift_rel": max_dke / maxf(ke0, 1e-9),
		"omega_local_y": _local_omega(body).y,
		"inertia": [inertia.x, inertia.y, inertia.z]}))
	_check(flips >= 1, "intermediate-axis component changes sign (%d flips, t=%.3f s)" % [flips, flip_time])
	_check(max_dlen / maxf(L0.length(), 1e-9) < 0.02,
			"intermediate flip conserves |L| modulus (rel drift %.6f)" % (max_dlen / maxf(L0.length(), 1e-9)))
	_check(max_dir <= dir_bound,
			"intermediate world L direction bounded by 2*|omega|*h (max %.4f deg <= %.4f deg)" % [rad_to_deg(max_dir), rad_to_deg(dir_bound)])
	_check(dir_growth <= 0.25 * dir_bound,
			"intermediate world L direction does not grow (early mean %.4f deg, late mean %.4f deg)" % [rad_to_deg(dir_early), rad_to_deg(dir_late)])
	_check(max_dke / maxf(ke0, 1e-9) < 0.02, "intermediate flip conserves rotational KE (rel drift %.5f)" % (max_dke / maxf(ke0, 1e-9)))
