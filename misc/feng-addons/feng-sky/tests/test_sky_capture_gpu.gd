extends SceneTree
## Run with --gpu-profile: production radiance-update timestamps identify actual
## rebuilds, while panorama readback checks cached reflection content.
const Atmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
var views: Array[SubViewport] = []
var skies: Array[FengSkyAtmosphere] = []
var cameras: Array[Camera3D] = []
var suns: Array[DirectionalLight3D] = []
var seen_frames: Dictionary = {}
var failed := false
signal timestamp_sample(frame: int, names: PackedStringArray)
func _initialize() -> void:
	call_deferred("run")
func require(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("REGRESSION: " + message)
func settle(frames: int) -> void:
	for i in frames:
		await process_frame
		await RenderingServer.frame_post_draw
func _read_timestamps() -> void:
	var rd := RenderingServer.get_rendering_device()
	var names := PackedStringArray()
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		if name.begins_with("Sky Radiance Update "):
			names.append(name)
	_deliver_timestamps.call_deferred(rd.get_captured_timestamps_frame(), names)
func _deliver_timestamps(frame: int, names: PackedStringArray) -> void:
	timestamp_sample.emit(frame, names)
func record(counts: Dictionary) -> void:
	RenderingServer.call_on_render_thread(_read_timestamps)
	var sample: Array = await timestamp_sample
	if seen_frames.has(sample[0]):
		return
	seen_frames[sample[0]] = true
	for name in sample[1]:
		counts[name] = counts.get(name, 0) + 1
func count_for(counts: Dictionary, index: int) -> int:
	return counts.get("Sky Radiance Update %d" % skies[index].sky.get_rid().get_id(), 0)
func panorama(index: int) -> Image:
	return RenderingServer.sky_bake_panorama(skies[index].sky.get_rid(), 1.0, false, Vector2i(64,32))
func difference(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return INF
	var delta := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x,y)
			var q := b.get_pixel(x,y)
			delta += Vector3(p.r-q.r,p.g-q.g,p.b-q.b).length_squared()
	return sqrt(delta / (3.0*a.get_width()*a.get_height()))
func phase(label: String, action: Callable, expect_a: bool, expect_b: bool) -> void:
	await settle(8)
	await record({})
	var counts: Dictionary = {}
	for frame in 20:
		action.call(frame)
		await settle(1)
		await record(counts)
	await settle(4)
	await record(counts)
	var a := count_for(counts,0)
	var b := count_for(counts,1)
	print("SKY CAPTURE COUNTS ", label, " world_a=",a," world_b=",b)
	require(a >= 12 if expect_a else a == 0, label + " wrong world A radiance rebuild count")
	require(b >= 12 if expect_b else b == 0, label + " wrong world B radiance rebuild count")
func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var physical_units := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	for index in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(64,64)
		viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		views.append(viewport)
		var camera := Camera3D.new()
		camera.position = Vector3(0.0,2.0,0.0)
		viewport.add_child(camera)
		camera.current = true
		camera.look_at(camera.position + Vector3(0.0,0.4,1.0),Vector3.UP)
		cameras.append(camera)
		var sun := DirectionalLight3D.new()
		sun.light_intensity_lux = 60000.0
		sun.light_energy = 1.0 if physical_units else 60000.0 / PI
		sun.rotation_degrees = Vector3(-45.0,0.0,0.0)
		viewport.add_child(sun)
		suns.append(sun)
		var sky := Atmosphere.new()
		sky.affect_height_fog = false
		sky.sun_light = sun
		viewport.add_child(sky)
		skies.append(sky)
		var renderer = load("res://addons/feng-render-pipeline/renderer.gd").new()
		for entry in renderer.passes:
			if entry.stable_id == "library:eye_adaptation":
				entry.metering_mode = 2
				entry.apply_physical_camera_exposure = false
				entry.exposure_compensation = -12.0
		var compositor := Compositor.new()
		camera.compositor = compositor
		renderer.apply(compositor)
	await settle(24)
	var reference := panorama(0)
	require(reference != null and not reference.is_empty(), "radiance panorama readback unavailable")
	await phase("fixed_camera_motion",func(i):
		cameras[0].position.x = float(i)
		cameras[1].position.x = -float(i), false, false)
	require(difference(reference, panorama(0)) == 0.0, "camera motion changed fixed-capture reflection content")
	await phase("sun_motion",func(i): suns[0].rotation_degrees.x = -20.0-float(i), true, false)
	require(difference(reference, panorama(0)) > 0.01, "sun movement did not refresh radiance")
	await phase("capture_origin_motion",func(i): skies[0].radiance_capture_position.y = float(i)*1000.0, true, false)
	var elevated := panorama(0)
	require(difference(reference, elevated) > 0.01, "capture altitude did not change reflection content")
	skies[0].radiance_follow_camera = true
	await phase("camera_follow",func(i): cameras[0].position.x = 100.0+float(i), true, false)
	skies[0].radiance_follow_camera = false
	await phase("camera_follow_disabled",func(i): cameras[0].position.x = 200.0+float(i), false, false)
	var before_space := views[0].get_texture().get_image()
	cameras[0].position.y = 80000.0
	await settle(16)
	var after_space := views[0].get_texture().get_image()
	require(difference(before_space,after_space) > 0.01, "visible sky stopped following actual camera altitude")
	require(difference(elevated,panorama(0)) == 0.0, "ground-to-space view silently changed authored radiance origin")
	# An optical edit must refresh just the edited world's map.
	await phase("optical_settings",func(i): skies[0].rayleigh_scattering_scale = 0.5+float(i)*0.04, true, false)
	for viewport in views:
		viewport.free()
	await process_frame
	if not failed:
		print("SKY CAPTURE GPU PASS")
	quit(1 if failed else 0)
