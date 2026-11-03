extends SceneTree
## In-memory compression overrides only. Never changes the saved scene or VT payload.
var _terrain: Terrain3D
var _mode := "ntc"
var _output := ""
var _sample_count := 1200
var _started := 0
var _cache_pages := -1
var _moving := false
const EXPECTED_VIEW_MIPS := [0,0,125,150,104,75,137,0,0,0,0,0,0,0,0,0,0]

func _view_ready(settings: Dictionary) -> bool:
	# Retired/retained pages vary with asynchronous arrival order. Compare the
	# actual selected view (including every mip), not those unused cache slots.
	var view: Dictionary = settings.get("avt_sector_stats", {})
	return bool(view.get("height_bounds_ready",false)) and not bool(view.get("planning_pending",true)) and int(view.get("visible_plan_pages",0))==675 and int(view.get("visible_missing_pages",-1))==0 and int(view.get("visible_pending_pages",-1))==0 and Array(view.get("plan_level_mips",[]))==EXPECTED_VIEW_MIPS and int(settings.get("producer",{}).get("svt_ready_slots",0))==42

func _init() -> void:
	_started = Time.get_ticks_usec()
	_run.call_deferred()

func _summary(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	return {"samples": sorted.size(), "mean": total/sorted.size(), "median": sorted[sorted.size()/2], "p95": sorted[mini(sorted.size()-1, int(sorted.size()*0.95))], "max": sorted.back()}

func _memory() -> Dictionary:
	return {"video": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED), "textures": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED), "buffers": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)}

func _fail(message: String) -> void:
	push_error(message)
	quit(1)

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="): _mode = arg.trim_prefix("--mode=")
		if arg.begins_with("--output="): _output = arg.trim_prefix("--output=")
		if arg.begins_with("--frames="): _sample_count = int(arg.trim_prefix("--frames="))
		if arg.begins_with("--cache-pages="): _cache_pages = int(arg.trim_prefix("--cache-pages="))
		if arg == "--motion": _moving = true
	if _mode not in ["raw", "raw_vt", "bc7", "ntc", "ntc_direct"]: _fail("Unknown compression mode"); return
	create_timer(180.0).timeout.connect(_fail.bind("Terrain comparison timed out"))
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.size = Vector2i(1280, 720)
	var demo: Node3D = load("res://terrain_ntc_demo.tscn").instantiate()
	_terrain = demo.get_node("EnvironmentScene/Terrain3D")
	_terrain.surface_svt_auto_bake = false # Exclude background editing/bake jobs from rendering measurements.
	var neural := _mode.begins_with("ntc")
	_terrain.surface_vt_compression = 4 if neural else (1 if _mode == "bc7" else 0)
	_terrain.surface_svt_compression = _terrain.surface_vt_compression
	if not neural: _terrain.vt_neural_data = null
	else:
		_terrain.vt_neural_data.runtime_storage = 0 if _mode == "ntc_direct" else 1
		if _cache_pages >= 0: _terrain.vt_neural_data.decoded_cache_pages = _cache_pages
	_terrain.assets.texture_array_compression = 0 if _mode == "raw" else 1
	root.add_child(demo)
	demo.set_process(false) # Camera remains fixed; exclude the inspection HUD's polling.
	for child: Node in demo.get_children():
		if child is CanvasLayer: child.visible = false
	var viewport := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport, true)
	var loading_gpu: Array[float] = []
	var loading_cpu: Array[float] = []
	var last_state: Array = []
	var stable_since := Time.get_ticks_usec()
	var peak_video := 0
	var settings := {}
	var loading_frames := 0
	while Time.get_ticks_usec()-_started < 120_000_000:
		await RenderingServer.frame_post_draw
		loading_frames += 1
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport)
		if gpu > 0.0: loading_gpu.append(gpu)
		loading_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
		if loading_frames%8 != 0: continue
		peak_video = maxi(peak_video, int(_memory().video))
		settings = _terrain.get_vt_settings()
		var producer: Dictionary = settings.get("producer", {})
		var state := [producer.get("ready_pages", 0), producer.get("neural_decodes", 0), producer.get("baked_pages", 0), producer.get("cached_uploads", 0)]
		var pending := int(producer.get("pending", 0))+int(producer.get("encode_pending", 0))+int(settings.get("bake_pending", 0))+int(settings.get("svt_source_pending", 0))+int(producer.get("neural_runtime", {}).get("cache_pending", 0))
		if pending > 0 or state != last_state or not _view_ready(settings):
			stable_since = Time.get_ticks_usec()
		last_state = state
		if Time.get_ticks_usec()-stable_since > 2_000_000: break
	var load_ms := (Time.get_ticks_usec()-_started)/1000.0
	var initial: Dictionary = settings.get("producer", {}).duplicate()
	if not _view_ready(settings) or int(initial.get("page_count", 0)) != 1024:
		_fail("VT did not finish the identical visible mip plan: %s" % settings.get("avt_sector_stats",{})); return
	if neural and (int(initial.get("neural_decodes", 0)) < int(initial.get("ready_pages",0)) or int(initial.get("baked_pages", 0)) != 0 or int(initial.get("neural_missing_or_stale", 0)) != 0):
		_fail("NTC did not exclusively use the current baked pages"); return
	print("TERRAIN_COMPARISON_PHASE ", JSON.stringify({"phase": "loaded", "load_ms": load_ms, "loading_frames": loading_frames}))
	for i in range(180): await RenderingServer.frame_post_draw
	var samples := {"gpu_ms": [], "render_cpu_ms": [], "vt_update_cpu_ms": []}
	var memory_before := _memory()
	var steady_wall_ms := 0.0
	var restarts := 0
	var final := {}
	var camera: Camera3D = demo.get_node("Camera3D")
	var original_view := camera.transform
	for attempt in range(5):
		initial = _terrain.get_vt_settings().producer.duplicate(true)
		memory_before = _memory()
		samples = {"gpu_ms": [], "render_cpu_ms": [], "vt_update_cpu_ms": []}
		print("TERRAIN_COMPARISON_PHASE ", JSON.stringify({"phase": "steady_begin", "frames": _sample_count}))
		var steady_begin := Time.get_ticks_usec()
		var last_physics := -1
		for i in range(_sample_count):
			if _moving:
				# Identical frame-indexed poses, same position/FOV, even at different FPS.
				var phase := TAU*float(i)/float(_sample_count)
				camera.transform = original_view.rotated_local(Vector3.UP,0.2*sin(phase)).rotated_local(Vector3.RIGHT,0.06*sin(phase*2.0))
			await RenderingServer.frame_post_draw
			samples.gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
			samples.render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
			if i%16 == 0:
				settings = _terrain.get_vt_settings()
				if Engine.get_physics_frames() != last_physics:
					last_physics = Engine.get_physics_frames()
					samples.vt_update_cpu_ms.append(float(settings.get("vt_cpu_ms", 0.0)))
		steady_wall_ms = (Time.get_ticks_usec()-steady_begin)/1000.0
		settings = _terrain.get_vt_settings(); final = settings.producer
		var stable := _view_ready(settings)
		for key: String in ["neural_decodes","baked_pages","cached_uploads","neural_dispatches"]:
			stable = stable and int(final.get(key,0))==int(initial.get(key,0))
		if _moving or stable: break
		restarts+=1
		print("TERRAIN_COMPARISON_SETTLING discarded_window=",attempt+1)
		if attempt==4: _fail("No stationary measurement window"); return
		# Reject the whole window when asynchronous terrain preparation continued;
		# never select individual fast frames or mix cold-page work into steady data.
		for i in range(180): await RenderingServer.frame_post_draw
	print("TERRAIN_COMPARISON_PHASE ", JSON.stringify({"phase": "steady_end", "frames": _sample_count, "wall_ms": steady_wall_ms}))
	var asset_info := _terrain.assets.get_texture_array_info()
	if asset_info.get("encoder_missing", false) or asset_info.get("gpu_fallback", false): _fail("Source texture codec fell back"); return
	var data_stats: Dictionary = _terrain.vt_neural_data.get_storage_info() if neural else {}
	var report := {"mode": _mode, "resolution": Vector2i(1280, 720), "sample_count": _sample_count, "cpu_name": OS.get_processor_name(), "cpu_threads": OS.get_processor_count(), "gpu_name": RenderingServer.get_video_adapter_name(), "driver": "D3D12", "renderer": "FRP", "vsync": "disabled", "load_to_stationary_ms": load_ms, "loading_frames": loading_frames, "loading_gpu_ms": _summary(loading_gpu), "loading_render_cpu_ms": _summary(loading_cpu), "loading_peak_video_bytes": peak_video, "steady_wall_ms": steady_wall_ms, "memory": memory_before, "source_arrays": asset_info, "payload": data_stats, "vt": settings}
	for name: String in samples:
		var values: Array[float] = []
		values.assign(samples[name])
		report[name] = _summary(values)
	report["motion"] = _moving
	report["settle_restarts"] = restarts
	report["memory_end"] = _memory()
	report["measured_page_work"] = {}
	for key: String in ["neural_decodes","neural_dispatches","baked_pages","cached_uploads","neural_missing_or_stale"]:
		report.measured_page_work[key] = int(final.get(key,0))-int(initial.get(key,0))
	if not _output.is_empty():
		FileAccess.open(_output+".json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
		root.get_texture().get_image().save_png(_output+".png")
	print("TERRAIN_COMPARISON_PASS ", _mode)
	quit()
