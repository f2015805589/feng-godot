@tool
extends RefCounted
## Canonical immutable surface geometry for RTGI capture and dirty-mesh comparison.

static func capture(mesh: Mesh, surface_index: int) -> Dictionary:
	var arrays := mesh.surface_get_arrays(surface_index)
	# PrimitiveMesh exposes triangle arrays without ArrayMesh format flags.
	var primitive := int(mesh.surface_get_primitive_type(surface_index)) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
	var format := int(mesh.surface_get_format(surface_index)) if mesh is ArrayMesh else 0
	if primitive != Mesh.PRIMITIVE_TRIANGLES \
			or arrays.size() < Mesh.ARRAY_MAX \
			or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array \
			or not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		return {"unsupported_reason": "rtgi_requires_vertex_normal_uv1"}
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array else PackedVector2Array()
	if vertices.is_empty() or vertices.size() != normals.size():
		return {"unsupported_reason": "rtgi_mesh_attribute_count_mismatch"}
	for vertex_index in vertices.size():
		if not vertices[vertex_index].is_finite() or not normals[vertex_index].is_finite():
			return {"unsupported_reason": "rtgi_mesh_source_contains_nonfinite_position_or_normal"}
	if uvs.is_empty():
		uvs.resize(vertices.size())
	for uv in uvs:
		if not is_finite(uv.x) or not is_finite(uv.y):
			return {"unsupported_reason": "rtgi_mesh_source_contains_nonfinite_uv"}
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] is PackedInt32Array else PackedInt32Array()
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array else PackedFloat32Array()
	var bones_per_vertex := 8 if (format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0 else 4
	var skinned := not bones.is_empty() or not weights.is_empty()
	if skinned and (bones.size() != vertices.size() * bones_per_vertex or weights.size() != bones.size()):
		return {"unsupported_reason": "rtgi_skin_attribute_count_mismatch"}
	var max_weighted_bone_index := -1
	for influence in bones.size():
		if bones[influence] < 0:
			return {"unsupported_reason": "rtgi_skin_bone_index_negative"}
		if not is_finite(weights[influence]) or weights[influence] < 0.0:
			return {"unsupported_reason": "rtgi_skin_weight_nonfinite_or_negative"}
		if weights[influence] > 0.0:
			max_weighted_bone_index = maxi(max_weighted_bone_index, bones[influence])
	if vertices.size() != uvs.size():
		return {"unsupported_reason": "rtgi_mesh_attribute_count_mismatch"}
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
	if indices.is_empty():
		if vertices.size() % 3 != 0:
			return {"unsupported_reason": "rtgi_non_triangle_surface"}
		indices.resize(vertices.size())
		for index in vertices.size():
			indices[index] = index
	if indices.size() % 3 != 0:
		return {"unsupported_reason": "rtgi_non_triangle_indices"}
	for index in indices:
		if index < 0 or index >= vertices.size():
			return {"unsupported_reason": "rtgi_index_out_of_range"}
	var packed := PackedFloat32Array()
	packed.resize(vertices.size() * 8)
	for index in vertices.size():
		var v := vertices[index]
		var n := normals[index]
		var uv := uvs[index]
		var offset := index * 8
		packed[offset] = v.x
		packed[offset + 1] = v.y
		packed[offset + 2] = v.z
		packed[offset + 3] = n.x
		packed[offset + 4] = n.y
		packed[offset + 5] = n.z
		packed[offset + 6] = uv.x
		packed[offset + 7] = uv.y
	var blend_shape_rows: Array[Dictionary] = []
	if mesh is ArrayMesh:
		var shape_arrays: Array = mesh.surface_get_blend_shape_arrays(surface_index)
		if shape_arrays.size() != mesh.get_blend_shape_count():
			return {"unsupported_reason": "rtgi_blend_shape_surface_mismatch"}
		for shape_index in shape_arrays.size():
			var shape: Array = shape_arrays[shape_index]
			if shape.size() < Mesh.ARRAY_MAX or not shape[Mesh.ARRAY_VERTEX] is PackedVector3Array:
				return {"unsupported_reason": "rtgi_blend_shape_vertex_data_unavailable"}
			var shape_vertices: PackedVector3Array = shape[Mesh.ARRAY_VERTEX]
			var shape_normals: PackedVector3Array = shape[Mesh.ARRAY_NORMAL] if shape[Mesh.ARRAY_NORMAL] is PackedVector3Array else PackedVector3Array()
			if shape_vertices.size() != vertices.size() or shape_normals.size() != vertices.size():
				return {"unsupported_reason": "rtgi_blend_shape_attribute_count_mismatch"}
			for shape_vertex_index in shape_vertices.size():
				if not shape_vertices[shape_vertex_index].is_finite() \
						or not shape_normals[shape_vertex_index].is_finite():
					return {"unsupported_reason": "rtgi_blend_shape_source_contains_nonfinite_data"}
			blend_shape_rows.append({"vertices": shape_vertices, "normals": shape_normals})
	var blend_shape_signature: Array = []
	for blend_shape in blend_shape_rows:
		blend_shape_signature.append(blend_shape.vertices.to_byte_array())
		blend_shape_signature.append(blend_shape.normals.to_byte_array())
	var blend_shape_mode := (mesh as ArrayMesh).get_blend_shape_mode() \
			if mesh is ArrayMesh else Mesh.BLEND_SHAPE_MODE_RELATIVE
	var vertex_bytes := packed.to_byte_array()
	var index_bytes := indices.to_byte_array()
	var source_geometry_signature := int(hash([vertex_bytes, index_bytes,
		bones.to_byte_array(), weights.to_byte_array(), blend_shape_signature,
		blend_shape_mode, primitive]))
	return {"vertex_bytes": vertex_bytes, "index_bytes": index_bytes,
		"vertex_count": vertices.size(), "index_count": indices.size(),
		"source_geometry_signature": source_geometry_signature,
		"surface_index": surface_index, "bones": bones, "weights": weights,
		"bones_per_vertex": bones_per_vertex, "skinned": skinned,
		"max_weighted_bone_index": max_weighted_bone_index,
		"blend_shapes": blend_shape_rows, "blend_shape_mode": blend_shape_mode}
