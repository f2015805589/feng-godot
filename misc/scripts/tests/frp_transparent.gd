extends SceneTree

# FRP shades transparent geometry (and the opaque forward fallback) per object through
# the clustered forward path: the same render list, PassMode and uniform set that
# forward_clustered uses, reading the cluster light list the deferred lighting pass was
# built from. There is no second full-screen lighting pass and no second geometry pass.
#
# This suite measures the consequences on the GPU:
#   * an omni light colours the transparent quad's pixels (per-object forward shading);
#   * moving that light out of reach returns the pixels to the unlit colour;
#   * showing the quad costs one draw call, so the opaque scene is not re-rendered.

var scene: Node3D
var camera: Camera3D
var environment: Environment
var light: OmniLight3D
var quad: MeshInstance3D

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


func center_pixel(image: Image) -> Color:
	return image.get_pixelv(CENTER)


## Largest per-pixel luminance difference between two frames.
func max_luminance_delta(a: Image, b: Image) -> float:
	var best := 0.0
	for y in range(4, a.get_height() - 4, 2):
		for x in range(4, a.get_width() - 4, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var la := ca.r * 0.2126 + ca.g * 0.7152 + ca.b * 0.0722
			var lb := cb.r * 0.2126 + cb.g * 0.7152 + cb.b * 0.0722
			best = maxf(best, absf(la - lb))
	return best


func draw_calls() -> int:
	return RenderingServer.viewport_get_render_info(
		root.get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	print("START FRP transparent forward+ tests")
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false

	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 1.0, 3.0)
	camera.current = true
	scene.add_child(camera)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.4, 0.4, 0.4)
	floor_material.roughness = 1.0
	floor_mesh.material_override = floor_material
	scene.add_child(floor_mesh)

	# The quad faces the camera and covers the centre of the view. Alpha blending puts
	# it in the transparent render list, which is the forward path.
	quad = MeshInstance3D.new()
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(2.0, 2.0)
	quad.mesh = quad_mesh
	quad.position = Vector3(0.0, 1.0, 0.0)
	var quad_material := StandardMaterial3D.new()
	quad_material.albedo_color = Color(0.8, 0.8, 0.8, 1.0)
	quad_material.roughness = 0.5
	quad_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material_override = quad_material
	scene.add_child(quad)

	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.25
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	light = OmniLight3D.new()
	light.position = Vector3(0.0, 1.0, 0.9)
	light.omni_range = 6.0
	light.light_energy = 6.0
	light.light_color = Color(1.0, 0.0, 0.0)
	light.shadow_enabled = false
	scene.add_child(light)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	var renderer = renderer_script.new()
	var compositor := Compositor.new()
	camera.compositor = compositor
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "the default pipeline must validate clean: %s" % [renderer.get_validation_warnings()])

	# 1. Per-object forward shading: the omni light must colour the transparent quad.
	var lit := await frame()
	var lit_pixel := center_pixel(lit)
	print("Transparent quad, red omni light in range: %s" % [lit_pixel])
	require(lit_pixel.r > lit_pixel.g + 0.15, "the omni light did not light the transparent quad: %s" % [lit_pixel])

	# 2. Switch the light off: the same pixels have to go back to the unlit colour, which
	# is what proves the shading came from the frame's light list.
	light.visible = false
	var unlit := await frame()
	var unlit_pixel := center_pixel(unlit)
	print("Transparent quad, light off: %s" % [unlit_pixel])
	require(absf(unlit_pixel.r - unlit_pixel.g) < 0.05, "the unlit transparent quad is still red: %s" % [unlit_pixel])
	require(lit_pixel.r > unlit_pixel.r + 0.15, "the light changed nothing but the colour balance: %s vs %s" % [lit_pixel, unlit_pixel])

	# 3. The light is in the list again but out of reach: the frame has to match the
	# unlit one, so the transparent pass really consults the light list per object.
	light.visible = true
	light.position = Vector3(0.0, 1.0, -200.0)
	var far_light := await frame()
	var far_delta := max_luminance_delta(unlit, far_light)
	print("Light out of range vs no light: delta=%.4f" % far_delta)
	require(far_delta < 0.02, "a light far outside the view still shaded the frame (delta %.4f)" % far_delta)
	light.position = Vector3(0.0, 1.0, 0.9)

	# 4. Transparent geometry is drawn by the transparent pass and nothing else: hiding
	# the quad must cost exactly one draw call. A second geometry pass, or a second
	# full-screen lighting pass, would show up in this delta.
	quad.visible = false
	var floor_only := await frame()
	var floor_draws := draw_calls()
	quad.visible = true
	await frame()
	var quad_draws := draw_calls()
	print("Draw calls: opaque scene %d, with the transparent quad %d" % [floor_draws, quad_draws])
	require(floor_draws > 0, "the draw call counter reports nothing; the guard would be vacuous")
	# The camera looks straight ahead, so the centre of the baseline frame is the black
	# background; the floor shows up lower down and has to be lit.
	require(floor_only.get_pixel(160, 200).g > 0.05, "the opaque baseline frame is empty: %s" % [floor_only.get_pixel(160, 200)])
	require(quad_draws <= floor_draws + 1, "the transparent quad added %d draw calls over %d: transparent geometry is not sharing the frame's passes" % [quad_draws, floor_draws])

	print("PASS transparent geometry is forward-shaded per object from the frame's light list")
	scene.queue_free()
	await process_frame
	quit()
