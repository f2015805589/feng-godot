extends SceneTree

# The seeded Eye Adaptation pass meters the scene before tone mapping, and
# uses the previous completed exposure to pre-expose the next frame.
#
# This suite proves the metering actually converges in both directions: a
# bright scene is exposed DOWN towards the scale target and a dark scene is
# exposed UP, and the result stays stable once converged.

var scene: Node3D
var camera: Camera3D
var renderer
var ea_pass

const CENTER := Vector2i(160, 120)


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)


func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _initialize() -> void:
	call_deferred("run")


func _make_scene(brightness: float) -> void:
	if scene != null:
		scene.queue_free()
		await process_frame
	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 3.0)
	scene.add_child(camera)
	camera.current = true

	var sphere := MeshInstance3D.new()
	sphere.mesh = SphereMesh.new()
	scene.add_child(sphere)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, 0.4, 0.0)
	light.light_energy = brightness
	scene.add_child(light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0)
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	renderer = renderer_script.new()
	var compositor := Compositor.new()
	camera.compositor = compositor
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "the default pipeline must validate clean: %s" % [renderer.get_validation_warnings()])


func _set_eye_adaptation(extend = null) -> void:
	# The seeded pipeline already carries the library entry: drive it rather
	# than stacking a second metering pass. extend == null disables the pass.
	ea_pass = null
	for pass_entry in renderer.passes:
		if pass_entry != null and pass_entry.stable_id == &"library:eye_adaptation":
			ea_pass = pass_entry
			break
	require(ea_pass != null, "the seeded pipeline must carry the Eye Adaptation pass")
	var authored: Dictionary = ea_pass.get_frp_parameters()
	require(authored.has("pre_exposure") and authored.has("extend_default_luminance_range"),
			"both global switches must be exported by the Eye Adaptation pass")
	for property in renderer.get_property_list():
		require(property.name != "pre_exposure" and property.name != "extend_default_luminance_range",
				"exposure switches must not appear at the Renderer root")
	require(not ea_pass.get_volume_parameter_names().has("pre_exposure")
			and not ea_pass.get_volume_parameter_names().has("extend_default_luminance_range"),
			"the two global switches belong to the pass, outside the Volume schema")
	ea_pass.enabled = extend != null
	if extend != null:
		ea_pass.extend_default_luminance_range = extend
	renderer.apply(camera.compositor)


func run() -> void:
	print("START FRP eye adaptation tests")
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false

	# Bright scene: exposure must fold the frame DOWN towards the scale target.
	await _make_scene(16.0)
	_set_eye_adaptation()
	var bright_off := (await frame()).get_pixelv(CENTER)
	_set_eye_adaptation(true)
	var bright_first := (await frame()).get_pixelv(CENTER)
	var bright_settled := (await frame()).get_pixelv(CENTER)
	print("bright off=%s first=%s settled=%s" % [bright_off, bright_first, bright_settled])
	require(bright_settled.get_luminance() < bright_off.get_luminance() - 0.05,
			"bright scene must be exposed down: off=%s settled=%s" % [bright_off, bright_settled])
	require(absf(bright_settled.get_luminance() - bright_first.get_luminance()) < 0.15,
			"exposure must be temporally stable once converged: first=%s settled=%s" % [bright_first, bright_settled])
	require(bright_settled.get_luminance() > 0.4,
			"folded output must sit near the scale target, not black: settled=%s" % [bright_settled])

	# Dark scene: exposure must fold the frame UP.
	await _make_scene(0.02)
	_set_eye_adaptation()
	var dark_off := (await frame()).get_pixelv(CENTER)
	_set_eye_adaptation(true)
	var dark_settled := (await frame()).get_pixelv(CENTER)
	print("dark off=%s settled=%s" % [dark_off, dark_settled])
	require(dark_settled.get_luminance() > dark_off.get_luminance() + 0.05,
			"dark scene must be exposed up: off=%s settled=%s" % [dark_off, dark_settled])

	# The defining property of pre-exposure: once converged, the same scene at
	# wildly different absolute energies displays identically (UE's promise)
	# as long as the metered luminance stays inside the metering range.
	await _make_scene(6.0)
	_set_eye_adaptation(true)
	await frame()
	var energy6 := (await frame()).get_pixelv(CENTER)
	await _make_scene(600.0)
	_set_eye_adaptation(true)
	await frame()
	var energy600 := (await frame()).get_pixelv(CENTER)
	print("energy6=%s energy600=%s" % [energy6, energy600])
	require(energy6.get_luminance() > 0.4 and energy6.get_luminance() < 0.99,
			"converged output must sit near the scale target: %s" % [energy6])
	require(absf(energy6.get_luminance() - energy600.get_luminance()) < 0.08,
			"converged output must be energy-invariant: 6=%s 600=%s" % [energy6, energy600])
	ea_pass.pre_exposure = false
	renderer.apply(camera.compositor)
	await frame()
	var no_pre_exposure := (await frame()).get_pixelv(CENTER)
	require(absf(no_pre_exposure.get_luminance() - energy600.get_luminance()) < 0.08,
			"disabling pre-exposure must preserve final image exposure: %s vs %s" % [no_pre_exposure, energy600])
	ea_pass.pre_exposure = true
	renderer.apply(camera.compositor)
	await _make_scene(60000.0)
	_set_eye_adaptation(true)
	for i in 16:
		await frame()
	var extreme_energy := (await frame()).get_pixelv(CENTER)
	require(absf(extreme_energy.get_luminance() - energy600.get_luminance()) < 0.08,
			"pre-exposure must protect bright light accumulation: %s vs %s" % [extreme_energy, energy600])

	# UE's Extend toggle: with the legacy [-8, 4] log2 metering range the same
	# bright scene saturates the histogram and stays over-exposed.
	await _make_scene(600.0)
	_set_eye_adaptation(false)
	await frame()
	var unextended := (await frame()).get_pixelv(CENTER)
	print("unextended=%s extended=%s" % [unextended, energy600])
	require(unextended.get_luminance() > energy600.get_luminance() + 0.02,
			"without the extended range the frame must stay over-exposed: %s vs %s" % [unextended, energy600])
	ea_pass.extend_default_luminance_range = true
	ea_pass.metering_mode = 2
	ea_pass.aperture = 4.0
	renderer.apply(camera.compositor)
	var manual_f4 := (await frame()).get_pixelv(CENTER)
	ea_pass.aperture = 2.0
	renderer.apply(camera.compositor)
	var manual_f2 := (await frame()).get_pixelv(CENTER)
	require(manual_f2.get_luminance() > manual_f4.get_luminance() + 0.05,
			"manual physical exposure must respond to aperture: f/4=%s f/2=%s" % [manual_f4, manual_f2])
	ea_pass.metering_mode = 0
	var bias_curve := Curve.new()
	bias_curve.add_point(Vector2(0.0, 1.0))
	bias_curve.add_point(Vector2(1.0, 1.0))
	var bias_texture := CurveTexture.new()
	bias_texture.width = 64
	bias_texture.curve = bias_curve
	ea_pass.exposure_compensation_curve = bias_texture
	renderer.apply(camera.compositor)
	var curved_exposure := (await frame()).get_pixelv(CENTER)
	require(curved_exposure.get_luminance() > energy600.get_luminance() + 0.05,
			"a +1 stop exposure compensation curve must brighten the result: %s vs %s" % [curved_exposure, energy600])
	ea_pass.exposure_compensation_curve = null
	renderer.apply(camera.compositor)
	bias_texture = null
	bias_curve = null
	await frame()
	var mask_image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	mask_image.fill(Color.BLACK)
	var black_mask := ImageTexture.create_from_image(mask_image)
	ea_pass.metering_mask = black_mask
	renderer.apply(camera.compositor)
	var masked_exposure := (await frame()).get_pixelv(CENTER)
	require(masked_exposure.get_luminance() > energy600.get_luminance() + 0.05,
			"the metering mask must control histogram weights: %s vs %s" % [masked_exposure, energy600])
	ea_pass.metering_mask = null
	renderer.apply(camera.compositor)
	black_mask = null
	await frame()

	# The per-camera Volume binding must retain Renderer switches while it layers
	# UE-style exposure settings and pass states over the authored pass.
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	var volume_compositor = compositor_script.new()
	volume_compositor.renderer = renderer
	ea_pass.extend_default_luminance_range = true
	volume_compositor.set_volume_parameters({"library:eye_adaptation": {"exposure_compensation": 2.0}}, {})
	await process_frame
	var volume_state = volume_compositor.get("_view_state")
	require(volume_state != null, "Volume view state was not created")
	var resolved: Dictionary = volume_state.get("_resolved").get("library:eye_adaptation", {})
	require(resolved.get("extend_default_luminance_range") == true and resolved.get("pre_exposure") == true,
			"Volume binding must retain the extended range and pre-exposure switches: %s" % [resolved])
	require(is_equal_approx(resolved.get("exposure_compensation", 0.0), 2.0),
			"Volume binding must expose the authored exposure override: %s" % [resolved])
	volume_compositor.set_volume_parameters({"library:eye_adaptation": {"exposure_compensation": 2.0}}, {"library:eye_adaptation": false})
	await process_frame
	resolved = volume_compositor.get("_view_state").get("_resolved").get("library:eye_adaptation", {})
	require(resolved.get("pre_exposure") == false and resolved.get("frp_eye_adaptation_enabled") == false,
			"Volume pass disable must also disable pre-exposure: %s" % [resolved])

	print("PASS FRP eye adaptation meters and tonemaps in both directions")
	quit(0)
