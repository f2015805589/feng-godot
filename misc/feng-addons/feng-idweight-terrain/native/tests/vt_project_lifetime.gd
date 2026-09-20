extends SceneTree
## Measure an existing scene in a copied project; never edits its resources.
func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var packed = load(OS.get_environment("VT_TEST_SCENE")) as PackedScene
	if packed == null:
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	var terrain = scene.find_child("Terrain3D", true, false)
	var camera = scene.find_child("Camera3D", true, false)
	if terrain == null or camera == null:
		push_error("Expected Terrain3D and Camera3D in the selected scene")
		quit(1)
		return
	var origin: Transform3D = camera.transform
	var frames := maxi(120, int(OS.get_environment("VT_TEST_WINDOW")))
	var windows := maxi(4, int(OS.get_environment("VT_TEST_WINDOWS")))
	var snap_turn := OS.get_environment("VT_TEST_MOTION") == "snap"
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	for window in windows:
		var moving := window > 0 and window < windows - 1
		var samples: Array[float] = []
		var phase_sums := {}
		var gpu_total := 0.0
		for frame in frames:
			if snap_turn:
				camera.transform = origin
				camera.rotate_y(PI if window % 2 else 0.0)
			elif moving:
				var phase := float(frame) / float(frames) * TAU
				camera.position = origin.origin + Vector3(sin(phase) * 96.0, 0.0, sin(phase * 2.0) * 64.0)
				camera.rotation.y = origin.basis.get_euler().y + sin(phase) * 0.6
			else:
				camera.transform = origin
			await physics_frame
			await RenderingServer.frame_post_draw
			var settings: Dictionary = terrain.get_vt_settings()
			if snap_turn and frame in [0, 1, 3, 7, 15, 31, 63, 119]:
				# Sparse readbacks belong to this diagnostic, never the terrain tick.
				root.get_texture().get_image().save_png("res://turn_%02d_%03d.png" % [window, frame])
				print("VT_PROJECT_TURN ", JSON.stringify({"window": window, "frame": frame, "settings": settings}))
			samples.append(float(settings.get("vt_cpu_ms", 0.0)))
			gpu_total += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			for key in settings.get("vt_phases", {}):
				if not String(key).ends_with("peak"):
					phase_sums[key] = phase_sums.get(key, 0.0) + float(settings.vt_phases[key])
		samples.sort()
		var total := 0.0
		for sample in samples:
			total += sample
		for key in phase_sums:
			phase_sums[key] /= samples.size()
		var settings: Dictionary = terrain.get_vt_settings()
		print("VT_PROJECT ", JSON.stringify({"window": window, "moving": moving, "motion": "snap" if snap_turn else "orbit",
				"mean_ms": total / samples.size(), "p95_ms": samples[int(samples.size() * 0.95)],
				"viewport_gpu_mean_ms": gpu_total / samples.size(),
				"phase_mean_ms": phase_sums, "static_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
				"objects": Performance.get_monitor(Performance.OBJECT_COUNT), "settings": settings}))
	scene.queue_free()
	await process_frame
	print("PASS project VT lifetime sampling completed")
	quit()
