@tool
class_name FengSkyRuntime
extends RefCounted
## Main-thread, world-scoped publication point for Feng Sky atmosphere data.
## Render code only consumes values copied into the owning sky material.

const FengSkyParameters = preload("res://addons/feng-sky/feng_sky_parameters.gd")
const FengSkyTransport = preload("res://addons/feng-sky/feng_sky_transport.gd")
const FengSkyMultiScatteringLut = preload("res://addons/feng-sky/feng_sky_multiscattering_lut.gd")

const VIEW_SAMPLES := 8
const SUN_SAMPLES := 6
const AMBIENT_ZENITH_STEP_DEG := 2.0
const AMBIENT_SAMPLE_COUNT := 64
const ATMOSPHERE_SHADER_PATH := "res://addons/feng-sky/feng_sky_atmosphere.gdshader"
const DEFAULT_RAYLEIGH_PER_KM := Vector3(0.005802, 0.013558, 0.0331)
const DEFAULT_PLANET_CENTER_M := Vector3(0.0, -6360000.0, 0.0)
const MAX_SCATTER_COEFFICIENT_PER_KM := FengSkyParameters.MAX_SCATTER_COEFFICIENT_PER_KM

static var _snapshots_by_world: Dictionary = {} # world id -> {provider: WeakRef, snapshot}

static var _rendering_by_world: Dictionary = {} # world id -> {provider: WeakRef, snapshot}
static var _rendering_snapshots: Array[Dictionary] = []
static var _rendering_mutex := Mutex.new()


static func publish_rendering_snapshot(provider: Object, world_id: int, snapshot: Dictionary) -> void:
	if provider == null or not is_instance_valid(provider) or world_id == 0:
		return
	var value := snapshot.duplicate(true)
	value["world_id"] = world_id
	value["provider_id"] = provider.get_instance_id()
	value["render_targets"] = value.get("render_targets", [])
	_rendering_by_world[world_id] = {"provider": weakref(provider), "snapshot": value}
	_publish_rendering_array()


static func remove_rendering_snapshot(provider: Object, world_id: int) -> void:
	var reference: WeakRef = _rendering_by_world.get(world_id, {}).get("provider")
	if reference == null:
		return
	var current := reference.get_ref()
	if current == provider or current == null or not is_instance_valid(current):
		_rendering_by_world.erase(world_id)
		_publish_rendering_array()


static func rendering_snapshot_for_world(world_id: int) -> Dictionary:
	# Main-thread accessor validates ownership immediately, matching fog reads.
	refresh_rendering_snapshots()
	return (_rendering_by_world.get(world_id, {}).get("snapshot", {}) as Dictionary).duplicate(true)


static func refresh_rendering_snapshots() -> void:
	# Main-thread only. The component owns viewport routing and publishes targets.
	var changed := false
	for world_id in _rendering_by_world.keys():
		var reference: WeakRef = _rendering_by_world[world_id]["provider"]
		var provider := reference.get_ref()
		if provider == null or not is_instance_valid(provider) or not provider.has_method("_feng_sky_rendering_is_active") or not provider.call("_feng_sky_rendering_is_active", world_id):
			_rendering_by_world.erase(world_id)
			changed = true
			continue
	if changed:
		_publish_rendering_array()


static func _publish_rendering_array() -> void:
	var values: Array[Dictionary] = []
	for entry in _rendering_by_world.values():
		values.append(entry["snapshot"])
	_rendering_mutex.lock()
	_rendering_snapshots = values
	_rendering_mutex.unlock()


static func rendering_snapshots() -> Array[Dictionary]:
	# Render-thread safe: no Node, scene-tree, or Resource mutation/inspection.
	_rendering_mutex.lock()
	var result := _rendering_snapshots
	_rendering_mutex.unlock()
	return result


static func publish_snapshot(provider: Object, world_id: int, snapshot: Dictionary) -> void:
	if provider == null or not is_instance_valid(provider) or world_id == 0:
		return
	var value := snapshot.duplicate(true)
	value["world_id"] = world_id
	value["provider_id"] = provider.get_instance_id()
	_snapshots_by_world[world_id] = {"provider": weakref(provider), "snapshot": value}


static func remove_snapshot(provider: Object, world_id: int) -> void:
	if world_id == 0:
		return
	var provider_ref: WeakRef = _snapshots_by_world.get(world_id, {}).get("provider")
	if provider_ref == null:
		return
	var current := provider_ref.get_ref()
	if current == provider or current == null or not is_instance_valid(current):
		_snapshots_by_world.erase(world_id)


static func snapshot_for_world(world_id: int) -> Dictionary:
	var provider_ref: WeakRef = _snapshots_by_world.get(world_id, {}).get("provider")
	if provider_ref == null:
		return {}
	var provider := provider_ref.get_ref()
	# Revalidate on main-thread reads so same-frame environment handoffs cannot
	# expose the previous provider's atmosphere before its next _process().
	if provider == null or not is_instance_valid(provider) \
			or not provider.has_method("_feng_sky_runtime_is_active") \
			or not provider.call("_feng_sky_runtime_is_active", world_id):
		_snapshots_by_world.erase(world_id)
		return {}
	return (_snapshots_by_world[world_id]["snapshot"] as Dictionary).duplicate(true)


static func atmosphere_shader() -> Shader:
	return load(ATMOSPHERE_SHADER_PATH) as Shader


static func atmosphere_shader_code() -> String:
	var shader := atmosphere_shader()
	return shader.code if shader != null else ""


static func compute_atmosphere_sample(settings: Dictionary, sun_direction_world: Vector3, sun_irradiance: float, sun_color_linear: Vector3, cached_multi_scattering_image: Image = null, ground_only: bool = false) -> Dictionary:
	## Public for deterministic diagnostics; called by the provider only on a
	## cache miss. It returns unit-sun ambient radiance and ground transmittance.
	var sanitized := sanitize_atmosphere_settings(settings)
	var radius: float = sanitized["planet_radius_km"]
	var mie_g := clampf(float(sanitized["mie_asymmetry"]), 0.0, 0.999)
	var sun_direction := sanitize_sun_direction(sun_direction_world)
	var planet_center_m: Vector3 = sanitized["planet_center_m"]
	var surface_origin := -planet_center_m / 1000.0
	var surface_radius := surface_origin.length()
	var up := sanitize_sun_direction(surface_origin) if surface_radius > 0.001 else Vector3.UP
	if ground_only:
		return {"ambient_unit_sun": Vector3.ZERO,
			"ground_transmittance": FengSkyTransport.ground_sun_transmittance(up, sun_direction, sanitized)}
	var reference_altitude := maxf(surface_radius - radius, 0.0)
	var ray_origin := up * (radius + reference_altitude)

	var east := Vector3.RIGHT - up * up.dot(Vector3.RIGHT)
	if east.length_squared() < 0.001:
		east = Vector3.FORWARD - up * up.dot(Vector3.FORWARD)
	east = east.normalized()
	var north := up.cross(east).normalized()
	var multi_scattering_image := cached_multi_scattering_image
	if multi_scattering_image == null and float(sanitized["multi_scattering_factor"]) > 0.0:
		multi_scattering_image = FengSkyMultiScatteringLut.make_image(sanitized)
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
			continue # The virtual ground is dark; bounce reaches the sky through MS.
		var cosine_angle := clampf(view_direction.dot(sun_direction), -1.0, 1.0)
		var mie_denom := maxf(1.0 + mie_g * mie_g - 2.0 * mie_g * cosine_angle, 0.0001)
		var mie_phase_pdf := (1.0 - mie_g * mie_g) / (4.0 * PI * pow(mie_denom, 1.5))
		var mixture_pdf := 0.5 * mie_uniform_pdf + 0.5 * mie_phase_pdf
		var importance_weight := 1.0 / maxf(4.0 * PI * mixture_pdf, 0.000001)
		ambient_unit += FengSkyTransport.integrate_ray(ray_origin, view_direction, sun_direction, sanitized, multi_scattering_image) * (importance_weight / float(AMBIENT_SAMPLE_COUNT))
	ambient_unit *= (sanitized["sky_luminance_factor"] as Vector3) * (sanitized["sky_only_luminance_factor"] as Vector3)
	var ground_transmittance := FengSkyTransport.ground_sun_transmittance(up, sun_direction, sanitized)
	var irradiance := maxf(FengSkyParameters.finite_float(sun_irradiance, 0.0), 0.0)
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
	# Compatibility entry point; the parameter model owns the shared contract.
	return FengSkyParameters.sanitize_atmosphere_settings(settings)


static func _sample_henyey_greenstein_cosine(u: float, g: float) -> float:
	g = clampf(g, 0.0, 0.999)
	if absf(g) < 0.001:
		return 1.0 - 2.0 * u
	var term := (1.0 - g * g) / maxf(1.0 - g + 2.0 * g * u, 0.000001)
	return clampf((1.0 + g * g - term * term) / (2.0 * g), -1.0, 1.0)


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
	if not value.is_finite():
		return Vector3.ZERO
	return value.max(Vector3.ZERO)
