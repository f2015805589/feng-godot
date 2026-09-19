extends SceneTree

# The project pipeline: one setting that both the editor's Scene view and a running game
# render with (Project Settings > Rendering > Renderer > Compositor).
#
# This suite is the runtime half. project_pipeline.gd is what the autoload installs, so
# the test drives the same node the game gets and checks the whole chain: the setting is
# loaded, it reaches the world the viewport renders, the Temporal AA entry inside it is
# the TAA switch even while the viewport's own use_taa says otherwise, a scene that
# brings its own compositor keeps the world, and clearing the setting gives the frame
# back unchanged.

const SETTING := "rendering/renderer/compositor"
const PIPELINE_PATH := "res://addons/feng-render-pipeline/project_pipeline.gd"
const COMPOSITOR_PATH := "res://addons/feng-render-pipeline/compositor.gd"
const RENDERER_PATH := "res://addons/feng-render-pipeline/renderer.gd"
const NODE_NAME := "FengProjectPipeline"
const TEMPORAL_AA_ID := 6

var root_window: Window


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
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if max(max(abs(pa.r - pb.r), abs(pa.g - pb.g)), abs(pa.b - pb.b)) > 0.01:
				changed += 1
	return changed


## Jitter, and therefore a running temporal resolve, is what separates "TAA is on" from
## "TAA is off" from the frames alone: a static scene without it renders identical frames.
func jitter() -> int:
	for i in 4:
		await frame()
	var a: Image = await frame()
	var b: Image = await frame()
	return changed_pixels(a, b)


func _initialize() -> void:
	call_deferred("run")


func build_renderer(temporal_enabled: bool):
	var renderer = load(RENDERER_PATH).new()
	var found := false
	for pass_entry in renderer.passes:
		if pass_entry.get("native_id") != null and int(pass_entry.native_id) == TEMPORAL_AA_ID:
			pass_entry.enabled = temporal_enabled
			found = true
	require(found, "the default renderer does not expose native pass %d" % TEMPORAL_AA_ID)
	return renderer


func save_pipeline(resource, path: String) -> String:
	var error := ResourceSaver.save(resource, path)
	require(error == OK, "could not write the test pipeline to %s (error %d)" % [path, error])
	return path


func install_node():
	var node = load(PIPELINE_PATH).new()
	require(node != null, "project_pipeline.gd did not load")
	root.add_child(node)
	return node


func injected() -> Array:
	return root.find_children(NODE_NAME, "WorldEnvironment", true, false)


func run() -> void:
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0

	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 0, 6)
	camera.current = true

	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	plane.mesh = pm
	plane.rotation_degrees = Vector3(-82, 0, 0)
	plane.position = Vector3(0, -1.0, 0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.9, 0.9, 0.9)
	pm.material = pmat
	scene.add_child(plane)

	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sphere.mesh = sm
	sphere.position = Vector3(0.6, 0.1, 0)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.1, 0.1, 0.1)
	smat.roughness = 0.05
	sm.material = smat
	scene.add_child(sphere)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.05, 0.08, 0.15)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.5
	scene.add_child(light)

	# Two pipelines, identical except for the Temporal AA entry that is the switch, plus
	# a Compositor that carries one of them for the scene-owned case.
	var taa_renderer = build_renderer(true)
	var plain_renderer = build_renderer(false)
	var taa_path := save_pipeline(taa_renderer, "user://project_pipeline_taa.tres")
	var plain_path := save_pipeline(plain_renderer, "user://project_pipeline_plain.tres")
	var compositor = load(COMPOSITOR_PATH).new()
	compositor.renderer = taa_renderer
	var compositor_path := save_pipeline(compositor, "user://project_pipeline_compositor.tres")

	var node = install_node()

	# Control: with no project pipeline the viewport decides, and it says no.
	var off_baseline := await jitter()
	require(off_baseline == 0, "a static scene without TAA is not deterministic (%d pixels)" % off_baseline)
	var off_image: Image = await frame()
	var off_luma := mean_luma(off_image)
	require(off_luma > 0.02, "the baseline scene is not lit: %.4f" % off_luma)
	require(injected().is_empty(), "an empty setting installed a pipeline anyway")

	# The setting alone turns the frame into a TAA frame, with the viewport's own switch
	# still off: that is what makes the editor and the game the same renderer.
	ProjectSettings.set_setting(SETTING, taa_path)
	var setting_jitter := await jitter()
	require(injected().size() == 1, "the setting did not install the project pipeline")
	var lit_image: Image = await frame()
	require(mean_luma(lit_image) > off_luma * 0.5, "the project pipeline voided the frame")
	require(setting_jitter > 0, "the project pipeline's Temporal AA entry did not turn TAA on")

	# The entry is the switch even when the viewport's use_taa says the opposite, in both
	# directions: an entry that is off must not leave a temporal resolve running with no
	# jitter, which is the blur the entry exists to switch off.
	ProjectSettings.set_setting(SETTING, plain_path)
	var plain_jitter := await jitter()
	require(plain_jitter == 0, "a pipeline whose Temporal AA entry is off still resolved a frame")
	root.use_taa = true
	var viewport_switch_jitter := await jitter()
	require(viewport_switch_jitter == 0, "the viewport switch overrode the schedule's Temporal AA entry")
	root.use_taa = false
	ProjectSettings.set_setting(SETTING, taa_path)
	var reenabled_jitter := await jitter()
	require(reenabled_jitter > 0, "re-enabling the entry did not turn TAA back on")

	# A Compositor resource is used as it is, and a bare pipeline resource is wrapped.
	ProjectSettings.set_setting(SETTING, compositor_path)
	var compositor_jitter := await jitter()
	require(compositor_jitter > 0, "a Compositor named by the setting did not reach the frame")

	# A scene that brings its own compositor owns the world: the project pipeline steps
	# aside instead of fighting it, and takes the world back when that node is gone.
	var scene_compositor = load(COMPOSITOR_PATH).new()
	scene_compositor.renderer = plain_renderer
	var scene_world := WorldEnvironment.new()
	scene_world.name = "SceneCompositor"
	scene_world.compositor = scene_compositor
	root.add_child(scene_world)
	var scene_owned := await jitter()
	require(scene_owned == 0, "the scene's own compositor did not take the world over the project pipeline")
	require(injected().is_empty(), "the project pipeline stayed installed while a scene compositor owned the world")
	scene_world.queue_free()
	require(await jitter() > 0, "the project pipeline did not take the world back")

	# Clearing the setting removes it again: the frame goes back to the viewport's switches.
	ProjectSettings.set_setting(SETTING, "")
	var cleared := await jitter()
	require(cleared == 0, "clearing the setting left TAA running (%d pixels)" % cleared)
	require(injected().is_empty(), "clearing the setting left the project pipeline installed")
	var cleared_image: Image = await frame()
	require(abs(mean_luma(cleared_image) - off_luma) < 0.05, "the cleared frame is not the baseline scene")

	node.queue_free()
	await frame()
	print("PASS the project setting is the pipeline a running game renders, its Temporal AA entry is the switch, and a scene compositor wins")
	quit(0)
