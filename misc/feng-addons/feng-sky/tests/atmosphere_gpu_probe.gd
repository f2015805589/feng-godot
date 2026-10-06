extends SceneTree

const FengSkyAtmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const FengHeightFog = preload("res://addons/feng-fog/feng_height_fog.gd")

const OUTPUT_DIR := "user://sky_probe"

var _renderer
var _viewport: SubViewport
var _camera: Camera3D
var _scene: Node3D
var _sky: FengSkyAtmosphere
var _sun: DirectionalLight3D
var _fog: FengHeightFog
var _far_wall_body: StaticBody3D
var _exposure_pass
var _compositor: Compositor
var _samples: Dictionary = {}
signal exposure_sample_ready(scale: float)


func _initialize() -> void:
	call_deferred("run")


func find_pass(stable_id: String):
	for entry in _renderer.passes:
		if entry != null and entry.stable_id == stable_id:
			return entry
	return null


func settle(frames: int) -> void:
	for _index in frames:
		await process_frame
	await RenderingServer.frame_post_draw


func current_exposure_scale() -> float:
	if _exposure_pass == null or not _exposure_pass.enabled:
		return 1.0
	RenderingServer.call_on_render_thread(_read_current_exposure_scale)
	return await exposure_sample_ready


func _read_current_exposure_scale() -> void:
	# The plain Compositor binds this exact authored effect. Its GPU state must
	# be read on the render thread, rather than from a dormant authored clone.
	var scale := -1.0
	var states: Dictionary = _exposure_pass.get("_state")
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for entry_value in states.values():
			var views: Dictionary = entry_value.get("views", {})
			if not views.has(0):
				continue
			var params_rid: RID = views[0].get("params")
			if not params_rid.is_valid():
				continue
			var values := rd.buffer_get_data(params_rid).to_float32_array()
			if values.size() > 129:
				scale = values[129]
				break
	_deliver_exposure_scale.call_deferred(scale)


func _deliver_exposure_scale(scale: float) -> void:
	exposure_sample_ready.emit(scale)


func luma(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


func measure_frame_metrics(label: String, frame_count: int) -> Dictionary:
	var process_seconds_total := 0.0
	var measured_frames := 0
	var wall_start_usec := Time.get_ticks_usec()
	for _index in frame_count:
		await process_frame
		var process_seconds := float(Performance.get_monitor(Performance.TIME_PROCESS))
		if is_finite(process_seconds) and process_seconds > 0.0:
			process_seconds_total += process_seconds
			measured_frames += 1
		await RenderingServer.frame_post_draw
	var wall_elapsed_usec := Time.get_ticks_usec() - wall_start_usec
	var result := {
		"process_ms": process_seconds_total * 1000.0 / float(maxi(measured_frames, 1)),
		"wall_ms_through_post_draw": float(wall_elapsed_usec) / float(maxi(frame_count, 1)) / 1000.0,
		"measured_frames": measured_frames,
		"wall_frames": frame_count,
	}
	print("SKY GPU PERF ", label,
		" process_ms=", result["process_ms"],
		" wall_ms_through_post_draw=", result["wall_ms_through_post_draw"],
		" measured_frames=", measured_frames,
		" wall_frames=", frame_count,
		" pixel_readback=none")
	return result


func sample(label: String, physical_units: bool, settle_frames := 64,
		expect_atmosphere_snapshot := true) -> bool:
	# Plain Compositor has no deferred authored-property rebinding. Apply every
	# case so pre-exposure/metering edits reach both native and custom passes.
	_renderer.apply(_compositor)
	await settle(settle_frames)
	var image := _viewport.get_texture().get_image()
	var width := image.get_width()
	var height := image.get_height()
	# Project a known far-wall surface point instead of assuming a 4:3 window.
	# Desktop window managers may resize the requested 320x240 test window;
	# a fixed UV can then leave the finite wall or sample the near occluder.
	var fog_target := _far_wall_body.global_position + Vector3(-15.0, 15.0, 0.25)
	var fog_screen := _camera.unproject_position(fog_target)
	if not Rect2(Vector2.ZERO, Vector2(width, height)).has_point(fog_screen):
		push_error("Projected far-wall probe is outside the viewport: %s / %sx%s" % [fog_screen, width, height])
		return false
	var fog_x := roundi(fog_screen.x)
	var fog_y := roundi(fog_screen.y)
	var mesh_x := width / 2
	var mesh_y := height * 5 / 8
	var fog_pixel := image.get_pixel(fog_x, fog_y)
	var mesh_color := image.get_pixel(mesh_x, mesh_y)
	var sun_direction := _sun.global_transform.basis.z.normalized()
	var sample_point := Vector2(fog_x, fog_y)
	var ray_origin := _camera.project_ray_origin(sample_point)
	var ray_direction := _camera.project_ray_normal(sample_point)
	var away_ray_dot_sun := ray_direction.dot(sun_direction)
	var ray_query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_direction * 100.0)
	var ray_hit := _scene.get_world_3d().direct_space_state.intersect_ray(ray_query)
	if ray_hit.is_empty() or ray_hit.get("collider") != _far_wall_body:
		push_error("Fog sample ray must hit the far-wall geometry, got %s" % ray_hit.get("collider"))
		return false
	var ray_hit_distance := ray_origin.distance_to(ray_hit["position"])
	if ray_hit_distance <= _fog.start_distance + 10.0:
		push_error("Fog sample target is not beyond the fog start distance: %s m" % ray_hit_distance)
		return false
	var world_id := _scene.get_world_3d().get_instance_id()
	var snapshot := FengSkyRuntime.snapshot_for_world(world_id)
	var exposure_scale: float = await current_exposure_scale()
	var material := _sky.sky.sky_material as ShaderMaterial
	var solar_scale: float = material.get_shader_parameter("sun_irradiance")
	var expected_solar_scale := _sun.light_energy * (_sun.light_intensity_lux if physical_units else PI)
	if not is_equal_approx(solar_scale, expected_solar_scale):
		push_error("Sky solar scale mismatch: expected %s, got %s" % [expected_solar_scale, solar_scale])
		return false
	if expect_atmosphere_snapshot and snapshot.is_empty():
		push_error("Expected the active atmosphere provider snapshot for case %s" % label)
		return false
	if not expect_atmosphere_snapshot and not snapshot.is_empty():
		push_error("Fog-disabled atmosphere still published a provider snapshot for case %s" % label)
		return false
	if away_ray_dot_sun >= 0.0:
		push_error("Fog sample ray is not outside the sun lobe")
		return false
	if _fog.directional_inscattering_color != Color.BLACK:
		push_error("The GPU probe must keep the author directional lobe black")
		return false
	if luma(mesh_color) < 0.01:
		push_error("Near direct-lit geometry was tone-mapped to black")
		return false
	if physical_units and _sun.light_intensity_lux >= 60000.0 \
			and expect_atmosphere_snapshot and luma(fog_pixel) < 0.15:
		push_error("The 60k-lux away-sun fog pixel stayed too dark with atmosphere coupling enabled")
		return false
	if not is_finite(exposure_scale) or exposure_scale <= 0.0:
		push_error("The actual eye-adaptation exposure scale is invalid")
		return false
	var image_path := OUTPUT_DIR.path_join(label + ".png")
	var save_error := image.save_png(image_path)
	if save_error != OK:
		push_error("Could not save probe image %s: %s" % [image_path, save_error])
		return false
	_samples[label] = {
		"fog_pixel": fog_pixel,
		"fog_luma": luma(fog_pixel),
		"mesh_pixel": mesh_color,
		"mesh_luma": luma(mesh_color),
		"exposure_scale": exposure_scale,
		"ray_hit_distance": ray_hit_distance,
	}
	print("SKY GPU CASE ", label,
		" sun_lux=", _sun.light_intensity_lux,
		" sun_energy=", _sun.light_energy,
		" unit=", snapshot.get("sun_irradiance_unit", "missing"),
		" sky_solar_scale=", solar_scale,
		" sun_direction=", sun_direction,
		" away_sun_ray_dot=", away_ray_dot_sun,
		" ray_hit=far_wall",
		" ray_hit_distance_m=", ray_hit_distance,
		" ambient_radiance=", snapshot.get("ambient_radiance", Vector3.ZERO),
		" ground_illuminance=", snapshot.get("sun_ground_illuminance", Vector3.ZERO),
		" authored_fog_source=", _fog.snapshot_fields().get("fog_color"),
		" exposure_scale=", exposure_scale,
		" away_sun_fog_pixel=", fog_pixel,
		" away_sun_fog_sdr_luma=", luma(fog_pixel),
		" lit_mesh_pixel=", mesh_color,
		" lit_mesh_luma=", luma(mesh_color),
		" resolution=", image.get_size(),
		" png=", ProjectSettings.globalize_path(image_path),
		" save_error=", save_error)
	return true


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	# Keep measurement/image resolution independent of desktop window policies.
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(320, 240)
	_viewport.world_3d = World3D.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.use_taa = false
	root.add_child(_viewport)
	_scene = Node3D.new()
	_viewport.add_child(_scene)
	_camera = Camera3D.new()
	_camera.current = true
	_camera.position = Vector3(0.0, 1.5, 4.0)
	_camera.fov = 80.0
	_scene.add_child(_camera)
	_camera.look_at(Vector3(0.0, 2.0, -8.0), Vector3.UP)

	_sky = FengSkyAtmosphere.new()
	_sky.affect_height_fog = true
	_sky.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_scene.add_child(_sky)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	_sun.light_energy = 1.0
	_sun.light_intensity_lux = 6.0
	_sun.light_color = Color.WHITE
	_sun.light_temperature = 6500.0
	_sky.sun_light = _sun
	_scene.add_child(_sun)

	var wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(7.0, 2.0, 0.5)
	wall.mesh = wall_mesh
	wall.position = Vector3(0.0, 1.6, 0.0)
	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.42, 0.42, 0.42)
	wall_material.roughness = 1.0
	wall.material_override = wall_material
	_scene.add_child(wall)

	var far_wall := MeshInstance3D.new()
	var far_wall_mesh := BoxMesh.new()
	far_wall_mesh.size = Vector3(60.0, 40.0, 0.5)
	far_wall.mesh = far_wall_mesh
	far_wall.position = Vector3(0.0, 2.0, -30.0)
	var far_wall_material := StandardMaterial3D.new()
	far_wall_material.albedo_color = Color(0.36, 0.36, 0.36)
	far_wall_material.roughness = 1.0
	far_wall.material_override = far_wall_material
	_scene.add_child(far_wall)
	_far_wall_body = StaticBody3D.new()
	_far_wall_body.position = far_wall.position
	var far_wall_collision := CollisionShape3D.new()
	var far_wall_shape := BoxShape3D.new()
	far_wall_shape.size = far_wall_mesh.size
	far_wall_collision.shape = far_wall_shape
	_far_wall_body.add_child(far_wall_collision)
	_scene.add_child(_far_wall_body)

	var floor := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(30.0, 30.0)
	floor.mesh = floor_mesh
	floor.position = Vector3(0.0, 0.5, -5.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.3, 0.3, 0.3)
	floor_material.roughness = 1.0
	floor.material_override = floor_material
	_scene.add_child(floor)

	_fog = FengHeightFog.new()
	_fog.fog_density = 1.0
	_fog.fog_height_falloff = 0.001
	_fog.start_distance = 5.0
	_fog.fog_inscattering_color = Color(0.7162962, 0.7162962, 0.7162962)
	_fog.directional_inscattering_color = Color.BLACK
	_scene.add_child(_fog)

	var renderer_script := load("res://addons/feng-render-pipeline/renderer.gd")
	_renderer = renderer_script.new()
	_exposure_pass = find_pass("library:eye_adaptation")
	var fog_pass = find_pass("library:height_fog")
	if _exposure_pass == null or fog_pass == null:
		push_error("FRP library eye adaptation or height fog pass is missing")
		quit(2)
		return
	_exposure_pass.extend_default_luminance_range = true
	_exposure_pass.pre_exposure = true
	_exposure_pass.speed_up = 100.0
	_exposure_pass.speed_down = 100.0
	_compositor = Compositor.new()
	_camera.compositor = _compositor
	if not _renderer.get_validation_warnings().is_empty():
		push_error("FRP validation warnings: %s" % [_renderer.get_validation_warnings()])
		quit(2)
		return
	_renderer.apply(_compositor)
	var physical_units := bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))
	if physical_units:
		var low_ok: bool = await sample("atmosphere_6_lux_away_from_sun", true)
		if not low_ok:
			quit(2)
			return
		_sun.light_intensity_lux = 60000.0
		var high_ok: bool = await sample("atmosphere_60000_lux_away_from_sun", true)
		if not high_ok:
			quit(2)
			return
		_exposure_pass.metering_mode = 2 # Fixed EV100=0; isolate fog-source changes from metering.
		_exposure_pass.apply_physical_camera_exposure = false
		_exposure_pass.exposure_compensation = -12.0 # Fixed output scale 1/4096 avoids clipping both sides.
		var fixed_coupled_ok: bool = await sample(
			"atmosphere_60000_lux_fixed_exposure_fog_on", true)
		if not fixed_coupled_ok:
			quit(2)
			return
		var coupled_luma: float = _samples["atmosphere_60000_lux_fixed_exposure_fog_on"]["fog_luma"]
		_fog.enabled = false
		var fog_disabled_ok: bool = await sample(
			"atmosphere_60000_lux_fixed_exposure_height_fog_disabled", true)
		if not fog_disabled_ok:
			quit(2)
			return
		var fog_disabled_luma: float = _samples["atmosphere_60000_lux_fixed_exposure_height_fog_disabled"]["fog_luma"]
		_fog.enabled = true
		var coupled_color: Color = _samples["atmosphere_60000_lux_fixed_exposure_fog_on"]["fog_pixel"]
		var disabled_color: Color = _samples["atmosphere_60000_lux_fixed_exposure_height_fog_disabled"]["fog_pixel"]
		var fog_rgb_delta := Vector3(coupled_color.r, coupled_color.g, coupled_color.b).distance_to(
			Vector3(disabled_color.r, disabled_color.g, disabled_color.b))
		# Spectral atmosphere lighting can change hue strongly at similar luma.
		# Test visible RGB contribution instead of requiring an arbitrary luma drop.
		if fog_rgb_delta < 0.08:
			push_error("Height fog did not visibly change the ray-hit far-wall pixel")
			quit(2)
			return
		print("SKY GPU HEIGHT_FOG comparison enabled_sdr_luma=", coupled_luma,
			" disabled_sdr_luma=", fog_disabled_luma,
			" absolute_luma_delta=", absf(fog_disabled_luma - coupled_luma), " rgb_delta=", fog_rgb_delta)
		_sky.affect_height_fog = false
		var uncoupled_ok: bool = await sample(
			"atmosphere_60000_lux_fixed_exposure_fog_off", true, 64, false)
		if not uncoupled_ok:
			quit(2)
			return
		var uncoupled_luma: float = _samples["atmosphere_60000_lux_fixed_exposure_fog_off"]["fog_luma"]
		if uncoupled_luma >= coupled_luma - 0.08:
			push_error("Atmosphere coupling did not visibly brighten the away-sun fog pixel")
			quit(2)
			return
		print("SKY GPU FOG_COUPLING comparison enabled_sdr_luma=", coupled_luma,
			" disabled_sdr_luma=", uncoupled_luma,
			" ratio=", uncoupled_luma / maxf(coupled_luma, 0.000001))
		_sky.affect_height_fog = true
		_exposure_pass.pre_exposure = false
		var no_pre_exposure_ok: bool = await sample(
			"atmosphere_60000_lux_fixed_exposure_pre_exposure_off", true)
		if not no_pre_exposure_ok:
			quit(2)
			return
		var pre_exposure_on_pixel: Color = _samples["atmosphere_60000_lux_fixed_exposure_fog_on"]["fog_pixel"]
		var pre_exposure_off_pixel: Color = _samples["atmosphere_60000_lux_fixed_exposure_pre_exposure_off"]["fog_pixel"]
		var pre_exposure_delta := Vector3(
			pre_exposure_on_pixel.r - pre_exposure_off_pixel.r,
			pre_exposure_on_pixel.g - pre_exposure_off_pixel.g,
			pre_exposure_on_pixel.b - pre_exposure_off_pixel.b).length()
		if pre_exposure_delta > 0.08:
			push_error("Pre-exposure on/off changed the away-sun fog sample beyond tolerance: %s" % pre_exposure_delta)
			quit(2)
			return
		print("SKY GPU PREEXPOSURE comparison rgb_delta=", pre_exposure_delta,
			" exposure_on=", _samples["atmosphere_60000_lux_fixed_exposure_fog_on"]["exposure_scale"],
			" exposure_off=", _samples["atmosphere_60000_lux_fixed_exposure_pre_exposure_off"]["exposure_scale"])
	else:
		var normalized_ok: bool = await sample("atmosphere_nonphysical_energy_1", false)
		if not normalized_ok:
			quit(2)
			return
	# Compare the built-in model with the legacy sky in the same scene and pass
	# stack. These intervals deliberately avoid viewport readback so the timing
	# includes normal rendering without synchronous pixel extraction.
	await settle(60)
	var atmosphere_metrics: Dictionary = await measure_frame_metrics("built_in_atmosphere", 120)
	_sky.atmosphere_enabled = false
	await settle(60)
	var legacy_metrics: Dictionary = await measure_frame_metrics("legacy_physical_sky", 120)
	_sky.atmosphere_enabled = true
	await settle(60)
	var atmosphere_repeat_metrics: Dictionary = await measure_frame_metrics("built_in_atmosphere_repeat", 120)
	print("SKY GPU PASS resolution=", _viewport.size,
		" screen_ray_steps=", 8, " sun_path_mode=LUT_or_exact_extreme_fallback",
		" atmosphere_cache=", _sky.atmosphere_cache_stats(),
		" profile_frame_count=", 120,
		" atmosphere_process_ms=", atmosphere_metrics["process_ms"],
		" legacy_process_ms=", legacy_metrics["process_ms"],
		" atmosphere_repeat_process_ms=", atmosphere_repeat_metrics["process_ms"],
		" atmosphere_wall_ms=", atmosphere_metrics["wall_ms_through_post_draw"],
		" legacy_wall_ms=", legacy_metrics["wall_ms_through_post_draw"],
		" atmosphere_repeat_wall_ms=", atmosphere_repeat_metrics["wall_ms_through_post_draw"],
		" gpu_timer=unavailable_from_Performance_monitors")
	quit(0)
