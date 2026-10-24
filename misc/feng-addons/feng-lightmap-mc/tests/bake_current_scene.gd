extends SceneTree
## GPU-backed sky snapshot, followed by the same asynchronous CPU bake as the
## Inspector. Run in the target project with --script and -- user arguments.
## No authored scene or pipeline settings are rewritten by this helper.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var options := {
		"scene":"res://box_test.tscn", "output":"res://Temp/lightmap_current_candidate.res",
		"report":"res://Temp/lightmap_current_candidate.json", "resolution":128,
		"samples":512, "workers":8, "warmup":180,
	}
	for argument in OS.get_cmdline_user_args():
		var pair := argument.trim_prefix("--").split("=",true,1)
		if pair.size() == 2 and options.has(pair[0]):
			options[pair[0]] = int(pair[1]) if typeof(options[pair[0]]) == TYPE_INT else pair[1]
	var packed := load(String(options.scene)) as PackedScene
	if packed == null:
		push_error("Could not load the scene for the lightmap validation bake.")
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	current_scene = scene
	var volume := scene.find_child("FengLightmapVolume",true,false)
	if volume == null or not volume.has_method("request_inspector_bake"):
		push_error("The target scene has no FengLightmapVolume.")
		quit(1)
		return
	for frame in int(options.warmup):
		await process_frame
	volume.atlas_resolution = int(options.resolution)
	volume.samples_per_texel = int(options.samples)
	volume.worker_count = int(options.workers)
	volume.output_resource_path = String(options.output)
	var started := Time.get_ticks_msec()
	volume.request_inspector_bake()
	while bool(volume.get("_inspector_bake_pending")):
		await process_frame
	var report: Dictionary = volume.last_bake_report.duplicate()
	# The resource contains raw arrays already; keep the JSON useful and small.
	report.erase("layers")
	report["elapsed_ms"] = Time.get_ticks_msec()-started
	report["scene"] = options.scene
	report["resolution"] = options.resolution
	report["samples_per_texel"] = options.samples
	if report.get("ok",false):
		report["saved_input_check"] = volume.validate_saved_bake_inputs()
	var report_path := ProjectSettings.globalize_path(String(options.report))
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path,FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report,"  "))
		file.close()
	print("FENG_LIGHTMAP_CURRENT_SCENE ",JSON.stringify(report))
	quit(0 if report.get("ok",false) else 1)
