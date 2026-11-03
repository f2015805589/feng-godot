extends SceneTree

var meshes: Array[ArrayMesh] = []
var bodies: Array[RID] = []
var failed := false

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("CONTACT_CACHE ", message, " ", ok)
	failed = failed or not ok

func patch(x: float, y: float, size: float) -> Array:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * size
	plane.subdivide_width = 2
	plane.subdivide_depth = 2
	var arrays := plane.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size(): vertices[i] += Vector3(x, y, 0)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	return arrays

func make_mesh(arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	meshes.append(mesh)
	return mesh

func make_body(arrays: Array, pinned: bool) -> RID:
	var body := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_mesh(body, make_mesh(arrays).get_rid())
	PhysicsServer3D.soft_body_set_space(body, root.world_3d.space)
	PhysicsServer3D.soft_body_set_linear_stiffness(body, 0.9)
	PhysicsServer3D.call("soft_body_configure", body, {"can_sleep": false})
	if pinned:
		for i in arrays[Mesh.ARRAY_VERTEX].size(): PhysicsServer3D.soft_body_pin_point(body, i, true)
	bodies.append(body)
	return body

func height(body: RID, tile: int) -> float:
	var value := 0.0
	for i in 16: value += PhysicsServer3D.soft_body_get_point_global_position(body, tile * 16 + i).y
	return value / 16.0

func run() -> void:
	# One disconnected source mesh simultaneously contacts six independent
	# targets, exceeding the bounded candidate cache. Eviction must only cause
	# recomputation, never drop collisions or retain a destroyed target's faces.
	var combined: Array = []
	combined.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var supports: Array[RID] = []
	for tile in 6:
		supports.append(make_body(patch(tile * 2.0, 0, 1.5), true))
		var upper := patch(tile * 2.0, 0.3, 1.0)
		var offset := vertices.size()
		vertices.append_array(upper[Mesh.ARRAY_VERTEX])
		for index in upper[Mesh.ARRAY_INDEX]: indices.append(offset + index)
	combined[Mesh.ARRAY_VERTEX] = vertices
	combined[Mesh.ARRAY_INDEX] = indices
	var source := make_body(combined, false)
	for i in 120: await physics_frame
	for tile in 6: check(height(source, tile) > 0.025, "all six supports survive cache eviction: %d" % tile)
	PhysicsServer3D.free_rid(supports[2])
	bodies.erase(supports[2])
	# Replace a still-live collider's topology while other pairs remain cached.
	var replacement := patch(2.0, -0.4, 1.5)
	PhysicsServer3D.soft_body_set_mesh(supports[1], make_mesh(replacement).get_rid())
	for i in 90: await physics_frame
	check(height(source, 2) < -1.0, "deleted target no longer supplies cached contacts")
	check(height(source, 1) > -0.39 and height(source, 1) < -0.2, "replacement mesh uses its new surface")
	for tile in [0, 3, 4, 5]: check(height(source, tile) > 0.025, "unrelated cached support remains stable: %d" % tile)
	for body in bodies: PhysicsServer3D.free_rid(body)
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
