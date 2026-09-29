extends SceneTree

# The seeded Eye Adaptation pass meters the frame's luminance with a 64-bin
# log histogram, adapts temporally, then folds the color buffer by
# scale / adapted — the addon equivalent of UE's pre-exposure.
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
	ea_pass.enabled = extend != null
	if extend != null:
		ea_pass.extend_luminance_range = extend
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

	# UE's Extend toggle: with the default [0.0003, 64] metering range the same
	# bright scene saturates the histogram and stays over-exposed.
	await _make_scene(600.0)
	_set_eye_adaptation(false)
	await frame()
	var unextended := (await frame()).get_pixelv(CENTER)
	print("unextended=%s extended=%s" % [unextended, energy600])
	require(unextended.get_luminance() > energy600.get_luminance() + 0.02,
			"without the extended range the frame must stay over-exposed: %s vs %s" % [unextended, energy600])

	print("PASS FRP eye adaptation pass meters, adapts and folds the frame in both directions")
	quit()
