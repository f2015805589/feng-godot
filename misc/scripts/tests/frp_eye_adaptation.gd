extends SceneTree

# The built-in Eye Adaptation pass meters the frame's luminance with a 64-bin
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


func _enable_eye_adaptation() -> void:
	var pass_script = load("res://addons/feng-render-pipeline/passes/eye_adaptation_pass.gd")
	require(pass_script != null, "eye adaptation pass script did not load")
	ea_pass = pass_script.new()
	ea_pass.resource_name = "Eye Adaptation"
	# Place it before the native Post Process / Tonemap entry: metering happens on
	# the lit HDR buffer and the folding acts as pre-exposure for everything after.
	var post_index := -1
	for i in renderer.passes.size():
		var entry = renderer.passes[i]
		if entry.get("native_id") != null and int(entry.native_id) == 7:
			post_index = i
			break
	require(post_index >= 0, "renderer does not expose the Post Process / Tonemap entry")
	renderer.passes.insert(post_index, ea_pass)
	renderer.apply(camera.compositor)


func run() -> void:
	print("START FRP eye adaptation tests")
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false

	# Bright scene: exposure must fold the frame DOWN towards the scale target.
	await _make_scene(16.0)
	var bright_off := (await frame()).get_pixelv(CENTER)
	_enable_eye_adaptation()
	var bright_first := (await frame()).get_pixelv(CENTER)
	var bright_settled := (await frame()).get_pixelv(CENTER)
	print("bright off=%s first=%s settled=%s" % [bright_off, bright_first, bright_settled])
	require(bright_settled.get_luminance() < bright_off.get_luminance() - 0.05,
			"bright scene must be exposed down: off=%s settled=%s" % [bright_off, bright_settled])
	require(absf(bright_settled.get_luminance() - bright_first.get_luminance()) < 0.15,
			"exposure must be temporally stable once converged: first=%s settled=%s" % [bright_first, bright_settled])

	# Dark scene: exposure must fold the frame UP.
	await _make_scene(0.02)
	var dark_off := (await frame()).get_pixelv(CENTER)
	_enable_eye_adaptation()
	var dark_settled := (await frame()).get_pixelv(CENTER)
	print("dark off=%s settled=%s" % [dark_off, dark_settled])
	require(dark_settled.get_luminance() > dark_off.get_luminance() + 0.05,
			"dark scene must be exposed up: off=%s settled=%s" % [dark_off, dark_settled])

	print("PASS FRP eye adaptation pass meters, adapts and folds the frame in both directions")
	quit()
