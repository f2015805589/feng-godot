@tool
extends RefCounted
## Pure spherical atmosphere transport. Inputs are normalized by FengSkyParameters.
## Distances are kilometres; RGB scattering/extinction are inverse kilometres.
## The density and isotropic multiple-scattering closure follow Hillaire (2020):
## https://github.com/sebh/UnrealEngineSkyAtmosphere
## This bounded implementation is not a pixel-identical Unreal renderer.

const VIEW_SAMPLES := 8
const SUN_SAMPLES := 6
const MAX_VIEW_SAMPLES := 64


static func absorption_density(altitude: float, settings: Dictionary) -> float:
	if altitude < float(settings["absorption_density_layer_width_km"]):
		return clampf(float(settings["absorption_layer0_linear_term"]) * altitude + float(settings["absorption_layer0_constant_term"]), 0.0, 1.0)
	return clampf(float(settings["absorption_layer1_linear_term"]) * altitude + float(settings["absorption_layer1_constant_term"]), 0.0, 1.0)


static func view_sample_count(settings: Dictionary) -> int:
	return clampi(roundi(float(VIEW_SAMPLES) * float(settings["trace_sample_count_scale"])), 2, MAX_VIEW_SAMPLES)


static func mie_phase(cosine_angle: float, g: float) -> float:
	# Cornette-Shanks, with directions both pointing away from the sample point.
	var denominator := maxf(1.0 + g * g - 2.0 * g * cosine_angle, 0.0001)
	return 3.0 * (1.0 - g * g) * (1.0 + cosine_angle * cosine_angle) / (8.0 * PI * (2.0 + g * g) * pow(denominator, 1.5))


static func transmittance_to_sun(point: Vector3, sun_direction: Vector3, settings: Dictionary) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	if ray_hits_ground(point, sun_direction, radius):
		return Vector3.ZERO
	var top_radius := radius + float(settings["atmosphere_height_km"])
	var path_length := sphere_exit_distance(point, sun_direction, top_radius)
	if path_length <= 0.0:
		return Vector3.ONE
	var columns := Vector3.ZERO
	for sample_index in SUN_SAMPLES:
		var sample_start := pow(float(sample_index) / float(SUN_SAMPLES), 2.0)
		var sample_end := pow(float(sample_index + 1) / float(SUN_SAMPLES), 2.0)
		var step_length := (sample_end - sample_start) * path_length
		var point_on_ray := point + sun_direction * ((sample_start + sample_end) * 0.5 * path_length)
		var altitude := maxf(point_on_ray.length() - radius, 0.0)
		columns += Vector3(exp(-altitude / float(settings["rayleigh_scale_height_km"])), exp(-altitude / float(settings["mie_scale_height_km"])), absorption_density(altitude, settings)) * step_length
	return exp_negative(settings["rayleigh_scattering_per_km"] * columns.x + settings["mie_extinction_coefficients"] * columns.y + settings["absorption_extinction_per_km"] * columns.z)


static func ground_sun_transmittance(up: Vector3, sun_direction: Vector3, settings: Dictionary) -> Vector3:
	# The minimum elevation is an artistic direct-light transmittance control.
	# It must not move the visual sun, change the sky or illuminate the night sky.
	var minimum_cosine := sin(deg_to_rad(float(settings["minimum_light_elevation_deg"])))
	var cosine_elevation := up.dot(sun_direction)
	var lighting_direction := sun_direction
	if cosine_elevation < minimum_cosine:
		var tangent := sun_direction - up * cosine_elevation
		if tangent.length_squared() < 0.000001:
			tangent = Vector3.RIGHT - up * up.dot(Vector3.RIGHT)
			if tangent.length_squared() < 0.000001:
				tangent = Vector3.FORWARD - up * up.dot(Vector3.FORWARD)
		lighting_direction = up * minimum_cosine + tangent.normalized() * sqrt(maxf(1.0 - minimum_cosine * minimum_cosine, 0.0))
	if up.dot(lighting_direction) < 0.0:
		return Vector3.ZERO
	return transmittance_to_sun(up * float(settings["planet_radius_km"]), lighting_direction, settings)


static func integrate_ray(origin: Vector3, view_direction: Vector3, sun_direction: Vector3, settings: Dictionary, multi_scattering_image: Image = null) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	var top_radius := radius + float(settings["atmosphere_height_km"])
	var ray_origin := origin
	var path := sphere_exit_distance(origin, view_direction, top_radius)
	if origin.length() > top_radius:
		var b := origin.dot(view_direction)
		var discriminant := b * b - (origin.length_squared() - top_radius * top_radius)
		if discriminant < 0.0 or -b + sqrt(discriminant) <= 0.0:
			return Vector3.ZERO
		var entry := maxf(-b - sqrt(discriminant), 0.0)
		ray_origin += view_direction * entry
		path -= entry
	if path <= 0.0:
		return Vector3.ZERO
	var ground := ground_distance(ray_origin, view_direction, radius)
	if ground >= 0.0:
		path = minf(path, ground)
	var cosine := clampf(view_direction.dot(sun_direction), -1.0, 1.0)
	var rayleigh_phase := 3.0 * (1.0 + cosine * cosine) / (16.0 * PI)
	var aerosol_phase := mie_phase(cosine, settings["mie_asymmetry"])
	var beta_rayleigh: Vector3 = settings["rayleigh_scattering_per_km"]
	var beta_mie_scatter: Vector3 = settings["mie_scattering_coefficients"]
	var beta_mie_extinction: Vector3 = settings["mie_extinction_coefficients"]
	var beta_absorption: Vector3 = settings["absorption_extinction_per_km"]
	var samples := view_sample_count(settings)
	var radial_dot := ray_origin.dot(view_direction)
	var transmission := Vector3.ONE
	var radiance := Vector3.ZERO
	for i in samples:
		var start := pow(float(i) / float(samples), 2.0)
		var end := pow(float(i + 1) / float(samples), 2.0)
		if radial_dot < 0.0:
			start = 1.0 - pow(1.0 - float(i) / float(samples), 2.0)
			end = 1.0 - pow(1.0 - float(i + 1) / float(samples), 2.0)
		var point := ray_origin + view_direction * ((start + end) * 0.5 * path)
		var step_length := (end - start) * path
		var altitude := maxf(point.length() - radius, 0.0)
		var rayleigh := beta_rayleigh * exp(-altitude / float(settings["rayleigh_scale_height_km"]))
		var mie_density := exp(-altitude / float(settings["mie_scale_height_km"]))
		var mie := beta_mie_scatter * mie_density
		var extinction := rayleigh + beta_mie_extinction * mie_density + beta_absorption * absorption_density(altitude, settings)
		var source := (rayleigh * rayleigh_phase + mie * aerosol_phase) * transmittance_to_sun(point, sun_direction, settings)
		if multi_scattering_image != null and float(settings["multi_scattering_factor"]) > 0.0:
			source += (rayleigh + mie) * sample_multiple_scattering(multi_scattering_image, point, sun_direction, settings) * float(settings["multi_scattering_factor"])
		radiance += transmission * source * view_segment_factor(extinction, step_length)
		transmission *= exp_negative(extinction * step_length)
	# The virtual planet is an occluder. Its albedo belongs only to the indirect
	# illumination calculation, not an artificial visible lower-hemisphere fill.
	return radiance.max(Vector3.ZERO)


static func sample_multiple_scattering(image: Image, point: Vector3, sun_direction: Vector3, settings: Dictionary) -> Vector3:
	var altitude := maxf(point.length() - float(settings["planet_radius_km"]), 0.0)
	var sun_cosine := clampf(point.normalized().dot(sun_direction), -1.0, 1.0)
	var solar_coordinate := signf(sun_cosine) * sqrt(absf(sun_cosine))
	var uv := Vector2(solar_coordinate * 0.5 + 0.5, sqrt(clampf(altitude / float(settings["atmosphere_height_km"]), 0.0, 1.0)))
	return sample_image(image, uv)


static func sample_image(image: Image, uv: Vector2) -> Vector3:
	var xy := uv.clamp(Vector2.ZERO, Vector2.ONE) * Vector2(image.get_width() - 1, image.get_height() - 1)
	var x := floori(xy.x)
	var y := floori(xy.y)
	var nx := mini(x + 1, image.get_width() - 1)
	var ny := mini(y + 1, image.get_height() - 1)
	var lower := image.get_pixel(x, y).lerp(image.get_pixel(nx, y), xy.x - float(x))
	var upper := image.get_pixel(x, ny).lerp(image.get_pixel(nx, ny), xy.x - float(x))
	var color := lower.lerp(upper, xy.y - float(y))
	return Vector3(color.r, color.g, color.b)


static func ray_hits_ground(point: Vector3, direction: Vector3, radius: float) -> bool:
	var b := point.dot(direction)
	return b < 0.0 and b * b - (point.length() - radius) * (point.length() + radius) >= 0.0


static func ground_distance(origin: Vector3, direction: Vector3, radius: float) -> float:
	var b := origin.dot(direction)
	var discriminant := b * b - (origin.length() - radius) * (origin.length() + radius)
	if discriminant < 0.0:
		return -1.0
	var distance := -b - sqrt(discriminant)
	return distance if distance >= 0.0 else -1.0


static func sphere_exit_distance(origin: Vector3, direction: Vector3, radius: float) -> float:
	var b := origin.dot(direction)
	var discriminant := b * b - (origin.length() - radius) * (origin.length() + radius)
	if discriminant < 0.0:
		return -1.0
	return maxf(-b + sqrt(discriminant), 0.0)


static func exp_negative(value: Vector3) -> Vector3:
	return Vector3(exp(-value.x), exp(-value.y), exp(-value.z))


static func view_segment_factor(extinction: Vector3, step_length: float) -> Vector3:
	var segment_transmittance := exp_negative(extinction * step_length)
	var factor := Vector3.ONE * step_length
	for channel in 3:
		if extinction[channel] > 0.0000001:
			factor[channel] = (1.0 - segment_transmittance[channel]) / extinction[channel]
	return factor
