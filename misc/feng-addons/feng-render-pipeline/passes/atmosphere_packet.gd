@tool
extends RefCounted
## Bounded renderer handoff. This translates a normalized snapshot, never nodes.
## Sixteen vec4s are shared by opaque compute and native forward/deferred paths.

static func _v(value: Variant, fallback := Vector3.ZERO) -> Vector3:
	if value is Vector3 and value.is_finite():
		return value
	return fallback

static func _f(value: Variant, fallback: float) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return float(value)
	return fallback

static func _append(values: PackedFloat32Array, vector: Vector3, scalar: float) -> void:
	values.append_array(PackedFloat32Array([vector.x, vector.y, vector.z, scalar]))

static func make(snapshot: Dictionary, camera: Transform3D, optical_valid: bool, multiple_valid: bool) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	if snapshot.is_empty() or not snapshot.get("settings") is Dictionary:
		values.resize(64)
		return values
	var s: Dictionary = snapshot["settings"]
	var origin := (camera.origin - _v(s.get("planet_center_m"), Vector3(0.0, -6360000.0, 0.0))) * 0.001
	_append(values, origin, _f(s.get("planet_radius_km"), 6360.0))
	_append(values, _v(s.get("rayleigh_scattering_per_km")), _f(s.get("rayleigh_scale_height_km"), 8.0))
	_append(values, _v(s.get("mie_scattering_coefficients")), _f(s.get("mie_scale_height_km"), 1.2))
	_append(values, _v(s.get("mie_extinction_coefficients")), _f(s.get("mie_asymmetry"), 0.8))
	_append(values, _v(s.get("absorption_extinction_per_km")), _f(s.get("atmosphere_height_km"), 60.0))
	values.append_array(PackedFloat32Array([
		_f(s.get("absorption_density_layer_width_km"), 25.0),
		_f(s.get("absorption_layer0_linear_term"), 1.0 / 15.0),
		_f(s.get("absorption_layer0_constant_term"), -2.0 / 3.0),
		_f(s.get("absorption_layer1_linear_term"), -1.0 / 15.0),
		_f(s.get("absorption_layer1_constant_term"), 8.0 / 3.0),
		_f(s.get("multi_scattering_factor"), 1.0),
		_f(s.get("aerial_perspective_start_depth_km"), 0.1),
		_f(s.get("aerial_perspective_view_distance_scale"), 1.0)]))
	# sky_luminance_factor is the normalized combined sky+aerial factor.
	# sky_only_luminance_factor and legacy background sky gain are excluded.
	_append(values, _v(s.get("sky_luminance_factor"), Vector3.ONE), float(roundi(clampf(8.0 * _f(s.get("trace_sample_count_scale"), 1.0), 2.0, 64.0))))
	for prefix in ["", "secondary_"]:
		var direction := _v(snapshot.get(prefix + "sun_direction"), Vector3.UP)
		direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector3.UP
		_append(values, direction, maxf(_f(snapshot.get(prefix + "sun_irradiance"), 0.0), 0.0))
		_append(values, _v(snapshot.get(prefix + "sun_color_linear")), _f(s.get("minimum_light_elevation_deg"), -90.0) if prefix.is_empty() else 0.0)
	values.append_array(PackedFloat32Array([float(optical_valid), float(multiple_valid), 1.0, 0.0 if bool(snapshot.get("render_in_main_pass", true)) else 1.0]))
	values.resize(64)
	return values
