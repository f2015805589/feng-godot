class_name FFogVolumetricLightmapProbeConverter
extends RefCounted
## Resamples the addon LightmapGI tetra probe adapter into a deliberately
## coarse UE-format uniform-brick payload. This is an approximation, not a
## reconstruction of a UE adaptive VLM capture.

const DEFAULT_BRICK_SIZE := 4
const PI := 3.14159265358979323846
const SH0 := 0.282095
const SH1 := 0.488603
const SH2_XY := 1.092548
const SH2_ZZ := 0.315392
const SH2_XX_YY := 0.546274
const MAX_OUTPUT_VOXELS := 1 << 22
const Volume = preload("fog_volumetric_lightmap.gd")


static func build_payload(p_probe_volume: Resource,
		p_indirection_dimensions: Vector3i = Vector3i.ONE,
		p_brick_size: int = DEFAULT_BRICK_SIZE) -> Dictionary:
	if p_probe_volume == null or not is_instance_valid(p_probe_volume) \
			or not p_probe_volume.has_method("get_gpu_payload") \
			or not p_probe_volume.has_method("sample_sh9_with_validity"):
		return _failure("A valid LightmapGI tetra probe adapter is required.")
	if p_indirection_dimensions.x <= 0 or p_indirection_dimensions.y <= 0 \
			or p_indirection_dimensions.z <= 0 or p_indirection_dimensions.x > 256 \
			or p_indirection_dimensions.y > 256 or p_indirection_dimensions.z > 256 \
			or p_brick_size <= 0 or p_brick_size > 32:
		return _failure("Uniform indirection dimensions and brick size must be positive and within the CPU conversion limit.")
	var source: Dictionary = p_probe_volume.call("get_gpu_payload")
	if source.is_empty():
		return _failure("The source probe adapter has no valid immutable payload.")
	var bounds: AABB = source.get("bounds", AABB())
	var capture: Transform3D = source.get("capture_transform", Transform3D.IDENTITY)
	if not bounds.has_volume() or not capture.is_finite() \
			or absf(capture.basis.determinant()) <= 0.00000001:
		return _failure("Probe source bounds or capture transform are invalid.")
	var padded := p_brick_size + 1
	var atlas_dims := Vector3i(p_indirection_dimensions.x * padded,
		p_indirection_dimensions.y * padded, p_indirection_dimensions.z * padded)
	var voxel_count := atlas_dims.x * atlas_dims.y * atlas_dims.z
	if voxel_count <= 0 or voxel_count > MAX_OUTPUT_VOXELS:
		return _failure("Requested probe-to-brick atlas exceeds the CPU conversion limit.")
	var indirection := PackedByteArray()
	indirection.resize(p_indirection_dimensions.x * p_indirection_dimensions.y * p_indirection_dimensions.z * 4)
	var ambient := PackedByteArray()
	ambient.resize(voxel_count * 8)
	var coefficient_layers: Array[PackedByteArray] = []
	for _layer in 6:
		var layer := PackedByteArray()
		layer.resize(voxel_count * 4)
		coefficient_layers.append(layer)
	var bent := PackedByteArray()
	bent.resize(voxel_count * 4)
	bent.fill(255)
	for voxel in voxel_count:
		var bent_offset := voxel * 4
		bent[bent_offset] = 128
		bent[bent_offset + 1] = 128
		bent[bent_offset + 2] = 255
		bent[bent_offset + 3] = 255
	var shadow := PackedByteArray()
	shadow.resize(voxel_count)
	shadow.fill(255)
	var invalid_brick_count := 0
	var valid_brick_count := 0
	for brick_z in p_indirection_dimensions.z:
		for brick_y in p_indirection_dimensions.y:
			for brick_x in p_indirection_dimensions.x:
				var cell_offset := ((brick_z * p_indirection_dimensions.y + brick_y) * p_indirection_dimensions.x + brick_x) * 4
				indirection[cell_offset] = brick_x
				indirection[cell_offset + 1] = brick_y
				indirection[cell_offset + 2] = brick_z
				indirection[cell_offset + 3] = 1
				var brick_valid := true
				for local_z in range(p_brick_size + 1):
					for local_y in range(p_brick_size + 1):
						for local_x in range(p_brick_size + 1):
							var normalized := Vector3(
								(float(brick_x) + float(local_x) / p_brick_size) / p_indirection_dimensions.x,
								(float(brick_y) + float(local_y) / p_brick_size) / p_indirection_dimensions.y,
								(float(brick_z) + float(local_z) / p_brick_size) / p_indirection_dimensions.z)
							var local_position := bounds.position + normalized * bounds.size
							var world_position := capture * local_position
							var sampled: Dictionary = p_probe_volume.call("sample_sh9_with_validity", world_position)
							var coefficients: PackedFloat32Array = sampled.get("coefficients", PackedFloat32Array())
							if not bool(sampled.get("valid", false)) or coefficients.size() != 27:
								brick_valid = false
								continue
							var atlas_coord := Vector3i(brick_x * padded + local_x,
								brick_y * padded + local_y, brick_z * padded + local_z)
							var voxel := (atlas_coord.z * atlas_dims.y + atlas_coord.y) * atlas_dims.x + atlas_coord.x
							_encode_probe_sample(coefficients, voxel, ambient, coefficient_layers)
				if brick_valid:
					valid_brick_count += 1
				else:
					invalid_brick_count += 1
					indirection[cell_offset + 3] = 0
	if valid_brick_count == 0:
		return _failure("No converted brick is fully covered by valid source tetra samples.")
	var payload := {
		"format_version": Volume.FORMAT_VERSION,
		"coordinate_units": "m",
		"capture_transform": capture,
		"bounds_local": bounds,
		"brick_size": p_brick_size,
		"indirection_dimensions": p_indirection_dimensions,
		"brick_atlas_dimensions": atlas_dims,
		"indirection_rgba8_uint": indirection,
		"ambient_rgba16f": ambient,
		"sh_coefficients_rgba8_unorm": coefficient_layers,
		"sky_bent_normal_rgba8_unorm": bent,
		"directional_shadow_r8_unorm": shadow,
		"baked_exposure": float(source.get("baked_exposure", 1.0)),
		"includes_environment_radiance": bool(source.get("includes_environment_radiance", false)),
		# Probe captures do not store direct-at-probe Sun contribution or a VLM
		# primary-directional shadow layer; never use them to suppress a live Sun.
		"contains_static_direct_directional_lighting": false,
		"has_sky_bent_normal": false,
		"has_directional_shadowing": false,
		"static_directional_light_key": "",
		"coefficient_domain": "ue_vlm_ambient_and_normalized_sh_v1",
		"source_revision": int(source.get("source_revision", 0)),
	}
	var validation := Volume.validate_payload(payload)
	if not bool(validation.get("valid", false)):
		return _failure("Converted probe payload failed VLM validation: %s" % validation.get("reason", "unknown error"))
	return {
		"valid": true,
		"payload": payload,
		"source": "lightmapgi_tetra_probe_resample",
		"approximate": true,
		"valid_brick_count": valid_brick_count,
		"invalid_brick_count": invalid_brick_count,
		"missing_layers": ["sky_bent_normal", "directional_shadow"],
		"diagnostic": "Uniformly resampled probe SH into UE-format bricks; no adaptive density, sky-bent visibility, or static directional shadow data was invented.",
	}


static func convert_into(p_probe_volume: Resource, p_target: Resource,
		p_indirection_dimensions: Vector3i = Vector3i.ONE,
		p_brick_size: int = DEFAULT_BRICK_SIZE) -> Dictionary:
	if p_target == null or not is_instance_valid(p_target) \
			or not p_target.has_method("import_decoded_payload"):
		return _failure("A target FFogVolumetricLightmap resource is required.")
	var result := build_payload(p_probe_volume, p_indirection_dimensions, p_brick_size)
	if not bool(result.get("valid", false)):
		return result
	var imported: Dictionary = p_target.call("import_decoded_payload", result["payload"])
	if not bool(imported.get("valid", false)):
		return _failure("Target resource rejected the converted payload: %s" % imported.get("reason", "unknown error"))
	result["changed"] = bool(imported.get("changed", false))
	return result


static func _encode_probe_sample(p_coefficients: PackedFloat32Array, p_voxel: int,
		p_ambient: PackedByteArray, p_layers: Array[PackedByteArray]) -> void:
	var ambient_values := Vector3.ZERO
	for channel in 3:
		var base := channel
		ambient_values[channel] = maxf(p_coefficients[base] * SH0 * PI * PI, 0.0)
	var ambient_offset := p_voxel * 8
	p_ambient.encode_half(ambient_offset, ambient_values.x)
	p_ambient.encode_half(ambient_offset + 2, ambient_values.y)
	p_ambient.encode_half(ambient_offset + 4, ambient_values.z)
	p_ambient.encode_half(ambient_offset + 6, 1.0)
	for channel in 3:
		var source_base := channel
		var base_coefficient := p_coefficients[source_base]
		var layer0 := PackedFloat32Array([
			p_coefficients[1 * 3 + channel],
			p_coefficients[2 * 3 + channel],
			p_coefficients[3 * 3 + channel],
			p_coefficients[4 * 3 + channel],
		])
		var layer1 := PackedFloat32Array([
			p_coefficients[5 * 3 + channel],
			p_coefficients[6 * 3 + channel],
			p_coefficients[7 * 3 + channel],
			p_coefficients[8 * 3 + channel],
		])
		var normalized0 := PackedFloat32Array()
		normalized0.resize(4)
		var normalized1 := PackedFloat32Array()
		normalized1.resize(4)
		if base_coefficient > 0.000001:
			for lane in 4:
				normalized0[lane] = clampf(layer0[lane] / base_coefficient, -1.0, 1.0)
				normalized1[lane] = clampf(layer1[lane] / base_coefficient, -1.0, 1.0)
		else:
			normalized0.fill(0.0)
			normalized1.fill(0.0)
		var lane_bytes0 := PackedByteArray()
		var lane_bytes1 := PackedByteArray()
		for lane in 4:
			lane_bytes0.append(_encode_unorm(normalized0[lane]))
			lane_bytes1.append(_encode_unorm(normalized1[lane]))
		var layer0_index := channel * 2
		var layer1_index := layer0_index + 1
		var destination := p_voxel * 4
		for lane in 4:
			p_layers[layer0_index][destination + lane] = lane_bytes0[lane]
			p_layers[layer1_index][destination + lane] = lane_bytes1[lane]


static func _encode_unorm(p_signed: float) -> int:
	return clampi(roundi((clampf(p_signed, -1.0, 1.0) * 0.5 + 0.5) * 255.0), 0, 255)


static func _failure(p_reason: String) -> Dictionary:
	return {"valid": false, "reason": p_reason}
