extends SceneTree
var meshes: Array[ArrayMesh] = []
var bodies: Array[RID] = []
var failed := false

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("SOFT_CONTACT ", message, " ", ok)
	failed = failed or not ok

func patch(size: float, y: float, rotation_y := 0.0) -> Array:
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	plane.subdivide_width = 3
	plane.subdivide_depth = 3
	var arrays := plane.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		vertices[i] = Basis(Vector3.UP, rotation_y) * vertices[i] + Vector3(0,y,0)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	return arrays

func make_body(arrays: Array) -> RID:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	meshes.append(mesh)
	var body := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_mesh(body, mesh.get_rid())
	PhysicsServer3D.soft_body_set_space(body, root.world_3d.space)
	PhysicsServer3D.soft_body_set_linear_stiffness(body, 0.9)
	bodies.append(body)
	return body

func lowest(body: RID, start: int, count: int) -> float:
	var value := INF
	for i in range(start, start+count):
		value = minf(value, PhysicsServer3D.soft_body_get_point_global_position(body,i).y)
	return value

func run() -> void:
	var lower_arrays := patch(4,0)
	var upper_arrays := patch(1,0.7,0.37)
	var count: int = upper_arrays[Mesh.ARRAY_VERTEX].size()
	var lower := make_body(lower_arrays)
	for i in lower_arrays[Mesh.ARRAY_VERTEX].size(): PhysicsServer3D.soft_body_pin_point(lower,i,true)
	var upper := make_body(upper_arrays)
	for i in 120: await physics_frame
	check(lowest(upper,0,count)>0.025, "separate soft meshes support each other between unaligned vertices")
	# Godot collision masks use either side's mask, not a two-sided AND.
	PhysicsServer3D.soft_body_set_collision_layer(lower, 2)
	PhysicsServer3D.soft_body_set_collision_mask(lower, 0)
	PhysicsServer3D.soft_body_set_collision_mask(upper, 2)
	for i in 60: await physics_frame
	check(lowest(upper,0,count)>0.025, "asymmetric soft collision mask still collides")
	PhysicsServer3D.soft_body_set_collision_mask(upper, 0)
	for i in 60: await physics_frame
	check(lowest(upper,0,count)<-0.4, "both masks rejecting disables soft collision")
	PhysicsServer3D.free_rid(upper); bodies.erase(upper)
	upper = make_body(upper_arrays)
	PhysicsServer3D.soft_body_set_collision_mask(upper, 2)
	PhysicsServer3D.soft_body_add_collision_exception(upper,lower)
	for i in 60: await physics_frame
	check(lowest(upper,0,count)<-0.4, "soft collision exceptions honored")
	PhysicsServer3D.free_rid(upper); bodies.erase(upper)
	PhysicsServer3D.free_rid(lower); bodies.erase(lower)
	# One soft mesh has two disconnected patches: a pinned lower layer and a
	# falling upper layer. Self contact must operate on triangles, not just points.
	var combined := lower_arrays.duplicate(true)
	var vertices: PackedVector3Array = combined[Mesh.ARRAY_VERTEX]
	var lower_count := vertices.size()
	vertices.append_array(upper_arrays[Mesh.ARRAY_VERTEX])
	combined[Mesh.ARRAY_VERTEX] = vertices
	combined[Mesh.ARRAY_NORMAL] = null
	combined[Mesh.ARRAY_TANGENT] = null
	combined[Mesh.ARRAY_TEX_UV] = null
	var indices: PackedInt32Array = combined[Mesh.ARRAY_INDEX]
	for index in upper_arrays[Mesh.ARRAY_INDEX]: indices.append(index+lower_count)
	combined[Mesh.ARRAY_INDEX] = indices
	var folded := make_body(combined)
	for i in lower_count: PhysicsServer3D.soft_body_pin_point(folded,i,true)
	for i in 120: await physics_frame
	check(lowest(folded,lower_count,count)>0.025, "self contact separates folded layers")
	PhysicsServer3D.call("soft_body_configure",folded,{"self_collision":false})
	for i in 60: await physics_frame
	check(lowest(folded,lower_count,count)<-0.4, "self contact toggle works")
	for body in bodies: PhysicsServer3D.free_rid(body)
	bodies.clear()
	# Enlarge collision thickness after a cached broadphase has been built.
	# Unchanged vertices must not keep the old, too-small face bounds alive.
	lower = make_body(lower_arrays)
	for i in lower_count: PhysicsServer3D.soft_body_pin_point(lower,i,true)
	upper = make_body(patch(1,0.18,0.37))
	for body in bodies: PhysicsServer3D.call("soft_body_configure",body,{"collision_radius":0.005})
	await physics_frame
	await physics_frame
	for body in bodies: PhysicsServer3D.call("soft_body_configure",body,{"collision_radius":0.1})
	for i in 3: await physics_frame
	check(lowest(upper,0,count)>0.19, "collision radius edit invalidates cached swept bounds")
	for body in bodies: PhysicsServer3D.free_rid(body)
	bodies.clear()
	# Swept contact: cross a pinned triangle surface in a single substep.
	lower = make_body(lower_arrays)
	for i in lower_count: PhysicsServer3D.soft_body_pin_point(lower,i,true)
	upper = make_body(patch(1,0.2,0.37))
	PhysicsServer3D.soft_body_set_state(upper,PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,Vector3(0,-100,0))
	for i in 5: await physics_frame
	check(lowest(upper,0,count)>0.015, "swept point/triangle prevents fast layer crossing")
	for body in bodies: PhysicsServer3D.free_rid(body)
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
