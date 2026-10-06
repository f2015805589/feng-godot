extends SceneTree
## Fixed-exposure GPU contracts for Unreal-style exponential height fog.

const Fog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const SkyNode = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")

var viewport: SubViewport
var scene: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var fog: FengHeightFog
var sky: FengSkyAtmosphere
var exposure: FengEyeAdaptationPass
var materials: Array[StandardMaterial3D] = []
var points: Array[Vector2i] = []
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)


func settle() -> void:
	for i in 48:
		await process_frame
		await RenderingServer.frame_post_draw


func capture(label: String) -> Array[Color]:
	await settle()
	var image := viewport.get_texture().get_image()
	var folder := "res://height_fog_images"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	require(image.save_png(folder.path_join(label + ".png")) == OK, "could not save " + label)
	var colors: Array[Color] = []
	for point in points:
		colors.append(image.get_pixelv(point))
	for snapshot in FogRuntime.snapshots():
		if snapshot.get("world_id") == scene.get_world_3d().get_instance_id():
			print("HEIGHT FOG GPU ", label, " source=", snapshot.get("fog_color"),
				" lobe=", snapshot.get("inscattering_color"), " pixels=", colors)
	return colors


func distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


func finite_color(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b)


func red(colors: Array[Color], label: String) -> void:
	for color in colors:
		require(color.r > 0.25 and color.r > color.g * 2.0 and color.r > color.b * 2.0,
			label + " lost the authored red radiance: " + str(color))


func run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(320, 240)
	viewport.world_3d = World3D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	scene = Node3D.new()
	viewport.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 2.0, 0.0)
	camera.current = true
	camera.far = 10000.0
	scene.add_child(camera)
	sky = SkyNode.new()
	scene.add_child(sky)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	sun.light_intensity_lux = 6.0
	sun.light_energy = 1.0
	scene.add_child(sun)
	sky.sun_light = sun
	fog = Fog.new()
	require(fog.fog_inscattering_color == Color.BLACK,
		"new fog must default to a black authored source while retaining extinction")
	fog.fog_density = 2.0
	fog.fog_height_falloff = 0.001
	fog.directional_inscattering_color = Color.BLACK
	fog.directional_inscattering_start_distance = 0.0
	scene.add_child(fog)

	# Identical black, zero-specular cards isolate fog in deferred opaque,
	# unshaded fallback, and transparent material paths.
	for i in 3:
		var card := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(8.0, 14.0)
		card.mesh = mesh
		card.position = Vector3((i - 1) * 10.0, 2.0, -40.0)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color.BLACK
		# Remove default specular reflection so this fixture isolates fog.
		material.metallic_specular = 0.0
		if i > 0:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if i == 2:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		card.material_override = material
		scene.add_child(card)
		materials.append(material)
		points.append(Vector2i(camera.unproject_position(card.global_position)))

	var renderer := FengRenderer.new()
	for entry in renderer.passes:
		if entry.stable_id == &"library:eye_adaptation":
			exposure = entry
			exposure.metering_mode = 2
			exposure.apply_physical_camera_exposure = false
			exposure.pre_exposure = false
			exposure.exposure_compensation = -1.0
		elif entry.stable_id in [&"native:6", &"library:magic_gi", &"library:color_grade"]:
			entry.enabled = false
	var compositor := FengCompositor.new()
	compositor.renderer = renderer
	camera.compositor = compositor
	require(renderer.get_validation_warnings().is_empty(), "pipeline validation failed")

	# A fixed manual exposure makes this a source-unit contract, not an
	# auto-metering comparison. The authored base must not change with sun energy.
	sky.affect_height_fog = false
	fog.fog_inscattering_color = Color(0.8, 0.08, 0.03)
	var source_low := await capture("raw_base_6lux_fixed_exposure")
	red(source_low, "fixed-exposure authored source")
	var physical := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	if physical:
		sun.light_intensity_lux = 60000.0
	else:
		sun.light_energy = 10000.0
	var source_high := await capture("raw_base_high_sun_fixed_exposure")
	red(source_high, "high-sun authored source")
	for i in source_low.size():
		require(distance(source_low[i], source_high[i]) < 0.04,
			"raw authored fog source changed with direct-light energy at fixed exposure")
	for i in range(1, source_high.size()):
		require(distance(source_high[0], source_high[i]) < 0.04,
			"fog differs between deferred, unshaded, and transparent paths at equal depth")
	var raw_snapshot: Dictionary = {}
	for snapshot in FogRuntime.snapshots():
		if snapshot.get("world_id") == scene.get_world_3d().get_instance_id():
			raw_snapshot = snapshot
	require(raw_snapshot.get("fog_color") == Vector3(0.8, 0.08, 0.03)
		and not raw_snapshot.has("fog_albedo"),
		"the GPU snapshot must retain raw authored RGB without a material albedo field")

	# The same fixed camera exposure must produce equivalent output with and
	# without the height-fog pass's pre-exposure compensation.
	exposure.pre_exposure = true
	var pre_on := await capture("fixed_pre_exposure_on")
	exposure.pre_exposure = false
	var pre_off := await capture("fixed_pre_exposure_off")
	for i in pre_on.size():
		require(distance(pre_on[i], pre_off[i]) < 0.04,
			"height fog applied pre-exposure more than once or omitted it")
	# With a black default source, fog changes transmission without emitting
	# arbitrary radiance. White receivers make the extinction visible.
	for material in materials:
		material.albedo_color = Color.WHITE
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fog.fog_inscattering_color = Color.BLACK
	fog.directional_inscattering_color = Color.BLACK
	fog.fog_density = 2.0
	fog.fog_height_falloff = 0.001
	fog.enabled = false
	var no_fog := await capture("white_receiver_no_fog")
	fog.enabled = true
	var black_source_fog := await capture("white_receiver_black_source_fog")
	for i in black_source_fog.size():
		require(finite_color(no_fog[i]) and finite_color(black_source_fog[i])
			and distance(black_source_fog[i], Color.BLACK) < distance(no_fog[i], Color.BLACK),
			"black authored source must attenuate receiver without nonblack in-scattering")

	# Compare clear sky with the active fog at a fixed exposure and a grazing
	# 60000-lux atmosphere sun. This specifically exercises ground attenuation.
	sky.affect_height_fog = true
	sun.rotation_degrees = Vector3(-0.25, 0.0, 0.0)
	sun.light_intensity_lux = 60000.0
	sun.light_energy = 1.0 if physical else 60000.0 / PI
	fog.fog_density = 0.02
	fog.fog_height_falloff = 0.2
	exposure.metering_mode = 2
	exposure.apply_physical_camera_exposure = false
	exposure.pre_exposure = false
	exposure.exposure_compensation = -12.0
	camera.rotation_degrees = Vector3(0.0, 180.0, 0.0)
	await process_frame
	var world_sun_direction := sun.global_transform.basis.z.normalized()
	var sun_screen_position := camera.unproject_position(camera.global_position + world_sun_direction * 1000.0)
	var sun_pixel := Vector2i(roundi(sun_screen_position.x), roundi(sun_screen_position.y))
	var horizon_pixel := Vector2i(160, 122)
	points = [sun_pixel, horizon_pixel]
	fog.enabled = false
	var sky_only := await capture("low_sun_sky_only_fixed_exposure")
	fog.enabled = true
	var fog_on := await capture("low_sun_fog_on_fixed_exposure")
	var low_sun_snapshot := FengSkyRuntime.snapshot_for_world(scene.get_world_3d().get_instance_id())
	var ground: Vector3 = low_sun_snapshot.get("sun_ground_illuminance", Vector3.ZERO)
	var top := sky._sun_linear_color(sun) * sky._sun_irradiance(sun)
	var transmission := ground.dot(Vector3(0.2126, 0.7152, 0.0722)) \
		/ maxf(top.dot(Vector3(0.2126, 0.7152, 0.0722)), 0.000001)
	var ray := camera.project_ray_normal(Vector2(horizon_pixel))
	var separation := acos(clampf(ray.dot(world_sun_direction), -1.0, 1.0))
	var sky_horizon_peak := maxf(sky_only[1].r, maxf(sky_only[1].g, sky_only[1].b))
	var fog_horizon_peak := maxf(fog_on[1].r, maxf(fog_on[1].g, fog_on[1].b))
	require(sun_screen_position.x >= 0.0 and sun_screen_position.x < viewport.size.x
		and sun_screen_position.y >= 0.0 and sun_screen_position.y < viewport.size.y,
		"low-sun disk projected outside the fixed GPU viewport")
	require(finite_color(sky_only[0]) and finite_color(sky_only[1])
		and finite_color(fog_on[0]) and finite_color(fog_on[1]),
		"fixed-exposure low-sun sky/fog samples contain non-finite display values")
	require(world_sun_direction.y > 0.0 and world_sun_direction.y < 0.01
		and transmission > 0.0 and transmission < 0.5,
		"GPU low-sun case did not preserve top source with attenuated ground illuminance")
	require(separation > deg_to_rad(sky.sun_angular_radius_deg * 1.5),
		"horizon sample fell inside the solar disk rather than measuring adjacent sky")
	require(sky_horizon_peak < 0.99,
		"fixed-exposure sky-only horizon adjacent to the solar disk saturated")
	require(fog_horizon_peak < 0.99,
		"fixed-exposure low-sun Fog-on horizon saturated; check post-transmittance source")
	print("LOW SUN GPU physical_units=", physical,
		" direction=", world_sun_direction, " sun_pixel=", sun_pixel,
		" horizon_pixel=", horizon_pixel, " disk_sky=", sky_only[0], " disk_fog=", fog_on[0],
		" adjacent_sky=", sky_only[1], " adjacent_fog=", fog_on[1],
		" adjacent_to_sun_deg=", rad_to_deg(separation), " top_source=", top,
		" ground_source=", ground, " ground_to_top_luma=", transmission,
		" exposure=manual_2^-12 pre_exposure=false")

	if not failed:
		print("PASS Unreal height fog GPU: raw radiance, fixed exposure, transmission, pre-exposure, three material paths, and low-sun ground attenuation")
	quit(1 if failed else 0)
