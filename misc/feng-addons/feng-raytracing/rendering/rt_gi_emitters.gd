@tool
extends RefCounted
## World-area times luminance distribution, shared by NEE and BSDF MIS PDFs.
static func build(instances: Array) -> PackedByteArray:
	var records := PackedFloat32Array()
	var total := 0.0
	for instance in instances:
		var mesh: Dictionary = instance.mesh
		var transform: Transform3D = instance.transform
		var vertices: PackedByteArray = mesh.vertex_bytes
		var indices: PackedByteArray = mesh.index_bytes
		for surface in mesh.surfaces:
			var material: Dictionary = mesh.materials[surface.material_index]
			if not material.emission_enabled: continue
			var color: Color = material.emission * material.emission_energy_multiplier
			var radiance := Vector3(maxf(color.r, 0), maxf(color.g, 0), maxf(color.b, 0))
			var luminance := radiance.dot(Vector3(0.2126, 0.7152, 0.0722))
			if not is_finite(luminance) or luminance <= 0: continue
			for triangle in int(surface.index_count) / 3:
				var points: Array[Vector3] = []
				for corner in 3:
					var index := indices.decode_u32(surface.index_base_byte + (triangle * 3 + corner) * 4)
					var offset: int = surface.vertex_base_byte + index * 32
					points.append(transform * Vector3(vertices.decode_float(offset), vertices.decode_float(offset + 4), vertices.decode_float(offset + 8)))
				var e1 := points[1] - points[0]
				var e2 := points[2] - points[0]
				var cross_product := e1.cross(e2)
				var area := cross_product.length() * 0.5
				if not is_finite(area) or area <= 1e-10: continue
				# Clockwise Godot front face; preserve it under mirrored instances.
				var normal := -cross_product.normalized() * signf(transform.basis.determinant())
				total += area * luminance
				records.append_array(PackedFloat32Array([points[0].x, points[0].y, points[0].z, total,
					e1.x, e1.y, e1.z, luminance, e2.x, e2.y, e2.z, float((int(material.flags) & 2) != 0),
					radiance.x, radiance.y, radiance.z, area, normal.x, normal.y, normal.z, 0]))
	var data := PackedFloat32Array([total, records.size() / 20, 0, 0])
	data.append_array(records)
	return data.to_byte_array()
