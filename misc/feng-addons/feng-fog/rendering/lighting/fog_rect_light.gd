class_name FFogRectLight
extends RefCounted
## CPU oracle for the UE-style rect-light volumetric integration contract.
## Light positions, full-span area axes, direction, and sample positions share
## one space (FRP's area-light packet is camera-view space).

const MIN_AREA_LENGTH_SQUARED := 0.0001
const MIN_EDGE_DENOMINATOR := 0.0001
const MIN_LIGHT_DISTANCE := 0.0001
const BARN_DOOR_COS_THRESHOLD := 0.035
const FRAME_ALIGNMENT_EPSILON := 0.001


## CPU implementation of UE RectLight.ush::GetRect for the area-light
## geometry used by volumetric integration. `p_to_light` is light-center minus
## receiver, and the area vectors are native full spans in the same view space.
## The returned vectors describe only the visible rectangle. Keep the original
## center/full spans for phase evaluation and source-texture lookup.
static func visible_rect(p_to_light: Vector3, p_area_width: Vector3,
		p_area_height: Vector3, p_native_light_forward: Vector3,
		p_barn_cos_angle: float, p_barn_length_m: float,
		p_barn_enabled: bool) -> Dictionary:
	if not p_to_light.is_finite() or not p_area_width.is_finite() \
			or not p_area_height.is_finite() or not p_native_light_forward.is_finite() \
			or not is_finite(p_barn_cos_angle) or not is_finite(p_barn_length_m):
		return _invalid_visible_rect("Rect visible-area inputs contain NaN or infinity.")
	var width_length_squared := p_area_width.length_squared()
	var height_length_squared := p_area_height.length_squared()
	var forward_length_squared := p_native_light_forward.length_squared()
	var to_light_length_squared := p_to_light.length_squared()
	if not is_finite(width_length_squared) or not is_finite(height_length_squared) \
			or not is_finite(forward_length_squared) or not is_finite(to_light_length_squared):
		return _invalid_visible_rect("Rect visible-area vector magnitude overflowed.")
	if width_length_squared <= MIN_AREA_LENGTH_SQUARED \
			or height_length_squared <= MIN_AREA_LENGTH_SQUARED \
			or forward_length_squared <= MIN_AREA_LENGTH_SQUARED:
		return _invalid_visible_rect("Rect source has a zero area axis or forward direction.")
	if to_light_length_squared <= MIN_LIGHT_DISTANCE * MIN_LIGHT_DISTANCE:
		return _invalid_visible_rect("Rect source center coincides with the receiver.")
	if p_barn_cos_angle < 0.0 or p_barn_cos_angle > 1.0 or p_barn_length_m < 0.0:
		return _invalid_visible_rect("Barn-door cosine or length is outside its supported range.")

	var width_length := sqrt(width_length_squared)
	var height_length := sqrt(height_length_squared)
	var width_axis := p_area_width / width_length
	var height_axis := p_area_height / height_length
	var native_forward := p_native_light_forward / sqrt(forward_length_squared)
	# UE's Rect.Axis[1] is the tangent and Axis[2] is the light-data direction.
	# Godot publishes local -Z as forward, so UE's axis 2 is -native forward.
	var axis_1 := height_axis
	var axis_2 := -native_forward
	var axis_0 := axis_1.cross(axis_2)
	var axis_0_length_squared := axis_0.length_squared()
	if not is_finite(axis_0_length_squared) or axis_0_length_squared <= MIN_AREA_LENGTH_SQUARED:
		return _invalid_visible_rect("Rect axes do not define a finite light plane.")
	axis_0 /= sqrt(axis_0_length_squared)
	if width_axis.dot(axis_0) < 1.0 - FRAME_ALIGNMENT_EPSILON \
			or absf(width_axis.dot(height_axis)) > FRAME_ALIGNMENT_EPSILON \
			or absf(width_axis.dot(native_forward)) > FRAME_ALIGNMENT_EPSILON \
			or absf(height_axis.dot(native_forward)) > FRAME_ALIGNMENT_EPSILON:
		return _invalid_visible_rect("Rect full-span axes do not match the native light frame.")
	var original_half_extent := Vector2(width_length, height_length) * 0.5
	var original := _visible_rect_result(p_to_light, p_area_width, p_area_height,
			original_half_extent, Vector2.ZERO, false, Vector3.ZERO)
	if not p_barn_enabled or p_barn_cos_angle <= BARN_DOOR_COS_THRESHOLD \
			or p_barn_length_m <= 0.0:
		return original
	var light_space := Vector3(axis_0.dot(p_to_light), axis_1.dot(p_to_light),
			axis_2.dot(p_to_light))
	if not light_space.is_finite() or light_space.z <= 0.0:
		return _invalid_visible_rect("Receiver is behind the rect light or on its plane.")

	# Literal GetRect projection and clamp, matching UE RectLight.ush:652-685.
	var sin_theta := sqrt(maxf(1.0 - p_barn_cos_angle * p_barn_cos_angle, 0.0))
	var barn_depth := minf(light_space.z, p_barn_cos_angle * p_barn_length_m)
	var s_ratio := barn_depth / maxf(0.0001, p_barn_cos_angle * p_barn_length_m)
	var door_projection := sin_theta * p_barn_length_m * s_ratio
	var sign_s := Vector2(signf(light_space.x), signf(light_space.y))
	var projected_sample := Vector2(light_space.x, light_space.y)
	projected_sample = sign_s * Vector2(
			maxf(absf(projected_sample.x), original_half_extent.x + door_projection),
			maxf(absf(projected_sample.y), original_half_extent.y + door_projection))
	var closest_corner := Vector3(
			sign_s.x * (original_half_extent.x + door_projection),
			sign_s.y * (original_half_extent.y + door_projection), barn_depth)
	var sample_projection := Vector3(projected_sample.x, projected_sample.y, light_space.z)
	var s_projected := sample_projection - closest_corner
	var cos_eta := maxf(s_projected.z, 0.001)
	var tan_eta := Vector2(absf(s_projected.x), absf(s_projected.y)) / cos_eta
	var projected_door_distance := Vector2(barn_depth, barn_depth) * tan_eta
	var delta := projected_door_distance - Vector2(door_projection, door_projection)
	var minimum_xy := Vector2(
			clampf(-original_half_extent.x + delta.x * maxf(0.0, -sign_s.x),
				-original_half_extent.x, original_half_extent.x),
			clampf(-original_half_extent.y + delta.y * maxf(0.0, -sign_s.y),
				-original_half_extent.y, original_half_extent.y))
	var maximum_xy := Vector2(
			clampf(original_half_extent.x - delta.x * maxf(0.0, sign_s.x),
				-original_half_extent.x, original_half_extent.x),
			clampf(original_half_extent.y - delta.y * maxf(0.0, sign_s.y),
				-original_half_extent.y, original_half_extent.y))
	var rect_offset := 0.5 * (minimum_xy + maximum_xy)
	var visible_half_extent := 0.5 * (maximum_xy - minimum_xy)
	if not rect_offset.is_finite() or not visible_half_extent.is_finite():
		return _invalid_visible_rect("Barn-door clipping produced non-finite geometry.")
	if visible_half_extent.x <= 0.0 or visible_half_extent.y <= 0.0:
		var blocked := _invalid_visible_rect("Barn doors fully block this receiver.")
		blocked["half_extent"] = visible_half_extent
		blocked["offset"] = rect_offset
		return blocked
	var shifted_to_light := p_to_light - axis_0 * rect_offset.x - axis_1 * rect_offset.y
	var visible_width := axis_0 * (2.0 * visible_half_extent.x)
	var visible_height := axis_1 * (2.0 * visible_half_extent.y)
	if not shifted_to_light.is_finite() or not visible_width.is_finite() or not visible_height.is_finite():
		return _invalid_visible_rect("Barn-door clipping produced non-finite output vectors.")
	return _visible_rect_result(shifted_to_light, visible_width, visible_height,
			visible_half_extent, rect_offset,
			rect_offset.length_squared() > 1.0e-8
				or visible_half_extent.distance_to(original_half_extent) > 1.0e-4,
			light_space)


static func _visible_rect_result(p_to_light: Vector3, p_area_width: Vector3,
		p_area_height: Vector3, p_half_extent: Vector2, p_offset: Vector2,
		p_clipped: bool, p_light_space: Vector3) -> Dictionary:
	return {
		"valid": true,
		"to_light": p_to_light,
		"area_width": p_area_width,
		"area_height": p_area_height,
		"half_extent": p_half_extent,
		"offset": p_offset,
		"clipped": p_clipped,
		"light_space_receiver": p_light_space,
	}


static func _invalid_visible_rect(p_reason: String) -> Dictionary:
	return {
		"valid": false,
		"reason": p_reason,
		"to_light": Vector3.ZERO,
		"area_width": Vector3.ZERO,
		"area_height": Vector3.ZERO,
		"half_extent": Vector2.ZERO,
		"offset": Vector2.ZERO,
		"clipped": false,
		"light_space_receiver": Vector3.ZERO,
	}


## `p_area_width` and `p_area_height` are the native 224-byte LightData full-span
## vectors. This mirrors UE's RectLightIntegrate `IntegrateLight(Rect)` for fog:
## the spherical polygon integration already provides angular falloff, so this
## function never adds a second inverse-square attenuation term.
static func evaluate_volume(p_sample_position: Vector3, p_light_position: Vector3,
		p_area_width: Vector3, p_area_height: Vector3, p_light_forward: Vector3,
		p_inv_radius: float, p_cell_radius: float, p_light_soft_fading: float,
		p_projector_rect: Rect2 = Rect2(), p_atlas_size: Vector2i = Vector2i.ZERO,
		p_atlas_max_mip: float = 0.0, p_enable_soft_fade: bool = true,
		p_view_forward: Vector3 = Vector3(0.0, 0.0, -1.0),
		p_barn_cos_angle: float = 0.0, p_barn_length_m: float = 0.0,
		p_barn_enabled: bool = false) -> Dictionary:
	if not p_sample_position.is_finite() or not p_light_position.is_finite() \
			or not p_area_width.is_finite() or not p_area_height.is_finite() \
			or not p_light_forward.is_finite() or not p_view_forward.is_finite() \
			or not is_finite(p_inv_radius) \
			or not is_finite(p_cell_radius) or not is_finite(p_light_soft_fading):
		return _invalid("Rect-light inputs contain NaN or infinity.")
	if p_area_width.length_squared() <= MIN_AREA_LENGTH_SQUARED \
			or p_area_height.length_squared() <= MIN_AREA_LENGTH_SQUARED \
			or p_light_forward.length_squared() <= MIN_AREA_LENGTH_SQUARED:
		return _invalid("Rect light has a zero extent or invalid forward direction.")
	var width_length := p_area_width.length()
	var height_length := p_area_height.length()
	var axis_width := p_area_width / width_length
	var axis_height := p_area_height / height_length
	var light_forward := p_light_forward.normalized()
	var origin := p_light_position - p_sample_position
	var visible := visible_rect(origin, p_area_width, p_area_height, p_light_forward,
			p_barn_cos_angle, p_barn_length_m, p_barn_enabled)
	var vector_irradiance := Vector3.ZERO
	var base_irradiance := 0.0
	if bool(visible.get("valid", false)):
		var visible_to_light: Vector3 = visible["to_light"]
		var visible_width: Vector3 = visible["area_width"]
		var visible_height: Vector3 = visible["area_height"]
		var corners: Array[Vector3] = [
				(visible_to_light - visible_width * 0.5 - visible_height * 0.5).normalized(),
				(visible_to_light + visible_width * 0.5 - visible_height * 0.5).normalized(),
				(visible_to_light + visible_width * 0.5 + visible_height * 0.5).normalized(),
				(visible_to_light - visible_width * 0.5 + visible_height * 0.5).normalized(),
		]
		var edge_weights := PackedFloat32Array()
		edge_weights.resize(4)
		for edge_index in 4:
			var next_index := (edge_index + 1) % 4
			edge_weights[edge_index] = _ue_rect_edge_weight(corners[edge_index].dot(corners[next_index]))
		vector_irradiance = corners[1].cross(-edge_weights[0] * corners[0] + edge_weights[1] * corners[2]) \
				+ corners[3].cross(edge_weights[3] * corners[0] - edge_weights[2] * corners[2])
		base_irradiance = 0.5 * vector_irradiance.length()
	var integrated_direction := vector_irradiance.normalized() \
			if vector_irradiance.length_squared() > MIN_AREA_LENGTH_SQUARED else origin.normalized()
	var to_receiver := p_sample_position - p_light_position
	var receiver_distance_squared := to_receiver.length_squared()
	var front_cosine := light_forward.dot(to_receiver.normalized()) \
			if receiver_distance_squared > MIN_LIGHT_DISTANCE else 0.0
	var front_facing := front_cosine >= 0.0
	var radius_mask := _ue_rect_radius_mask(receiver_distance_squared, maxf(p_inv_radius, 0.0))
	var fade_distance := maxf(p_cell_radius, 0.0) * maxf(p_light_soft_fading, 0.0)
	var soft_fade := clampf(light_forward.dot(to_receiver) / fade_distance, 0.0, 1.0) \
			if p_enable_soft_fade and fade_distance > 0.0 else 1.0
	# FRP uses c = dot(L, viewRay) with the minus-sign HG denominator. Here
	# camera_vector points from the froxel to camera, so -camera_vector is the
	# camera-to-froxel view ray. UE's equivalent plus-sign form uses
	# cosUE = dot(L, -CameraVector) = -c. RectIrradiance contributes scalar
	# falloff only; its integrated polygon vector is not L.
	var center_light_direction := origin.normalized()
	var camera_vector := -p_sample_position.normalized() \
			if p_sample_position.length_squared() > MIN_LIGHT_DISTANCE else \
			(-p_view_forward.normalized() if p_view_forward.length_squared() > MIN_AREA_LENGTH_SQUARED else Vector3.ZERO)
	var phase_cosine := center_light_direction.dot(-camera_vector)
	var source_texture := _source_texture_sample(center_light_direction, origin,
			axis_width, axis_height, light_forward,
			Vector2(width_length * 0.5, height_length * 0.5),
			p_projector_rect, p_atlas_size, p_atlas_max_mip)
	return {
		"valid": true,
		"integrate_light": base_irradiance,
		"vector_irradiance": vector_irradiance,
		"integrated_direction_diagnostic": integrated_direction,
		"center_light_direction": center_light_direction,
		"phase_cosine": clampf(phase_cosine, -1.0, 1.0),
		"front_cosine": front_cosine,
		"front_facing": front_facing,
		"front_mask": 1.0 if front_facing else 0.0,
		"visible_rect": visible,
		"radius_mask": radius_mask,
		"soft_fade": soft_fade,
		"combined_geometric_weight": base_irradiance * radius_mask \
				* (1.0 if front_facing else 0.0) * soft_fade,
		"inverse_square_applied": false,
		"source_texture": source_texture,
		"source_color_multiplier": Vector3.ONE,
		"source_texture_enabled": bool(source_texture.get("valid", false)),
		"source_texture_default_multiplier": Vector3.ONE,
		"barn_door_supported": true,
		"coordinate_space": "caller_space; FRP area packet is center_camera_view_space",
	}


## CPU mirror of UE's 2013 spherical-rectangle edge approximation.
static func _ue_rect_edge_weight(p_dot: float) -> float:
	var cosine := clampf(p_dot, -1.0, 1.0)
	return (1.5708 - 0.175 * cosine) / sqrt(maxf(cosine + 1.0, MIN_EDGE_DENOMINATOR))


## UE rect lights use the finite-radius mask, not point-light inverse-square
## falloff: saturate(1-(DistanceSqr*InvRadius^2)^2)^2.
static func _ue_rect_radius_mask(p_distance_squared: float, p_inv_radius: float) -> float:
	var normalized_distance_squared := maxf(p_distance_squared, 0.0) * p_inv_radius * p_inv_radius
	var radius := clampf(1.0 - normalized_distance_squared * normalized_distance_squared, 0.0, 1.0)
	return radius * radius


## Maps the UE RectLight source-texture ray-plane intersection into the native
## AreaLight3D atlas rectangle (`projector_rect`) and mip limit (`cos_spot_angle`).
static func _source_texture_sample(p_lighting_direction: Vector3, p_origin: Vector3,
		p_axis_width: Vector3, p_axis_height: Vector3, p_light_forward: Vector3,
		p_half_extent: Vector2, p_atlas_rect: Rect2, p_atlas_size: Vector2i,
		p_atlas_max_mip: float) -> Dictionary:
	if p_atlas_rect.size.x <= 0.0 or p_atlas_rect.size.y <= 0.0 \
			or p_atlas_size.x <= 0 or p_atlas_size.y <= 0:
		return {"valid": false, "uv": Vector2(0.5, 0.5), "mip": 0.0, "reason": "No AreaLight3D source-texture atlas rect is bound."}
	var denominator := p_lighting_direction.dot(p_light_forward)
	if absf(denominator) <= MIN_LIGHT_DISTANCE:
		return {"valid": false, "uv": Vector2(0.5, 0.5), "mip": 0.0, "reason": "Lighting direction does not intersect the rect plane."}
	var distance_to_plane := p_origin.dot(p_light_forward) / denominator
	if not is_finite(distance_to_plane) or distance_to_plane <= 0.0:
		return {"valid": false, "uv": Vector2(0.5, 0.5), "mip": 0.0, "reason": "Rect source plane is behind the lighting direction."}
	var point_in_rect := p_lighting_direction * distance_to_plane - p_origin
	var local_position := Vector2(point_in_rect.dot(p_axis_width), point_in_rect.dot(p_axis_height))
	var half_extent := Vector2(maxf(p_half_extent.x, 0.0001), maxf(p_half_extent.y, 0.0001))
	var local_uv := (local_position / half_extent) * Vector2(0.5, -0.5) + Vector2(0.5, 0.5)
	var atlas_pixels := Vector2(p_atlas_rect.size.x * p_atlas_size.x,
			p_atlas_rect.size.y * p_atlas_size.y)
	var min_rect_pixels := maxf(minf(atlas_pixels.x, atlas_pixels.y), 1.0)
	var log_argument := maxf(distance_to_plane / sqrt(maxf(half_extent.x * half_extent.y, 0.0001)), 0.000001)
	var source_lod := log(log_argument) / log(2.0) + log(min_rect_pixels) / log(2.0) - 2.0
	var max_mip := maxf(p_atlas_max_mip, 0.0)
	var mip := clampf(minf(source_lod, max_mip), 0.0, max_mip)
	var mip_texel_scale := pow(2.0, ceilf(mip))
	var half_texel := Vector2(0.5 * mip_texel_scale / p_atlas_size.x,
			0.5 * mip_texel_scale / p_atlas_size.y)
	var uv_min := p_atlas_rect.position + half_texel
	var uv_max := p_atlas_rect.end - half_texel
	if uv_min.x >= uv_max.x or uv_min.y >= uv_max.y:
		return {"valid": false, "uv": p_atlas_rect.get_center(), "mip": mip, "reason": "Atlas rect is too small for the selected mip border."}
	var atlas_uv := p_atlas_rect.position + local_uv * p_atlas_rect.size
	atlas_uv.x = clampf(atlas_uv.x, uv_min.x, uv_max.x)
	atlas_uv.y = clampf(atlas_uv.y, uv_min.y, uv_max.y)
	return {
		"valid": true,
		"uv": atlas_uv,
		"local_uv": local_uv,
		"mip": mip,
		"distance_to_plane": distance_to_plane,
		"half_extent": half_extent,
		"atlas_rect": p_atlas_rect,
		"atlas_max_mip": max_mip,
		"sample_semantics": "linear_mip_sample of AreaLight3D.area_texture packed in area_light_atlas",
	}


static func _invalid(p_reason: String) -> Dictionary:
	return {
		"valid": false,
		"reason": p_reason,
		"integrate_light": 0.0,
		"radius_mask": 0.0,
		"front_mask": 0.0,
		"soft_fade": 0.0,
		"combined_geometric_weight": 0.0,
		"inverse_square_applied": false,
	}
