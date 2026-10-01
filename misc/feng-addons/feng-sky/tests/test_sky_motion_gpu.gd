extends SceneTree
## End-to-end motion regression through a fresh default FRP schedule, followed
## by an explicitly labeled TAA-disabled control using that same local pipeline.
## Read only a small sun-centered region every fourth moving frame. The separate
## numerical probe covers raw float32 values; this detects postprocess blackouts.
const Atmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const OUTPUT_DIR := "user://sky_motion_probe"
var _failed := false
var _viewport: SubViewport
var _camera: Camera3D
var _sun: DirectionalLight3D
var _sky: FengSkyAtmosphere
var _renderer
var _exposure
var _captures := 0
signal exposure_sample_ready(scale: float)


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("REGRESSION: " + message)


func settle(frames: int) -> void:
	for _frame in frames:
		await process_frame
		await RenderingServer.frame_post_draw


func find_pass(stable_id: String):
	for entry in _renderer.passes:
		if entry != null and entry.stable_id == stable_id:
			return entry
	return null


func exposure_scale() -> float:
	RenderingServer.call_on_render_thread(_read_exposure_scale)
	return await exposure_sample_ready


func _read_exposure_scale() -> void:
	# A plain Compositor binds the authored effects directly. Read its active
	# eye-adaptation state on the render thread, which owns the RD buffers.
	var scale := NAN
	var states: Dictionary = _exposure.get("_state")
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for state in states.values():
			var views: Dictionary = state.get("views", {})
			if not views.has(0):
				continue
			var params: RID = views[0].get("params", RID())
			if params.is_valid():
				var values := rd.buffer_get_data(params).to_float32_array()
				if values.size() > 129:
					scale = values[129]
					break
	_deliver_exposure_scale.call_deferred(scale)


func _deliver_exposure_scale(scale: float) -> void:
	exposure_sample_ready.emit(scale)


func sample_sun(label: String, save_image: bool) -> void:
	var image := _viewport.get_texture().get_image()
	var direction := _sun.global_transform.basis.z.normalized()
	var sun_pixel := Vector2i(_camera.unproject_position(_camera.global_position + direction * 1000.0).floor())
	require(sun_pixel.x >= 2 and sun_pixel.y >= 2 and sun_pixel.x < image.get_width() - 2
		and sun_pixel.y < image.get_height() - 2, "motion fixture lost its tracked solar region")
	if _failed:
		return
	var minimum_luma := INF
	var maximum_luma := 0.0
	for y in range(sun_pixel.y - 2, sun_pixel.y + 3):
		for x in range(sun_pixel.x - 2, sun_pixel.x + 3):
			var color := image.get_pixel(x, y)
			require(is_finite(color.r) and is_finite(color.g) and is_finite(color.b),
				"non-finite framebuffer value around the moving sun: " + label)
			var luminance := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			minimum_luma = minf(minimum_luma, luminance)
			maximum_luma = maxf(maximum_luma, luminance)
	# These rays are entirely sun/corona in a daylight, one-degree sky-only view.
	# None should become black as the sun, camera, TAA or exposure history moves.
	require(minimum_luma > 0.01 and maximum_luma > 0.05,
		"black solar framebuffer region in %s: min=%s max=%s" % [label, minimum_luma, maximum_luma])
	var scale: float = await exposure_scale()
	require(is_finite(scale) and scale > 0.0, "non-finite eye-adaptation scale in " + label)
	if save_image or _failed:
		require(image.save_png(OUTPUT_DIR.path_join(label + ".png")) == OK, "could not save motion probe image")
	_captures += 1
	print("SKY MOTION GPU ", label, " pixel=", sun_pixel, " luma_min=", minimum_luma,
		" luma_max=", maximum_luma, " exposure=", scale)


func run() -> void:
	require(RenderingServer.get_current_rendering_method() == "frp", "sky motion probe requires the Feng FRP renderer")
	if _failed:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(129, 129)
	_viewport.world_3d = World3D.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var scene := Node3D.new()
	_viewport.add_child(scene)
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 1.0
	_camera.position = Vector3(0.0, 2.0, 0.0)
	scene.add_child(_camera)
	_sky = Atmosphere.new()
	_sky.affect_height_fog = false
	scene.add_child(_sky)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	scene.add_child(_sun)
	_sky.sun_light = _sun
	_camera.look_at(_camera.position + _sun.global_transform.basis.z, Vector3.UP)
	_renderer = load("res://addons/feng-render-pipeline/renderer.gd").new()
	_exposure = find_pass("library:eye_adaptation")
	require(_exposure != null, "default FRP schedule has no eye-adaptation pass")
	if _failed:
		quit(1)
		return
	var enabled_passes := 0
	for entry in _renderer.passes:
		if entry != null and entry.enabled:
			enabled_passes += 1
	require(enabled_passes == 13, "motion regression must keep the default 13 enabled passes")
	_exposure.extend_default_luminance_range = true
	_exposure.speed_up = 100.0
	_exposure.speed_down = 100.0
	var compositor := Compositor.new()
	_camera.compositor = compositor
	_renderer.apply(compositor)
	require(_renderer.get_validation_warnings().is_empty(), "default FRP motion pipeline failed validation")
	var physical_units := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var temporal_aa = find_pass("native:6")
	require(temporal_aa != null, "default FRP schedule has no native Temporal AA pass")
	if _failed:
		_viewport.free()
		quit(1)
		return
	var case_index := 0
	# First eight cases retain all 13 enabled defaults. The last four are an
	# isolated 12-pass control with only the local native TAA entry disabled.
	for mode in [Vector2i(1, 1), Vector2i(0, 1), Vector2i(1, 0)]:
		_exposure.pre_exposure = bool(mode.x)
		temporal_aa.enabled = bool(mode.y)
		_renderer.apply(compositor)
		require(_renderer.get_validation_warnings().is_empty(), "motion control pipeline failed validation")
		for irradiance in [60000.0, 10000000.0]:
			_sun.light_intensity_lux = irradiance
			_sun.light_energy = 1.0 if physical_units else irradiance / PI
			for radius_deg in [0.01, 0.2666]:
				_sky.sun_angular_radius_deg = radius_deg
				await settle(16)
				var label := "case_%02d_lux_%d_radius_%s_pre_%d_taa_%d" % [case_index, int(irradiance), radius_deg, mode.x, mode.y]
				for moving_frame in 12:
					var phase := float(case_index * 12 + moving_frame)
					_sun.rotation_degrees = Vector3(-35.0 - 10.0 * sin(phase * 0.13), phase * 3.0, 0.0)
					_camera.position = Vector3(phase * 1.25, 2.0 + 0.5 * sin(phase * 0.31), -phase * 0.8)
					var sun_direction := _sun.global_transform.basis.z.normalized()
					var tangent := sun_direction.cross(Vector3.UP).normalized()
					# Sweep the disk across the image while translating and rotating.
					var view := (sun_direction + tangent * tan(deg_to_rad(0.15 * sin(phase * 0.65)))).normalized()
					_camera.look_at(_camera.position + view * 1000.0, Vector3.UP)
					await settle(1)
					if moving_frame % 4 == 3:
						await sample_sun(label + "_frame_%02d" % moving_frame, moving_frame == 11)
						if _failed:
							_viewport.free()
							quit(1)
							return
				case_index += 1
	_viewport.free()
	await process_frame
	if not _failed:
		print("SKY MOTION GPU PASS cases=", case_index, " captures=", _captures,
			" sampled_pixels_per_capture=", 25, " default_enabled_passes=", enabled_passes,
			" taa_disabled_control_enabled_passes=", enabled_passes - 1,
			" image_dir=", ProjectSettings.globalize_path(OUTPUT_DIR))
	quit(1 if _failed else 0)
