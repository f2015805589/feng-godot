class_name FFogCapsuleLight
extends RefCounted
## CPU oracle and unit conversion for UE-compatible volumetric point/capsule
## attenuation. Native range/spot attenuation remains a separate multiplier.

const MIN_DISTANCE_BIAS_M := 0.01
const EPSILON_SQUARED := 1.0e-12


static func distance_bias_m(p_cell_radius_m: float,
		p_inverse_squared_distance_bias_scale: float = 1.0) -> float:
	if not is_finite(p_cell_radius_m) or not is_finite(p_inverse_squared_distance_bias_scale):
		return MIN_DISTANCE_BIAS_M
	return maxf(maxf(p_cell_radius_m, 0.0)
			* maxf(p_inverse_squared_distance_bias_scale, 0.0), MIN_DISTANCE_BIAS_M)


static func axis_world_from_light_transform(p_light_transform: Transform3D,
		p_local_axis_index: int = 1) -> Vector3:
	if not p_light_transform.is_finite() or p_local_axis_index < 0 or p_local_axis_index > 2:
		return Vector3.ZERO
	var local_axis := Vector3.RIGHT if p_local_axis_index == 0 \
			else Vector3.UP if p_local_axis_index == 1 else Vector3.BACK
	var axis := p_light_transform.basis.orthonormalized() * local_axis
	return axis.normalized() if axis.length_squared() > EPSILON_SQUARED else Vector3.ZERO


static func integrate(p_to_light: Vector3, p_axis: Vector3, p_source_length_m: float,
		p_distance_bias_m: float, p_inverse_squared: bool = true) -> Dictionary:
	if not p_to_light.is_finite() or not p_axis.is_finite() \
			or not is_finite(p_source_length_m) or p_source_length_m < 0.0 \
			or not is_finite(p_distance_bias_m) or p_distance_bias_m < 0.0:
		return {"valid": false, "falloff": 0.0, "direction": Vector3.ZERO}
	var distance_squared := p_to_light.length_squared()
	if not is_finite(distance_squared):
		return {"valid": false, "falloff": 0.0, "direction": Vector3.ZERO}
	var center_direction := p_to_light.normalized() if distance_squared > EPSILON_SQUARED else Vector3.ZERO
	if p_source_length_m <= 0.0:
		var point_falloff := 1.0 / maxf(distance_squared + p_distance_bias_m * p_distance_bias_m,
				EPSILON_SQUARED) \
				if p_inverse_squared else 1.0
		return {"valid": true, "falloff": point_falloff, "direction": center_direction}
	if p_axis.length_squared() <= EPSILON_SQUARED:
		return {"valid": false, "falloff": 0.0, "direction": Vector3.ZERO}
	var axis := p_axis.normalized()
	var half_segment := axis * (p_source_length_m * 0.5)
	var p0 := p_to_light - half_segment
	var p1 := p_to_light + half_segment
	var len0_squared := p0.length_squared()
	var len1_squared := p1.length_squared()
	if not is_finite(len0_squared) or not is_finite(len1_squared) \
			or len0_squared <= EPSILON_SQUARED or len1_squared <= EPSILON_SQUARED:
		# The GPU helper uses the point-source limit if either endpoint collapses
		# onto the receiver. Keep the CPU oracle identical for this singular case.
		var point_falloff := 1.0 / maxf(distance_squared + p_distance_bias_m * p_distance_bias_m,
				EPSILON_SQUARED) \
				if p_inverse_squared else 1.0
		return {"valid": true, "falloff": point_falloff, "direction": center_direction}
	var inverse_length0 := 1.0 / sqrt(len0_squared)
	var inverse_length1 := 1.0 / sqrt(len1_squared)
	var inverse_lengths := inverse_length0 * inverse_length1
	var line_direction := 0.5 * (p0 * inverse_length0 + p1 * inverse_length1)
	var falloff := 1.0
	if p_inverse_squared:
		var cosine_subtended := p0.dot(p1) * inverse_lengths
		var bias_squared := p_distance_bias_m * p_distance_bias_m
		var denominator := 0.5 * cosine_subtended + 0.5 + bias_squared * inverse_lengths
		if not is_finite(denominator) or denominator <= EPSILON_SQUARED:
			return {"valid": false, "falloff": 0.0, "direction": Vector3.ZERO}
		falloff = inverse_lengths / denominator
	if not line_direction.is_finite() or not is_finite(falloff):
		return {"valid": false, "falloff": 0.0, "direction": Vector3.ZERO}
	return {"valid": true, "falloff": falloff, "direction": line_direction}
