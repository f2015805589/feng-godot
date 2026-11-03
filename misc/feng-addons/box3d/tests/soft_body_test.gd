extends SceneTree

var failed := false
func check(value: bool, message: String) -> void:
	print("SOFT_BODY ", message, " ", value)
	failed = failed or not value

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	# SoftBody3D uses the common body instance-ID API in its constructor.
	var node := SoftBody3D.new()
	check(PhysicsServer3D.body_get_object_instance_id(node.get_physics_rid()) == node.get_instance_id(), "SoftBody3D instance identity")
	node.free()
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position.y = -0.1
	root.add_child(floor_body)
	var source := PlaneMesh.new()
	source.size = Vector2(2, 2)
	source.subdivide_width = 6
	source.subdivide_depth = 6
	var arrays := source.get_mesh_arrays()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var body := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_space(body, root.world_3d.space)
	PhysicsServer3D.soft_body_set_total_mass(body, 2.0)
	PhysicsServer3D.soft_body_set_linear_stiffness(body, 0.9)
	PhysicsServer3D.soft_body_set_simulation_precision(body, 6)
	PhysicsServer3D.soft_body_set_mesh(body, mesh.get_rid())
	PhysicsServer3D.soft_body_set_transform(body, Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	# The SoftBody3D render handoff sends identity; it must not undo placement.
	PhysicsServer3D.soft_body_set_transform(body, Transform3D.IDENTITY)
	check(PhysicsServer3D.soft_body_get_bounds(body).position.y > 1.9, "render transform reset preserves placement")
	PhysicsServer3D.soft_body_apply_central_impulse(body, Vector3(2, 0, 0))
	var velocity: Vector3 = PhysicsServer3D.soft_body_get_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	check(absf(velocity.x - 1.0) < 0.0001, "central impulse obeys total mass")
	PhysicsServer3D.soft_body_set_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.soft_body_apply_central_force(body, Vector3(120, 0, 0))
	await physics_frame
	await physics_frame
	velocity = PhysicsServer3D.soft_body_get_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	check(velocity.x > 0.9 and velocity.x < 1.1, "force integrates once, not every subsequent frame")
	PhysicsServer3D.soft_body_set_state(body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.soft_body_pin_point(body, 0, true)
	var pinned := PhysicsServer3D.soft_body_get_point_global_position(body, 0)
	check(pinned.y > 1.9, "mesh uploaded and transformed")
	var index: int = arrays[Mesh.ARRAY_VERTEX].size()-1
	var start := PhysicsServer3D.soft_body_get_point_global_position(body, index)
	for i in 150:
		await physics_frame
	var end := PhysicsServer3D.soft_body_get_point_global_position(body, index)
	check(end.is_finite() and end.y < start.y-0.1, "gravity deforms cloth")
	check(PhysicsServer3D.soft_body_get_point_global_position(body, 0).distance_to(pinned)<0.0001, "pinned point stays fixed")
	var minimum := INF
	for i in arrays[Mesh.ARRAY_VERTEX].size():
		minimum = minf(minimum, PhysicsServer3D.soft_body_get_point_global_position(body, i).y)
	check(minimum >= -0.03, "cloth collides with Box3D floor")
	PhysicsServer3D.soft_body_add_collision_exception(body, floor_body.get_rid())
	PhysicsServer3D.soft_body_remove_all_pinned_points(body)
	check(not PhysicsServer3D.soft_body_is_point_pinned(body, 0), "unpin")
	for i in 120:
		await physics_frame
	check(PhysicsServer3D.soft_body_get_bounds(body).position.y < -0.5, "collision exception actually passes floor")
	# Rebinding and freeing a space before the soft RID must not leave a dangling pointer.
	var space := PhysicsServer3D.space_create()
	PhysicsServer3D.soft_body_set_space(body, space)
	PhysicsServer3D.free_rid(space)
	check(not PhysicsServer3D.soft_body_get_space(body).is_valid(), "space release detaches soft body")
	PhysicsServer3D.free_rid(body)
	# Closed, welded mesh keeps its volume after falling onto rigid geometry.
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	sphere.radial_segments = 12
	sphere.rings = 8
	var sphere_arrays := sphere.get_mesh_arrays()
	var sphere_mesh := ArrayMesh.new()
	sphere_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere_arrays)
	var elastic := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_mesh(elastic, sphere_mesh.get_rid())
	PhysicsServer3D.soft_body_set_transform(elastic, Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	PhysicsServer3D.soft_body_set_pressure_coefficient(elastic, 1.0)
	PhysicsServer3D.soft_body_set_damping_coefficient(elastic, 0.8)
	PhysicsServer3D.soft_body_set_space(elastic, root.world_3d.space)
	var sphere_indices: PackedInt32Array = sphere_arrays[Mesh.ARRAY_INDEX]
	var volume_before := volume(elastic, sphere_indices)
	for i in 180:
		await physics_frame
	var volume_after := volume(elastic, sphere_indices)
	var bounds := PhysicsServer3D.soft_body_get_bounds(elastic)
	print("SOFT_BODY elastic bounds=", bounds, " volume_ratio=", volume_after / volume_before)
	check(volume_after / volume_before > 0.7 and volume_after / volume_before < 1.3, "closed mesh volume retained")
	check(bounds.position.y > -0.06 and bounds.position.y < 0.1 and bounds.size.is_finite(), "elastic mesh rests on rigid floor")
	PhysicsServer3D.free_rid(elastic)
	floor_body.free()
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func volume(body: RID, indices: PackedInt32Array) -> float:
	var result := 0.0
	var origin := PhysicsServer3D.soft_body_get_point_global_position(body, 0)
	for i in range(0, indices.size(), 3):
		var a := PhysicsServer3D.soft_body_get_point_global_position(body, indices[i])-origin
		var b := PhysicsServer3D.soft_body_get_point_global_position(body, indices[i+1])-origin
		var c := PhysicsServer3D.soft_body_get_point_global_position(body, indices[i+2])-origin
		result += a.dot(b.cross(c)) / 6.0
	return absf(result)
