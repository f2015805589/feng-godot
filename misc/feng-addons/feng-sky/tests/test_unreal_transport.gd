extends SceneTree
## Independent invariants for the UE-style transport model, not a claim of
## pixel parity with a proprietary Unreal engine build or screenshot baseline.

const Parameters = preload("res://addons/feng-sky/feng_sky_parameters.gd")
const Transport = preload("res://addons/feng-sky/feng_sky_transport.gd")
const OpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
const MultiScattering = preload("res://addons/feng-sky/feng_sky_multiscattering_lut.gd")
const Runtime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("TRANSPORT REGRESSION: " + message)


func run() -> void:
	test_density_and_phase()
	test_rgb_transmission()
	test_optical_lut()
	test_multiple_scattering()
	test_multiple_scattering_reference()
	test_art_and_quality()
	if not failed:
		print("UNREAL TRANSPORT PASS")
	quit(1 if failed else 0)


func test_density_and_phase() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({})
	for pair in [[0.0, 0.0], [10.0, 0.0], [17.5, 0.5], [25.0, 1.0], [32.5, 0.5], [40.0, 0.0], [60.0, 0.0]]:
		require(absf(Transport.absorption_density(pair[0], settings) - float(pair[1])) < 0.000001, "piecewise ozone tent differs from the 10/25/40 km reference")
	for g in [-0.99, -0.8, 0.0, 0.8, 0.99]:
		# Uniform theta quadrature resolves both narrow forward/backward lobes;
		# 2pi sin(theta) is the independently derived solid-angle Jacobian.
		var integral := 0.0
		const SAMPLES := 32768
		for i in SAMPLES:
			var theta := PI * (float(i) + 0.5) / float(SAMPLES)
			integral += Transport.mie_phase(cos(theta), g) * sin(theta) * (2.0 * PI * PI / float(SAMPLES))
		require(absf(integral - 1.0) < 0.001, "Cornette-Shanks phase is not normalized for g=" + str(g))
	require(Transport.mie_phase(1.0, 0.8) > Transport.mie_phase(-1.0, 0.8), "Mie forward direction is reversed")


func test_rgb_transmission() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({
		"atmosphere_height_km": 1.0, "mie_scale_height_km": 1000.0,
		"rayleigh_scattering_per_km": Vector3.ZERO, "mie_scattering_coefficients": Vector3.ZERO,
		"mie_extinction_coefficients": Vector3(0.1, 0.2, 0.3), "absorption_extinction_per_km": Vector3.ZERO,
		"multi_scattering_factor": 0.0,
	})
	var origin := Vector3.UP * float(settings["planet_radius_km"])
	var actual := Transport.transmittance_to_sun(origin, Vector3.UP, settings)
	var analytic_column := 1000.0 * (1.0 - exp(-1.0 / 1000.0))
	var expected := Vector3(exp(-0.1 * analytic_column), exp(-0.2 * analytic_column), exp(-0.3 * analytic_column))
	require(actual.distance_to(expected) < 0.00003, "RGB Mie absorption differs from analytic exponential-density Beer-Lambert transmission")
	require(actual.x > actual.y and actual.y > actual.z, "RGB Mie absorption collapsed to a scalar")
	require(Transport.transmittance_to_sun(origin, Vector3.DOWN, settings) == Vector3.ZERO, "sun transmission leaks through planet")
	require(Transport.transmittance_to_sun(origin + Vector3.UP, Vector3.UP, settings) == Vector3.ONE, "zero atmosphere path must transmit vacuum")
	var reference := Parameters.sanitize_atmosphere_settings({})
	var with_ozone := Transport.transmittance_to_sun(origin, Vector3.UP, reference)
	reference["absorption_extinction_per_km"] = Vector3.ZERO
	var without_ozone := Transport.transmittance_to_sun(origin, Vector3.UP, reference)
	require(with_ozone.x < without_ozone.x and with_ozone.y < without_ozone.y and with_ozone.z < without_ozone.z, "ozone must absorb all positive-coefficient bands")
	var relative_absorption := Vector3.ONE - with_ozone / without_ozone
	require(relative_absorption.y > relative_absorption.x and relative_absorption.x > relative_absorption.z, "ozone spectrum did not preserve strongest green absorption")


func sample_optical_columns(image: Image, point: Vector3, direction: Vector3, settings: Dictionary) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	var height: float = settings["atmosphere_height_km"]
	var top := radius + height
	var r := point.length()
	var b := point.dot(direction)
	var path := maxf(-b + sqrt(maxf(b * b + (top - r) * (top + r), 0.0)), 0.0)
	var rho := sqrt(maxf((r - radius) * (r + radius), 0.0))
	var horizon := sqrt(height * (2.0 * radius + height))
	var minimum := maxf(top - r, 0.0)
	var unit_path := clampf((path - minimum) / maxf(rho + horizon - minimum, 0.000001), 0.0, 1.0)
	return Transport.sample_image(image, Vector2(1.0 - sqrt(1.0 - unit_path), rho / horizon))


func test_optical_lut() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({})
	var start := Time.get_ticks_usec()
	var image := OpticalLut.make_image(settings)
	print("RGB OPTICAL LUT build_usec=", Time.get_ticks_usec() - start, " bytes=", image.get_data().size())
	require(image.get_format() == Image.FORMAT_RGBF, "optical columns must include full-precision ozone channel")
	var maximum_error := 0.0
	var worst: Array = []
	for altitude in [0.001, 1.0, 10.0, 24.9, 25.0, 25.1, 40.0, 59.9]:
		var radius: float = settings["planet_radius_km"]
		var point: Vector3 = Vector3.UP * (radius + float(altitude))
		var minimum_mu: float = -sqrt(maxf((radius + float(altitude)) * (radius + float(altitude)) - radius * radius, 0.0)) / (radius + float(altitude))
		for i in 65:
			var mu := lerpf(minimum_mu + 0.00001, 1.0, pow(float(i) / 64.0, 2.0))
			var direction := Vector3(sqrt(maxf(1.0 - mu * mu, 0.0)), mu, 0.0)
			var columns := sample_optical_columns(image, point, direction, settings)
			var actual := Transport.exp_negative(settings["rayleigh_scattering_per_km"] * columns.x + settings["mie_extinction_coefficients"] * columns.y + settings["absorption_extinction_per_km"] * columns.z)
			var expected := Transport.transmittance_to_sun(point, direction, settings)
			var difference := (actual - expected).abs()
			if difference[difference.max_axis_index()] > maximum_error:
				worst = [altitude, mu, actual, expected]
			maximum_error = maxf(maximum_error, difference[difference.max_axis_index()])
	require(maximum_error < 0.01, "RGB/ozone LUT differs from direct transport by >1% absolute transmission")
	print("RGB OPTICAL LUT maximum_absolute_error=", maximum_error, " worst=", worst)
	var original_signature := OpticalLut.geometry_signature(settings)
	settings["absorption_extinction_per_km"] = Vector3.ONE
	require(OpticalLut.geometry_signature(settings) == original_signature, "coefficient-only edit rebuilt density columns")
	settings["absorption_layer0_linear_term"] = 0.1
	require(OpticalLut.geometry_signature(settings) != original_signature, "ozone profile edit did not invalidate density columns")


func test_multiple_scattering() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({})
	var origin := Vector3.UP * (float(settings["planet_radius_km"]) + 0.001)
	var sun := Vector3(1.0, 1.0, 0.0).normalized()
	var start := Time.get_ticks_usec()
	var image := MultiScattering.make_image(settings)
	print("MULTIPLE SCATTERING LUT build_usec=", Time.get_ticks_usec() - start, " bytes=", image.get_data().size())
	var build_count: int = MultiScattering._build_count
	var view := Vector3.UP
	var single := Transport.integrate_ray(origin, view, sun, settings)
	var multiple := Transport.integrate_ray(origin, view, sun, settings, image)
	require(multiple.x > single.x and multiple.y > single.y and multiple.z > single.z, "multiple scattering did not contribute to sky radiance")
	var signature := MultiScattering.signature(settings)
	settings["multi_scattering_factor"] = 2.0
	settings["sky_luminance_factor"] = Vector3.ONE * 3.0
	settings["trace_sample_count_scale"] = 2.0
	require(MultiScattering.signature(settings) == signature, "artist factor or view quality rebuilt physical MS LUT")
	var second_image := MultiScattering.make_image(settings)
	require(MultiScattering._build_count == build_count, "equivalent MS settings rebuilt cached bytes")
	image.set_pixel(0, 0, Color(10.0, 10.0, 10.0))
	require(second_image.get_pixel(0, 0) != image.get_pixel(0, 0), "separate worlds share a mutable MS image")
	settings = Parameters.sanitize_atmosphere_settings({"ground_albedo": Vector3.ZERO})
	var black_ground := MultiScattering.make_image(settings)
	var black_radiance := MultiScattering.sample(black_ground, origin, sun, settings)
	settings["ground_albedo"] = Vector3.ONE
	var white_ground := MultiScattering.make_image(settings)
	var white_radiance := MultiScattering.sample(white_ground, origin, sun, settings)
	require(white_radiance.x > black_radiance.x and white_radiance.y > black_radiance.y and white_radiance.z > black_radiance.z, "ground albedo did not enter the multiple-scattering illumination")
	settings["multi_scattering_factor"] = 0.0
	var without_bounce := Transport.integrate_ray(origin, view, sun, settings, white_ground)
	settings["ground_albedo"] = Vector3.ZERO
	require(Transport.integrate_ray(origin, view, sun, settings, black_ground) == without_bounce, "ground albedo affects sky with multiple scattering disabled")
	for point in [Vector3.UP * 6360.001, Vector3.UP * 6370.0, Vector3.UP * 6419.999]:
		for direction in [Vector3.UP, Vector3.RIGHT, Vector3.DOWN]:
			require(MultiScattering.sample(white_ground, point, direction, settings).is_finite(), "MS LUT produced a non-finite boundary sample")
	var extreme := Parameters.sanitize_atmosphere_settings({"rayleigh_scattering_per_km": Vector3.ONE * 100.0, "mie_scattering_coefficients": Vector3.ONE * 100.0, "mie_extinction_coefficients": Vector3.ONE * 100.0, "ground_albedo": Vector3.ONE})
	var extreme_image := MultiScattering.make_image(extreme)
	for y in extreme_image.get_height():
		for x in extreme_image.get_width():
			var pixel := extreme_image.get_pixel(x, y)
			require(is_finite(pixel.r) and is_finite(pixel.g) and is_finite(pixel.b) and pixel.r >= 0.0 and pixel.g >= 0.0 and pixel.b >= 0.0, "extreme conservative medium escaped finite nonnegative MS range")
	var vacuum := Parameters.sanitize_atmosphere_settings({"rayleigh_scattering_per_km": Vector3.ZERO, "mie_scattering_coefficients": Vector3.ZERO, "mie_extinction_coefficients": Vector3.ZERO, "absorption_extinction_per_km": Vector3.ZERO, "ground_albedo": Vector3.ONE})
	var vacuum_image := MultiScattering.make_image(vacuum)
	require(MultiScattering.sample(vacuum_image, origin, sun, vacuum) == Vector3.ZERO, "empty atmosphere creates multiple scattering from ground alone")
	require(Transport.integrate_ray(origin, view, sun, vacuum, vacuum_image) == Vector3.ZERO, "empty atmosphere scatters light")
	print("MULTIPLE SCATTERING single=", single, " multiple=", multiple, " black_ground=", black_radiance, " white_ground=", white_radiance)


func reference_transmission(point: Vector3, sun: Vector3, settings: Dictionary) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	var r := point.length()
	var b := point.dot(sun)
	if b < 0.0 and b * b >= (r - radius) * (r + radius):
		return Vector3.ZERO
	var top := radius + float(settings["atmosphere_height_km"])
	var path := maxf(-b + sqrt(maxf(b * b + (top - r) * (top + r), 0.0)), 0.0)
	var optical_depth := Vector3.ZERO
	const STEPS := 32
	for i in STEPS:
		var start := pow(float(i) / float(STEPS), 2.0)
		var end := pow(float(i + 1) / float(STEPS), 2.0)
		var altitude := maxf((point + sun * ((start + end) * 0.5 * path)).length() - radius, 0.0)
		var rayleigh: Vector3 = settings["rayleigh_scattering_per_km"] * exp(-altitude / float(settings["rayleigh_scale_height_km"]))
		var mie: Vector3 = settings["mie_extinction_coefficients"] * exp(-altitude / float(settings["mie_scale_height_km"]))
		var ozone_density := clampf((altitude - 10.0) / 15.0, 0.0, 1.0) if altitude < 25.0 else clampf((40.0 - altitude) / 15.0, 0.0, 1.0)
		optical_depth += (rayleigh + mie + settings["absorption_extinction_per_km"] * ozone_density) * ((end - start) * path)
	return Vector3(exp(-optical_depth.x), exp(-optical_depth.y), exp(-optical_depth.z))


func reference_multiple_scattering(origin: Vector3, sun: Vector3, settings: Dictionary) -> Vector3:
	# Independent high-budget implementation of the isotropic closure equations,
	# with 64 directions, 64 view steps and 32 sun steps, no LUT sampling.
	const DIRECTIONS := 64
	const STEPS := 64
	var radius: float = settings["planet_radius_km"]
	var top := radius + float(settings["atmosphere_height_km"])
	var incoming := Vector3.ZERO
	var feedback := Vector3.ZERO
	for direction_index in DIRECTIONS:
		var mu := 1.0 - 2.0 * (float(direction_index) + 0.5) / float(DIRECTIONS)
		var phi := TAU * fposmod(float(direction_index) * 0.6180339887498949, 1.0)
		var direction := Vector3(sqrt(1.0 - mu * mu) * cos(phi), mu, sqrt(1.0 - mu * mu) * sin(phi))
		var r := origin.length()
		var b := origin.dot(direction)
		var path := maxf(-b + sqrt(maxf(b * b + (top - r) * (top + r), 0.0)), 0.0)
		var ground_discriminant := b * b - (r - radius) * (r + radius)
		var ground := -b - sqrt(ground_discriminant) if b < 0.0 and ground_discriminant >= 0.0 else -1.0
		if ground >= 0.0:
			path = minf(path, ground)
		var transmission := Vector3.ONE
		for i in STEPS:
			var start := pow(float(i) / float(STEPS), 2.0)
			var end := pow(float(i + 1) / float(STEPS), 2.0)
			if mu < 0.0:
				start = 1.0 - pow(1.0 - float(i) / float(STEPS), 2.0)
				end = 1.0 - pow(1.0 - float(i + 1) / float(STEPS), 2.0)
			var point := origin + direction * ((start + end) * 0.5 * path)
			var altitude := maxf(point.length() - radius, 0.0)
			var rayleigh: Vector3 = settings["rayleigh_scattering_per_km"] * exp(-altitude / float(settings["rayleigh_scale_height_km"]))
			var mie_density := exp(-altitude / float(settings["mie_scale_height_km"]))
			var scattering: Vector3 = rayleigh + settings["mie_scattering_coefficients"] * mie_density
			var ozone_density := clampf((altitude - 10.0) / 15.0, 0.0, 1.0) if altitude < 25.0 else clampf((40.0 - altitude) / 15.0, 0.0, 1.0)
			var extinction: Vector3 = rayleigh + settings["mie_extinction_coefficients"] * mie_density + settings["absorption_extinction_per_km"] * ozone_density
			var dt := (end - start) * path
			var segment := Vector3(exp(-extinction.x * dt), exp(-extinction.y * dt), exp(-extinction.z * dt))
			var integrated := Vector3.ONE * dt
			for channel in 3:
				if extinction[channel] > 0.0000001:
					integrated[channel] = (1.0 - segment[channel]) / extinction[channel]
			var scattered := transmission * scattering * integrated
			incoming += scattered * reference_transmission(point, sun, settings) / (4.0 * PI * float(DIRECTIONS))
			feedback += scattered / float(DIRECTIONS)
			transmission *= segment
		if ground >= 0.0:
			var ground_point := origin + direction * ground
			incoming += transmission * reference_transmission(ground_point, sun, settings) * (settings["ground_albedo"] as Vector3) * (maxf(ground_point.normalized().dot(sun), 0.0) / (PI * float(DIRECTIONS)))
	return incoming / (Vector3.ONE - feedback.clamp(Vector3.ZERO, Vector3.ONE * 0.95))


func test_multiple_scattering_reference() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({})
	var image := MultiScattering.make_image(settings)
	var squared_error := 0.0
	var squared_reference := 0.0
	var maximum_relative := 0.0
	var maximum_absolute := 0.0
	for altitude in [0.001, 10.0, 30.0]:
		for sun_cosine in [-0.1, -0.02, 0.02, 0.1, 0.7]:
			var origin := Vector3.UP * (6360.0 + float(altitude))
			var sun := Vector3(sqrt(1.0 - float(sun_cosine) * float(sun_cosine)), sun_cosine, 0.0)
			var actual := MultiScattering.sample(image, origin, sun, settings)
			var expected := reference_multiple_scattering(origin, sun, settings)
			var difference := (actual - expected).abs()
			maximum_absolute = maxf(maximum_absolute, difference[difference.max_axis_index()])
			maximum_relative = maxf(maximum_relative, difference.length() / maxf(expected.length(), 0.00001))
			squared_error += difference.length_squared()
			squared_reference += expected.length_squared()
	var normalized_rms := sqrt(squared_error / squared_reference)
	print("MULTIPLE SCATTERING REFERENCE normalized_rms=", normalized_rms, " max_relative=", maximum_relative, " max_absolute=", maximum_absolute)
	# This is a measured numerical quality gate against the same isotropic
	# model, not an Unreal image baseline or a full path-traced atmosphere.
	require(normalized_rms < 0.08 and maximum_absolute < 0.005, "bounded MS approximation drifted beyond its reference quality budget")


func test_art_and_quality() -> void:
	var settings := Parameters.sanitize_atmosphere_settings({"multi_scattering_factor": 0.0})
	require(Transport.view_sample_count(settings) == 8, "default trace budget changed")
	settings["trace_sample_count_scale"] = 4.0
	require(Transport.view_sample_count(settings) == 32, "quality scale does not control actual sample count")
	var below_sun := Vector3(1.0, -0.1, 0.0).normalized()
	var without_clamp := Transport.ground_sun_transmittance(Vector3.UP, below_sun, settings)
	require(without_clamp == Vector3.ZERO, "unclamped below-horizon light transmitted through the planet")
	settings["minimum_light_elevation_deg"] = 10.0
	var clamped := Transport.ground_sun_transmittance(Vector3.UP, below_sun, settings)
	var floor_sun := Vector3(cos(deg_to_rad(10.0)), sin(deg_to_rad(10.0)), 0.0)
	var floor_result := Transport.transmittance_to_sun(Vector3.UP * float(settings["planet_radius_km"]), floor_sun, settings)
	require(clamped.distance_to(floor_result) < 0.000001, "minimum elevation does not clamp direct-light transmittance")
	var first := Runtime.compute_atmosphere_sample(settings, Vector3.UP, 1.0, Vector3.ONE)
	settings["sky_luminance_factor"] = Vector3(2.0, 3.0, 4.0)
	settings["sky_only_luminance_factor"] = Vector3.ONE * 2.0
	var second := Runtime.compute_atmosphere_sample(settings, Vector3.UP, 1.0, Vector3.ONE)
	require((second["ambient_unit_sun"] as Vector3).distance_to((first["ambient_unit_sun"] as Vector3) * Vector3(4.0, 6.0, 8.0)) < 0.000001, "sky artist gains did not reach the captured sky ambient")
	require(second["ground_transmittance"] == first["ground_transmittance"], "sky artist gain changed physical direct transmittance")
