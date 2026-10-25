extends SceneTree

const Snapshot = preload("res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var snapshot := Snapshot.new()
	var node := MeshInstance3D.new()
	var meshes: Array[Mesh] = [BoxMesh.new(), PlaneMesh.new(), SphereMesh.new(), CylinderMesh.new()]
	for influences in [0, 4, 8]:
		var arrays := PlaneMesh.new().get_mesh_arrays()
		var mesh := ArrayMesh.new()
		mesh.add_blend_shape("offset")
		var shape: Array = []
		shape.resize(Mesh.ARRAY_MAX)
		for attribute in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT]:
			shape[attribute] = arrays[attribute]
		if influences > 0:
			var bones := PackedInt32Array()
			var weights := PackedFloat32Array()
			bones.resize(arrays[Mesh.ARRAY_VERTEX].size() * influences)
			weights.resize(bones.size())
			weights.fill(1.0 / influences)
			arrays[Mesh.ARRAY_BONES] = bones
			arrays[Mesh.ARRAY_WEIGHTS] = weights
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [shape], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if influences == 8 else 0)
		meshes.append(mesh)
	var unindexed := ArrayMesh.new()
	var triangle: Array = []
	triangle.resize(Mesh.ARRAY_MAX)
	triangle[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	triangle[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	unindexed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, triangle)
	meshes.append(unindexed)
	var passed := true
	for mesh in meshes:
		node.mesh = mesh
		var payload := snapshot._capture_mesh(node, mesh)
		var valid := not payload.has("unsupported_reason") and snapshot._mesh_geometry_matches(mesh, payload)
		if valid:
			var surface: Dictionary = payload.surfaces[0]
			valid = snapshot._current_surface_geometry_signature(mesh, 0) == surface.source_geometry_signature
			print("RTGI_GEOMETRY ", mesh.get_class(), " ", hash([payload.vertex_bytes, payload.index_bytes, surface.source_geometry_signature,
				surface.bones, surface.weights, surface.bones_per_vertex, surface.skinned, surface.max_weighted_bone_index,
				surface.blend_shapes, surface.blend_shape_mode, surface.vertex_count, surface.index_count]))
		passed = passed and valid
		print("RTGI_PRIMITIVE_CAPTURE ", mesh.get_class(), " ", valid)
	var changed := meshes[0] as BoxMesh
	node.mesh = changed
	var before := snapshot._capture_mesh(node, changed)
	changed.size *= 2.0
	passed = passed and not snapshot._mesh_geometry_matches(changed, before)
	var lines := ArrayMesh.new()
	var line_arrays: Array = []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ONE])
	lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	node.mesh = lines
	passed = passed and snapshot._capture_mesh(node, lines).has("unsupported_reason")
	node.free()
	snapshot.detach()
	quit(0 if passed else 1)
