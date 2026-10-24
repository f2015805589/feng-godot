@tool
extends RefCounted
## Spherical transport estimator, independent of volume/editor and GPU caches.

const DirectionalData = preload("feng_magic_gi_directional_data.gd")
const EmitterBakeSet = preload("feng_magic_gi_emitter_bake_set.gd")

static func bake_probe(output: Resource, geometry: RefCounted, probe: int,
		rays: int, bounces: int, distance: float, coordinates: Array[PackedFloat64Array],
		shifts: PackedFloat32Array, emitter_shifts: PackedFloat32Array,
		directional_sources: Array[Dictionary] = []) -> void:
	var directional: DirectionalData = output.directional
	var center: Vector3 = output.positions[probe]
	var nee_sources: Array[Dictionary] = []
	if output.bake_exact_directional_secondary.is_empty() and directional_sources.is_empty():
		# Preserve the direct unit-test/legacy call shape as an explicitly valid
		# no-directional-source bake. Production BakeJob always supplies its
		# prepared 27-float result and the immutable capture snapshot.
		output.bake_exact_directional_secondary.resize(27)
		output.bake_exact_directional_secondary.fill(0.0)
	if output.bake_exact_directional_secondary.size() != 27:
		output.bake_exact_directional_secondary_valid = false
		return
	output.bake_exact_directional_secondary.fill(0.0)
	output.bake_exact_directional_secondary_valid = false
	for source in directional_sources:
		var direction_value: Variant = source.get("direction_world", null)
		var radiance_value: Variant = source.get("radiance_rgb", null)
		var sky_mode_value: Variant = source.get("sky_mode", null)
		if typeof(direction_value) != TYPE_VECTOR3 or typeof(radiance_value) != TYPE_VECTOR3 \
				or typeof(sky_mode_value) != TYPE_INT:
			output.bake_exact_directional_secondary_valid = false
			return
		var direction: Vector3 = direction_value
		var radiance: Vector3 = radiance_value
		var sky_mode := int(sky_mode_value)
		if not direction.is_finite() or direction.length_squared() < 0.999 \
				or direction.length_squared() > 1.001 or not radiance.is_finite() \
				or sky_mode < DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY \
				or sky_mode > DirectionalLight3D.SKY_MODE_SKY_ONLY:
			output.bake_exact_directional_secondary_valid = false
			return
		if sky_mode != DirectionalLight3D.SKY_MODE_SKY_ONLY:
			nee_sources.append(source)
	# Empty is a valid immutable snapshot when the bake has no eligible direct
	# sources. It must remain distinct from a missing/invalid snapshot above.
	var exact_directional_secondary := PackedFloat64Array()
	exact_directional_secondary.resize(27)
	exact_directional_secondary.fill(0.0)
	# Accumulate locally in float64, then publish once. Updating Resource-backed
	# packed arrays inside the ray loop incurs repeated property/COW traffic.
	var angular_transport := PackedFloat64Array()
	var angular_sky := PackedFloat64Array()
	var angular_emission := PackedFloat64Array()
	angular_transport.resize(243)
	angular_sky.resize(81)
	angular_emission.resize(geometry.emitters.groups.size() * 54)
	var receiver_normal: Vector3 = output.normals[probe] if output.normals.size() > probe else Vector3.UP
	var surface_transport := PackedFloat32Array()
	var surface_sky := PackedFloat32Array()
	var surface_emission := PackedFloat32Array()
	surface_transport.resize(27)
	surface_sky.resize(9)
	surface_emission.resize(geometry.emitters.groups.size() * 6)
	for sample_index in rays:
		var u := fposmod(coordinates[0][sample_index] + shifts[0], 1.0)
		var v := fposmod(coordinates[1][sample_index] + shifts[1], 1.0)
		var height := 1.0 - 2.0 * u
		var radius := sqrt(maxf(0.0, 1.0 - height * height))
		var direction := Vector3(radius * cos(TAU * v), height, radius * sin(TAU * v))
		var outgoing := DirectionalData.basis(direction)
		var receiver_weight := 4.0 * maxf(receiver_normal.dot(direction), 0.0) / rays
		var vertex := center
		var normal := Vector3.ZERO
		var path_start_face := -1
		var throughput := Vector3.ONE
		for bounce in bounces + 1:
			for emitter in geometry.emitters.groups.size():
				var shift_index: int = (bounce * geometry.emitters.groups.size() + emitter) * 3
				var source: Dictionary = geometry.emitters.sample_connection(emitter, vertex, normal,
					fposmod(coordinates[0][sample_index] + emitter_shifts[shift_index], 1.0),
					fposmod(coordinates[1][sample_index] + emitter_shifts[shift_index + 1], 1.0),
					fposmod(coordinates[2][sample_index] + emitter_shifts[shift_index + 2], 1.0),
					distance, bounce == 0, true)
				if source.is_empty():
					continue
				var visibility_hit: Dictionary = geometry.trace_emitter_connection(
					source.shadow_origin, source.shadow_direction,
					source.visibility_distance, path_start_face)
				if not _matches_sampled_emitter_hit(visibility_hit, emitter, source):
					continue
				var texture_rgb: Vector3 = source.texture_rgb
				if source.has("texture_uv1") and source.has("texture_uv2"):
					texture_rgb = geometry.emitters.sample_texture(emitter,
							source.texture_uv1, source.texture_uv2)
				var bsdf_pdf := _path_direction_pdf(bounce, normal, source.sample_direction)
				var light_weight := EmitterBakeSet.power_heuristic(float(source.light_pdf), bsdf_pdf)
				# SH and cosine use the original physical sample direction. The
				# collinear shadow ray exists only to query visibility.
				var source_basis := DirectionalData.basis(source.sample_direction) if bounce == 0 else outgoing
				var factor := float(source.weight) * light_weight / rays * (1.0 if bounce == 0 else 4.0 * PI)
				var surface_factor := float(source.weight) * (maxf(receiver_normal.dot(source.sample_direction), 0.0) / (PI * rays) if bounce == 0 else receiver_weight) * light_weight
				for channel in 3:
					surface_emission[emitter * 6 + channel] += throughput[channel] * surface_factor
					surface_emission[emitter * 6 + 3 + channel] += throughput[channel] * surface_factor * texture_rgb[channel]
				for k in 9:
					var base: int = emitter * 54 + k * 6
					for channel in 3:
						var weight := throughput[channel] * source_basis[k] * factor
						angular_emission[base + channel] += weight
						angular_emission[base + 3 + channel] += weight * texture_rgb[channel]
			# A probe itself has no surface normal, so direct lighting there remains
			# the native renderer's responsibility. At later path vertices the
			# throughput already contains each hit's albedo; evaluate direct
			# directional light exactly and project the outgoing radiance along the
			# original probe ray, not along the NEE shadow direction.
			if bounce > 0 and not nee_sources.is_empty():
				for light_source in nee_sources:
					var light_direction: Vector3 = light_source["direction_world"]
					var cosine := maxf(normal.dot(light_direction), 0.0)
					if cosine <= 0.0:
						continue
					if not geometry.trace_directional_visibility(vertex, light_direction,
							path_start_face):
						continue
					var light_radiance: Vector3 = light_source["radiance_rgb"]
					var outgoing_radiance := throughput * light_radiance * (cosine / PI)
					for k in 9:
						var projection_weight := outgoing[k] * (4.0 * PI / rays)
						for channel in 3:
							exact_directional_secondary[k * 3 + channel] += \
									projection_weight * outgoing_radiance[channel]
			var hit: Dictionary = geometry.trace_path(vertex, direction, distance, path_start_face)
			if hit.is_empty():
				var incoming := outgoing if bounce == 0 else DirectionalData.basis(direction)
				for k in 9:
					if bounce == 0:
						surface_sky[k] += PI * receiver_weight * incoming[k]
					else:
						for channel in 3:
							surface_transport[k * 3 + channel] += receiver_weight * throughput[channel] * incoming[k]
				for outgoing_index in 9:
					for incoming_index in 9:
						var weight := outgoing[outgoing_index] * incoming[incoming_index] * (4.0 * PI / rays)
						if bounce == 0:
							angular_sky[outgoing_index * 9 + incoming_index] += weight
						else:
							for channel in 3:
								angular_transport[outgoing_index * 27 + incoming_index * 3 + channel] += weight * throughput[channel]
				break
			if int(hit.get("emitter_index", -1)) >= 0:
				var hit_emitter := int(hit["emitter_index"])
				var path_pdf := _path_direction_pdf(bounce, normal, direction)
				var light_pdf: float = geometry.emitters.solid_angle_pdf(hit_emitter, vertex,
						hit.position, hit.emission_normal)
				var hit_weight := EmitterBakeSet.power_heuristic(path_pdf, light_pdf)
				var hit_texture: Vector3 = hit.emission_texture_rgb
				var hit_surface_factor := receiver_weight * hit_weight
				var hit_angular_factor := 4.0 * PI * hit_weight / rays
				for channel in 3:
					var hit_value := throughput[channel] * hit_surface_factor
					surface_emission[hit_emitter * 6 + channel] += hit_value
					surface_emission[hit_emitter * 6 + 3 + channel] += hit_value * hit_texture[channel]
				for k in 9:
					var base: int = hit_emitter * 54 + k * 6
					for channel in 3:
						var hit_value := throughput[channel] * outgoing[k] * hit_angular_factor
						angular_emission[base + channel] += hit_value
						angular_emission[base + 3 + channel] += hit_value * hit_texture[channel]
			if bounce == bounces:
				break
			throughput *= hit.albedo
			if throughput.length_squared() < 0.00001:
				break
			vertex = hit.position
			normal = hit.normal
			path_start_face = int(hit["face_index"])
			var dimension := (bounce + 1) * 2
			u = fposmod(coordinates[dimension][sample_index] + shifts[dimension], 1.0)
			v = fposmod(coordinates[dimension + 1][sample_index] + shifts[dimension + 1], 1.0)
			direction = cosine_hemisphere_direction(normal, u, v)

	for k in 243:
		directional.transfer[probe * 243 + k] = angular_transport[k]
	for k in 81:
		directional.sky[probe * 81 + k] = angular_sky[k]
	for k in 27:
		if not is_finite(exact_directional_secondary[k]):
			output.bake_exact_directional_secondary_valid = false
			return
	for k in 27:
		output.bake_exact_directional_secondary[k] = exact_directional_secondary[k]
	output.bake_exact_directional_secondary_valid = true
	for emitter in geometry.emitters.groups.size():
		for k in 54:
			directional.emission[(emitter * output.probe_count() + probe) * 54 + k] = angular_emission[emitter * 54 + k]
	# Retain the surface estimator for previews and exact boundary fallback. Both
	# estimators share each traced path; no second set of intersection queries.
	if output.transfer.size() >= (probe + 1) * 27:
		for k in 27:
			output.transfer[probe * 27 + k] = surface_transport[k]
		for k in 9:
			output.primary_sky_visibility[probe * 9 + k] = surface_sky[k]
		for emitter in geometry.emitters.groups.size():
			for k in 6:
				output.emitter_transport[(emitter * output.probe_count() + probe) * 6 + k] = surface_emission[emitter * 6 + k]

static func _path_direction_pdf(bounce: int, normal: Vector3, direction: Vector3) -> float:
	if bounce == 0:
		return 1.0 / (4.0 * PI)
	return maxf(normal.normalized().dot(direction.normalized()), 0.0) / PI

static func cosine_hemisphere_direction(normal: Vector3, u: float, v: float) -> Vector3:
	var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT).normalized()
	var bitangent := normal.cross(tangent)
	return tangent * sqrt(u) * cos(TAU * v) + bitangent * sqrt(u) * sin(TAU * v) + normal * sqrt(1.0 - u)

static func _matches_sampled_emitter_hit(hit: Dictionary, emitter_index: int,
		sample: Dictionary) -> bool:
	if hit.is_empty() or int(hit.get("emitter_index", -1)) != emitter_index:
		return false
	var expected_face := int(sample.get("sample_face_index", -1))
	var hit_face := int(hit.get("face_index", -1))
	if expected_face >= 0:
		# The canonical native face identity proves the ray reached the selected
		# emitter triangle. Its plane/ray intersection is unique; float32 hit-point
		# reconstruction must not discard that valid sample.
		if hit_face == expected_face:
			return true
		var compatible_faces: PackedInt32Array = sample.get("compatible_hit_faces", PackedInt32Array())
		if not compatible_faces.has(hit_face):
			return false
	var endpoint: Vector3 = sample.sample_position
	return hit.position.distance_to(endpoint) <= float(sample.endpoint_tolerance)
