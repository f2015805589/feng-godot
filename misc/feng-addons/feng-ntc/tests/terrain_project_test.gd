extends SceneTree
## Actual test场景 VT payload bake/runtime check. No density or resolution override.
const Baker = preload("res://addons/feng-ntc/terrain_vt_baker.gd")
var _thread: Thread
var _codec: Object
var _terrain: Terrain3D
func _init() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in range(count): await RenderingServer.frame_post_draw
func _timeout() -> void:
	push_error("Terrain project timed out")
	if _codec != null: _codec.cancel()
	quit(1)
func _run() -> void:
	var bake := "--bake" in OS.get_cmdline_user_args()
	var bc := "--bc7" in OS.get_cmdline_user_args()
	var output := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	create_timer(1200.0 if bake else 120.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 720)
	var demo: Node3D = load("res://terrain_ntc_demo.tscn").instantiate()
	_terrain = demo.get_node("EnvironmentScene/Terrain3D")
	if bake:
		_terrain.vt_neural_data = null
		_terrain.surface_vt_compression = 0
		_terrain.surface_svt_compression = 0
	elif bc:
		_terrain.vt_neural_data = null
		_terrain.surface_vt_compression = 1
		_terrain.surface_svt_compression = 1
	if "--no-collision" in OS.get_cmdline_user_args(): _terrain.collision_mode = 0
	root.add_child(demo)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	for warmup in range(10):
		await frames(90)
		var stats: Dictionary = _terrain.get_vt_settings().get("producer", {})
		print("TERRAIN_VT_WARMUP ", warmup, " ready=", stats.get("ready_pages", 0), " pending=", stats.get("pending", 0))
		if warmup >= 3 and int(stats.get("ready_pages", 0)) > 0 and int(stats.get("pending", 0)) == 0: break
	_terrain.set_physics_process(false)
	await frames(8)
	if bake:
		var signature := _terrain.get_vt_neural_signature()
		var captured := _terrain.export_vt_neural_pages()
		print("TERRAIN_VT_CAPTURED ", captured.size(), " signature=", signature)
		if captured.is_empty(): push_error("No evaluated VT pages"); quit(1); return
		var status := GDExtensionManager.load_extension("res://addons/feng-ntc/tools/feng_ntc.gdextension")
		if not ClassDB.class_exists(&"FengNTCCodec"): push_error("Cannot load NTC authoring extension: %s" % status); quit(1); return
		_codec = ClassDB.instantiate(&"FengNTCCodec")
		_thread = Thread.new()
		_thread.start(Baker.compress.bind(_codec, captured, signature, 4.0, 16384))
		var tick := Time.get_ticks_msec()
		while _thread.is_alive():
			await process_frame
			if Time.get_ticks_msec()-tick > 3000:
				print("TERRAIN_VT_TRAIN ", _codec.get_status())
				tick = Time.get_ticks_msec()
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		_codec = null
		if not result.get("ok", false): push_error(str(result)); quit(1); return
		DirAccess.make_dir_recursive_absolute("res://terrain_ntc")
		var error := ResourceSaver.save(result.asset, "res://terrain_ntc/terrain_vt.ntc.res", ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH)
		if error != OK: push_error(error_string(error)); quit(1); return
		print("TERRAIN_VT_BAKE_RESULT ", JSON.stringify({"storage": result.storage, "psnr": result.psnr, "signature": signature}))
	else:
		var settings := _terrain.get_vt_settings()
		var stats: Dictionary = settings.get("producer", {})
		print("TERRAIN_VT_PROJECT_STATS ", JSON.stringify(stats))
		if not bc and int(stats.get("neural_decodes", 0)) < 1:
			push_error("Actual terrain did not decode NTC pages"); quit(1); return
		var before := int(stats.get("neural_decodes", 0))
		var samples: Array[float] = []
		for i in range(120):
			await frames(1)
			var gpu := RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			if gpu > 0.0: samples.append(gpu)
		samples.sort()
		var report := {"mode": "BC7" if bc else "NTC", "payload": _terrain.vt_neural_data.get_storage_info() if not bc else {}, "source_signature": _terrain.get_vt_neural_signature(), "vt": _terrain.get_vt_settings(), "gpu_median_ms": samples[samples.size()/2] if not samples.is_empty() else 0.0,
			"texture_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED), "buffer_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED), "video_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED), "source_arrays": _terrain.assets.get_texture_array_info()}
		if before != int(_terrain.get_vt_settings().get("producer", {}).get("neural_decodes", 0)):
			push_error("Steady VT cache decoded again"); quit(1); return
		print("TERRAIN_VT_PROJECT_RESULT ", JSON.stringify(report))
		if not output.is_empty():
			FileAccess.open(output+".json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
			for child: Node in demo.get_children():
				if child is CanvasLayer: child.visible = false
			await frames(3)
			root.get_texture().get_image().save_png(output+".png")
	print("TERRAIN_VT_PROJECT_PASS ", "bake" if bake else "runtime")
	quit()
