extends SceneTree

# The Post Process / Tonemap pass can run its overlay before or after the tone
# mapping. `overlay_after_tonemap` selects the position, and the overlay shader learns
# which one it is on through a shader keyword (specialization constant 0).
#
# This suite proves both placements on the GPU with an overlay that writes a flat
# colour chosen by that keyword:
#
#   * before tone mapping the overlay writes HDR red into the frame's colour buffer and
#     the tone mapper maps it, so the presented pixel is a *toned* red;
#   * after tone mapping the tone mapping is deferred, the overlay writes LDR green into
#     its own texture and the pass presents it, so the presented pixel is exactly green.
#
# Pure green in the second case proves three things at once: the pass ran after the tone
# mapping, the keyword reached the shader, and the pass's own present() put the result on
# screen. The zero/one colours mean neither case depends on the destination colour space.

var scene: Node3D
var camera: Camera3D
var environment: Environment

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


func run() -> void:
	print("START FRP post before/after tonemap tests")
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false

	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 1.0, 3.0)
	camera.current = true
	scene.add_child(camera)

	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.8, 0.8)
	mesh.material_override = material
	scene.add_child(mesh)

	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.1, 0.15)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.0
	# A non-identity tone mapper: with the default Linear one an HDR 1.0 is already
	# screen white, so "the overlay's write was tone mapped" would not be measurable.
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	var renderer = renderer_script.new()
	var compositor := Compositor.new()
	camera.compositor = compositor
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "the default pipeline must validate clean: %s" % [renderer.get_validation_warnings()])

	var post_entry = null
	for pass_entry in renderer.passes:
		if pass_entry.get("native_id") != null and int(pass_entry.native_id) == 7:
			post_entry = pass_entry
	require(post_entry != null, "renderer does not expose the Post Process / Tonemap entry")
	var post_script = post_entry.get("implementation")
	require(post_script != null, "the Post entry has no addon pass script")
	require(post_script.get("overlay_after_tonemap") != null, "the Post pass script does not expose the placement parameter")

	# The overlay: a raster pass that writes the keyword's colour into its own texture.
	var shader_pass_script = load("res://addons/feng-render-pipeline/passes/shader_pass.gd")
	var overlay = shader_pass_script.new()
	overlay.mode = FengShaderPass.Mode.RASTER
	overlay.shader_file = load("res://addons/feng-render-pipeline/examples/post_overlay.glsl")
	require(overlay.shader_file != null, "the post overlay shader did not load")
	overlay.resource_name = "Post Overlay"
	var output := FengPassOutput.new()
	output.name = &"post_ldr"
	output.data_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	output.usage = FengPassOutput.Usage.SAMPLED | FengPassOutput.Usage.COLOR_ATTACHMENT
	var outputs: Array[FengPassOutput] = [output]
	overlay.outputs = outputs
	post_script.overlay = overlay

	# 1. After tone mapping: the engine's present step is skipped, the overlay writes LDR
	#    green into its own texture and the pass presents it.
	post_script.overlay_after_tonemap = true
	renderer.apply(compositor)
	var after := await frame()
	var after_pixel := after.get_pixelv(CENTER)
	print("Post overlay after tone mapping: %s" % [after_pixel])
	require(after_pixel.g > 0.9 and after_pixel.r < 0.1, "an overlay after tone mapping was not presented: %s" % [after_pixel])

	# 2. Before tone mapping: the overlay writes HDR red into the frame's colour buffer
	#    and the tone mapper maps it, so the result is a toned red rather than pure red.
	post_script.overlay_after_tonemap = false
	renderer.apply(compositor)
	var before := await frame()
	var before_pixel := before.get_pixelv(CENTER)
	print("Post overlay before tone mapping: %s" % [before_pixel])
	require(before_pixel.r > 0.3 and before_pixel.r > before_pixel.g + 0.15, "an overlay before tone mapping did not reach the frame: %s" % [before_pixel])
	require(before_pixel.g > 0.02 or before_pixel.r < 0.95, "the overlay's write skipped the tone mapping (AgX would have moved it): %s" % [before_pixel])

	# 3. The keyword follows the parameter, so the same shader serves both positions.
	require(after_pixel.g - before_pixel.g > 0.3, "the position keyword did not change the overlay shader: %s vs %s" % [before_pixel, after_pixel])

	# 4. The overlay carries its own enabled flag, next to the shader and parameters the
	#    inspector shows for it: switching it off stops the overlay's work and its
	#    declared textures without touching the pass, and nothing here calls apply().
	overlay.enabled = false
	var disabled := await frame()
	var disabled_pixel := disabled.get_pixelv(CENTER)
	print("Post pass with the overlay switched off: %s" % [disabled_pixel])
	require(disabled_pixel.g < 0.9 and absf(disabled_pixel.r - disabled_pixel.g) < 0.05 and disabled_pixel.r > 0.2,
		"switching the overlay off did not restore the engine's frame: %s" % [disabled_pixel])
	overlay.enabled = true
	var restored := await frame()
	var restored_pixel := restored.get_pixelv(CENTER)
	require(restored_pixel.r > 0.3 and restored_pixel.r > restored_pixel.g + 0.15, "switching the overlay back on did not restore its effect: %s" % [restored_pixel])

	# 5. Removing the overlay restores the engine's own frame: the lit sphere again,
	#    neither the toned red nor the presented green.
	post_script.overlay = null
	renderer.apply(compositor)
	var plain := await frame()
	var plain_pixel := plain.get_pixelv(CENTER)
	print("Post pass without an overlay: %s" % [plain_pixel])
	require(plain_pixel.g < 0.9 and absf(plain_pixel.r - plain_pixel.g) < 0.05 and plain_pixel.r > 0.2,
		"removing the overlay did not restore the engine's frame: %s" % [plain_pixel])

	print("PASS post effects run before or after tone mapping, selected by a shader keyword")
	scene.queue_free()
	await process_frame
	quit()
