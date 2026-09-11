# FRP global illumination coverage.
#
# The FRP G-buffer stores its 30-bit normal in normal_roughness.rgb and keeps
# roughness in gbuffer_orm.g, because the 2-bit normal_roughness alpha only has
# room for the dynamic/static flag. The GI compute shader therefore decodes a
# different roughness source than forward_clustered, selected by a pipeline
# specialization constant. Nothing else in the test suite turns GI on, so this
# script exists to actually execute that path: process_gi() only runs when SDFGI
# or VoxelGI is enabled.
extends SceneTree

var scene: Node3D
var environment: Environment

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

func frame() -> Image:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func mean_luminance(image: Image) -> float:
	var total := 0.0
	var count := 0
	# Skip a margin so the comparison is about scene content, not the border.
	for y in range(8, image.get_height() - 8, 4):
		for x in range(8, image.get_width() - 8, 4):
			var c := image.get_pixel(x, y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			count += 1
	return total / maxf(float(count), 1.0)

# Where the shadow lands depends on the light and camera, so rather than guess a
# screen region, measure the strongest per-pixel brightening GI caused.
func max_luminance_gain(before: Image, after: Image) -> float:
	var best := 0.0
	for y in range(4, before.get_height() - 4, 2):
		for x in range(4, before.get_width() - 4, 2):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			var la := a.r * 0.2126 + a.g * 0.7152 + a.b * 0.0722
			var lb := b.r * 0.2126 + b.g * 0.7152 + b.b * 0.0722
			best = maxf(best, lb - la)
	return best

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	print("START FRP GI tests")
	scene = Node3D.new()
	root.add_child(scene)

	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 2.0, 6.0)
	camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	camera.current = true
	scene.add_child(camera)

	# A large floor plus a blocker: the floor area behind the blocker is only lit
	# by indirect light, so SDFGI is the only thing that can brighten it.
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_mesh.mesh = plane
	scene.add_child(floor_mesh)

	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(3.0, 3.0, 3.0)
	blocker.mesh = box
	blocker.position = Vector3(0.0, 1.5, 0.0)
	scene.add_child(blocker)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, 20.0, 0.0)
	light.light_energy = 3.0
	light.shadow_enabled = true
	scene.add_child(light)

	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0)
	# Zero ambient isolates the SDFGI contribution: without GI the shadowed
	# floor must stay black.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.0
	environment.sdfgi_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	var without_gi := await frame()
	var baseline := mean_luminance(without_gi)
	require(baseline > 0.01, "scene did not render at all, got %f" % baseline)

	# Turning SDFGI on must run gi.process_gi() with FRP's split roughness
	# layout. A broken binding or pipeline selection surfaces here as an engine
	# error (the test runner asserts on "ERROR:"), and a wrong roughness decode
	# would leave the indirect contribution at zero.
	environment.sdfgi_enabled = true
	var with_gi := await frame()
	# SDFGI cascades converge over several frames.
	for i in 20:
		with_gi = await frame()
	var lit := mean_luminance(with_gi)
	var gain := max_luminance_gain(without_gi, with_gi)
	print("SDFGI mean ", baseline, " -> ", lit, "  max per-pixel gain=", gain)
	# A binding or pipeline-selection failure surfaces as an engine error (the
	# runner asserts on "ERROR:"), and a roughness decode reading the wrong
	# channel would leave the indirect contribution at zero.
	require(gain > 0.02, "SDFGI produced no indirect light (max gain %f)" % gain)
	# Sanity bound against a decode that returns garbage: indirect light may
	# brighten the frame, but it must not blow it out.
	require(lit < baseline * 2.0, "SDFGI output implausibly bright (%f -> %f)" % [baseline, lit])

	# The G-buffer layout itself (30-bit normal in rgb, dynamic flag in the
	# 2-bit alpha, roughness in orm.g) is asserted by frp_passes.gd, which reads
	# those targets from a POST_GBUFFER compositor effect.
	print("PASS SDFGI runs with FRP split roughness and produces indirect light")
	scene.queue_free()
	await process_frame
	quit()
