extends SceneTree

const Registry = preload("res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd")
const GPU = preload("res://addons/feng-raytracing/rendering/rt_gi_scene_gpu.gd")
var snapshot: Dictionary
var gpu_done := false
var gpu_ok := false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var renderer: Resource = load("res://render/new_resource.tres")
	var rtgi: Resource
	for pass_resource: Resource in renderer.passes:
		if pass_resource.has_method("set_rtgi_diagnostics_enabled"):
			rtgi = pass_resource
			rtgi.set_rtgi_diagnostics_enabled(true)
	var scene: Node3D = load("res://terrain_ntc_demo.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for i in 90:
		await process_frame
	var terrain: Node3D = scene.get_node("EnvironmentScene/Terrain3D")
	var registry := Registry.new()
	registry.attach(root.world_3d, root, 1)
	var target := RenderingServer.viewport_get_render_target(root.get_viewport_rid())
	var before := Time.get_ticks_msec()
	snapshot = registry.snapshot(target, [target])
	print("TERRAIN_RTGI snapshot=", snapshot.valid, " capture_ms=", Time.get_ticks_msec()-before, " reasons=", snapshot.unsupported_reasons)
	var valid := bool(snapshot.valid)
	var terrain_instance: Dictionary = {}
	for instance: Dictionary in snapshot.instances:
		if instance.instance_id == terrain.get_instance_id():
			terrain_instance = instance
	valid = valid and not terrain_instance.is_empty()
	if valid:
		print("TERRAIN_RTGI surfaces=", terrain_instance.mesh.surfaces.size(), " vertex_bytes=", terrain_instance.mesh.vertex_bytes.size())
		var unchanged := registry.snapshot(target, [target])
		valid = valid and unchanged.topology_revision == snapshot.topology_revision
	RenderingServer.call_on_render_thread(build_gpu)
	for i in 600:
		await process_frame
		if gpu_done:
			break
	valid = valid and gpu_done and gpu_ok
	for i in 120:
		await process_frame
	var diagnostics: Dictionary = rtgi.get_rtgi_diagnostics_snapshot() if rtgi else {}
	var counters: Dictionary = diagnostics.get("counters", {})
	print("TERRAIN_RTGI trace=", counters.get("trace_dispatches", 0), " resolve=", counters.get("resolve_successes", 0), " composite=", counters.get("composite_dispatches", 0))
	valid = valid and int(counters.get("trace_dispatches", 0)) > 0 and int(counters.get("composite_dispatches", 0)) > 0
	registry.detach()
	scene.queue_free()
	await process_frame
	print("TERRAIN_RTGI_RESULT ", valid)
	quit(0 if valid else 1)

func build_gpu() -> void:
	var scene_gpu := GPU.new()
	gpu_ok = scene_gpu.initialize(RenderingServer.get_rendering_device()) and scene_gpu.sync_scene(snapshot, 1)
	print("TERRAIN_RTGI GPU_BUILD ", gpu_ok, " ", scene_gpu.error)
	scene_gpu.release()
	gpu_done = true
