@tool
class_name FengSkyRuntime
extends RefCounted
## Main-thread, world-scoped publication point for Feng Sky atmosphere data.
## Render code only consumes values copied into the owning sky material.

const VIEW_SAMPLES := 8
const SUN_SAMPLES := 6
const AMBIENT_ZENITH_STEP_DEG := 2.0
const AMBIENT_SAMPLE_COUNT := 64
const ATMOSPHERE_SHADER_PATH := "res://addons/feng-sky/feng_sky_atmosphere.gdshader"
const DEFAULT_RAYLEIGH_PER_KM := Vector3(0.005802, 0.013558, 0.0331)
const DEFAULT_PLANET_CENTER_M := Vector3(0.0, -6360000.0, 0.0)
const MAX_SCATTER_COEFFICIENT_PER_KM := 1.0

static var _providers_by_world: Dictionary = {} # world instance id -> WeakRef
static var _snapshots_by_world: Dictionary = {} # world instance id -> immutable value dictionary


static func publish_snapshot(provider: Object, world_id: int, snapshot: Dictionary) -> void:
	if provider == null or not is_instance_valid(provider) or world_id == 0:
		return
	var value := snapshot.duplicate(true)
	value["world_id"] = world_id
	value["provider_id"] = provider.get_instance_id()
	_providers_by_world[world_id] = weakref(provider)
	_snapshots_by_world[world_id] = value


static func remove_snapshot(provider: Object, world_id: int) -> void:
	if world_id == 0:
		return
	var provider_ref: WeakRef = _providers_by_world.get(world_id)
	if provider_ref == null:
		return
	var current := provider_ref.get_ref()
	if current == provider or current == null or not is_instance_valid(current):
		_providers_by_world.erase(world_id)
		_snapshots_by_world.erase(world_id)


static func snapshot_for_world(world_id: int) -> Dictionary:
	var provider_ref: WeakRef = _providers_by_world.get(world_id)
	if provider_ref == null:
		return {}
	var provider := provider_ref.get_ref()
	if provider == null or not is_instance_valid(provider):
		_providers_by_world.erase(world_id)
		_snapshots_by_world.erase(world_id)
		return {}
	# Fog calls this from its main-thread runtime. Validate the current provider
	# identity here as well as in FengSkyAtmosphere._process(), so a World3D
	# environment handoff cannot expose a stale snapshot for one frame.
	if not provider.has_method("_feng_sky_runtime_is_active") or not provider.call("_feng_sky_runtime_is_active", world_id):
		_providers_by_world.erase(world_id)
		_snapshots_by_world.erase(world_id)
		return {}
	var snapshot: Dictionary = _snapshots_by_world.get(world_id, {})
	if snapshot.is_empty():
		return {}
	return snapshot.duplicate(true)


static func atmosphere_shader() -> Shader:
	return load(ATMOSPHERE_SHADER_PATH) as Shader


static func atmosphere_shader_code() -> String:
	var shader := atmosphere_shader()
	return shader.code if shader != null else ""


static func compute_atmosphere_sample(settings: Dictionary, sun_direction_world: Vector3, sun_irradiance: float, sun_color_linear: Vector3) -> Dictionary:
	## Public for deterministic diagnostics; called by the provider only on a
	## cache miss. It returns unit-sun ambient radiance and ground transmittance.
	var sanitized := sanitize_atmosphere_settings(settings)
	var radius: float = sanitized["planet_radius_km"]
	var top_radius := radius + float(sanitized["atmosphere_height_km"])
	var rayleigh_height: float = sanitized["rayleigh_scale_height_km"]
	var mie_height: float = sanitized["mie_scale_height_km"]
	var beta_rayleigh: Vector3 = sanitized["rayleigh_scattering_per_km"]
	var beta_mie_scatter: float = sanitized["mie_scattering_per_km"]
	var beta_mie_extinction: float = sanitized["mie_extinction_per_km"]
	var mie_g: float = sanitized["mie_asymmetry"]
	var sun_direction := sanitize_sun_direction(sun_direction_world)
	var planet_center_m: Vector3 = sanitized["planet_center_m"]
	var surface_origin := -planet_center_m / 1000.0
	var surface_radius := surface_origin.length()
	var up := surface_origin.normalized() if surface_radius > 0.001 else Vector3.UP
	var reference_altitude := maxf(surface_radius - radius, 0.0)
	var ray_origin := up * (radius + reference_altitude)

	var east := Vector3.RIGHT - up * up.dot(Vector3.RIGHT)
	if east.length_squared() < 0.001:
		east = Vector3.FORWARD - up * up.dot(Vector3.FORWARD)
	east = east.normalized()
	var north := up.cross(east).normalized()
	var ambient_unit := Vector3.ZERO
	var sample_pairs := maxi(AMBIENT_SAMPLE_COUNT / 2, 1)
	var sun_tangent := Vector3.RIGHT - sun_direction * sun_direction.dot(Vector3.RIGHT)
	if sun_tangent.length_squared() < 0.001:
		sun_tangent = Vector3.FORWARD - sun_direction * sun_direction.dot(Vector3.FORWARD)
	sun_tangent = sun_tangent.normalized()
	var sun_bitangent := sun_direction.cross(sun_tangent).normalized()
	var mie_uniform_pdf := 1.0 / (4.0 * PI)
	for sample_index in range(AMBIENT_SAMPLE_COUNT):
		var pair_index := sample_index / 2
		var u := (float(pair_index) + 0.5) / float(sample_pairs)
		var phi := TAU * fposmod(float(pair_index) * 0.6180339887498949, 1.0)
		var view_direction: Vector3
		if sample_index % 2 == 0:
			# Half of the deterministic mixture covers the whole sphere uniformly.
			var cosine_zenith := 1.0 - 2.0 * u
			var sine_zenith := sqrt(maxf(1.0 - cosine_zenith * cosine_zenith, 0.0))
			view_direction = up * cosine_zenith + east * (sine_zenith * cos(phi)) + north * (sine_zenith * sin(phi))
		else:
			# The other half samples around the sun using the normalized HG phase
			# distribution, capturing the narrow circumsolar forward peak.
			var cosine_sun_angle := _sample_henyey_greenstein_cosine(u, mie_g)
			var sine_sun_angle := sqrt(maxf(1.0 - cosine_sun_angle * cosine_sun_angle, 0.0))
			view_direction = sun_direction * cosine_sun_angle + sun_tangent * (sine_sun_angle * cos(phi)) + sun_bitangent * (sine_sun_angle * sin(phi))
		view_direction = view_direction.normalized()
		if view_direction.dot(up) <= 0.0:
			continue # The lower hemisphere is ground, with no ground-bounce term.
		var cosine_angle := clampf(view_direction.dot(sun_direction), -1.0, 1.0)
		var mie_denom := maxf(1.0 + mie_g * mie_g - 2.0 * mie_g * cosine_angle, 0.0001)
		var mie_phase_pdf := (1.0 - mie_g * mie_g) / (4.0 * PI * pow(mie_denom, 1.5))
		var mixture_pdf := 0.5 * mie_uniform_pdf + 0.5 * mie_phase_pdf
		var importance_weight := 1.0 / maxf(4.0 * PI * mixture_pdf, 0.000001)
		ambient_unit += _integrate_ray(
			ray_origin,
			view_direction,
			sun_direction,
			radius,
			top_radius,
			rayleigh_height,
			mie_height,
			beta_rayleigh,
			beta_mie_scatter,
			beta_mie_extinction,
			mie_g
		) * (importance_weight / float(AMBIENT_SAMPLE_COUNT))
	var ground_transmittance := _ground_sun_transmittance(
		up,
		sun_direction,
		radius,
		top_radius,
		rayleigh_height,
		mie_height,
		beta_rayleigh,
		beta_mie_extinction
	)
	var irradiance := maxf(_finite_input_float(sun_irradiance, 0.0), 0.0)
	var source_color := _finite_vector(sun_color_linear)
	var scaled_ambient := ambient_unit * irradiance * source_color
	var ground_illuminance := source_color * irradiance * ground_transmittance
	return {
		"ambient_unit_sun": ambient_unit,
		"ambient_radiance": _finite_vector(scaled_ambient),
		"ground_transmittance": ground_transmittance,
		"sun_ground_illuminance": _finite_vector(ground_illuminance),
		"ambient_sample_count": AMBIENT_SAMPLE_COUNT,
	}


static func sanitize_atmosphere_settings(settings: Dictionary) -> Dictionary:
	## Inspector ranges are hints only. This shared contract keeps CPU fog
	## integration and GPU sky uniforms on the same finite physical parameter set.
	var rayleigh := _finite_input_vector(settings.get("rayleigh_scattering_per_km", DEFAULT_RAYLEIGH_PER_KM), DEFAULT_RAYLEIGH_PER_KM)
	var mie_scatter := clampf(_finite_input_float(settings.get("mie_scattering_per_km", 0.003996), 0.003996), 0.0, MAX_SCATTER_COEFFICIENT_PER_KM)
	var mie_extinction := clampf(_finite_input_float(settings.get("mie_extinction_per_km", 0.00444), 0.00444), 0.0, MAX_SCATTER_COEFFICIENT_PER_KM)
	return {
		"planet_radius_km": clampf(_finite_input_float(settings.get("planet_radius_km", 6360.0), 6360.0), 6000.0, 7000.0),
		"atmosphere_height_km": clampf(_finite_input_float(settings.get("atmosphere_height_km", 60.0), 60.0), 1.0, 120.0),
		"rayleigh_scale_height_km": clampf(_finite_input_float(settings.get("rayleigh_scale_height_km", 8.0), 8.0), 1.0, 30.0),
		"mie_scale_height_km": clampf(_finite_input_float(settings.get("mie_scale_height_km", 1.2), 1.2), 0.1, 10.0),
		"rayleigh_scattering_per_km": rayleigh.max(Vector3.ZERO).clamp(Vector3.ZERO, Vector3.ONE * MAX_SCATTER_COEFFICIENT_PER_KM),
		"mie_scattering_per_km": mie_scatter,
		"mie_extinction_per_km": maxf(mie_extinction, mie_scatter),
		"mie_asymmetry": clampf(_finite_input_float(settings.get("mie_asymmetry", 0.8), 0.8), -0.95, 0.95),
		"planet_center_m": _finite_input_vector(settings.get("planet_center_m", DEFAULT_PLANET_CENTER_M), DEFAULT_PLANET_CENTER_M),
		"ground_albedo": _finite_input_vector(settings.get("ground_albedo", Vector3(0.1, 0.1, 0.1)), Vector3(0.1, 0.1, 0.1)).clamp(Vector3.ZERO, Vector3.ONE),
		"sun_angular_radius_deg": clampf(_finite_input_float(settings.get("sun_angular_radius_deg", 0.2666), 0.2666), 0.01, 2.0),
	}


static func _sample_henyey_greenstein_cosine(u: float, g: float) -> float:
	if absf(g) < 0.001:
		return 1.0 - 2.0 * u
	var term := (1.0 - g * g) / maxf(1.0 - g + 2.0 * g * u, 0.000001)
	return clampf((1.0 + g * g - term * term) / (2.0 * g), -1.0, 1.0)


static func _integrate_ray(origin: Vector3, view_direction: Vector3, sun_direction: Vector3, radius: float, top_radius: float, rayleigh_height: float, mie_height: float, beta_rayleigh: Vector3, beta_mie_scatter: float, beta_mie_extinction: float, mie_g: float) -> Vector3:
	var atmosphere_distance := _sphere_exit_distance(origin, view_direction, top_radius)
	if atmosphere_distance <= 0.0:
		return Vector3.ZERO
	var ground_discriminant := view_direction.dot(origin) * view_direction.dot(origin) - (origin.length_squared() - radius * radius)
	if ground_discriminant >= 0.0:
		var near_ground := -view_direction.dot(origin) - sqrt(ground_discriminant)
		if near_ground > 0.0 and near_ground < atmosphere_distance:
			atmosphere_distance = near_ground
	var cosine_angle := clampf(view_direction.dot(sun_direction), -1.0, 1.0)
	var rayleigh_phase := 3.0 * (1.0 + cosine_angle * cosine_angle) / (16.0 * PI)
	var mie_denom := maxf(1.0 + mie_g * mie_g - 2.0 * mie_g * cosine_angle, 0.0001)
	var mie_phase := (1.0 - mie_g * mie_g) / (4.0 * PI * pow(mie_denom, 1.5))
	var view_transmittance := Vector3.ONE
	var radiance := Vector3.ZERO
	var radial_dot := origin.normalized().dot(view_direction)
	for sample_index in range(VIEW_SAMPLES):
		var sample_start := pow(float(sample_index) / float(VIEW_SAMPLES), 2.0)
		var sample_end := pow(float(sample_index + 1) / float(VIEW_SAMPLES), 2.0)
		if radial_dot < 0.0:
			sample_start = 1.0 - pow(1.0 - float(sample_index) / float(VIEW_SAMPLES), 2.0)
			sample_end = 1.0 - pow(1.0 - float(sample_index + 1) / float(VIEW_SAMPLES), 2.0)
		var step_length := (sample_end - sample_start) * atmosphere_distance
		var point := origin + view_direction * ((sample_start + sample_end) * 0.5 * atmosphere_distance)
		var altitude := maxf(point.length() - radius, 0.0)
		var rayleigh_density := exp(-altitude / rayleigh_height)
		var mie_density := exp(-altitude / mie_height)
		var sun_transmittance := _transmittance_to_sun(point, sun_direction, radius, top_radius, rayleigh_height, mie_height, beta_rayleigh, beta_mie_extinction)
		var source := beta_rayleigh * (rayleigh_density * rayleigh_phase) + Vector3.ONE * (beta_mie_scatter * mie_density * mie_phase)
		var extinction := beta_rayleigh * rayleigh_density + Vector3.ONE * (beta_mie_extinction * mie_density)
		var segment_transmittance := _exp_negative(extinction * step_length)
		var segment_factor := _view_segment_factor(extinction, step_length)
		radiance += view_transmittance * sun_transmittance * source * segment_factor
		view_transmittance *= segment_transmittance
	return _finite_vector(radiance)


static func _transmittance_to_sun(point: Vector3, sun_direction: Vector3, radius: float, top_radius: float, rayleigh_height: float, mie_height: float, beta_rayleigh: Vector3, beta_mie_extinction: float) -> Vector3:
	if _ray_hits_ground(point, sun_direction, radius):
		return Vector3.ZERO
	var path_length := _sphere_exit_distance(point, sun_direction, top_radius)
	if path_length <= 0.0:
		return Vector3.ZERO
	var rayleigh_column := 0.0
	var mie_column := 0.0
	for sample_index in range(SUN_SAMPLES):
		var sample_start := pow(float(sample_index) / float(SUN_SAMPLES), 2.0)
		var sample_end := pow(float(sample_index + 1) / float(SUN_SAMPLES), 2.0)
		var step_length := (sample_end - sample_start) * path_length
		var point_on_ray := point + sun_direction * ((sample_start + sample_end) * 0.5 * path_length)
		var altitude := maxf(point_on_ray.length() - radius, 0.0)
		rayleigh_column += exp(-altitude / rayleigh_height) * step_length
		mie_column += exp(-altitude / mie_height) * step_length
	var optical_depth := beta_rayleigh * rayleigh_column + Vector3.ONE * (beta_mie_extinction * mie_column)
	return _finite_vector(_exp_negative(optical_depth))


static func _ground_sun_transmittance(up: Vector3, sun_direction: Vector3, radius: float, top_radius: float, rayleigh_height: float, mie_height: float, beta_rayleigh: Vector3, beta_mie_extinction: float) -> Vector3:
	if up.dot(sun_direction) <= 0.0:
		return Vector3.ZERO
	var path_length := _sphere_exit_distance(up * radius, sun_direction, top_radius)
	if path_length <= 0.0:
		return Vector3.ZERO
	var rayleigh_column := 0.0
	var mie_column := 0.0
	for sample_index in range(SUN_SAMPLES):
		var sample_start := pow(float(sample_index) / float(SUN_SAMPLES), 2.0)
		var sample_end := pow(float(sample_index + 1) / float(SUN_SAMPLES), 2.0)
		var step_length := (sample_end - sample_start) * path_length
		var point := up * radius + sun_direction * ((sample_start + sample_end) * 0.5 * path_length)
		var altitude := maxf(point.length() - radius, 0.0)
		rayleigh_column += exp(-altitude / rayleigh_height) * step_length
		mie_column += exp(-altitude / mie_height) * step_length
	var optical_depth := beta_rayleigh * rayleigh_column + Vector3.ONE * (beta_mie_extinction * mie_column)
	return _finite_vector(_exp_negative(optical_depth))


static func _ray_hits_ground(point: Vector3, direction: Vector3, radius: float) -> bool:
	var b := point.dot(direction)
	var c := point.length_squared() - radius * radius
	return b < 0.0 and b * b - c >= 0.0


static func _sphere_exit_distance(origin: Vector3, direction: Vector3, radius: float) -> float:
	var b := origin.dot(direction)
	var c := origin.length_squared() - radius * radius
	var discriminant := b * b - c
	if discriminant < 0.0:
		return -1.0
	return maxf(-b + sqrt(discriminant), 0.0)


static func sanitize_sun_direction(direction: Vector3) -> Vector3:
	if not direction.is_finite():
		return Vector3.UP
	# Normalize after scaling to avoid overflow/underflow in length_squared
	# for finite transforms authored through code.
	var magnitude := direction.abs()[direction.abs().max_axis_index()]
	if magnitude == 0.0:
		return Vector3.UP
	return (direction / magnitude).normalized()


static func _finite_vector(value: Vector3) -> Vector3:
	if not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z):
		return Vector3.ZERO
	return value.max(Vector3.ZERO)


static func _finite_input_float(value: Variant, fallback: float) -> float:
	var number := float(value)
	return number if is_finite(number) else fallback


static func _finite_input_vector(value: Variant, fallback: Vector3) -> Vector3:
	if not value is Vector3:
		return fallback
	var vector: Vector3 = value
	if not is_finite(vector.x) or not is_finite(vector.y) or not is_finite(vector.z):
		return fallback
	return vector


static func _exp_negative(value: Vector3) -> Vector3:
	return Vector3(exp(-value.x), exp(-value.y), exp(-value.z))


static func _view_segment_factor(extinction: Vector3, step_length: float) -> Vector3:
	var segment_transmittance := _exp_negative(extinction * step_length)
	var factor := Vector3(step_length, step_length, step_length)
	if extinction.x > 0.0000001:
		factor.x = (1.0 - segment_transmittance.x) / extinction.x
	if extinction.y > 0.0000001:
		factor.y = (1.0 - segment_transmittance.y) / extinction.y
	if extinction.z > 0.0000001:
		factor.z = (1.0 - segment_transmittance.z) / extinction.z
	return factor
