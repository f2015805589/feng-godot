extends SceneTree
## magicGI / FRP per-frame CPU + GPU cost profile. Prints MGI_PROFILE_* lines.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const SceneTracker = preload("res://addons/feng-magic-gi/feng_magic_gi_scene_tracker.gd")

var _volume: Node3D
var _camera: Camera3D
var _light: DirectionalLight3D
var _environment: Environment
var _movers: Array[MeshInstance3D] = []
var _frame_us: Array[float] = []
var _cpu_us: Array[float] = []
var _gpu_us: Array[float] = []
var _frame_t := 0

func _initialize() -> void:
	call_deferred("run")

func _process(_delta: float) -> bool:
	if _frame_t > 0:
		_frame_us.append(Time.get_ticks_usec() - _frame_t)
	_frame_t = Time.get_ticks_usec()
	var rid := root.get_viewport_rid()
	_cpu_us.append(RenderingServer.viewport_get_measured_render_time_cpu(rid) * 1000.0)
	_gpu_us.append(RenderingServer.viewport_get_measured_render_time_gpu(rid) * 1000.0)
	var t := Time.get_ticks_msec() / 1000.0
	_camera.position = Vector3(sin(t * 2.0) * 4.0, 3.0, cos(t * 2.0) * 4.0)
	_camera.look_at(Vector3(0, 1, 0), Vector3.UP)
	for i in _movers.size():
		_movers[i].position.x = sin(t * 3.0 + i * 1.7) * 2.0
		_movers[i].position.y = 1.0 + sin(t * 5.0 + i) * 0.3
	return false

func make_bake() -> Resource:
	var data = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = _volume.grid_dimensions()
	data.volume_size = _volume.size
	data.spacing = _volume.probe_spacing
	data.surface_offset = _volume.surface_offset
	data.volume_transform = _volume.global_transform
	data.world_to_grid = _volume.world_to_grid_transform()
	data.bake_samples = _volume.bake_samples
	data.bake_bounces = _volume.bake_bounces
	data.bake_distance = _volume.bake_distance
	data.terrain_reflectance = _volume.terrain_reflectance
	data.material_reflectance = _volume.fallback_material_reflectance
	data.positions = _volume.probe_positions.duplicate()
	data.normals = _volume.probe_normals.duplicate()
	data.transfer.resize(data.positions.size() * 27)
	for probe in data.positions.size():
		data.transfer[probe * 27] = 0.28
		data.transfer[probe * 27 + 1] = 0.28
		data.transfer[probe * 27 + 2] = 0.28
	data.scene_signature = Baker.signature_for_geometry(_volume._current_scene_signature)
	data.bake_version = Time.get_ticks_usec()
	data.build_cell_indices()
	return data

func stats(values: Array[float]) -> String:
	if values.is_empty():
		return "n/a"
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v in sorted:
		total += v
	return "avg=%.1f p50=%.1f p95=%.1f max=%.1f" % [
		total / sorted.size(),
		sorted[sorted.size() / 2],
		sorted[int(sorted.size() * 0.95)],
		sorted[-1],
	]

func timeit(iterations: int, callable: Callable) -> float:
	var start := Time.get_ticks_usec()
	for _i in iterations:
		callable.call()
	return float(Time.get_ticks_usec() - start) / iterations

func run() -> void:
	root.msaa_3d = Viewport.MSAA_4X
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var scene := Node3D.new()
	root.add_child(scene)
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 3.0, 5.0)
	_camera.current = true
	scene.add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 8.0)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = plane
	scene.add_child(floor_mesh)
	for i in 12:
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.6, 0.6, 0.6)
		box.mesh = bm
		box.position = Vector3(sin(i * 1.3) * 2.5, 1.0, cos(i * 1.3) * 2.5)
		scene.add_child(box)
		_movers.append(box)
	var ceiling := MeshInstance3D.new()
	var cm := PlaneMesh.new()
	cm.size = Vector2(8.0, 8.0)
	ceiling.mesh = cm
	ceiling.rotation_degrees.x = 180.0
	ceiling.position.y = 3.9
	scene.add_child(ceiling)

	var world_environment := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.25, 0.35, 0.55)
	sky_material.sky_horizon_color = Color(0.4, 0.4, 0.4)
	_environment.sky.sky_material = sky_material
	world_environment.environment = _environment
	scene.add_child(world_environment)
	_light = DirectionalLight3D.new()
	_light.light_energy = 1.5
	_light.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	scene.add_child(_light)

	var magic_script = load("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
	_volume = magic_script.new()
	_volume.size = Vector3(8.0, 4.0, 8.0)
	_volume.position = Vector3(0.0, 2.0, 0.0)
	_volume.probe_spacing = 1.0
	_volume.surface_offset = 0.03
	_volume.bake_samples = 1
	_volume.bake_bounces = 1
	_volume.bake_distance = 8.0
	_volume.sun = _light
	_volume.lighting_environment = _environment
	_volume.show_probes = false
	scene.add_child(_volume)
	for _i in 12:
		await process_frame
	_volume.refresh_surface_points()

	var bake := make_bake()
	_volume.bake_data = bake
	for _i in 12:
		await process_frame

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	var renderer = renderer_script.new()
	var compositor = compositor_script.new()
	compositor.renderer = renderer
	_camera.compositor = compositor
	for _i in 12:
		await process_frame
	await RenderingServer.frame_post_draw

	# Warm up the whole pipeline (shader compile, atlas upload, first publish).
	for _i in 30:
		await process_frame
	await RenderingServer.frame_post_draw

	# --- Function-level micro timings (microseconds per call) ---
	var state = null
	for s in Runtime._registry.values():
		if s.get_volume() == _volume:
			state = s
	var world: World3D = _volume.get_world_3d()
	print("MGI_PROFILE_QUICK_SIG_US %.0f" % timeit(50, func(): SceneTracker.quick_signature(_volume)))
	print("MGI_PROFILE_RENDER_TARGETS_US %.0f" % timeit(50, func(): Runtime._render_targets(world)))
	print("MGI_PROFILE_PUBLISH_US %.0f" % timeit(20, func(): Runtime._publish()))
	if state and state.lighting:
		print("MGI_PROFILE_COEFFICIENTS_US %.0f" % timeit(50, func(): state.lighting.coefficients(_volume)))
	var placement := Placement.new()
	var collect_us := timeit(3, func(): placement.collect(_volume, false, true))
	print("MGI_PROFILE_COLLECT_US %.0f (probes=%d, tris=%d)" % [collect_us, placement.positions.size(), placement.faces.size() / 3])
	print("MGI_PROFILE_REFRESH_US %.0f" % timeit(3, func(): _volume.refresh_surface_points()))

	# --- Frame-level measurement over ~5 seconds of motion ---
	_frame_us.clear()
	_cpu_us.clear()
	_gpu_us.clear()
	for _i in 300:
		await process_frame
	print("MGI_PROFILE_FRAME_US %s (n=%d)" % [stats(_frame_us), _frame_us.size()])
	print("MGI_PROFILE_RENDER_CPU_US %s" % stats(_cpu_us))
	print("MGI_PROFILE_RENDER_GPU_US %s" % stats(_gpu_us))

	# Still frames (nothing moving) for comparison.
	for i in _movers.size():
		_movers[i].position = Vector3(0, 20 + i, 0) # park out of the scene
	_frame_us.clear()
	_cpu_us.clear()
	_gpu_us.clear()
	for _i in 120:
		await process_frame
	print("MGI_PROFILE_STILL_FRAME_US %s" % stats(_frame_us))
	print("MGI_PROFILE_STILL_RENDER_CPU_US %s" % stats(_cpu_us))
	print("MGI_PROFILE_STILL_RENDER_GPU_US %s" % stats(_gpu_us))
	print("PASS profile done")
	quit(0)
