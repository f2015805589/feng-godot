extends SceneTree
## Regression/benchmark for repeatedly alternating view-dependent lighting flags.
## The default 13 non-debug passes stay enabled throughout. Output timings are
## observations, not cross-machine performance thresholds.

const FRAME_COUNT := 48
var views: Array[SubViewport] = []
var environments: Array[Environment] = []
var suns: Array[DirectionalLight3D] = []
var areas: Array[AreaLight3D] = []
var failed := false

func _initialize() -> void:
	run.call_deferred()

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func step() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func compiled() -> int:
	return int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW))

func make_view(index: int, renderer: FengRenderer) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(160, 120)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	views.append(viewport)
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.15, 0.18)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.4, 0.4, 0.4)
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL if index == 0 else Environment.FOG_MODE_DEPTH
	world.environment = environment
	viewport.add_child(world)
	environments.append(environment)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 4.0)
	viewport.add_child(camera)
	camera.current = true
	var compositor := FengCompositor.new()
	compositor.renderer = renderer
	camera.compositor = compositor
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.7, 0.3, 0.15)
	mesh.material_override = material
	viewport.add_child(mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20.0, -20.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	viewport.add_child(sun)
	suns.append(sun)
	var area := AreaLight3D.new()
	area.position = Vector3(1.0, 1.0, 2.0)
	area.area_range = 5.0
	area.light_energy = 0.2
	viewport.add_child(area)
	areas.append(area)

func set_variants(frame: int) -> void:
	for index in views.size():
		var mask := (frame + index) % 8
		environments[index].fog_mode = Environment.FOG_MODE_DEPTH if (mask & 1) != 0 else Environment.FOG_MODE_EXPONENTIAL
		suns[index].light_angular_distance = 0.5 if (mask & 2) != 0 else 0.0
		areas[index].visible = (mask & 4) != 0

func statistics(samples: Array[float]) -> Dictionary:
	samples.sort()
	return {"median_ms": samples[samples.size() / 2], "p95_ms": samples[int(samples.size() * 0.95)], "max_ms": samples.back()}

func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.directional_shadow_atlas_set_size(256, false)
	var renderer := FengRenderer.new()
	var enabled_count := 0
	for entry in renderer.passes:
		if entry.enabled:
			enabled_count += 1
	require(renderer.passes.size() == 17 and enabled_count == 16, "default 16 non-debug passes changed")
	for index in 2:
		make_view(index, renderer)
	# Exercise every combination repeatedly, allowing async scene-shader jobs to settle.
	for frame in 48:
		set_variants(frame)
		await step()
	var before := compiled()
	var cpu_samples: Array[float] = []
	var gpu_samples: Array[float] = []
	var wall_samples: Array[float] = []
	for frame in FRAME_COUNT:
		set_variants(frame)
		var started := Time.get_ticks_usec()
		await step()
		wall_samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
		var cpu := 0.0
		var gpu := 0.0
		for viewport in views:
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
		cpu_samples.append(cpu)
		gpu_samples.append(gpu)
	var after := compiled()
	print("LIGHTING_CACHE ", JSON.stringify({"frames": FRAME_COUNT, "warm_draw_compilations": before, "new_draw_compilations": after - before,
		"cpu": statistics(cpu_samples), "gpu": statistics(gpu_samples), "wall": statistics(wall_samples),
		"device": RenderingServer.get_video_adapter_name()}))
	require(after == before, "warmed lighting variants recompiled while switching views")
	for viewport in views:
		var pixel := viewport.get_texture().get_image().get_pixel(80, 60)
		require(is_finite(pixel.r) and is_finite(pixel.g) and is_finite(pixel.b) and pixel.r > 0.05,
			"lighting cache switch lost finite lit scene color: %s" % pixel)
	for viewport in views:
		viewport.queue_free()
	await process_frame
	if not failed:
		print("PASS FRP bounded lighting pipeline cache survives alternating camera fog, soft-shadow and area-light variants")
	quit(1 if failed else 0)
