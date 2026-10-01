@tool
extends RefCounted
## Isotropic second-and-higher-order incident radiance per unit solar irradiance.
## Hillaire's directional integral / geometric-series closure, evaluated at a
## deliberately bounded resolution. Ground bounce is only included here.
## https://github.com/sebh/UnrealEngineSkyAtmosphere/blob/master/Resources/RenderSkyRayMarching.hlsl
## Compared with that reference: 16 directions, 12 nonlinear ray segments,
## 16x16 texels with squared altitude/signed-square solar cosine mapping, and feedback clamped below 1.

const Transport = preload("res://addons/feng-sky/feng_sky_transport.gd")
const WIDTH := 16
const HEIGHT := 16
const DIRECTION_SAMPLES := 16
const PATH_SAMPLES := 12
const MAX_CACHE_ENTRIES := 4
const MAX_FEEDBACK := 0.95
static var _cache: Array = [] # signature plus immutable-by-convention bytes
static var _build_count := 0


static func signature(settings: Dictionary) -> Array:
	# Artist gain, light position/color/intensity, world center, camera exposure,
	# and view-march quality do not change this unit-sun transfer function.
	return [settings["planet_radius_km"], settings["atmosphere_height_km"],
		settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
		settings["rayleigh_scattering_per_km"], settings["mie_scattering_coefficients"],
		settings["mie_extinction_coefficients"], settings["absorption_extinction_per_km"],
		settings["absorption_density_layer_width_km"], settings["absorption_layer0_linear_term"],
		settings["absorption_layer0_constant_term"], settings["absorption_layer1_linear_term"],
		settings["absorption_layer1_constant_term"], settings["ground_albedo"]]


static func make_image(settings: Dictionary) -> Image:
	var key := signature(settings)
	for index in _cache.size():
		var entry: Dictionary = _cache[index]
		if entry["signature"] == key:
			_cache.remove_at(index)
			_cache.append(entry)
			return Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBF, entry["bytes"])
	var data := _build(settings).to_byte_array()
	_cache.append({"signature": key, "bytes": data})
	if _cache.size() > MAX_CACHE_ENTRIES:
		_cache.pop_front()
	_build_count += 1
	return Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBF, data)


static func sample(image: Image, point: Vector3, sun_direction: Vector3, settings: Dictionary) -> Vector3:
	return Transport.sample_multiple_scattering(image, point, sun_direction, settings)


static func _build(settings: Dictionary) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(WIDTH * HEIGHT * 3)
	var radius: float = settings["planet_radius_km"]
	var height: float = settings["atmosphere_height_km"]
	var rayleigh_coefficient: Vector3 = settings["rayleigh_scattering_per_km"]
	var mie_coefficient: Vector3 = settings["mie_scattering_coefficients"]
	# Pure absorption has no scattered source, including ground bounce into air.
	if rayleigh_coefficient == Vector3.ZERO and mie_coefficient == Vector3.ZERO:
		return values
	for y in HEIGHT:
		var altitude := maxf(height * pow(float(y) / float(HEIGHT - 1), 2.0), 0.001)
		var origin := Vector3(0.0, radius + minf(altitude, height - 0.001), 0.0)
		for x in WIDTH:
			var solar_coordinate := 2.0 * float(x) / float(WIDTH - 1) - 1.0
			var sun_cosine := solar_coordinate * absf(solar_coordinate)
			var sun := Vector3(sqrt(maxf(1.0 - sun_cosine * sun_cosine, 0.0)), sun_cosine, 0.0)
			var incoming := Vector3.ZERO
			var feedback := Vector3.ZERO
			for direction_index in DIRECTION_SAMPLES:
				# Deterministic uniform solid-angle quadrature, including both sides
				# of the horizon. No narrow Mie phase peak is assumed for later orders.
				var mu := 1.0 - 2.0 * (float(direction_index) + 0.5) / float(DIRECTION_SAMPLES)
				var phi := TAU * fposmod(float(direction_index) * 0.6180339887498949, 1.0)
				var sine := sqrt(maxf(1.0 - mu * mu, 0.0))
				var direction := Vector3(sine * cos(phi), mu, sine * sin(phi))
				var result := _integrate_isotropic(origin, direction, sun, settings)
				incoming += result[0] / float(DIRECTION_SAMPLES)
				feedback += result[1] / float(DIRECTION_SAMPLES)
			# Analytical segment integration bounds feedback physically. This
			# extra guard also keeps extreme, nearly conservative artist profiles
			# finite when a low-resolution quadrature approaches unit feedback.
			feedback = feedback.clamp(Vector3.ZERO, Vector3.ONE * MAX_FEEDBACK)
			var radiance := incoming / (Vector3.ONE - feedback)
			var offset := (y * WIDTH + x) * 3
			values[offset] = radiance.x
			values[offset + 1] = radiance.y
			values[offset + 2] = radiance.z
	return values


static func _integrate_isotropic(origin: Vector3, direction: Vector3, sun: Vector3, settings: Dictionary) -> Array[Vector3]:
	var radius: float = settings["planet_radius_km"]
	var path := Transport.sphere_exit_distance(origin, direction, radius + float(settings["atmosphere_height_km"]))
	var ground := Transport.ground_distance(origin, direction, radius)
	if ground >= 0.0:
		path = minf(path, ground)
	var incoming := Vector3.ZERO
	var feedback := Vector3.ZERO
	var transmission := Vector3.ONE
	var beta_rayleigh: Vector3 = settings["rayleigh_scattering_per_km"]
	var beta_mie: Vector3 = settings["mie_scattering_coefficients"]
	var beta_extinction: Vector3 = settings["mie_extinction_coefficients"]
	var beta_absorption: Vector3 = settings["absorption_extinction_per_km"]
	for i in PATH_SAMPLES:
		var start := pow(float(i) / float(PATH_SAMPLES), 2.0)
		var end := pow(float(i + 1) / float(PATH_SAMPLES), 2.0)
		if direction.y < 0.0:
			start = 1.0 - pow(1.0 - float(i) / float(PATH_SAMPLES), 2.0)
			end = 1.0 - pow(1.0 - float(i + 1) / float(PATH_SAMPLES), 2.0)
		var point := origin + direction * ((start + end) * 0.5 * path)
		var altitude := maxf(point.length() - radius, 0.0)
		var rayleigh := beta_rayleigh * exp(-altitude / float(settings["rayleigh_scale_height_km"]))
		var mie_density := exp(-altitude / float(settings["mie_scale_height_km"]))
		var scattering := rayleigh + beta_mie * mie_density
		var extinction := rayleigh + beta_extinction * mie_density + beta_absorption * Transport.absorption_density(altitude, settings)
		var step_length := (end - start) * path
		var scattered := transmission * scattering * Transport.view_segment_factor(extinction, step_length)
		incoming += scattered * Transport.transmittance_to_sun(point, sun, settings) / (4.0 * PI)
		feedback += scattered
		transmission *= Transport.exp_negative(extinction * step_length)
	if ground >= 0.0:
		var ground_point := origin + direction * ground
		var cosine := maxf(ground_point.normalized().dot(sun), 0.0)
		if cosine > 0.0:
			incoming += transmission * Transport.transmittance_to_sun(ground_point, sun, settings) * (settings["ground_albedo"] as Vector3) * (cosine / PI)
	return [incoming, feedback]
