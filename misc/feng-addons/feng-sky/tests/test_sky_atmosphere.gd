extends SceneTree

const FengSkyAtmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const FengHeightFog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FengFogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const FengProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")
const FengWorldCompositor = preload("res://addons/feng-render-pipeline/world_compositor.gd")


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		push_error("REGRESSION: " + message)
		quit(1)


func make_viewport(world: World3D) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = world
	root.add_child(viewport)
	return viewport


func make_shared_sky() -> Sky:
	var shader := Shader.new()
	shader.code = "shader_type sky;\nuniform float test_gain = 1.0;\nvoid sky() { COLOR = vec3(test_gain); }\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	var sky := Sky.new()
	sky.sky_material = material
	return sky


func run() -> void:
	await run_checks()
	await run_runtime_checks()
	await process_frame
	print("feng_sky_atmosphere tests passed")
	quit()


func run_checks() -> void:
	var shared_environment := Environment.new()
	shared_environment.background_mode = Environment.BG_COLOR
	shared_environment.background_color = Color(0.12, 0.2, 0.3)
	shared_environment.ambient_light_energy = 2.0
	var shared_sky := make_shared_sky()
	var shared_material := shared_sky.sky_material as ShaderMaterial
	shared_environment.sky = shared_sky

	var viewport_a := make_viewport(World3D.new())
	var viewport_b := make_viewport(World3D.new())
	var component_a := FengSkyAtmosphere.new()
	component_a.environment = shared_environment
	viewport_a.add_child(component_a)
	var component_b := FengSkyAtmosphere.new()
	component_b.environment = shared_environment
	viewport_b.add_child(component_b)
	await process_frame

	require(component_a.environment != shared_environment, "component A kept the shared Environment")
	require(component_b.environment != shared_environment, "component B kept the shared Environment")
	require(component_a.environment != component_b.environment, "two World3Ds share the component Environment")
	require(component_a.environment.sky != shared_sky and component_b.environment.sky != shared_sky,
		"a component kept the shared Sky")
	require(component_a.environment.sky != component_b.environment.sky, "two World3Ds share the component Sky")
	require(component_a.environment.sky.sky_material != shared_material,
		"component A kept the shared Sky material")
	require(component_a.environment.sky.sky_material.shader != shared_material.shader,
		"component A kept the shared Shader")
	require(component_a.environment.background_mode == Environment.BG_SKY,
		"component A did not enforce BG_SKY")
	require(component_b.environment.background_mode == Environment.BG_SKY,
		"component B did not enforce BG_SKY")
	require(shared_environment.background_mode == Environment.BG_COLOR,
		"enforcing BG_SKY modified the shared Environment")
	require(shared_environment.ambient_light_energy == 2.0,
		"copying the Environment modified its source settings")
	require(viewport_a.world_3d.get_environment() == component_a.environment,
		"component A did not provide its World3D environment")
	require(viewport_b.world_3d.get_environment() == component_b.environment,
		"component B did not provide its World3D environment")

	var local_material_a := component_a.sky.sky_material as ShaderMaterial
	local_material_a.shader = null
	require(shared_material.shader != null, "editing component A's material changed the shared material")
	require((component_b.sky.sky_material as ShaderMaterial).shader != null,
		"editing component A's material changed component B")
	component_a.environment.sky = shared_sky
	component_a.environment.background_mode = Environment.BG_COLOR
	component_a._sync_environment()
	require(component_a.environment.sky != shared_sky,
		"synchronizing an inspector Sky assignment kept the shared Sky")
	require(component_a.environment.background_mode == Environment.BG_SKY,
		"synchronizing the Environment did not restore BG_SKY")

	var replacement := Sky.new()
	replacement.sky_material = PanoramaSkyMaterial.new()
	component_a.sky = replacement
	require(component_a.sky != replacement, "the replacement Sky was not localized")
	require(component_a.sky.sky_material is PanoramaSkyMaterial,
		"the component did not accept a PanoramaSkyMaterial")
	require(component_a.sky.sky_material != replacement.sky_material,
		"the replacement material was not localized")
	require(component_b.sky.sky_material is ShaderMaterial,
		"replacing component A's Sky changed component B")

	var default_component := FengSkyAtmosphere.new()
	require(default_component.sky != null, "a new component has no default Sky")
	require(default_component.sky.sky_material is ShaderMaterial,
		"a new component does not default to the atmosphere ShaderMaterial")
	var default_shader_material := default_component.sky.sky_material as ShaderMaterial
	require(default_shader_material.shader != null
		and default_shader_material.shader.code.contains("integrate_atmosphere"),
		"the default Sky does not use the single-scattering atmosphere model")
	var second_default_component := FengSkyAtmosphere.new()
	var second_default_material := second_default_component.sky.sky_material as ShaderMaterial
	require(default_shader_material.shader != second_default_material.shader,
		"two default atmosphere components share the shader resource")
	var second_shader_source := second_default_material.shader.code
	default_shader_material.shader.code = second_shader_source + "\n// private shader edit test\n"
	require(second_default_material.shader.code == second_shader_source,
		"editing one default atmosphere shader changed another component")
	default_shader_material.shader.code = second_shader_source
	require(default_component.atmosphere_enabled,
		"a new component does not enable the atmosphere model by default")
	require(default_component.affect_height_fog,
		"a new component does not contribute to height fog by default")
	require(default_component.environment.background_mode == Environment.BG_SKY,
		"a new component does not default to BG_SKY")
	require(is_equal_approx(default_component.environment.background_intensity, 1.0),
		"the built-in atmosphere did not neutralize the native sky background intensity")
	require(is_equal_approx(default_component.environment.background_energy_multiplier, 1.0),
		"the built-in atmosphere changed Environment's default sky energy multiplier")

	var persistence_root := Node3D.new()
	var persisted_component := FengSkyAtmosphere.new()
	var custom_environment := Environment.new()
	custom_environment.background_mode = Environment.BG_SKY
	custom_environment.background_intensity = 1234.0
	custom_environment.sky = replacement
	persisted_component.environment = custom_environment
	persisted_component.mie_asymmetry = 0.61
	persisted_component.affect_height_fog = false
	persisted_component.height_fog_contribution = 0.35
	persistence_root.add_child(persisted_component)
	persisted_component.owner = persistence_root
	viewport_a.add_child(persistence_root)
	await process_frame
	require(not persisted_component.atmosphere_enabled
		and is_equal_approx(persisted_component.environment.background_intensity, 1234.0),
		"adopting a custom Environment did not preserve its authored background intensity")
	persisted_component.atmosphere_enabled = true
	require(is_equal_approx(persisted_component.environment.background_intensity, 1.0),
		"enabling the built-in atmosphere did not set background intensity to unity")
	persisted_component.atmosphere_enabled = false
	require(is_equal_approx(persisted_component.environment.background_intensity, 1234.0),
		"switching to the custom Sky did not restore its authored background intensity")
	persisted_component.atmosphere_enabled = true
	require(is_equal_approx(persisted_component.environment.background_intensity, 1.0),
		"re-enabling the built-in atmosphere did not restore unity background intensity")
	var packed := PackedScene.new()
	require(packed.pack(persistence_root) == OK, "could not pack the atmosphere intensity persistence scene")
	const SAVE_PATH := "user://feng_sky_persistence_test.tscn"
	require(ResourceSaver.save(packed, SAVE_PATH) == OK, "could not save the atmosphere intensity persistence scene")
	var reloaded := (load(SAVE_PATH) as PackedScene).instantiate() as Node3D
	var reloaded_component := reloaded.get_child(0) as FengSkyAtmosphere
	require(reloaded_component != null, "the saved scene lost FengSkyAtmosphere")
	require(reloaded_component.atmosphere_enabled
		and reloaded_component.sky.sky_material is ShaderMaterial
		and is_equal_approx(reloaded_component.environment.background_intensity, 1.0),
		"an active atmosphere did not persist with its unity background intensity")
	require(reloaded_component.environment.sky == reloaded_component.sky,
		"the saved Sky slot and Environment sky diverged")
	require(is_equal_approx(reloaded_component.mie_asymmetry, 0.61),
		"the saved atmosphere parameters did not persist")
	require(not reloaded_component.affect_height_fog
		and is_equal_approx(reloaded_component.height_fog_contribution, 0.35),
		"the saved height-fog contribution settings did not persist")
	reloaded_component.atmosphere_enabled = false
	require(reloaded_component.sky.sky_material is PanoramaSkyMaterial,
		"disabling the atmosphere after reload did not restore the saved custom Sky")
	require(is_equal_approx(reloaded_component.environment.background_intensity, 1234.0),
		"disabling the atmosphere after reload did not restore the saved custom background intensity")

	var viewport_c := make_viewport(World3D.new())
	var first_environment := Environment.new()
	first_environment.background_mode = Environment.BG_COLOR
	var first_world_environment := WorldEnvironment.new()
	first_world_environment.environment = first_environment
	viewport_c.add_child(first_world_environment)
	var later_component := FengSkyAtmosphere.new()
	viewport_c.add_child(later_component)
	await process_frame
	require(viewport_c.world_3d.get_environment() == first_environment,
		"a later FengSkyAtmosphere took over another WorldEnvironment")
	require(first_environment.background_mode == Environment.BG_COLOR,
		"the later component modified the first WorldEnvironment's Environment")
	first_world_environment.free()
	await process_frame
	require(viewport_c.world_3d.get_environment() == later_component.environment,
		"the component did not become active after the first WorldEnvironment left")

	var pipeline_viewport := make_viewport(World3D.new())
	var sky_component := FengSkyAtmosphere.new()
	pipeline_viewport.add_child(sky_component)
	var pipeline_host := Node.new()
	pipeline_viewport.add_child(pipeline_host)
	var project_compositor := Compositor.new()
	const COMPOSITOR_PATH := "user://feng_sky_pipeline_compositor.tres"
	require(ResourceSaver.save(project_compositor, COMPOSITOR_PATH) == OK,
		"could not save the project compositor fixture")
	ProjectSettings.set_setting("rendering/renderer/compositor", COMPOSITOR_PATH)
	require(RenderingServer.get_current_rendering_method() == "frp",
		"the coexistence test is not running with the FRP rendering method")
	var installed_pipeline := FengProjectPipeline.install(pipeline_host, null)
	require(installed_pipeline != null and installed_pipeline.compositor != null,
		"FengProjectPipeline did not install its project compositor")
	require(installed_pipeline.environment == null,
		"the project pipeline unexpectedly installed an Environment")
	require(pipeline_viewport.world_3d.get_environment() == sky_component.environment,
		"the project pipeline WorldEnvironment displaced FengSkyAtmosphere's Environment")
	require(FengWorldCompositor.world_compositor(pipeline_viewport) == installed_pipeline.compositor,
		"the project pipeline compositor did not remain active beside FengSkyAtmosphere")
	FengProjectPipeline.clear(installed_pipeline)
	await process_frame
	require(pipeline_viewport.world_3d.get_environment() == sky_component.environment,
		"clearing the project pipeline also removed FengSkyAtmosphere's Environment")
	require(FengWorldCompositor.world_compositor(pipeline_viewport) == null,
		"clearing the project pipeline left its compositor active")
	ProjectSettings.set_setting("rendering/renderer/compositor", "")

	default_component.free()
	second_default_component.free()
	reloaded.free()
	viewport_a.free()
	viewport_b.free()
	viewport_c.free()
	pipeline_viewport.free()


func finite_vec3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func wait_for_snapshot(world_id: int, should_exist: bool, max_frames := 120) -> Dictionary:
	var snapshot: Dictionary = {}
	for _index in max_frames:
		await process_frame
		snapshot = FengSkyRuntime.snapshot_for_world(world_id)
		if (not snapshot.is_empty()) == should_exist:
			return snapshot
	return snapshot


func vec3_luma(value: Vector3) -> float:
	return 0.2126 * value.x + 0.7152 * value.y + 0.0722 * value.z


func require_vec3_near(actual: Vector3, expected: Vector3, tolerance: float, message: String) -> void:
	require(actual.distance_to(expected) <= tolerance, message)


func run_runtime_checks() -> void:
	var viewport_a := make_viewport(World3D.new())
	var viewport_b := make_viewport(World3D.new())
	var use_physical_units := bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))
	var sun_a := DirectionalLight3D.new()
	sun_a.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	sun_a.light_intensity_lux = 6.0
	sun_a.light_energy = 1.0 if use_physical_units else 0.5
	var sky_a := FengSkyAtmosphere.new()
	sky_a.sun_light = sun_a
	viewport_a.add_child(sky_a)
	viewport_a.add_child(sun_a)
	var sun_b := DirectionalLight3D.new()
	sun_b.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	sun_b.light_intensity_lux = 60000.0
	sun_b.light_energy = 1.0
	var sky_b := FengSkyAtmosphere.new()
	sky_b.sun_light = sun_b
	viewport_b.add_child(sky_b)
	viewport_b.add_child(sun_b)
	await process_frame
	var world_a_id := viewport_a.world_3d.get_instance_id()
	var world_b_id := viewport_b.world_3d.get_instance_id()
	var snapshot_a := await wait_for_snapshot(world_a_id, true)
	var snapshot_b := await wait_for_snapshot(world_b_id, true)
	var world_environment_a := viewport_a.world_3d.get_environment()
	var world_environment_b := viewport_b.world_3d.get_environment()
	require(not snapshot_a.is_empty() and not snapshot_b.is_empty(),
		"an active atmosphere provider did not publish its world snapshot")
	require(snapshot_a.get("world_id") == world_a_id, "the atmosphere snapshot used the wrong World3D")
	require(snapshot_b.get("world_id") == world_b_id, "the second atmosphere snapshot used the wrong World3D")
	require(snapshot_a.get("provider_id") == sky_a.get_instance_id(), "world A selected the wrong sky provider")
	require(snapshot_b.get("provider_id") == sky_b.get_instance_id(), "world B selected the wrong sky provider")
	require(snapshot_a.get("sun_light_id") == sun_a.get_instance_id(), "world A selected the wrong sun")
	require(snapshot_b.get("sun_light_id") == sun_b.get_instance_id(), "world B selected the wrong sun")
	var direction_a: Vector3 = snapshot_a.get("sun_direction", Vector3.ZERO)
	require(absf(direction_a.length() - 1.0) < 0.001 and direction_a.y > 0.0,
		"the atmosphere sun direction is not a normalized day-side vector")
	var ambient_a: Vector3 = snapshot_a.get("ambient_radiance", Vector3.ZERO)
	var ambient_b: Vector3 = snapshot_b.get("ambient_radiance", Vector3.ZERO)
	var ground_a: Vector3 = snapshot_a.get("sun_ground_illuminance", Vector3.ZERO)
	var ground_b: Vector3 = snapshot_b.get("sun_ground_illuminance", Vector3.ZERO)
	require(finite_vec3(ambient_a) and finite_vec3(ambient_b), "atmosphere ambient contains NaN or infinity")
	require(finite_vec3(ground_a) and finite_vec3(ground_b), "ground illuminance contains NaN or infinity")
	require(vec3_luma(ambient_a) > 0.0 and vec3_luma(ground_a) > 0.0,
		"daylight did not produce positive atmospheric radiance and ground illuminance")
	var ambient_ratio := vec3_luma(ambient_b) / maxf(vec3_luma(ambient_a), 0.000001)
	var ground_ratio := vec3_luma(ground_b) / maxf(vec3_luma(ground_a), 0.000001)
	var expected_ratio := 10000.0 if use_physical_units else 2.0
	var ratio_tolerance := 0.001 if use_physical_units else 0.0001
	require(absf(ambient_ratio - expected_ratio) < expected_ratio * ratio_tolerance,
		"scene-linear atmospheric radiance did not scale with physical lux or FRP energy")
	require(absf(ground_ratio - expected_ratio) < expected_ratio * ratio_tolerance,
		"atmosphere ground illuminance did not scale with physical lux or FRP energy")
	var expected_irradiance_a := 6.0 if use_physical_units else PI * 0.5
	var expected_irradiance_b := 60000.0 if use_physical_units else PI
	var material_a := sky_a.sky.sky_material as ShaderMaterial
	var material_b := sky_b.sky.sky_material as ShaderMaterial
	var shader_irradiance_a: float = material_a.get_shader_parameter("sun_irradiance")
	var shader_irradiance_b: float = material_b.get_shader_parameter("sun_irradiance")
	require(is_equal_approx(shader_irradiance_a, expected_irradiance_a)
		and is_equal_approx(shader_irradiance_b, expected_irradiance_b),
		"sky solar scale does not match physical lux or FRP energy × PI")
	require(snapshot_a.get("sun_irradiance_unit") == ("lux" if use_physical_units else "frp_normalized"),
		"the atmosphere snapshot mislabeled the sun irradiance unit")
	print("ATMOSPHERE DAY physical_units=", use_physical_units,
		" world_a_ambient=", ambient_a, " world_b_ambient=", ambient_b,
		" ambient_ratio=", ambient_ratio, " ground_a=", ground_a,
		" ground_b=", ground_b, " ground_ratio=", ground_ratio)

	var fog := FengHeightFog.new()
	fog.fog_inscattering_color = Color(0.1, 0.2, 0.3)
	viewport_b.add_child(fog)
	var authored_color := Vector3(0.1, 0.2, 0.3)
	var combined := fog.snapshot_fields()
	FengFogRuntime._add_sky_ambient(combined, world_b_id)
	require_vec3_near(combined["fog_color"], authored_color + ambient_b,
		maxf(ambient_b.length() * 0.001, 0.00001),
		"height fog did not add the world-matched atmosphere radiance exactly once")
	sky_b.height_fog_contribution = 0.5
	await process_frame
	var half_combined := fog.snapshot_fields()
	FengFogRuntime._add_sky_ambient(half_combined, world_b_id)
	require_vec3_near(half_combined["fog_color"], authored_color + ambient_b * 0.5,
		maxf(ambient_b.length() * 0.001, 0.00001),
		"height fog ignored its atmosphere contribution scale")
	sky_b.affect_height_fog = false
	await process_frame
	var disabled_combined := fog.snapshot_fields()
	FengFogRuntime._add_sky_ambient(disabled_combined, world_b_id)
	require_vec3_near(disabled_combined["fog_color"], authored_color, 0.000001,
		"disabling sky-to-fog left stale atmospheric radiance in the fog snapshot")
	sky_b.affect_height_fog = true
	sky_b.height_fog_contribution = 1.0
	var unit_gain_ambient := ambient_b
	var unit_gain_ground := ground_b
	world_environment_b.background_energy_multiplier = 2.0
	await process_frame
	snapshot_b = await wait_for_snapshot(world_b_id, true)
	var doubled_gain_ambient: Vector3 = snapshot_b.get("ambient_radiance", Vector3.ZERO)
	var doubled_gain_ground: Vector3 = snapshot_b.get("sun_ground_illuminance", Vector3.ZERO)
	require_vec3_near(doubled_gain_ambient, unit_gain_ambient * 2.0,
		maxf(unit_gain_ambient.length() * 0.001, 0.00001),
		"Environment background_energy_multiplier did not scale atmospheric ambient exactly once")
	require_vec3_near(doubled_gain_ground, unit_gain_ground,
		maxf(unit_gain_ground.length() * 0.001, 0.00001),
		"Environment background_energy_multiplier incorrectly scaled direct ground illuminance")
	var doubled_gain_fog := fog.snapshot_fields()
	FengFogRuntime._add_sky_ambient(doubled_gain_fog, world_b_id)
	require_vec3_near(doubled_gain_fog["fog_color"], authored_color + doubled_gain_ambient,
		maxf(doubled_gain_ambient.length() * 0.001, 0.00001),
		"height fog did not consume the matching gain-scaled atmosphere source once")
	print("ATMOSPHERE BACKGROUND_GAIN multiplier=2 ambient_unit=", unit_gain_ambient,
		" ambient_scaled=", doubled_gain_ambient,
		" ground_preserved=", doubled_gain_ground)
	world_environment_b.background_energy_multiplier = 1.0
	await process_frame
	snapshot_b = await wait_for_snapshot(world_b_id, true)
	ambient_b = snapshot_b.get("ambient_radiance", Vector3.ZERO)
	ground_b = snapshot_b.get("sun_ground_illuminance", Vector3.ZERO)

	var saved_rayleigh := sky_a.rayleigh_scattering_per_km
	var saved_mie := sky_a.mie_scattering_per_km
	sky_a.rayleigh_scattering_per_km = Vector3.ZERO
	sky_a.mie_scattering_per_km = 0.0
	await process_frame
	snapshot_a = await wait_for_snapshot(world_a_id, true)
	ambient_a = snapshot_a.get("ambient_radiance", Vector3.ONE)
	require(finite_vec3(ambient_a) and ambient_a.length() < 0.00001,
		"zero Rayleigh and Mie scattering produced non-zero atmospheric radiance")
	sky_a.rayleigh_scattering_per_km = saved_rayleigh
	sky_a.mie_scattering_per_km = saved_mie

	sun_a.rotation_degrees = Vector3(30.0, 0.0, 0.0)
	await process_frame
	snapshot_a = await wait_for_snapshot(world_a_id, true)
	var night_direction: Vector3 = snapshot_a.get("sun_direction", Vector3.ZERO)
	var night_ambient: Vector3 = snapshot_a.get("ambient_radiance", Vector3.ONE)
	var night_ground: Vector3 = snapshot_a.get("sun_ground_illuminance", Vector3.ONE)
	require(absf(night_direction.y + 0.5) < 0.001,
		"the deep-night case did not put the sun 30 degrees below the horizon")
	require(finite_vec3(night_ambient) and finite_vec3(night_ground), "night values are non-finite")
	require(night_ambient.length() < 0.00001 and vec3_luma(night_ground) < 0.00001,
		"planetary shadow left atmospheric radiance or ground illuminance at deep night")
	print("ATMOSPHERE NIGHT sun_direction=", night_direction,
		" ambient=", night_ambient, " ground_illuminance=", night_ground)
	sun_a.rotation_degrees = Vector3(1.0, 0.0, 0.0)
	await process_frame
	snapshot_a = await wait_for_snapshot(world_a_id, true)
	var twilight_direction: Vector3 = snapshot_a.get("sun_direction", Vector3.ZERO)
	var twilight_ambient: Vector3 = snapshot_a.get("ambient_radiance", Vector3.ZERO)
	var twilight_ground: Vector3 = snapshot_a.get("sun_ground_illuminance", Vector3.ONE)
	require(twilight_direction.y < 0.0 and vec3_luma(twilight_ground) == 0.0,
		"the twilight control did not keep direct ground sunlight below the horizon")
	require(finite_vec3(twilight_ambient) and vec3_luma(twilight_ambient) > 0.0,
		"the near-horizon twilight case lost its upper-atmosphere scattering")
	print("ATMOSPHERE TWILIGHT sun_direction=", twilight_direction,
		" ambient=", twilight_ambient, " ground_illuminance=", twilight_ground)
	sun_a.rotation_degrees = Vector3(-0.25, 0.0, 0.0)
	await process_frame
	snapshot_a = await wait_for_snapshot(world_a_id, true)
	var near_horizon_direction: Vector3 = snapshot_a.get("sun_direction", Vector3.ZERO)
	var near_horizon_ground: Vector3 = snapshot_a.get("sun_ground_illuminance", Vector3.ZERO)
	var near_horizon_top := sky_a._sun_linear_color(sun_a) * sky_a._sun_irradiance(sun_a)
	var near_horizon_transmission := vec3_luma(near_horizon_ground) / maxf(vec3_luma(near_horizon_top), 0.000001)
	var near_horizon_shader: ShaderMaterial = sky_a.sky.sky_material as ShaderMaterial
	require(near_horizon_direction.y > 0.0 and near_horizon_direction.y < 0.01,
		"the low-sun test did not put the source just above the horizon")
	require(finite_vec3(near_horizon_ground) and vec3_luma(near_horizon_ground) > 0.0
		and near_horizon_transmission < 0.5,
		"the near-horizon ground source did not retain a finite, strongly attenuated illuminance")
	require(is_equal_approx(float(near_horizon_shader.get_shader_parameter("sun_irradiance")),
		sky_a._sun_irradiance(sun_a)),
		"ground attenuation incorrectly changed the sky shader's top-of-atmosphere source")
	require_vec3_near(FengFogRuntime._matched_atmosphere_sun_illuminance(sun_a, snapshot_a),
		near_horizon_ground, maxf(near_horizon_ground.length() * 0.00001, 0.000001),
		"fog did not select the matching atmosphere light's ground illuminance")
	require(FengFogRuntime._matched_atmosphere_sun_illuminance(sun_b, snapshot_a) == null,
		"fog attenuated a different-world directional light")
	print("ATMOSPHERE LOW_SUN elevation_sine=", near_horizon_direction.y,
		" top_illuminance=", near_horizon_top, " ground_illuminance=", near_horizon_ground,
		" transmission_luma_ratio=", near_horizon_transmission)

	var custom_sky := make_shared_sky()
	sky_b.sky = custom_sky
	var custom_snapshot := await wait_for_snapshot(world_b_id, false)
	require(custom_snapshot.is_empty(), "selecting a custom Sky did not deactivate the atmosphere provider")
	var custom_fog := fog.snapshot_fields()
	FengFogRuntime._add_sky_ambient(custom_fog, world_b_id)
	require_vec3_near(custom_fog["fog_color"], authored_color, 0.000001,
		"a custom Sky changed the authored fog source")
	sky_b.atmosphere_enabled = true
	snapshot_b = await wait_for_snapshot(world_b_id, true)
	require(snapshot_b.get("provider_id") == sky_b.get_instance_id(),
		"explicitly re-enabling the atmosphere did not restore its World3D provider")

	sky_a.queue_free()
	await process_frame
	require(FengSkyRuntime.snapshot_for_world(world_a_id).is_empty(),
		"removing a provider left a stale atmosphere snapshot")
	require(not FengSkyRuntime.snapshot_for_world(world_b_id).is_empty(),
		"removing world A's provider affected world B")

	var handoff_sky := FengSkyAtmosphere.new()
	var handoff_sun := DirectionalLight3D.new()
	handoff_sun.rotation_degrees = Vector3(-30.0, 0.0, 0.0)
	handoff_sun.light_intensity_lux = 6000.0
	handoff_sky.sun_light = handoff_sun
	viewport_a.add_child(handoff_sky)
	viewport_a.add_child(handoff_sun)
	await process_frame
	var handoff_world_id := viewport_a.world_3d.get_instance_id()
	require(not FengSkyRuntime.snapshot_for_world(handoff_world_id).is_empty(),
		"the provider did not publish after re-entering its original World3D")
	viewport_a.remove_child(handoff_sky)
	await process_frame
	require(FengSkyRuntime.snapshot_for_world(handoff_world_id).is_empty(),
		"detaching a provider left a stale world snapshot")
	var handoff_environment := WorldEnvironment.new()
	handoff_environment.environment = Environment.new()
	viewport_a.add_child(handoff_environment)
	viewport_a.add_child(handoff_sky)
	await process_frame
	require(FengSkyRuntime.snapshot_for_world(handoff_world_id).is_empty(),
		"a later provider published while another WorldEnvironment owned the world")
	viewport_a.remove_child(handoff_environment)
	await process_frame
	require(not FengSkyRuntime.snapshot_for_world(handoff_world_id).is_empty(),
		"the provider did not republish after its WorldEnvironment became active")
	handoff_environment.free()
	viewport_a.free()
	viewport_b.free()

	var viewport_c := make_viewport(World3D.new())
	var sky_c := FengSkyAtmosphere.new()
	sky_c.affect_height_fog = false
	viewport_c.add_child(sky_c)
	await process_frame
	var material_c := sky_c.sky.sky_material as ShaderMaterial
	var no_sun_irradiance: float = material_c.get_shader_parameter("sun_irradiance")
	require(is_finite(no_sun_irradiance) and no_sun_irradiance == 0.0,
		"a sky excluded from fog kept phantom default sunlight when no sun was present")
	var sun_c := DirectionalLight3D.new()
	sun_c.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	sun_c.light_intensity_lux = 6.0
	sky_c.sun_light = sun_c
	viewport_c.add_child(sun_c)
	await process_frame
	material_c = sky_c.sky.sky_material as ShaderMaterial
	var low_sun_irradiance: float = material_c.get_shader_parameter("sun_irradiance")
	var low_sun_direction: Vector3 = material_c.get_shader_parameter("sun_direction")
	var low_expected_irradiance := 6.0 if bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false)) else PI * sun_c.light_energy
	require(is_equal_approx(low_sun_irradiance, low_expected_irradiance),
		"disabling fog contribution froze the sky's sunlight scale")
	require(low_sun_direction.distance_to(sun_c.global_transform.basis.z.normalized()) < 0.001,
		"disabling fog contribution froze the sky's sun direction")
	sun_c.light_intensity_lux = 60000.0
	sun_c.rotation_degrees = Vector3(-20.0, 35.0, 0.0)
	await process_frame
	material_c = sky_c.sky.sky_material as ShaderMaterial
	var high_sun_irradiance: float = material_c.get_shader_parameter("sun_irradiance")
	var high_sun_direction: Vector3 = material_c.get_shader_parameter("sun_direction")
	var high_expected_irradiance := 60000.0 if bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false)) else PI * sun_c.light_energy
	require(is_equal_approx(high_sun_irradiance, high_expected_irradiance),
		"disabling fog contribution froze sky sunlight scaling")
	require(high_sun_direction.distance_to(sun_c.global_transform.basis.z.normalized()) < 0.001,
		"disabling fog contribution froze sky sun rotation")
	require(FengSkyRuntime.snapshot_for_world(viewport_c.world_3d.get_instance_id()).is_empty(),
		"affect_height_fog=false still published a fog snapshot")
	sun_c.visible = false
	await process_frame
	material_c = sky_c.sky.sky_material as ShaderMaterial
	var hidden_sun_irradiance: float = material_c.get_shader_parameter("sun_irradiance")
	require(is_finite(hidden_sun_irradiance) and hidden_sun_irradiance == 0.0,
		"hiding the sun left its old intensity in the sky material")

	# Code-set values can exceed Inspector hints. The CPU snapshot and shader
	# material must consume the same sanitized parameter dictionary.
	sky_c.affect_height_fog = true
	sun_c.visible = true
	sun_c.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	sky_c.planet_radius_km = 9000.0
	sky_c.atmosphere_height_km = -4.0
	sky_c.rayleigh_scale_height_km = 400.0
	sky_c.mie_scale_height_km = -1.0
	sky_c.rayleigh_scattering_per_km = Vector3(3.0, -0.5, 0.25)
	sky_c.mie_scattering_per_km = 3.0
	sky_c.mie_extinction_per_km = 0.1
	sky_c.mie_asymmetry = 4.0
	sky_c.planet_center_m = Vector3(0.0, -7000000.0, 0.0)
	sky_c.ground_albedo = Vector3(-1.0, 1.5, 0.4)
	sky_c.sun_angular_radius_deg = 5.0
	var raw_settings := {
		"planet_radius_km": sky_c.planet_radius_km,
		"atmosphere_height_km": sky_c.atmosphere_height_km,
		"rayleigh_scale_height_km": sky_c.rayleigh_scale_height_km,
		"mie_scale_height_km": sky_c.mie_scale_height_km,
		"rayleigh_scattering_per_km": sky_c.rayleigh_scattering_per_km,
		"mie_scattering_per_km": sky_c.mie_scattering_per_km,
		"mie_extinction_per_km": sky_c.mie_extinction_per_km,
		"mie_asymmetry": sky_c.mie_asymmetry,
		"planet_center_m": sky_c.planet_center_m,
		"ground_albedo": sky_c.ground_albedo,
		"sun_angular_radius_deg": sky_c.sun_angular_radius_deg,
	}
	var sanitized: Dictionary = FengSkyRuntime.sanitize_atmosphere_settings(raw_settings)
	await process_frame
	var sanitized_snapshot := await wait_for_snapshot(viewport_c.world_3d.get_instance_id(), true)
	var provider_settings: Dictionary = sky_c._atmosphere_settings()
	require(provider_settings == sanitized,
		"the CPU atmosphere integration did not use the shared sanitized settings")
	require(finite_vec3(sanitized_snapshot.get("ambient_radiance", Vector3(NAN, NAN, NAN)))
		and finite_vec3(sanitized_snapshot.get("sun_ground_illuminance", Vector3(NAN, NAN, NAN))),
		"over-range code-set atmosphere settings produced non-finite CPU values")
	material_c = sky_c.sky.sky_material as ShaderMaterial
	for setting_name in ["planet_radius_km", "atmosphere_height_km", "rayleigh_scale_height_km",
			"mie_scale_height_km", "mie_scattering_per_km", "mie_extinction_per_km",
			"mie_asymmetry", "sun_angular_radius_deg"]:
		require(is_equal_approx(float(material_c.get_shader_parameter(setting_name)),
			float(sanitized[setting_name])),
			"shader uniform %s did not use the shared sanitized value" % setting_name)
	for setting_name in ["rayleigh_scattering_per_km", "planet_center_m", "ground_albedo"]:
		require((material_c.get_shader_parameter(setting_name) as Vector3).distance_to(
			sanitized[setting_name] as Vector3) < 0.000001,
			"shader uniform %s did not use the shared sanitized value" % setting_name)
	var expected_sanitized_sample: Dictionary = FengSkyRuntime.compute_atmosphere_sample(
		sanitized,
		sanitized_snapshot.get("sun_direction", Vector3.UP),
		float(material_c.get_shader_parameter("sun_irradiance")),
		sky_c._sun_linear_color(sun_c))
	require_vec3_near(sanitized_snapshot["ambient_radiance"],
		expected_sanitized_sample["ambient_radiance"], 0.001,
		"CPU ambient disagreed with a direct integration using the shared sanitized settings")
	var original_material := sky_c.sky.sky_material as ShaderMaterial
	var original_shader_code := original_material.shader.code
	var custom_shader := Shader.new()
	custom_shader.code = "shader_type sky;\nvoid sky() { COLOR = vec3(0.2); }\n"
	original_material.shader.code = custom_shader.code
	require((await wait_for_snapshot(viewport_c.world_3d.get_instance_id(), false)).is_empty(),
		"editing the owned atmosphere shader code left its ambient snapshot active")
	require(sky_c.atmosphere_enabled,
		"a direct nested shader edit incorrectly changed the component's atmosphere mode")
	original_material.shader.code = original_shader_code
	sanitized_snapshot = await wait_for_snapshot(viewport_c.world_3d.get_instance_id(), true)
	require(sanitized_snapshot.get("provider_id") == sky_c.get_instance_id(),
		"restoring the built-in shader code did not restore its world snapshot")
	var replacement_material := ShaderMaterial.new()
	replacement_material.shader = custom_shader
	sky_c.sky.sky_material = replacement_material
	require((await wait_for_snapshot(viewport_c.world_3d.get_instance_id(), false)).is_empty(),
		"replacing the owned atmosphere material left its ambient snapshot active")
	sky_c.sky.sky_material = original_material
	sanitized_snapshot = await wait_for_snapshot(viewport_c.world_3d.get_instance_id(), true)
	require(sanitized_snapshot.get("provider_id") == sky_c.get_instance_id(),
		"restoring the built-in atmosphere material did not restore its world snapshot")
	material_c = sky_c.sky.sky_material as ShaderMaterial
	require(is_equal_approx(float(material_c.get_shader_parameter("sun_irradiance")),
		sun_c.light_intensity_lux if bool(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/use_physical_light_units", false)) else PI),
		"restoring the atmosphere material did not refresh its sun uniforms")
	viewport_c.free()
