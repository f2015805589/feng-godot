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
	# Which frames of a snap turn are read back and reported. The default is the sparse diagnostic
	# the runner has always used; a caller that needs the per-frame convergence curve sets
	# `VT_TEST_SAMPLE_FRAMES` to a comma separated list (for example `0,1,2,3,4,5,6,7,8`). Readbacks
	# are per sampled frame, so a dense list costs one GPU sync per frame of the burst.
	var sample_frames: Array = [0, 1, 3, 7, 15, 31, 63, 119]
	var sample_env := OS.get_environment("VT_TEST_SAMPLE_FRAMES")
	if not sample_env.is_empty():
		sample_frames = []
		for part in sample_env.split(","):
			sample_frames.append(int(part))
	# Saving a 1080p PNG stalls the loop for a couple of hundred milliseconds, which the engine then
	# fills with physics ticks: a sampled frame would no longer be one displayed frame, and the
	# per-frame curve would not describe what a viewer sees. The readback itself has to happen on
	# the frame, so the images are kept and written after the window's loop.
	var pending_shots: Array = []
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
			if snap_turn and frame in sample_frames:
				# Sparse readbacks belong to this diagnostic, never the terrain tick.
				pending_shots.append([window, frame, root.get_texture().get_image()])
				print("VT_PROJECT_TURN ", JSON.stringify({"window": window, "frame": frame,
						"drawn": int(Engine.get_frames_drawn()), "physics": int(Engine.get_physics_frames()),
						"ms": int(Time.get_ticks_msec()), "fps": int(Engine.get_frames_per_second()),
						"settings": settings}))
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
		for shot in pending_shots:
			shot[2].save_png("res://turn_%02d_%03d.png" % [shot[0], shot[1]])
		pending_shots.clear()
	scene.queue_free()
	await process_frame
	print("PASS project VT lifetime sampling completed")
	quit()
