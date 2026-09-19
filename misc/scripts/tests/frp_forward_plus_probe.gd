extends SceneTree

# forward_plus regression probe, run by misc/scripts/test_frp_pipeline.py with
# --rendering-method forward_plus.
#
# FRP work must not change the other renderers. The decisive case is the viewport
# jitter rule: under the frp rendering method the authored pipeline decides the
# jitter phase count, and that rule has to stay behind its rendering-method guard.
# A compositor carrying an FRP schedule (without the Temporal AA entry) is therefore
# attached while forward_plus renders: forward_plus keeps jittering with the
# viewport's own TAA setting, exactly as if no schedule existed. If the guard were
# dropped, the schedule would switch the jitter off and consecutive frames would
# become identical.
#
# The four lighting configurations are measured as well, so a change that alters
# forward_plus output shows up as a number rather than passing silently.

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)


func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func mean_luma(image: Image) -> float:
	var sum := 0.0
	var w := image.get_width()
	var h := image.get_height()
	for y in h:
		for x in w:
			var p := image.get_pixel(x, y)
			sum += (p.r + p.g + p.b) / 3.0
	return sum / float(w * h)


func changed_pixels(a: Image, b: Image) -> int:
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				changed += 1
	return changed


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var method := RenderingServer.get_current_rendering_method()
	require(method == "forward_plus", "the probe must run under forward_plus, got '%s'" % method)

	root.msaa_3d = Viewport.MSAA_DISABLED
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0

	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 0, 6)
	camera.current = true

	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2, 2, 2)
	box.mesh = box_mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.6, 0.4)
	box.material_override = material
	scene.add_child(box)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.1, 0.2, 0.3)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.5
	scene.add_child(light)

	# 1. The control: viewport TAA on, no compositor at all. forward_plus jitters, so
	# consecutive frames differ. Without this the probe could pass by measuring a
	# frozen frame.
	root.use_taa = true
	var control_a: Image = await frame()
	var control_b: Image = await frame()
	var control_motion := changed_pixels(control_a, control_b)
	require(control_motion > 0, "forward_plus did not jitter with the viewport TAA setting on; the probe would be vacuous")
	require(mean_luma(control_a) > 0.02, "the forward_plus control frame is not lit")

	# 2. The same frame with a compositor carrying an FRP schedule that does not
	# contain the Temporal AA entry. Under the frp method that schedule would turn the
	# jitter off; under forward_plus the rendering-method guard keeps the viewport's
	# own decision, so the frames keep moving.
	# The schedule is the engine's own default order, minus the Temporal AA entry.
	# Reading it from the spec keeps this probe from pinning a pass id that the
	# engine later drops.
	var schedule := PackedInt32Array()
	var default_order: Array = RenderingServer.call("get_frp_pipeline_spec").get("default_order", [])
	for native_id in default_order:
		if int(native_id) != 6:
			schedule.append(int(native_id))
	require(schedule.size() > 0, "the engine reported no default FRP pass order")
	var compositor := Compositor.new()
	camera.compositor = compositor
	RenderingServer.compositor_set_frp_pipeline(compositor.get_rid(), schedule, PackedStringArray())
	var scheduled_a: Image = await frame()
	var scheduled_b: Image = await frame()
	var scheduled_motion := changed_pixels(scheduled_a, scheduled_b)
	require(scheduled_motion > 0, "an authored FRP schedule stopped forward_plus from jittering; the jitter rule is no longer behind its rendering-method guard")

	# 3. Determinism: the same schedule with the viewport TAA setting off must produce
	# frames that are identical, so the difference measured above is the jitter and not
	# frame-to-frame noise.
	root.use_taa = false
	var still_a: Image = await frame()
	var still_b: Image = await frame()
	require(changed_pixels(still_a, still_b) == 0, "forward_plus frames are not deterministic with TAA off")

	camera.compositor = null
	await frame()

	# 4. Record the lighting configurations.
	var measured := {}
	root.use_taa = false
	measured["none"] = mean_luma(await frame())
	root.use_taa = true
	measured["taa"] = mean_luma(await frame())
	root.use_taa = false
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	root.scaling_3d_scale = 0.5
	measured["fsr2"] = mean_luma(await frame())
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	root.debug_draw = Viewport.DEBUG_DRAW_MOTION_VECTORS
	measured["debug_mvs"] = mean_luma(await frame())
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED

	for key in measured:
		require(measured[key] > 0.02, "forward_plus '%s' frame is not lit: %.4f" % [key, measured[key]])
	print("PROBE forward_plus none=%.4f taa=%.4f fsr2=%.4f debug_mvs=%.4f (control motion=%d, scheduled motion=%d)" % [
		measured["none"], measured["taa"], measured["fsr2"], measured["debug_mvs"], control_motion, scheduled_motion])
	print("PASS forward_plus keeps its own jitter with an FRP schedule attached and stays lit in every configuration")
	quit(0)
