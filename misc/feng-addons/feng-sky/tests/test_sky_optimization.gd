extends SceneTree

const Atmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const Runtime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const OpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("REGRESSION: " + message)


func sample_columns(image: Image, point: Vector3, direction: Vector3, settings: Dictionary) -> Vector2:
	var radius: float = settings["planet_radius_km"]
	var height: float = settings["atmosphere_height_km"]
	var top := radius + height
	var r := point.length()
	var r_mu := point.dot(direction)
	var path := maxf(-r_mu + sqrt(maxf(r_mu * r_mu + (top - r) * (top + r), 0.0)), 0.0)
	var rho := sqrt(maxf((r - radius) * (r + radius), 0.0))
	var horizon := sqrt(height * (2.0 * radius + height))
	var minimum := maxf(top - r, 0.0)
	var uv := Vector2((path - minimum) / maxf(rho + horizon - minimum, 0.000001), rho / horizon).clamp(Vector2.ZERO, Vector2.ONE)
	uv.x = 1.0 - sqrt(1.0 - uv.x)
	var xy := uv * Vector2(image.get_width() - 1, image.get_height() - 1)
	var x := floori(xy.x)
	var y := floori(xy.y)
	var next_x := mini(x + 1, image.get_width() - 1)
	var next_y := mini(y + 1, image.get_height() - 1)
	var lower := image.get_pixel(x, y).lerp(image.get_pixel(next_x, y), xy.x - float(x))
	var upper := image.get_pixel(x, next_y).lerp(image.get_pixel(next_x, next_y), xy.x - float(x))
	var result := lower.lerp(upper, xy.y - float(y))
	return Vector2(result.r, result.g)


func lut_transmittance(image: Image, point: Vector3, direction: Vector3, settings: Dictionary) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	if Runtime._ray_hits_ground(point, direction, radius):
		return Vector3.ZERO
	if not OpticalLut.supports_settings(settings):
		if Runtime._sphere_exit_distance(point, direction, radius + float(settings["atmosphere_height_km"])) <= 0.0:
			return Vector3.ONE
		return Runtime._transmittance_to_sun(point, direction, radius, radius + float(settings["atmosphere_height_km"]),
			settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
			settings["rayleigh_scattering_per_km"], settings["mie_extinction_per_km"])
	var columns := sample_columns(image, point, direction, settings)
	var depth: Vector3 = settings["rayleigh_scattering_per_km"] * columns.x + Vector3.ONE * float(settings["mie_extinction_per_km"]) * columns.y
	return Runtime._exp_negative(depth)


func test_lut() -> void:
	var configurations := [
		{},
		{"rayleigh_scattering_per_km": Vector3.ZERO, "mie_scattering_per_km": 0.0, "mie_extinction_per_km": 0.0},
		{"rayleigh_scattering_per_km": Vector3.ONE, "mie_scattering_per_km": 1.0, "mie_extinction_per_km": 1.0},
		{"atmosphere_height_km": 64.0, "rayleigh_scale_height_km": 1.0, "mie_scale_height_km": 1.0},
		{"atmosphere_height_km": 64.0, "rayleigh_scale_height_km": 1.0, "mie_scale_height_km": 1.0,
			"rayleigh_scattering_per_km": Vector3.ONE, "mie_scattering_per_km": 1.0, "mie_extinction_per_km": 1.0},
		{"planet_radius_km": 7000.0, "atmosphere_height_km": 1.0, "rayleigh_scale_height_km": 30.0, "mie_scale_height_km": 0.1},
		{"planet_radius_km": 6000.0, "atmosphere_height_km": 120.0, "rayleigh_scale_height_km": 1.0, "mie_scale_height_km": 0.1},
		{"planet_radius_km": 7000.0, "atmosphere_height_km": 120.0, "rayleigh_scale_height_km": 30.0, "mie_scale_height_km": 10.0},
	]
	var maximum_error := 0.0
	var comparisons := 0
	for configuration in configurations:
		var settings := Runtime.sanitize_atmosphere_settings(configuration)
		var start := Time.get_ticks_usec()
		var image: Image = OpticalLut.make_image(settings) if OpticalLut.supports_settings(settings) else null
		var elapsed := Time.get_ticks_usec() - start
		if image == null:
			print("OPTICAL LUT exact fallback settings=", OpticalLut.geometry_signature(settings))
		else:
			require(image.get_format() == Image.FORMAT_RGF, "LUT must keep full precision optical columns")
			print("OPTICAL LUT build_usec=", elapsed, " bytes=", image.get_data().size(), " settings=", OpticalLut.geometry_signature(settings))
		var radius: float = settings["planet_radius_km"]
		var height: float = settings["atmosphere_height_km"]
		var config_max := 0.0
		var worst: Array = []
		# Quadratic altitude concentrates tests at sea level; explicit endpoints
		# exercise 1 m cameras, ground, top-of-atmosphere and grazing sun rays.
		var altitudes := [0.0, 0.001, 0.01, 0.1, height]
		for i in 25:
			altitudes.append(height * pow(float(i) / 24.0, 2.0))
		for altitude in altitudes:
			var r := radius + float(altitude)
			var minimum_mu := -sqrt(maxf((r - radius) * (r + radius), 0.0)) / r
			for i in 65:
				var mu := lerpf(minimum_mu, 1.0, pow(float(i) / 64.0, 2.0))
				var direction := Vector3(sqrt(maxf(1.0 - mu * mu, 0.0)), mu, 0.0).normalized()
				var point := Vector3(0.0, r, 0.0)
				var reference := Runtime._transmittance_to_sun(point, direction, radius, radius + height,
					settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
					settings["rayleigh_scattering_per_km"], settings["mie_extinction_per_km"])
				var actual := lut_transmittance(image, point, direction, settings)
				# An outward ray exactly on the atmosphere boundary traverses vacuum.
				# The old helper returns zero for that zero-length path; the LUT fixes it.
				if Runtime._sphere_exit_distance(point, direction, radius + height) <= 0.0 and not Runtime._ray_hits_ground(point, direction, radius):
					reference = Vector3.ONE
				var error := (actual - reference).abs().max_axis_index()
				var absolute_error := (actual - reference).abs()[error]
				if absolute_error > config_max:
					worst = [altitude, mu, actual, reference]
				config_max = maxf(config_max, absolute_error)
				require(actual.is_finite() and actual.min(Vector3.ZERO) == Vector3.ZERO and actual.max(Vector3.ONE) == Vector3.ONE,
					"LUT transmittance escaped [0,1]")
				comparisons += 1
		var night := lut_transmittance(image, Vector3(0.0, radius + 0.001, 0.0), Vector3.DOWN, settings)
		require(night == Vector3.ZERO, "LUT leaked through the planet at night")
		maximum_error = maxf(maximum_error, config_max)
		print("OPTICAL LUT max_rgb_absolute_error=", config_max, " worst=", worst)
	print("OPTICAL LUT comparisons=", comparisons, " max_rgb_absolute_error=", maximum_error)
	require(maximum_error < 0.01, "optical LUT differs from direct sun integration by more than 1% absolute transmission")


func integrate_view(image: Image, settings: Dictionary, origin: Vector3, view: Vector3, sun: Vector3, use_lut: bool) -> Vector3:
	var radius: float = settings["planet_radius_km"]
	var top := radius + float(settings["atmosphere_height_km"])
	var ray_origin := origin
	var path := Runtime._sphere_exit_distance(origin, view, top)
	if origin.length() > top:
		var b := origin.dot(view)
		var discriminant := b * b - (origin.length_squared() - top * top)
		if discriminant < 0.0 or -b + sqrt(discriminant) <= 0.0:
			return Vector3.ZERO
		var entry := maxf(-b - sqrt(discriminant), 0.0)
		ray_origin += view * entry
		path -= entry
	if path <= 0.0:
		return Vector3.ZERO
	var b := ray_origin.dot(view)
	var discriminant := b * b - (ray_origin.length_squared() - radius * radius)
	var ground := -1.0
	if discriminant >= 0.0:
		var near_ground := -b - sqrt(discriminant)
		if near_ground >= 0.0 and near_ground < path:
			ground = near_ground
			path = near_ground
	var cosine := clampf(view.dot(sun), -1.0, 1.0)
	var rayleigh_phase := 3.0 * (1.0 + cosine * cosine) / (16.0 * PI)
	var g: float = settings["mie_asymmetry"]
	var mie_phase := (1.0 - g * g) / (4.0 * PI * pow(maxf(1.0 + g * g - 2.0 * g * cosine, 0.0001), 1.5))
	var beta: Vector3 = settings["rayleigh_scattering_per_km"]
	var radiance := Vector3.ZERO
	var transmission := Vector3.ONE
	for i in Runtime.VIEW_SAMPLES:
		var start := pow(float(i) / Runtime.VIEW_SAMPLES, 2.0)
		var end := pow(float(i + 1) / Runtime.VIEW_SAMPLES, 2.0)
		if ray_origin.dot(view) < 0.0:
			start = 1.0 - pow(1.0 - float(i) / Runtime.VIEW_SAMPLES, 2.0)
			end = 1.0 - pow(1.0 - float(i + 1) / Runtime.VIEW_SAMPLES, 2.0)
		var point := ray_origin + view * ((start + end) * 0.5 * path)
		var segment := (end - start) * path
		var altitude := maxf(point.length() - radius, 0.0)
		var rayleigh_density := exp(-altitude / float(settings["rayleigh_scale_height_km"]))
		var mie_density := exp(-altitude / float(settings["mie_scale_height_km"]))
		var sun_trans: Vector3
		if use_lut:
			sun_trans = lut_transmittance(image, point, sun, settings)
		else:
			sun_trans = Runtime._transmittance_to_sun(point, sun, radius, top,
				settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"], beta, settings["mie_extinction_per_km"])
		var source := beta * (rayleigh_density * rayleigh_phase) + Vector3.ONE * (float(settings["mie_scattering_per_km"]) * mie_density * mie_phase)
		var extinction := beta * rayleigh_density + Vector3.ONE * (float(settings["mie_extinction_per_km"]) * mie_density)
		radiance += transmission * sun_trans * source * Runtime._view_segment_factor(extinction, segment)
		transmission *= Runtime._exp_negative(extinction * segment)
	if ground >= 0.0:
		var point := ray_origin + view * ground
		var ground_trans: Vector3
		if use_lut:
			ground_trans = lut_transmittance(image, point, sun, settings)
		else:
			ground_trans = Runtime._transmittance_to_sun(point, sun, radius, top,
				settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"], beta, settings["mie_extinction_per_km"])
		radiance += transmission * (settings["ground_albedo"] as Vector3) * ground_trans * maxf(point.normalized().dot(sun), 0.0) / PI
	return radiance


func test_view_equivalence() -> void:
	var settings := Runtime.sanitize_atmosphere_settings({})
	var image := OpticalLut.make_image(settings)
	var maximum_relative := 0.0
	var maximum_absolute := 0.0
	var comparisons := 0
	var squared_error := 0.0
	var squared_reference := 0.0
	for altitude in [0.001, 1.0, 10.0, 59.9, 60.0, 80.0]:
		var origin := Vector3(0.0, 6360.0 + altitude, 0.0)
		for sun_elevation in [-30.0, -5.0, -1.0, 0.0, 1.0, 5.0, 20.0, 80.0]:
			var sun_angle := deg_to_rad(sun_elevation)
			var sun := Vector3(cos(sun_angle), sin(sun_angle), 0.0)
			for view_elevation in [-89.0, -45.0, -1.0, -0.01, 0.0, 0.01, 1.0, 5.0, 15.0, 45.0, 89.0]:
				var view_angle := deg_to_rad(view_elevation)
				for azimuth in [0.0, PI * 0.5, PI]:
					var view := Vector3(cos(view_angle) * cos(azimuth), sin(view_angle), cos(view_angle) * sin(azimuth))
					var reference := integrate_view(image, settings, origin, view, sun, false)
					var actual := integrate_view(image, settings, origin, view, sun, true)
					var error := actual.distance_to(reference)
					maximum_absolute = maxf(maximum_absolute, error)
					if reference.length() > 0.00001:
						maximum_relative = maxf(maximum_relative, error / reference.length())
					squared_error += error * error
					squared_reference += reference.length_squared()
					require(actual.is_finite(), "view integration produced nonfinite radiance")
					comparisons += 1
	print("SKY VIEW comparisons=", comparisons, " max_relative=", maximum_relative,
		" max_absolute_unit_sun=", maximum_absolute, " normalized_rmse=", sqrt(squared_error / squared_reference))
	require(maximum_relative < 0.01, "integrated LUT sky/ground differs from direct reference by over 1%")


func test_dirty_updates() -> void:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	var sky := Atmosphere.new()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	sky.sun_light = sun
	viewport.add_child(sun)
	viewport.add_child(sky)
	await process_frame
	var before: Dictionary = sky.atmosphere_cache_stats()
	var start := Time.get_ticks_usec()
	for i in 1000:
		sky._process(0.016)
	var elapsed := Time.get_ticks_usec() - start
	var after: Dictionary = sky.atmosphere_cache_stats()
	for counter in ["settings_sanitizations", "shader_identity_checks", "optical_lut_updates", "snapshot_publications", "material_updates", "cache_misses"]:
		require(before[counter] == after[counter], "stable update repeated " + counter)
	print("ATMOSPHERE STABLE 1000_updates_usec=", elapsed, " counters=", after)
	var material := sky.sky.sky_material as ShaderMaterial
	var initial_lut: Texture2D = material.get_shader_parameter("optical_column_lut")
	sun.rotation_degrees.x -= 1.0
	sky._process(0.016)
	require(sky.atmosphere_cache_stats()["material_updates"] == after["material_updates"] + 1, "sun change missed material update")
	require(material.get_shader_parameter("optical_column_lut") == initial_lut, "sun rotation rebuilt optical columns")
	sky.mie_asymmetry = 0.5
	sky._process(0.016)
	require(material.get_shader_parameter("optical_column_lut") == initial_lut, "phase-only change rebuilt optical columns")
	sky.rayleigh_scattering_per_km *= 1.1
	sky._process(0.016)
	require(material.get_shader_parameter("optical_column_lut") == initial_lut, "coefficient-only change rebuilt optical columns")
	sky.rayleigh_scale_height_km += 1.0
	sky._process(0.016)
	require(material.get_shader_parameter("optical_column_lut") != initial_lut, "density change failed to rebuild optical columns")
	var snapshot := Runtime.snapshot_for_world(viewport.world_3d.get_instance_id())
	snapshot["ambient_radiance"] = Vector3(-10.0, -10.0, -10.0)
	require((Runtime.snapshot_for_world(viewport.world_3d.get_instance_id())["ambient_radiance"] as Vector3).x >= 0.0, "returned snapshot changed cached publication")
	var world := viewport.world_3d
	var previous_environment := world.environment
	world.environment = Environment.new()
	require(Runtime.snapshot_for_world(world.get_instance_id()).is_empty(), "same-frame environment handoff kept snapshot")
	world.environment = previous_environment
	sky._process(0.016)
	require(not Runtime.snapshot_for_world(world.get_instance_id()).is_empty(), "same-frame environment handback failed to republish")
	var source_code := material.shader.code
	material.shader.code += "\n// edited atmosphere\n"
	require(Runtime.snapshot_for_world(viewport.world_3d.get_instance_id()).is_empty(), "nested shader edit kept stale snapshot")
	material.shader.code = source_code
	sky._process(0.016)
	require(not Runtime.snapshot_for_world(viewport.world_3d.get_instance_id()).is_empty(), "restored shader failed to republish")
	var shared_source := Runtime.atmosphere_shader()
	var shared_code := shared_source.code
	shared_source.code += "\n// reference hot reload\n"
	require(Runtime.snapshot_for_world(viewport.world_3d.get_instance_id()).is_empty(), "reference shader hot reload kept stale identity")
	shared_source.code = shared_code
	sky._process(0.016)
	require(not Runtime.snapshot_for_world(viewport.world_3d.get_instance_id()).is_empty(), "restored reference shader failed to republish")
	var other_viewport := SubViewport.new()
	other_viewport.world_3d = World3D.new()
	root.add_child(other_viewport)
	var other := Atmosphere.new()
	other.rayleigh_scale_height_km = sky.rayleigh_scale_height_km
	other_viewport.add_child(other)
	await process_frame
	var other_material := other.sky.sky_material as ShaderMaterial
	var other_lut: Texture2D = other_material.get_shader_parameter("optical_column_lut")
	require(other_lut != material.get_shader_parameter("optical_column_lut"), "independent worlds share mutable LUT textures")
	var other_bytes := other_lut.get_image().get_data()
	sky.mie_scale_height_km += 0.2
	sky._process(0.016)
	require(other_lut.get_image().get_data() == other_bytes, "changing one atmosphere mutated another world's LUT")
	viewport.free()
	other_viewport.free()


func run() -> void:
	test_lut()
	test_view_equivalence()
	await test_dirty_updates()
	print("SKY OPTIMIZATION ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
