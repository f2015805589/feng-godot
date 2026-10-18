@tool
extends RefCounted
## World-area times luminance distribution, shared by NEE and BSDF MIS PDFs.
static func signature(instances: Array) -> Array:
	var result: Array = []
	for instance_value in instances:
		if not instance_value is Dictionary:
			continue
		var instance: Dictionary = instance_value
		var mesh_value: Variant = instance.get("mesh", {})
		if not mesh_value is Dictionary:
			continue
		var mesh: Dictionary = mesh_value
		var surface_rows: Dictionary = {}
		for row_value in instance.get("surface_rows", []):
			if row_value is Dictionary:
				surface_rows[int(row_value.get("surface_index", -1))] = row_value
		for surface_index in mesh.get("surfaces", []).size():
			var surface: Dictionary = mesh.surfaces[surface_index]
			var tracking: Dictionary = surface_rows.get(surface_index, {})
			if bool(tracking.get("deforming", false)) \
					or bool(tracking.get("nee_unsampled", false)):
				continue
			var material_index := int(surface.get("material_index", -1))
			var materials: Array = mesh.get("materials", [])
			if material_index < 0 or material_index >= materials.size():
				continue
			var material: Dictionary = materials[material_index]
			if not bool(material.get("emission_enabled", false)):
				continue
			var emission: Color = material.get("emission", Color.BLACK)
			var energy := float(material.get("emission_energy_multiplier", 1.0))
			var radiance := Vector3(maxf(emission.r * energy, 0.0),
				maxf(emission.g * energy, 0.0), maxf(emission.b * energy, 0.0))
			var luminance := radiance.dot(Vector3(0.2126, 0.7152, 0.0722))
			if not is_finite(luminance) or luminance <= 0.0:
				continue
			result.append([int(instance.get("instance_id", 0)), surface_index,
				instance.get("transform", Transform3D.IDENTITY),
				int(surface.get("source_geometry_signature", 0)), radiance,
				(int(material.get("flags", 0)) & 2) != 0])
	return result


static func build(instances: Array) -> PackedByteArray:
	var records := PackedFloat32Array()
	var total := 0.0
	for instance in instances:
		var mesh: Dictionary = instance.mesh
		var transform: Transform3D = instance.transform
		var vertices: PackedByteArray = mesh.vertex_bytes
		var indices: PackedByteArray = mesh.index_bytes
		var surface_rows: Dictionary = {}
		for row in instance.get("surface_rows", []):
			surface_rows[int(row.surface_index)] = row
		for surface_index in mesh.surfaces.size():
			var surface: Dictionary = mesh.surfaces[surface_index]
			var tracking: Dictionary = surface_rows.get(surface_index, {})
			# The emitter CDF is built from bind-pose/source vertices. Until a
			# deformed CDF is available, dynamic emissive triangles must be sampled
			# only by continuation rays; closest-hit reads the matching SurfaceRow
			# flag and leaves their emission unweighted.
			if bool(tracking.get("deforming", false)) or bool(tracking.get("nee_unsampled", false)):
				continue
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
