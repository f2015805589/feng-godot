extends SceneTree
const GROUND_CASES = ["cloth_ground", "cloth_ground_no_balls", "cloth_ground_no_self", "cloth_reimpact", "cloth_reimpact_create"]
var objects: Array[Node] = []
var frames := 0
var samples: Array[float] = []
var mode := "rigid"
var starters: Array[RigidBody3D] = []
var soft_bodies: Array[RID] = []
var solver_meshes: Array[ArrayMesh] = []
var actors: Array[CharacterBody3D] = []
var balls: Array[RigidBody3D] = []
var ground_cloth: RID
var cloth_pins: Array[int] = []
var reimpact_balls: Array[RigidBody3D] = []
var reimpact_trigger_frames: Array[int] = []
var reimpact_trigger_balls: Array[int] = []
var reimpact_trigger_speeds: Array[float] = []
var reimpact_trigger_cost_ms: Array[float] = []
var reimpact_trigger_targets: Array[String] = []
var reimpact_trigger_min_dist: Array[float] = []
var reimpact_trigger_hit_frame: Array[int] = []
var reimpact_windows: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="): mode = arg.trim_prefix("--case=")
	call_deferred("setup")

func _build_cloth_ground(with_balls = true, self_collision = true) -> void:
	# The playground's 3x2 m cloth: 62x30 subdivisions = 64x32 = 2048 particles.
	var plane := PlaneMesh.new()
	plane.size = Vector2(3, 2)
	plane.subdivide_width = 62
	plane.subdivide_depth = 30
	var arrays: Array = plane.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	solver_meshes.append(mesh)
	ground_cloth = PhysicsServer3D.soft_body_create()
	soft_bodies.append(ground_cloth)
	PhysicsServer3D.soft_body_set_mesh(ground_cloth, mesh.get_rid())
	PhysicsServer3D.soft_body_set_transform(ground_cloth, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 3.4, 0)))
	PhysicsServer3D.soft_body_set_simulation_precision(ground_cloth, 6)
	PhysicsServer3D.soft_body_set_linear_stiffness(ground_cloth, 0.85)
	PhysicsServer3D.soft_body_set_total_mass(ground_cloth, 1.0)
	PhysicsServer3D.soft_body_set_damping_coefficient(ground_cloth, 0.3)
	for i in vertices.size():
		if vertices[i].z < -0.99 and absf(vertices[i].x) > 1.49:
			PhysicsServer3D.soft_body_pin_point(ground_cloth, i, true)
			cloth_pins.append(i)
	PhysicsServer3D.soft_body_set_space(ground_cloth, root.world_3d.space)
	if PhysicsServer3D.has_method("soft_body_configure"):
		PhysicsServer3D.call("soft_body_configure", ground_cloth, {
			"can_sleep": true, "self_collision": self_collision, "soft_collision": true,
			"collision_radius": 0.004, "tearing": false})
	if with_balls:
		# Twenty playground balls (4 kg, r=0.3) fired at the hanging cloth at 20 m/s.
		# Rows are staggered in Z so the balls do not start overlapping each other.
		var ball_shape := SphereShape3D.new()
		ball_shape.radius = 0.3
		for row in 4:
			for column in 5:
				var ball := RigidBody3D.new()
				ball.name = "ClothBall%d_%d" % [row, column]
				ball.mass = 4.0
				ball.continuous_cd = true
				ball.contact_monitor = true
				ball.max_contacts_reported = 4
				ball.position = Vector3(-1.3 + column * 0.65, 2.55 + row * 0.55, 3.0 + row * 0.8)
				var collision := CollisionShape3D.new()
				collision.shape = ball_shape
				ball.add_child(collision)
				root.add_child(ball)
				ball.linear_velocity = Vector3(0.0, 0.0, -20.0)
				objects.append(ball)
				balls.append(ball)

func _build_reimpact_balls() -> void:
	# Three extra balls are created before warmup and kept frozen/off-layer.
	# During sampling they are only unfrozen, so no nodes are created in the timed loop.
	var launches := [Vector3(2.0, 2.0, 2.0), Vector3(-2.0, 2.0, 2.0), Vector3(0.0, 2.5, 3.5)]
	for i in launches.size():
		var ball := RigidBody3D.new()
		ball.name = "ReimpactBall%d" % i
		ball.mass = 4.0
		ball.continuous_cd = true
		ball.contact_monitor = true
		ball.max_contacts_reported = 4
		ball.freeze = true
		ball.gravity_scale = 0.0
		ball.collision_layer = 0
		ball.collision_mask = 0
		ball.can_sleep = false
		ball.position = launches[i]
		var collision := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 0.3
		collision.shape = shape
		ball.add_child(collision)
		root.add_child(ball)
		objects.append(ball)
		balls.append(ball)
		reimpact_balls.append(ball)

func _reimpact_target() -> Vector3:
	var bounds := PhysicsServer3D.soft_body_get_bounds(ground_cloth)
	var center := bounds.get_center()
	return Vector3(center.x, 0.35, center.z)

func _reimpact_velocity(ball: RigidBody3D) -> Vector3:
	var target := _reimpact_target()
	var delta := target - ball.global_position
	var horizontal := Vector2(delta.x, delta.z).length()
	var t := maxf(horizontal / 20.0, 0.05)
	return Vector3(delta.x / t, delta.y / t + 0.5 * 9.8 * t, delta.z / t)

func _create_reimpact_ball(index: int) -> RigidBody3D:
	var launches := [Vector3(2.0, 2.0, 2.0), Vector3(-2.0, 2.0, 2.0), Vector3(0.0, 2.5, 3.5)]
	var ball := RigidBody3D.new()
	ball.name = "CreateReimpactBall%d" % index
	ball.mass = 4.0
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	ball.can_sleep = false
	ball.position = launches[index]
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	collision.shape = shape
	ball.add_child(collision)
	root.add_child(ball)
	objects.append(ball)
	balls.append(ball)
	reimpact_balls.append(ball)
	return ball

func _trigger_reimpact(frame: int) -> void:
	var index := reimpact_trigger_frames.size()
	var ball: RigidBody3D
	if mode == "cloth_reimpact_create":
		if index >= 3:
			return
		ball = _create_reimpact_ball(index)
	else:
		if index >= reimpact_balls.size():
			return
		ball = reimpact_balls[index]
	var target := _reimpact_target()
	var velocity := _reimpact_velocity(ball)
	ball.freeze = false
	ball.gravity_scale = 1.0
	ball.collision_layer = 1
	ball.collision_mask = 1
	ball.linear_velocity = velocity
	ball.angular_velocity = Vector3.ZERO
	ball.sleeping = false
	reimpact_trigger_frames.append(frame)
	reimpact_trigger_balls.append(index)
	reimpact_trigger_speeds.append(velocity.length())
	reimpact_trigger_targets.append(str(target))
	reimpact_trigger_min_dist.append(1e9)
	reimpact_trigger_hit_frame.append(-1)

func _update_reimpact_distances(frame: int) -> void:
	if reimpact_trigger_frames.is_empty():
		return
	var bounds := PhysicsServer3D.soft_body_get_bounds(ground_cloth)
	for t in reimpact_trigger_frames.size():
		var ball := reimpact_balls[reimpact_trigger_balls[t]]
		if ball.freeze:
			continue
		var p := ball.global_position
		var closest := Vector3(
			clampf(p.x, bounds.position.x, bounds.end.x),
			clampf(p.y, bounds.position.y, bounds.end.y),
			clampf(p.z, bounds.position.z, bounds.end.z))
		var distance := p.distance_to(closest)
		if distance < reimpact_trigger_min_dist[t]:
			reimpact_trigger_min_dist[t] = distance
		if distance <= 0.4 and reimpact_trigger_hit_frame[t] < 0:
			reimpact_trigger_hit_frame[t] = frame

func _rigid_state() -> Dictionary:
	# Fixed order: float32 body count, then per RigidBody3D in `objects` order:
	# 12 transform floats (basis.x/y/z columns, then origin), 3 linear velocity,
	# 3 angular velocity, and 1 sleeping flag (1.0 awake, 0.0 sleeping).
	# StaticBody3D ground and non-RigidBody3D entries are skipped.
	var rigid: Array[RigidBody3D] = []
	for body in objects:
		if body is RigidBody3D:
			rigid.append(body)
	var values := PackedFloat32Array()
	values.append(float(rigid.size()))
	var awake := 0
	for body in rigid:
		var rid: RID = body.get_rid()
		var xform: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var linear: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var angular: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var sleeping: bool = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING)
		values.append(xform.basis.x.x)
		values.append(xform.basis.x.y)
		values.append(xform.basis.x.z)
		values.append(xform.basis.y.x)
		values.append(xform.basis.y.y)
		values.append(xform.basis.y.z)
		values.append(xform.basis.z.x)
		values.append(xform.basis.z.y)
		values.append(xform.basis.z.z)
		values.append(xform.origin.x)
		values.append(xform.origin.y)
		values.append(xform.origin.z)
		values.append(linear.x)
		values.append(linear.y)
		values.append(linear.z)
		values.append(angular.x)
		values.append(angular.y)
		values.append(angular.z)
		values.append(0.0 if sleeping else 1.0)
		if not sleeping:
			awake += 1
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(values.to_byte_array())
	return {"sha256": hash.finish().hex_encode(), "bodies": rigid.size(), "awake": awake}

func _ragdoll_state_sha256() -> String:
	# Same fixed float32 layout as _rigid_state, but over actors' physical_bones
	# in actor order and then bone order. _rigid_state itself is unchanged.
	var bones: Array[PhysicalBone3D] = []
	for actor in actors:
		for bone in actor.physical_bones:
			bones.append(bone)
	var values := PackedFloat32Array()
	values.append(float(bones.size()))
	for bone in bones:
		var rid: RID = bone.get_rid()
		var xform: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var linear: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var angular: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var sleeping: bool = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING)
		values.append(xform.basis.x.x)
		values.append(xform.basis.x.y)
		values.append(xform.basis.x.z)
		values.append(xform.basis.y.x)
		values.append(xform.basis.y.y)
		values.append(xform.basis.y.z)
		values.append(xform.basis.z.x)
		values.append(xform.basis.z.y)
		values.append(xform.basis.z.z)
		values.append(xform.origin.x)
		values.append(xform.origin.y)
		values.append(xform.origin.z)
		values.append(linear.x)
		values.append(linear.y)
		values.append(linear.z)
		values.append(angular.x)
		values.append(angular.y)
		values.append(angular.z)
		values.append(0.0 if sleeping else 1.0)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(values.to_byte_array())
	return hash.finish().hex_encode()

func setup() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(110, 0.2, 110)
	shape.shape = box
	ground.add_child(shape)
	ground.position.y = -0.1
	root.add_child(ground)
	objects.append(ground)
	if mode == "rigid":
		var domino := BoxShape3D.new()
		domino.size = Vector3(0.12, 1.2, 0.5)
		for ring in 30:
			var radius := 4.0 + ring * 1.15
			var count := int(TAU * radius / 0.65)
			for i in count:
				var angle := TAU * i / count
				var body := RigidBody3D.new()
				var collision := CollisionShape3D.new()
				collision.shape = domino
				body.add_child(collision)
				body.position = Vector3(cos(angle) * radius, 0.6, sin(angle) * radius)
				body.rotation.y = -angle - PI / 2
				root.add_child(body)
				objects.append(body)
				if i == 0: starters.append(body)
	elif mode.begins_with("ragdolls"):
		for i in 20:
			var actor: CharacterBody3D = load("res://addons/box3d/examples/ragdoll_actor.tscn").instantiate()
			actor.position = Vector3((i % 5) * 3.0, 3.0 + (i / 5) * 0.1, (i / 5) * 3.0)
			root.add_child(actor)
			actors.append(actor)
			objects.append(actor)
		for actor in actors:
			actor.set_ragdoll(true, Vector3(2, 0, 0))
	elif mode in ["soft_balls", "soft_rest"]:
		var sphere := SphereMesh.new()
		sphere.radial_segments = 16
		sphere.rings = 10
		for i in 8:
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
			solver_meshes.append(mesh)
			var rid := PhysicsServer3D.soft_body_create()
			soft_bodies.append(rid)
			PhysicsServer3D.soft_body_set_mesh(rid, mesh.get_rid())
			PhysicsServer3D.soft_body_set_transform(rid, Transform3D(Basis.IDENTITY, Vector3((i % 4) * 1.5, 1.2 + (i / 4) * 1.5, 0)))
			PhysicsServer3D.soft_body_set_simulation_precision(rid, 6)
			PhysicsServer3D.soft_body_set_linear_stiffness(rid, 0.6)
			PhysicsServer3D.soft_body_set_pressure_coefficient(rid, 1.0)
			PhysicsServer3D.soft_body_set_damping_coefficient(rid, 0.8)
			PhysicsServer3D.soft_body_set_total_mass(rid, 2.0)
			PhysicsServer3D.soft_body_set_space(rid, root.world_3d.space)
	elif mode == "cloth_ground":
		_build_cloth_ground()
	elif mode == "cloth_ground_no_balls":
		_build_cloth_ground(false, true)
	elif mode == "cloth_ground_no_self":
		_build_cloth_ground(true, false)
	elif mode == "cloth_reimpact":
		_build_cloth_ground(true, true)
		_build_reimpact_balls()
	elif mode == "cloth_reimpact_create":
		_build_cloth_ground(true, true)
	else:
		for layer in (3 if mode == "soft_stack" else 1):
			var plane := PlaneMesh.new()
			plane.size = Vector2(6, 6)
			plane.subdivide_width = 14 if mode == "soft_stack" else 30
			plane.subdivide_depth = plane.subdivide_width
			var pose := Transform3D(Basis(Vector3.UP, layer * 0.22), Vector3(0, 2 + layer * 0.3, 0))
			var pins: Array[int] = [0]
			if mode in ["cloth4096", "cloth2048"]:
				plane.size = Vector2(3, 2)
				plane.subdivide_width = 62
				plane.subdivide_depth = 62 if mode == "cloth4096" else 30
				pose = Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 3.4, 0))
				pins.clear()
				var vertices: PackedVector3Array = plane.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
				for v in vertices.size():
					if vertices[v].z < -0.99 and absf(vertices[v].x) > 1.49:
						pins.append(v)
			# Use server RIDs: headless SoftBody3D has no render-time pin handoff.
			# This also avoids double-submitting a deferred Node3D transform.
			var solver_mesh := ArrayMesh.new()
			solver_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plane.get_mesh_arrays())
			solver_meshes.append(solver_mesh)
			var rid := PhysicsServer3D.soft_body_create()
			soft_bodies.append(rid)
			PhysicsServer3D.soft_body_set_mesh(rid, solver_mesh.get_rid())
			PhysicsServer3D.soft_body_set_transform(rid, pose)
			PhysicsServer3D.soft_body_set_simulation_precision(rid, 6)
			if mode in ["cloth4096", "cloth2048"]:
				PhysicsServer3D.soft_body_set_linear_stiffness(rid, 0.85)
				PhysicsServer3D.soft_body_set_damping_coefficient(rid, 0.3)
			for pin in pins:
				PhysicsServer3D.soft_body_pin_point(rid, pin, true)
			PhysicsServer3D.soft_body_set_space(rid, root.world_3d.space)
			if PhysicsServer3D.has_method("soft_body_configure"):
				PhysicsServer3D.call("soft_body_configure", rid, {
					"self_collision": mode in ["soft_contacts", "soft_stack", "cloth4096", "cloth2048"],
					"soft_collision": mode in ["soft_stack", "cloth4096", "cloth2048"],
					"collision_radius": 0.004 if mode in ["cloth4096", "cloth2048"] else 0.025})
	var warmup := 1800 if mode.ends_with("rest") else 60
	if mode in GROUND_CASES: warmup = 1200
	for i in warmup:
		# Hit first, then release the top-corner pins at a fixed physics frame to
		# reproduce the lab's K cut without depending on render-time pin handoff.
		if mode in GROUND_CASES and i == 120:
			for pin in cloth_pins: PhysicsServer3D.soft_body_pin_point(ground_cloth, pin, false)
			cloth_pins.clear()
		await physics_frame
	for body in starters: body.apply_impulse(Vector3(0, 0, 0.65), Vector3(0, 0.55, 0))
	for i in 600:
		if i % 120 == 0 and mode == "ragdolls":
			for actor in actors:
				actor.physical_bones[1].apply_central_impulse(Vector3(1, 35, 0))
		if i % 120 == 0 and mode == "soft_balls":
			for body in soft_bodies:
				PhysicsServer3D.soft_body_apply_central_impulse(body, Vector3(0.2, 5, 0))
		if mode in ["cloth_reimpact", "cloth_reimpact_create"] and (i == 0 or i == 60 or i == 120):
			var trigger_start := Time.get_ticks_usec()
			_trigger_reimpact(i)
			reimpact_trigger_cost_ms.append((Time.get_ticks_usec() - trigger_start) / 1000.0)
		var started := Time.get_ticks_usec()
		await physics_frame
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
		if mode in ["cloth_reimpact", "cloth_reimpact_create"]:
			_update_reimpact_distances(i)
	var raw_samples: Array[float] = samples.duplicate()
	samples.sort()
	var total := 0.0
	for sample in samples: total += sample
	var p99_index := mini(samples.size() - 1, ceili(samples.size() * 0.99) - 1)
	var p99 := samples[p99_index]
	var max_frame_ms := -1.0
	var argmax := -1
	for i in raw_samples.size():
		if raw_samples[i] > max_frame_ms:
			max_frame_ms = raw_samples[i]
			argmax = i
	var argmax_start := maxi(0, argmax - 3)
	var argmax_end := mini(raw_samples.size() - 1, argmax + 3)
	var argmax_window: Array = raw_samples.slice(argmax_start, argmax_end + 1)
	var contact_count := 0
	var contact_tests := 0
	var particle_count := 0
	var sleeping_count := 0
	var maximum_speed := 0.0
	var kinetic_energy := 0.0
	var torn_seams := 0
	var cloth_min_y := INF
	var cloth_max_y := -INF
	var bounds_finite := true
	var soft_bounds := []
	# Outside the timed loop: compare every vertex, not just the bounding box,
	# when testing alternate worker counts or a scheduling/SIMD implementation.
	var positions_hash := HashingContext.new()
	positions_hash.start(HashingContext.HASH_SHA256)
	for body in soft_bodies:
		var stats: Dictionary = PhysicsServer3D.call("soft_body_get_statistics", body)
		var positions := PackedVector3Array()
		positions.resize(int(stats.visual_vertices))
		for i in positions.size(): positions[i] = PhysicsServer3D.soft_body_get_point_global_position(body, i)
		positions_hash.update(positions.to_byte_array())
		if mode in GROUND_CASES and body == ground_cloth:
			for i in positions.size():
				cloth_min_y = minf(cloth_min_y, positions[i].y)
				cloth_max_y = maxf(cloth_max_y, positions[i].y)
		contact_count += int(stats.contacts_solved)
		contact_tests += int(stats.contact_tests)
		maximum_speed = maxf(maximum_speed, float(stats.maximum_speed))
		kinetic_energy += float(stats.kinetic_energy)
		torn_seams += int(stats.torn_seams)
		particle_count += int(stats.particles)
		if PhysicsServer3D.soft_body_get_state(body, PhysicsServer3D.BODY_STATE_SLEEPING): sleeping_count += 1
		var measured_bounds := PhysicsServer3D.soft_body_get_bounds(body)
		bounds_finite = bounds_finite and measured_bounds.position.is_finite() and measured_bounds.size.is_finite()
		soft_bounds.append(str(measured_bounds))
		if mode in ["cloth4096", "cloth2048"] and (absf(measured_bounds.end.y - 4.404) > 0.01 or measured_bounds.position.y < 2.1):
			push_error("Benchmark hanging-cloth pose/pins were not applied")
			quit(1)
			return
	var sleeping_bones := 0
	for actor in actors:
		for bone in actor.physical_bones:
			if PhysicsServer3D.body_get_state(bone.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING): sleeping_bones += 1
	var sleeping_balls := 0
	for ball in balls:
		if ball.sleeping: sleeping_balls += 1
	var reimpact_hit_count := 0
	for hit in reimpact_trigger_hit_frame:
		if hit >= 0: reimpact_hit_count += 1
	if mode in ["cloth_reimpact", "cloth_reimpact_create"]:
		for t in reimpact_trigger_frames.size():
			var trigger_frame: int = reimpact_trigger_frames[t]
			var window_start := maxi(0, trigger_frame - 3)
			var window_end := mini(raw_samples.size() - 1, trigger_frame + 60)
			var times: Array = raw_samples.slice(window_start, window_end + 1)
			var peak_ms := 0.0
			var peak_offset := 0
			for j in times.size():
				if float(times[j]) > peak_ms:
					peak_ms = float(times[j])
					peak_offset = j
			var peak_frame := window_start + peak_offset
			reimpact_windows.append({
				"frame": trigger_frame, "ball": reimpact_trigger_balls[t],
				"target": reimpact_trigger_targets[t],
				"speed": reimpact_trigger_speeds[t],
				"trigger_cost_ms": reimpact_trigger_cost_ms[t],
				"min_distance": reimpact_trigger_min_dist[t],
				"hit_frame": reimpact_trigger_hit_frame[t],
				"window_start": window_start, "window_end": window_end,
				"peak_frame": peak_frame, "peak_ms": peak_ms, "peak_offset": peak_offset,
				"times_ms": times
			})
	var rigid_state: Dictionary = _rigid_state()
	var rigid_state_sha256: String = rigid_state.sha256
	var rigid_bodies: int = rigid_state.bodies
	var rigid_awake: int = rigid_state.awake
	var ragdoll_state_sha256: String = _ragdoll_state_sha256()
	var is_ground_case := mode in GROUND_CASES
	var cloth_landed := not is_ground_case or (cloth_min_y < 0.1 and cloth_min_y > -0.5)
	var finite_state := true
	if is_ground_case:
		finite_state = is_finite(cloth_min_y) and is_finite(cloth_max_y) and is_finite(maximum_speed) and is_finite(kinetic_energy) and bounds_finite
	if mode == "cloth_ground" and (balls.size() != 20 or particle_count != 2048 or not cloth_landed):
		push_error("cloth_ground reproduction failed: balls=%d particles=%d min_y=%s" % [balls.size(), particle_count, cloth_min_y])
		quit(1)
		return
	if mode in ["cloth_reimpact", "cloth_reimpact_create"] and (balls.size() != 23 or particle_count != 2048 or not cloth_landed or reimpact_trigger_frames.size() != 3):
		push_error("cloth_reimpact reproduction failed: mode=%s balls=%d particles=%d triggers=%d min_y=%s" % [mode, balls.size(), particle_count, reimpact_trigger_frames.size(), cloth_min_y])
		quit(1)
		return
	print("BOX3D_PERF ", JSON.stringify({"case": mode, "objects": objects.size()+soft_bodies.size(), "headless_frame_median_ms": samples[samples.size()/2], "headless_frame_mean_ms": total/samples.size(), "headless_frame_p95_ms": samples[int(samples.size()*0.95)], "ticks_hz": Engine.physics_ticks_per_second, "workers": ProjectSettings.get_setting("physics/box3d/worker_count"), "backend": PhysicsServer3D.get_class(), "soft_particles": particle_count, "soft_sleeping": sleeping_count, "ragdoll_bones": actors.size()*11, "sleeping_bones": sleeping_bones, "soft_contacts_last_step": contact_count, "soft_contact_tests_last_step": contact_tests, "headless_frame_p99_ms": p99, "headless_frame_max_ms": max_frame_ms, "frame_argmax": argmax, "frame_argmax_window_ms": argmax_window, "reimpact_trigger_frames": reimpact_trigger_frames, "reimpact_trigger_balls": reimpact_trigger_balls, "reimpact_trigger_speeds": reimpact_trigger_speeds, "reimpact_trigger_cost_ms": reimpact_trigger_cost_ms, "reimpact_trigger_targets": reimpact_trigger_targets, "reimpact_trigger_min_distance": reimpact_trigger_min_dist, "reimpact_trigger_hit_frame": reimpact_trigger_hit_frame, "reimpact_hit_count": reimpact_hit_count, "reimpact_windows": reimpact_windows, "soft_maximum_speed": maximum_speed if is_finite(maximum_speed) else null, "soft_kinetic_energy": kinetic_energy if is_finite(kinetic_energy) else null, "soft_torn_seams": torn_seams, "balls": balls.size(), "balls_sleeping": sleeping_balls, "rigid_bodies": rigid_bodies, "rigid_awake": rigid_awake, "rigid_state_sha256": rigid_state_sha256, "ragdoll_state_sha256": ragdoll_state_sha256, "cloth_landed": cloth_landed, "finite_state": finite_state, "cloth_min_y": cloth_min_y if is_ground_case and is_finite(cloth_min_y) else null, "cloth_max_y": cloth_max_y if is_ground_case and is_finite(cloth_max_y) else null, "soft_bounds": soft_bounds, "soft_positions_sha256": positions_hash.finish().hex_encode()}))
	for body in soft_bodies: PhysicsServer3D.free_rid(body)
	quit()
