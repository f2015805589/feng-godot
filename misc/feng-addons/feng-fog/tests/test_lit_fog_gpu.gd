extends SceneTree
## Rendered lit-albedo regression. Uses a fixed-size isolated viewport so desktop
## window placement, saved editor state and resolution cannot change metering.
const Fog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const SkyNode = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
var viewport: SubViewport
var scene: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var fog: FengHeightFog
var sky: FengSkyAtmosphere
var exposure: FengEyeAdaptationPass
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
	var folder := "res://lit_fog_images"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	require(image.save_png(folder.path_join(label + ".png")) == OK, "could not save " + label)
	var colors: Array[Color] = []
	for point in points:
		colors.append(image.get_pixelv(point))
	for snapshot in FogRuntime.snapshots():
		if snapshot.get("world_id") == scene.get_world_3d().get_instance_id():
			print("LIT FOG GPU ", label, " source=", snapshot.get("fog_color"),
				" lobe=", snapshot.get("inscattering_color"), " pixels=", colors)
	return colors

func distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

func red(colors: Array[Color], label: String) -> void:
	for color in colors:
		require(color.r > 0.25 and color.r > color.g * 2.0 and color.r > color.b * 2.0,
			label + " lost the red material color: " + str(color))

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
	fog.fog_inscattering_color = Color(0.8, 0.08, 0.03)
	fog.fog_density = 2.0
	fog.fog_height_falloff = 0.001
	fog.directional_inscattering_color = Color.BLACK
	fog.directional_inscattering_start_distance = 0.0
	fog.sun_light = sun
	scene.add_child(fog)
	# Identical black surfaces isolate fog in deferred opaque, forward fallback,
	# and transparent shading. They must all use the same scene-linear source.
	for i in 3:
		var card := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(8.0, 14.0)
		card.mesh = mesh
		card.position = Vector3((i - 1) * 10.0, 2.0, -40.0)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color.BLACK
		if i > 0:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if i == 2:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		card.material_override = material
		scene.add_child(card)
		points.append(Vector2i(camera.unproject_position(card.global_position)))
	var renderer := FengRenderer.new()
	for entry in renderer.passes:
		if entry.stable_id == &"library:eye_adaptation":
			exposure = entry
			exposure.extend_default_luminance_range = true
			exposure.speed_up = 100.0
			exposure.speed_down = 100.0
			exposure.exposure_compensation = -1.0
		elif entry.stable_id in [&"native:6", &"library:magic_gi", &"library:color_grade"]:
			entry.enabled = false
	var compositor := FengCompositor.new()
	compositor.renderer = renderer
	camera.compositor = compositor
	require(renderer.get_validation_warnings().is_empty(), "pipeline validation failed")
	var physical := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var low := await capture("lit_6")
	red(low, "low light")
	if physical:
		sun.light_intensity_lux = 60000.0
	else:
		sun.light_energy = 10000.0
	var high := await capture("lit_60000")
	red(high, "high light")
	for i in high.size():
		require(distance(low[i], high[i]) < 0.08,
			"auto-exposed color changed over a 10000x light range: %s -> %s" % [low[i], high[i]])
	# The rendering paths agree at equal depth (a small geometric ray-length
	# difference is allowed). Transparent does not use the opaque buffer depth.
	for i in range(1, high.size()):
		require(distance(high[0], high[i]) < 0.04, "fog differs between material rendering paths")
	# This control documents the original failure: fixed source + untinted sky
	# loses the red hue. It is deliberately still available as an explicit mode.
	fog.fog_color_mode = Fog.ColorMode.LEGACY_RADIANCE
	var legacy := await capture("legacy_60000")
	require(legacy[0].b > legacy[0].r, "legacy control no longer reproduces the fixed-radiance tint loss")
	fog.fog_color_mode = Fog.ColorMode.LIT
	# Fixed exposure removes adaptation from the pre-exposure comparison.
	exposure.metering_mode = 2
	exposure.apply_physical_camera_exposure = false
	exposure.exposure_compensation = -12.0
	var pre_on := await capture("lit_fixed_pre_on")
	exposure.pre_exposure = false
	var pre_off := await capture("lit_fixed_pre_off")
	for i in pre_on.size():
		require(distance(pre_on[i], pre_off[i]) < 0.04, "lit fog applied pre-exposure incorrectly")
	# No atmospheric provider still has correctly colored direct-light scattering.
	exposure.metering_mode = 0
	exposure.pre_exposure = true
	exposure.exposure_compensation = -1.0
	sky.affect_height_fog = false
	red(await capture("lit_no_sky_provider"), "direct-only fog")
	# With the optional lobe disabled, base material color also survives looking toward the sun.
	camera.look_at(camera.position + sun.global_basis.z, Vector3.UP)
	points = [Vector2i(160, 120)]
	red(await capture("lit_sun_facing_base"), "sun-facing base")
	fog.fog_inscattering_color = Color.BLACK
	var black := await capture("lit_black_albedo")
	require(black[0].r < 0.03 and black[0].g < 0.03 and black[0].b < 0.03,
		"black albedo emitted light")
	# White body regression at the actual failing sun direction: horizontal.
	# The atmosphere publishes zero ground irradiance here. Check brightness,
	# neutral color and a no-fog baseline, not only colored-fog chromaticity.
	sky.affect_height_fog = true
	sun.rotation_degrees = Vector3.ZERO
	fog.fog_inscattering_color = Color.WHITE
	for yaw in [0.0, 90.0, 180.0]:
		camera.rotation_degrees = Vector3(0.0, yaw, 0.0)
		var white_low: Array[Color] = []
		for high_light in [false, true]:
			sun.light_intensity_lux = 60000.0 if high_light else 6.0
			sun.light_energy = (10000.0 if high_light else 1.0) if not physical else 1.0
			var label := "white_%s_%s" % [60000 if high_light else 6, int(yaw)]
			var white := await capture(label)
			var c := white[0]
			require(minf(c.r, minf(c.g, c.b)) > 0.3,
				label + " lost visible white fog body: " + str(c))
			require(maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.1,
				label + " turned the white base into colored haze: " + str(c))
			if not high_light:
				white_low = white
			else:
				require(distance(white_low[0], white[0]) < 0.08,
					"white fog changed over the 10000x lighting range")
	# Center card is black, so removing the fog must remove the visible body.
	camera.rotation_degrees = Vector3.ZERO
	fog.enabled = false
	var no_fog := await capture("white_no_fog_control")
	require(no_fog[0].r < 0.03 and no_fog[0].g < 0.03 and no_fog[0].b < 0.03,
		"white body test did not isolate fog from its surface")
	fog.enabled = true
	# Independent orange lobe overlays the white body only toward the sun.
	camera.rotation_degrees.y = 180.0
	fog.directional_inscattering_color = Color(0.9, 0.33, 0.0)
	var orange_low: Array[Color] = []
	for high_light in [false, true]:
		sun.light_intensity_lux = 60000.0 if high_light else 6.0
		sun.light_energy = (10000.0 if high_light else 1.0) if not physical else 1.0
		fog.fog_inscattering_color = Color.WHITE
		var suffix := "60000" if high_light else "6"
		var white_with_orange := await capture("white_with_orange_lobe_" + suffix)
		fog.fog_inscattering_color = Color.BLACK
		var independent_orange := await capture("black_base_orange_lobe_" + suffix)
		require(independent_orange[0].r > 0.3 and independent_orange[0].r > independent_orange[0].b * 2.0,
			"black base incorrectly disabled or recolored the independent orange lobe")
		require(white_with_orange[0].r > white_with_orange[0].b + 0.05,
			"orange directional color was lost on the white base")
		if not high_light:
			orange_low = white_with_orange
		else:
			require(distance(orange_low[0], white_with_orange[0]) < 0.08,
				"white base plus orange lobe changed over the 10000x lighting range")

	if not failed:
		print("PASS lit fog GPU: 6/60000 intensity, hue, deferred/fallback/transparent, pre-exposure, no-sky, white horizon body and independent orange lobe")
	quit(1 if failed else 0)
