extends SceneTree
## UE author-control semantics and old scene migration, independent of imagery.
const SkyComponent = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const Parameters = preload("res://addons/feng-sky/feng_sky_parameters.gd")
const Runtime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func near(actual: Vector3, expected: Vector3, message: String) -> void:
	require(actual.distance_to(expected) < 0.000001, message)

func run() -> void:
	var sky := SkyComponent.new()
	var settings: Dictionary = sky._atmosphere_settings()
	near(settings["mie_scattering_coefficients"], Vector3.ONE * 0.003996, "Mie default scattering")
	near(settings["mie_extinction_coefficients"], Vector3.ONE * 0.004440, "Mie extinction must include absorption")
	near(settings["absorption_extinction_per_km"], Parameters.DEFAULT_ABSORPTION_PER_KM, "ozone default is independent of Mie absorption")
	sky.mie_scattering = Vector3(0.001, 0.002, 0.003)
	sky.mie_scattering_scale = 2.0
	sky.mie_absorption = Vector3(0.004, 0.005, 0.006)
	sky.mie_absorption_scale = 3.0
	settings = sky._atmosphere_settings()
	near(settings["mie_scattering_coefficients"], Vector3(0.002, 0.004, 0.006), "RGB Mie scatter scale")
	near(settings["mie_extinction_coefficients"], Vector3(0.014, 0.019, 0.024), "RGB Mie absorption is independent")
	near(settings["absorption_extinction_per_km"], Parameters.DEFAULT_ABSORPTION_PER_KM, "Mie edits must not replace ozone absorption")
	sky.mie_scattering_scale = 0.0
	near(sky._atmosphere_settings()["mie_scattering_coefficients"], Vector3.ZERO, "zero scatter scale")
	require(sky._atmosphere_settings()["mie_extinction_coefficients"] != Vector3.ZERO, "absorption survives zero scatter")
	sky.rayleigh_scattering_scale = 2.0
	near(sky._atmosphere_settings()["rayleigh_scattering_per_km"], Parameters.DEFAULT_RAYLEIGH_PER_KM * 2.0, "Rayleigh independent scale")
	sky.other_absorption_scale = 0.0
	near(sky._atmosphere_settings()["absorption_extinction_per_km"], Vector3.ZERO, "ozone can be disabled")
	sky.absorption_tip_altitude = 25.0
	sky.absorption_tip_value = 1.0
	sky.absorption_width = 15.0
	settings = sky._atmosphere_settings()
	for pair in [Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(17.5, 0.5), Vector2(25.0, 1.0), Vector2(32.5, 0.5), Vector2(40.0, 0.0), Vector2(60.0, 0.0)]:
		var layer := 0 if pair.x < settings["absorption_density_layer_width_km"] else 1
		var density := clampf(pair.x * settings["absorption_layer%d_linear_term" % layer] + settings["absorption_layer%d_constant_term" % layer], 0.0, 1.0)
		require(absf(density - pair.y) < 0.000001, "ozone tent at %s km" % pair.x)
	sky.bottom_radius = 10.0
	near(sky.planet_center_m, Vector3(0.0, -10000.0, 0.0), "radius moves sea level automatically")
	sky.planet_origin = Vector3(100.0, 200.0, 300.0)
	sky.transform_mode = SkyComponent.TransformMode.PLANET_TOP_AT_COMPONENT_TRANSFORM
	near(sky.planet_center_m, Vector3(100.0, -9800.0, 300.0), "component top transform in metres")
	sky.transform_mode = SkyComponent.TransformMode.PLANET_CENTER_AT_COMPONENT_TRANSFORM
	near(sky.planet_center_m, sky.planet_origin, "component center transform")
	sky.planet_center_m = Vector3(4.0, 5.0, 6.0)
	near(sky.planet_origin, Vector3(4.0, 5.0, 6.0), "legacy center setter selects explicit center mode")
	sky.planet_radius_km = 2.0
	require(sky.bottom_radius == 2.0 and sky._atmosphere_settings()["planet_radius_km"] == 2.0, "non-Earth planet supported")
	sky.sky_luminance_factor = Vector3(2.0, 3.0, 4.0)
	sky.sky_and_aerial_perspective_luminance_factor = Vector3(0.5, 0.6, 0.7)
	settings = sky._atmosphere_settings()
	near(settings["sky_only_luminance_factor"], Vector3(2.0, 3.0, 4.0), "sky-only gain is distinct")
	near(settings["sky_luminance_factor"], Vector3(0.5, 0.6, 0.7), "combined sky/aerial gain")

	sky.ground_radius = 0.1
	sky.mie_anisotropy = 0.999
	sky.trace_sample_count_scale = 8.0
	sky.aerial_perspective_start_depth = 0.0
	var bounds := sky._atmosphere_settings()
	require(bounds["planet_radius_km"] == 0.1, "UE small-planet minimum was clipped")
	require(is_equal_approx(bounds["mie_asymmetry"], 0.999), "UE extreme Mie anisotropy was clipped")
	require(bounds["trace_sample_count_scale"] == 8.0, "UE trace scale UI range was clipped")
	require(bounds["aerial_perspective_start_depth_km"] == 0.001, "UE aerial start minimum was not applied")
	sky.ground_radius = 2.0
	var saved_names: Array[String] = []
	var color_fields := ["ground_albedo", "rayleigh_scattering", "mie_scattering", "mie_absorption", "absorption"]
	for property in sky.get_property_list():
		if property["name"] in color_fields:
			require(property["type"] == TYPE_COLOR, "UE RGB field is an inspector color: " + property["name"])
		if int(property["usage"]) & PROPERTY_USAGE_STORAGE:
			saved_names.append(property["name"])
	for canonical in ["ground_radius", "rayleigh_scattering", "mie_absorption", "multi_scattering_factor", "absorption", "transform_mode", "render_in_main_pass", "holdout"]:
		require(saved_names.has(canonical), "canonical property is persisted: " + canonical)
	for legacy in ["planet_radius_km", "rayleigh_scattering_per_km", "mie_extinction_per_km", "mie_asymmetry", "planet_center_m"]:
		require(not saved_names.has(legacy), "legacy alias must not overwrite canonical data on save: " + legacy)
	var transform_parent := Node3D.new()
	var transform_proxy := Node3D.new()
	root.add_child(transform_parent)
	transform_parent.add_child(transform_proxy)
	transform_proxy.position = Vector3(2.0, 3.0, 4.0)
	sky.planet_transform = transform_proxy
	sky.transform_mode = SkyComponent.TransformMode.PLANET_TOP_AT_COMPONENT_TRANSFORM
	near(sky._atmosphere_settings()["planet_center_m"], Vector3(2.0, -1997.0, 4.0), "linked component transform uses world metres")
	var before_revision: int = sky.get("_settings_revision")
	transform_parent.position = Vector3(100.0, 50.0, -20.0)
	near(sky._atmosphere_settings()["planet_center_m"], Vector3(102.0, -1947.0, -16.0), "moving a parent invalidates atmosphere geometry origin")
	require(int(sky.get("_settings_revision")) > before_revision, "linked transform invalidates cached settings")
	transform_parent.free()
	require((sky._atmosphere_settings()["planet_center_m"] as Vector3).is_finite(), "removed transform proxy has a finite fallback")
	sky.free()
	test_legacy_shader()
	test_legacy_shader("e002032")
	await test_legacy_scene()
	if not failed:
		print("UNREAL ATMOSPHERE PARAMETERS PASS")
	quit(1 if failed else 0)

func test_legacy_scene() -> void:
	var path := "user://legacy_atmosphere_migration.tscn"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://addons/feng-sky/feng_sky_atmosphere.gd" id="1"]
[node name="LegacyAtmosphere" type="WorldEnvironment"]
script = ExtResource("1")
planet_radius_km = 6500.0
atmosphere_height_km = 80.0
rayleigh_scale_height_km = 9.0
mie_scale_height_km = 1.5
rayleigh_scattering_per_km = Vector3(0.01, 0.02, 0.03)
mie_scattering_per_km = 0.005
mie_extinction_per_km = 0.007
mie_asymmetry = 0.61
planet_center_m = Vector3(100, -6500000, 200)
ground_albedo = Vector3(0.2, 0.3, 0.4)
sun_angular_radius_deg = 0.3
''')
	file.close()
	var scene := load(path) as PackedScene
	require(scene != null, "old scene loads")
	if scene == null:
		return
	var loaded := scene.instantiate() as SkyComponent
	require(loaded.bottom_radius == 6500.0 and loaded.atmosphere_height == 80.0, "old radius/height migrate")
	require(is_equal_approx(loaded.mie_anisotropy, 0.61), "old anisotropy migrates")
	near(Parameters.finite_vector(loaded.mie_absorption, Vector3.ZERO), Vector3.ONE * 0.002, "old extinction becomes absorption")
	near(loaded.planet_center_m, Vector3(100.0, -6500000.0, 200.0), "old planet center survives")
	var settings: Dictionary = loaded._atmosphere_settings()
	var repacked := PackedScene.new()
	require(repacked.pack(loaded) == OK, "migrated scene repacks")
	var migrated_path := "user://canonical_atmosphere_migration.tscn"
	require(ResourceSaver.save(repacked, migrated_path) == OK, "migrated scene saves")
	var migrated := load(migrated_path) as PackedScene
	var roundtrip := migrated.instantiate() as SkyComponent
	require(roundtrip._atmosphere_settings() == settings, "canonical save/reload preserves normalized settings")
	loaded.free()
	roundtrip.free()

func test_legacy_shader(revision: String = "aa96f5c") -> void:
	var original_code := FileAccess.get_file_as_string("res://addons/feng-sky/tests/fixtures/atmosphere_%s.gdshader.txt" % revision)
	require(SkyComponent._is_released_legacy_shader(original_code.replace("\n", "\r\n")), "Windows CRLF default shader also migrates")
	var shader := Shader.new()
	shader.code = original_code
	var material := ShaderMaterial.new()
	material.shader = shader
	var source := Sky.new()
	source.sky_material = material
	var component := SkyComponent.new()
	component.sky = source
	require(component.atmosphere_enabled, "released embedded atmosphere shader migrates")
	require((component.sky.sky_material as ShaderMaterial).shader.code == Runtime.atmosphere_shader_code(), "migration uses current transport source")
	require(shader.code == original_code, "migration never mutates the user's shared shader")
	shader.code += "\n// custom author edit\n"
	component.sky = source
	require(not component.atmosphere_enabled, "custom shader edit is not silently upgraded")
	component.free()
