@tool
extends RefCounted
## Validates the native frame-input lease and packs the stable addon volume ABI.
## This code owns packet rules only; it does not allocate or dispatch GPU work.

const FRAME_INPUT_ABI := 1
const VolumeParameters = preload("res://addons/feng-fog/feng_volumetric_fog_parameters.gd")
const SAMPLE_PACKET_FLOATS := 20
const FROXEL_PIXEL_SIZE := 16
const FROXEL_DEPTH := 64
const DEPTH_DISTRIBUTION_SCALE := 32.0
const NEAR_OFFSET_M := 0.095
const MAX_RENDER_DISTANCE_M := 1000000.0
const FRAME_UNIFORM_FLOATS := 144
const HISTORY_MISS_SUPERSAMPLE_COUNT := 4


static func pack_frame_uniform(frame: Dictionary, height_fog: Dictionary, volume: Dictionary,
		grid: Vector3i, frame_index: int, previous_pre_exposure: float,
		history_valid: bool, storage_pre_exposure: float = 1.0,
		current_depth_valid: bool = false, previous_depth_valid: bool = false) -> PackedFloat32Array:
	var camera: Transform3D = frame.camera_transform
	var previous_camera: Transform3D = frame.previous_camera_transform
	# Native V1 transforms already include the per-eye offset. Offsets remain in
	# the packet for history identity checks, never for a second transform shift.
	var volume_start := float(volume.start_distance)
	var volume_far := float(volume.far_distance)
	var z_params := grid_z_params(float(frame.near_plane_m), volume_start, volume_far, grid.z)
	var previous_z_params := z_params
	var projection: Projection = frame.inverse_projection_unjittered
	var previous_projection: Projection = frame.previous_projection_unjittered
	var depth_projection: Projection = frame.projection
	var depth_inverse_projection: Projection = frame.inverse_projection
	var previous_world_to_view := previous_camera.affine_inverse()
	var fog_density0 := _finite(height_fog.get("fog_density", 0.0), 0.0)
	var fog_density1 := _finite(height_fog.get("second_fog_density", 0.0), 0.0)
	var fog_falloff0 := _finite(height_fog.get("fog_height_falloff", 0.0), 0.0)
	var fog_falloff1 := _finite(height_fog.get("second_fog_height_falloff", 0.0), 0.0)
	var fog_height0 := _finite(height_fog.get("fog_height", 0.0), 0.0)
	var fog_height1 := _finite(height_fog.get("second_fog_height", 0.0), 0.0)
	var observer_y := _observer_height(camera.origin.y, fog_density0, fog_height0,
			fog_density1, fog_height1, frame.projection)
	var height0 := PackedFloat32Array([
		fog_density0, fog_falloff0, fog_height0,
		_safe_positive(frame.far_plane_m, 1.0),
	])
	var height1 := PackedFloat32Array([
		fog_density1, fog_falloff1, fog_height1, observer_y,
	])
	var albedo: Vector3 = volume.albedo
	var emissive: Vector3 = volume.emissive
	var values := PackedFloat32Array()
	_append_projection(values, projection)
	_append_transform4(values, camera)
	_append_projection(values, previous_projection)
	_append_transform4(values, previous_world_to_view)
	_append_projection(values, depth_projection)
	_append_projection(values, depth_inverse_projection)
	values.append_array(PackedFloat32Array([
		camera.origin.x, camera.origin.y, camera.origin.z, 1.0 if frame.projection.is_orthogonal() else 0.0,
	]))
	var eye_offset: Vector3 = frame.get("eye_offset", Vector3.ZERO)
	values.append_array(PackedFloat32Array([eye_offset.x, eye_offset.y, eye_offset.z, 0.0]))
	values.append_array(height0)
	values.append_array(height1)
	values.append_array(PackedFloat32Array([albedo.x, albedo.y, albedo.z, float(volume.extinction_scale)]))
	values.append_array(PackedFloat32Array([emissive.x, emissive.y, emissive.z,
			float(volume.scattering_distribution)]))
	values.append_array(PackedFloat32Array([float(grid.x), float(grid.y), float(grid.z), float(frame.view_index)]))
	values.append_array(PackedFloat32Array([z_params.x, z_params.y, z_params.z,
			1.0 if current_depth_valid else 0.0]))
	values.append_array(PackedFloat32Array([previous_z_params.x, previous_z_params.y, previous_z_params.z,
			1.0 if history_valid and previous_depth_valid else 0.0]))
	values.append_array(PackedFloat32Array([volume_start, volume_far,
			float(volume.near_fade_in_distance), _safe_positive(storage_pre_exposure, 1.0)]))
	values.append_array(PackedFloat32Array([_safe_positive(previous_pre_exposure, 1.0),
			float(frame_index & 1023), float(frame.internal_size.x), float(frame.internal_size.y)]))
	var history_weight := clampf(_finite(volume.get("history_weight", 0.9), 0.9), 0.0, 0.99)
	values.append_array(PackedFloat32Array([history_weight, 1.0 if history_valid else 0.0,
			_safe_positive(frame.get("scene_normalization", 1.0), 1.0),
			float(maxi(int(volume.get("froxel_pixel_size", FROXEL_PIXEL_SIZE)), 1))]))
	if values.size() != FRAME_UNIFORM_FLOATS:
		return PackedFloat32Array()
	return values


static func normalize_volume_packet(value: Variant) -> Dictionary:
	if not value is Dictionary or not bool(value.get("enabled", false)):
		return {}
	var albedo: Variant = value.get("albedo", Vector3.ONE)
	var emissive: Variant = value.get("emissive", Vector3.ZERO)
	if not albedo is Vector3 or not albedo.is_finite():
		albedo = Vector3.ONE
	if not emissive is Vector3 or not emissive.is_finite():
		emissive = Vector3.ZERO
	var distance := _safe_nonnegative(value.get("distance", 60.0), 60.0)
	var start_distance := _safe_nonnegative(value.get("start_distance", 0.0), 0.0)
	var far_distance := minf(start_distance + distance, MAX_RENDER_DISTANCE_M)
	var quality := VolumeParameters.normalize_quality(int(_finite(value.get("quality", 0), 0.0)))
	var quality_profile := VolumeParameters.quality_profile(quality)
	var miss_count_value := int(_finite(value.get("history_miss_supersample_count", 0), 0.0))
	var miss_override := bool(value.get("history_miss_supersample_override", miss_count_value > 0))
	var miss_count := normalize_history_miss_count(miss_count_value) if miss_override \
			else int(quality_profile.history_miss_default)
	return {
		"enabled": true,
		"scattering_distribution": clampf(_finite(value.get("scattering_distribution", 0.2), 0.2), -0.99, 0.99),
		"albedo": albedo.clamp(Vector3.ZERO, Vector3.ONE),
		"emissive": emissive.max(Vector3.ZERO),
		"extinction_scale": _safe_nonnegative(value.get("extinction_scale", 1.0), 1.0),
		"distance": distance,
		"start_distance": start_distance,
		"far_distance": far_distance,
		"near_fade_in_distance": _safe_nonnegative(value.get("near_fade_in_distance", 0.0), 0.0),
		"static_lighting_scattering_intensity": _safe_nonnegative(value.get("static_lighting_scattering_intensity", 1.0), 1.0),
		"override_light_colors_with_fog_inscattering_colors": bool(value.get("override_light_colors_with_fog_inscattering_colors", false)),
		"history_weight": clampf(_finite(value.get("history_weight", 0.9), 0.9), 0.0, 0.99),
		"quality": quality,
		"froxel_pixel_size": int(quality_profile.froxel_pixel_size),
		"froxel_depth": int(quality_profile.froxel_depth),
		"history_miss_supersample_count": miss_count,
		"history_miss_supersample_override": miss_override,
		"jitter_enabled": bool(value.get("jitter_enabled", true)),
		"ray_traced_shadows_enabled": bool(value.get("ray_traced_shadows_enabled", false)),
		"light_soft_fading": _safe_nonnegative(value.get("light_soft_fading", 0.0), 0.0),
		"area_light_source_textures_enabled": bool(value.get("area_light_source_textures_enabled", false)),
	}


static func has_valid_volume_depth_range(camera_near_m: float, start_distance_m: float,
		far_distance_m: float) -> bool:
	if not is_finite(camera_near_m) or not is_finite(start_distance_m) \
			or not is_finite(far_distance_m):
		return false
	var start := maxf(start_distance_m, 0.0)
	var near := maxf(maxf(camera_near_m, 0.0), start) + NEAR_OFFSET_M
	# The log-Z constructor needs this minimum span. Treat a smaller authored
	# range as inactive instead of silently widening the published far plane.
	return far_distance_m > near + 0.001


static func normalize_screen_space_scattering(value: Variant) -> Dictionary:
	if not value is Dictionary or not bool(value.get("enabled", false)):
		return {}
	return {
		"enabled": true,
		"scene_color_scattering_amount_scale": _safe_nonnegative(value.get("scene_color_scattering_amount_scale", 1.0), 1.0),
		"scene_color_scattering_amount_power": _safe_nonnegative(value.get("scene_color_scattering_amount_power", 1.0), 1.0),
		"spread_scale": _safe_nonnegative(value.get("spread_scale", 0.1), 0.1),
		"blur_control": clampf(_safe_nonnegative(value.get("blur_control", 0.5), 0.5), 0.0, 1.0),
	}


static func normalize_history_miss_count(value: int) -> int:
	if value <= 1:
		return 1
	if value <= 4:
		return 4
	if value <= 8:
		return 8
	return 16


static func normalize_frame_inputs(value: Variant, expected_view: int = -1) -> Dictionary:
	if not value is Dictionary or int(value.get("abi_version", 0)) != FRAME_INPUT_ABI \
			or not bool(value.get("valid", false)):
		return {}
	var view_count := int(value.get("view_count", 0))
	var view_index := int(value.get("view_index", -1))
	var internal_size: Variant = value.get("internal_size", Vector2i.ZERO)
	var projection: Variant = value.get("projection")
	var inverse_projection: Variant = value.get("inverse_projection")
	var previous_projection: Variant = value.get("previous_projection")
	var previous_inverse_projection: Variant = value.get("previous_inverse_projection")
	var projection_unjittered: Variant = value.get("projection_unjittered", projection)
	var inverse_projection_unjittered: Variant = value.get("inverse_projection_unjittered",
			projection_unjittered.inverse() if projection_unjittered is Projection else Projection.IDENTITY)
	var previous_projection_unjittered: Variant = value.get("previous_projection_unjittered", previous_projection)
	var camera_transform: Variant = value.get("camera_transform")
	var previous_camera_transform: Variant = value.get("previous_camera_transform")
	if view_count <= 0 or view_index < 0 or view_index >= view_count \
			or (expected_view >= 0 and view_index != expected_view) \
			or not internal_size is Vector2i or internal_size.x <= 0 or internal_size.y <= 0 \
			or not projection is Projection or not inverse_projection is Projection \
			or not previous_projection is Projection or not previous_inverse_projection is Projection \
			or not projection_unjittered is Projection \
			or not inverse_projection_unjittered is Projection \
			or not previous_projection_unjittered is Projection \
			or not camera_transform is Transform3D or not previous_camera_transform is Transform3D \
			or not camera_transform.is_finite() or not previous_camera_transform.is_finite():
		return {}
	var camera_origin: Variant = value.get("camera_origin", camera_transform.origin)
	var eye_offset: Variant = value.get("eye_offset", Vector3.ZERO)
	var previous_eye_offset: Variant = value.get("previous_eye_offset", eye_offset)
	if not camera_origin is Vector3 or not camera_origin.is_finite() \
			or not eye_offset is Vector3 or not eye_offset.is_finite() \
			or not previous_eye_offset is Vector3 or not previous_eye_offset.is_finite():
		return {}
	var near_plane := _safe_nonnegative(value.get("near_plane_m", 0.05), 0.05)
	var far_plane := _safe_nonnegative(value.get("far_plane_m", 1000.0), 1000.0)
	var pre_exposure := _safe_positive(value.get("pre_exposure", 1.0), 1.0)
	var scene_normalization := _safe_positive(value.get("scene_normalization", 1.0), 1.0)
	if far_plane <= near_plane:
		return {}
	var out: Dictionary = value.duplicate(false)
	out["view_count"] = view_count
	out["view_index"] = view_index
	out["internal_size"] = internal_size
	out["projection_unjittered"] = projection_unjittered
	out["inverse_projection_unjittered"] = inverse_projection_unjittered
	out["previous_projection_unjittered"] = previous_projection_unjittered
	out["camera_origin"] = camera_origin
	out["eye_offset"] = eye_offset
	out["previous_eye_offset"] = previous_eye_offset
	out["near_plane_m"] = near_plane
	out["far_plane_m"] = far_plane
	out["pre_exposure"] = pre_exposure
	out["scene_normalization"] = scene_normalization
	return out


static func grid_z_params(camera_near_m: float, start_distance_m: float,
		far_distance_m: float, grid_z: int = FROXEL_DEPTH) -> Vector3:
	var n := maxf(_safe_nonnegative(camera_near_m, 0.05), _safe_nonnegative(start_distance_m, 0.0)) + NEAR_OFFSET_M
	var f := maxf(_safe_nonnegative(far_distance_m, n + 1.0), n + 0.001)
	var slices := maxi(grid_z, 1)
	var scale := DEPTH_DISTRIBUTION_SCALE
	var offset: float = (f - n * pow(2.0, float(slices) / scale)) / (f - n)
	var bias: float = (1.0 - offset) / n
	return Vector3(bias, offset, scale)


static func depth_from_z_slice(params: Vector3, slice: float) -> float:
	if not params.is_finite() or params.x <= 0.0 or params.z <= 0.0:
		return 0.0
	return (pow(2.0, slice / params.z) - params.y) / params.x


## Unreal uses Halton(frame & 1023, bases 2/3/5) for the current light sample.
## Lighting and the addon RT ray-input generator share this offset; medium,
## history reprojection, and final integration use fixed froxel centers.
static func sample_offset(frame_number: int) -> Vector3:
	var index := frame_number & 1023
	return Vector3(_radical_inverse(index, 2), _radical_inverse(index, 3),
			_radical_inverse(index, 5))


## UE selects one sample when history projects into the previous volume and
## four samples when history is unavailable or outside its valid volume.
static func history_miss_sample_count(history_valid: bool, previous_uvz: Vector3,
		supersample_count: int = HISTORY_MISS_SUPERSAMPLE_COUNT) -> int:
	var quality_count := 1 if supersample_count <= 1 else 4 if supersample_count <= 4 \
			else 8 if supersample_count <= 8 else 16
	if not history_valid or not previous_uvz.is_finite() \
			or previous_uvz.x < 0.0 or previous_uvz.y < 0.0 or previous_uvz.z < 0.0 \
			or previous_uvz.x >= 1.0 or previous_uvz.y >= 1.0 or previous_uvz.z >= 1.0:
		return quality_count
	return 1


static func conservative_reverse_z_min(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0
	var furthest_depth := 1.0
	for sample in samples:
		var depth := float(sample)
		if not is_finite(depth):
			depth = 0.0
		furthest_depth = minf(furthest_depth, clampf(depth, 0.0, 1.0))
	return furthest_depth


static func conservative_depth_occludes(furthest_reverse_z: float,
		cell_device_z: float, depth_available: bool) -> bool:
	return depth_available and is_finite(furthest_reverse_z) and is_finite(cell_device_z) \
			and furthest_reverse_z > cell_device_z


## CPU oracle for UE FixupHistoryUV gather order. `depths` uses x,y,z,w
## component order from Gather; the returned choice identifies the exact UV rule.
static func fixup_history_uv_from_gather(uv: Vector2, size: Vector2i,
		depths: PackedFloat32Array, cell_device_z: float) -> Dictionary:
	if size.x <= 0 or size.y <= 0 or depths.size() < 4 or not uv.is_finite() \
			or uv.x < 0.0 or uv.y < 0.0 or uv.x >= 1.0 or uv.y >= 1.0 \
			or not is_finite(cell_device_z):
		return {"valid": false, "uv": uv, "choice": "invalid"}
	var valid_x := is_finite(depths[0]) and depths[0] < cell_device_z
	var valid_y := is_finite(depths[1]) and depths[1] < cell_device_z
	var valid_z := is_finite(depths[2]) and depths[2] < cell_device_z
	var valid_w := is_finite(depths[3]) and depths[3] < cell_device_z
	if valid_x and valid_y and valid_z and valid_w:
		return {"valid": true, "uv": uv, "choice": "all"}
	var full_res_uv := uv * Vector2(size)
	var screen_coord := (full_res_uv - Vector2(0.5, 0.5)).floor()
	var full_res_offset := full_res_uv - screen_coord
	var fixed_uv := uv
	var choice := "none"
	if valid_w and valid_z:
		fixed_uv = (screen_coord + Vector2(full_res_offset.x, 0.5)) / Vector2(size)
		choice = "wz"
	elif valid_x and valid_y:
		fixed_uv = (screen_coord + Vector2(full_res_offset.x, 1.5)) / Vector2(size)
		choice = "xy"
	elif valid_w and valid_x:
		fixed_uv = (screen_coord + Vector2(0.5, full_res_offset.y)) / Vector2(size)
		choice = "wx"
	elif valid_z and valid_y:
		fixed_uv = (screen_coord + Vector2(1.5, full_res_offset.y)) / Vector2(size)
		choice = "zy"
	elif valid_x:
		fixed_uv = (screen_coord + Vector2(0.5, 1.5)) / Vector2(size)
		choice = "x"
	elif valid_y:
		fixed_uv = (screen_coord + Vector2(1.5, 1.5)) / Vector2(size)
		choice = "y"
	elif valid_w:
		fixed_uv = (screen_coord + Vector2(0.5, 0.5)) / Vector2(size)
		choice = "w"
	elif valid_z:
		fixed_uv = (screen_coord + Vector2(1.5, 0.5)) / Vector2(size)
		choice = "z"
	else:
		return {"valid": false, "uv": uv, "choice": "none"}
	var half_texel := Vector2(0.5, 0.5) / Vector2(size)
	fixed_uv = fixed_uv.clamp(half_texel, Vector2.ONE - half_texel)
	return {"valid": true, "uv": fixed_uv, "choice": choice}


static func conservative_history_sample_count(history_enabled: bool,
		previous_uv_valid: bool, depth_available: bool, current_furthest_reverse_z: float,
		current_cell_device_z: float, miss_samples: int) -> int:
	if conservative_depth_occludes(current_furthest_reverse_z,
			current_cell_device_z, depth_available):
		return 0
	return 1 if history_enabled and previous_uv_valid else normalize_history_miss_count(miss_samples)


## UE's current offset is Halton(frame), and history-miss samples walk backward
## through the same sequence. A disabled jitter mode repeats the voxel center.
static func history_miss_sample_offsets(frame_number: int,
		supersample_count: int = HISTORY_MISS_SUPERSAMPLE_COUNT,
		jitter_enabled: bool = true) -> Array[Vector3]:
	var count := 1 if supersample_count <= 1 else 4 if supersample_count <= 4 \
			else 8 if supersample_count <= 8 else 16
	var result: Array[Vector3] = []
	for sample_index in count:
		result.append(sample_offset(frame_number - sample_index) if jitter_enabled
				else Vector3(0.5, 0.5, 0.5))
	return result


static func z_slice_from_depth(params: Vector3, depth_m: float) -> float:
	if not params.is_finite() or params.x <= 0.0 or params.z <= 0.0 or depth_m <= 0.0:
		return 0.0
	return log(maxf(depth_m * params.x + params.y, 1.0e-12)) / log(2.0) * params.z


static func make_sampling_packet(grid: Vector3i, view_count: int, start_distance_m: float,
		far_distance_m: float, near_plane_m: float, stored_pre_exposure: float,
		froxel_pixel_size: int = FROXEL_PIXEL_SIZE) -> PackedFloat32Array:
	var safe_grid := Vector3i(maxi(grid.x, 1), maxi(grid.y, 1), maxi(grid.z, 1))
	var safe_views := maxi(view_count, 1)
	var atlas_width := safe_grid.x * safe_views
	var z_params := grid_z_params(near_plane_m, start_distance_m, far_distance_m, safe_grid.z)
	var packet := PackedFloat32Array([
		z_params.x, z_params.y, z_params.z, float(maxi(froxel_pixel_size, 1)),
		float(safe_grid.x), float(safe_grid.y), float(safe_grid.z), float(safe_views),
		float(atlas_width), float(safe_grid.y), float(safe_grid.z), float(safe_grid.x),
		_safe_nonnegative(start_distance_m, 0.0), _safe_nonnegative(far_distance_m, 1.0),
		_safe_nonnegative(near_plane_m, 0.05), _safe_positive(stored_pre_exposure, 1.0),
		1.0 / float(atlas_width), 1.0 / float(safe_grid.y), 1.0 / float(safe_grid.z), 1.0,
	])
	return packet


static func _finite(value: Variant, fallback: float) -> float:
	if not (value is int or value is float):
		return fallback
	var converted := float(value)
	return converted if is_finite(converted) else fallback


static func _safe_nonnegative(value: Variant, fallback: float) -> float:
	return clampf(_finite(value, fallback), 0.0, MAX_RENDER_DISTANCE_M)


static func _safe_positive(value: Variant, fallback: float) -> float:
	return maxf(_finite(value, fallback), 1.0e-8)


static func _radical_inverse(index: int, radix: int) -> float:
	var remaining := maxi(index, 0)
	var inverse_radix := 1.0 / float(radix)
	var factor := inverse_radix
	var value := 0.0
	while remaining > 0:
		value += float(remaining % radix) * factor
		remaining = int(remaining / radix)
		factor *= inverse_radix
	return value


static func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


static func _append_transform4(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0]))


static func _observer_height(camera_y: float, density0: float, height0: float,
		density1: float, height1: float, projection: Projection) -> float:
	if projection.is_orthogonal() or not is_finite(camera_y):
		return camera_y
	var cap := INF
	if density0 > 0.0 and is_finite(density0) and is_finite(height0):
		cap = minf(cap, height0 + 655.36)
	if density1 > 0.0 and is_finite(density1) and is_finite(height1):
		cap = minf(cap, height1 + 655.36)
	return minf(camera_y, cap) if is_finite(cap) else camera_y
