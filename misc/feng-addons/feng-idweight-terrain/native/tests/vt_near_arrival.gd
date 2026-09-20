## Capture the visible transition after a near-field page demand.
##
## This is a diagnostic rather than a speed assertion.  The camera is warmed at one view,
## snapped by 180 degrees, and held there while every physics frame is read back.  Each frame
## is reduced to a small sample and compared with the last frame after a settle period.  Keeping
## this comparison in the test makes the visible transition reproducible without treating the
## image readback time as a frame-time measurement.
extends SceneTree

const DEFAULT_WARM_TICKS := 240
const DEFAULT_ARRIVAL_FRAMES := 96
const DEFAULT_SETTLE_FRAMES := 120
const SAMPLE_SIZE := Vector2i(160, 90)
const ROI_LEFT := 0.10
const ROI_RIGHT := 0.90
const ROI_TOP := 0.50
const ROI_BOTTOM := 1.0
const LARGE_DIFFERENCE_THRESHOLD := 0.05
const KEY_FRAMES: Array[int] = [0, 1, 3, 7, 15, 31, 63, 95]

var terrain: Terrain3D
var scene: Node
var camera: Camera3D
var origin: Transform3D
var output_dir := "user://vt-near-arrival"
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func environment_int(name: String, fallback: int, minimum: int = 0) -> int:
	var raw := OS.get_environment(name)
	var value := fallback if raw == "" else int(raw)
	return maxi(minimum, value)

func prepare_output() -> void:
	var configured := OS.get_environment("VT_TEST_OUTPUT")
	if configured != "":
		output_dir = configured
	output_dir = ProjectSettings.globalize_path(output_dir)
	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	require(error == OK or error == ERR_ALREADY_EXISTS,
			"could not create output directory %s (error %d)" % [output_dir, error])

func tick_frame() -> Image:
	await physics_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func downsample_image(image: Image) -> Image:
	var reduced := image.duplicate()
	reduced.resize(SAMPLE_SIZE.x, SAMPLE_SIZE.y, Image.INTERPOLATE_BILINEAR)
	return reduced

func roi_metrics(sample: Image, reference: Image) -> Dictionary:
	var x_begin := int(floor(float(SAMPLE_SIZE.x) * ROI_LEFT))
	var x_end := int(ceil(float(SAMPLE_SIZE.x) * ROI_RIGHT))
	var y_begin := int(floor(float(SAMPLE_SIZE.y) * ROI_TOP))
	var y_end := int(ceil(float(SAMPLE_SIZE.y) * ROI_BOTTOM))
	var pixel_count := 0
	var difference_sum := 0.0
	var large_difference_pixels := 0
	for y in range(y_begin, y_end):
		for x in range(x_begin, x_end):
			var sample_pixel: Color = sample.get_pixel(x, y)
			var reference_pixel: Color = reference.get_pixel(x, y)
			var difference := (absf(sample_pixel.r - reference_pixel.r) \
					+ absf(sample_pixel.g - reference_pixel.g) \
					+ absf(sample_pixel.b - reference_pixel.b)) / 3.0
			difference_sum += difference
			if difference >= LARGE_DIFFERENCE_THRESHOLD:
				large_difference_pixels += 1
			pixel_count += 1
	var denominator := float(maxi(1, pixel_count))
	return {
		"mean_abs_rgb_error": difference_sum / denominator,
		"large_difference_pixel_ratio": float(large_difference_pixels) / denominator,
		"large_difference_pixels": large_difference_pixels,
		"roi_pixels": pixel_count,
	}

func stat_int(settings: Dictionary, sector: Dictionary, key: String, fallback: int = -1) -> int:
	if sector.has(key):
		return int(sector.get(key))
	if settings.has(key):
		return int(settings.get(key))
	return fallback

func stat_float(settings: Dictionary, sector: Dictionary, key: String, fallback: float = -1.0) -> float:
	if sector.has(key):
		return float(sector.get(key))
	if settings.has(key):
		return float(settings.get(key))
	return fallback

func capture_vt_metrics(phase: String, frame: int) -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	var sector: Dictionary = settings.get("avt_sector_stats", {})
	var svt: Dictionary = settings.get("svt_stats", {})
	var queue := int(settings.get("vt_page_fade_queue_size", 0))
	var active := int(settings.get("vt_page_fade_active_slots", 0))
	var missing := stat_int(settings, sector, "visible_missing_pages")
	var pending := stat_int(settings, sector, "visible_pending_pages")
	var produced := int(sector.get("produced", svt.get("produced", -1)))
	return {
		"phase": phase,
		"frame": frame,
		"vt_cpu": float(settings.get("vt_cpu_ms", 0.0)),
		"vt_cpu_ms": float(settings.get("vt_cpu_ms", 0.0)),
		"fadequeue": queue,
		"fade_queue_size": queue,
		"active": active,
		"fade_active_slots": active,
		"fade_pending_slots": int(settings.get("vt_page_fade_pending_slots", 0)),
		"fade_held_slots": int(settings.get("vt_page_fade_held_slots", 0)),
		"missing": missing,
		"visible_missing_pages": missing,
		"pending": pending,
		"visible_pending_pages": pending,
		"produced": produced,
		"avt_produced": int(sector.get("produced", -1)),
		"worker_evicted": int(sector.get("worker_evicted", 0)),
		"svt_produced": int(svt.get("produced", -1)),
		"requested_physical_pages": stat_int(settings, sector, "requested_physical_pages"),
		"plan_budget": stat_int(settings, sector, "plan_budget"),
		"capacity_mip_bias": stat_int(settings, sector, "capacity_mip_bias"),
		"sampling_density_scale": stat_float(settings, sector, "sampling_density_scale"),
	}

func save_image(image: Image, name: String) -> String:
	var path := output_dir.path_join(name)
	var error := image.save_png(path)
	require(error == OK, "could not save image %s (error %d)" % [path, error])
	return path

func append_arrival_frame(trace: Array[Dictionary], samples: Array[Image],
			frame: int, image: Image) -> void:
	var sample := downsample_image(image)
	samples.append(sample)
	var metric := capture_vt_metrics("arrival", frame)
	metric["sample_size"] = [SAMPLE_SIZE.x, SAMPLE_SIZE.y]
	if KEY_FRAMES.has(frame):
		metric["image_path"] = save_image(image, "arrival-%03d.png" % frame)
	trace.append(metric)

func write_report(report: Dictionary) -> void:
	var path := output_dir.path_join("vt_near_arrival.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("REGRESSION: could not write JSON report %s" % path)
		failed = true
		return
	file.store_string(JSON.stringify(report))
	file.close()
	print("VT_NEAR_REPORT path=%s" % path)

func run() -> void:
	prepare_output()
	var scene_path := OS.get_environment("VT_TEST_SCENE")
	if scene_path == "":
		scene_path = "res://render/test.tscn"
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("REGRESSION: could not load VT test scene %s" % scene_path)
		quit(1)
		return
	scene = packed.instantiate()
	root.add_child(scene)
	terrain = scene.find_child("Terrain3D", true, false) as Terrain3D
	camera = scene.find_child("Camera3D", true, false) as Camera3D
	if terrain == null or camera == null:
		push_error("REGRESSION: expected Terrain3D and Camera3D in %s" % scene_path)
		scene.queue_free()
		quit(1)
		return
	# Keep both feedback paths enabled for this near-arrival observation.  The scene is never
	# saved, and no capacity, distance, or page-budget setting is changed here.
	terrain.surface_vt_feedback = true
	require(terrain.surface_vt_feedback, "surface VT feedback must remain enabled")
	require(terrain.surface_svt_feedback, "SVT feedback must remain enabled")
	camera.rotation.x = deg_to_rad(-20.0)
	origin = camera.transform
	var warm_ticks := environment_int("VT_NEAR_WARM_TICKS", DEFAULT_WARM_TICKS, 1)
	var arrival_frames := environment_int("VT_NEAR_ARRIVAL_FRAMES", DEFAULT_ARRIVAL_FRAMES, 1)
	var settle_frames := environment_int("VT_NEAR_SETTLE_FRAMES", DEFAULT_SETTLE_FRAMES, 1)
	var warm_last := {}
	for frame in range(warm_ticks):
		await tick_frame()
		if frame == warm_ticks - 1:
			warm_last = capture_vt_metrics("warm", frame)

	# The 180-degree snap is applied once; the camera remains fixed for the complete arrival
	# trace so the error is caused by page arrival and fade state rather than continued motion.
	camera.transform = origin
	camera.rotate_y(PI)
	var arrival_trace: Array[Dictionary] = []
	var arrival_samples: Array[Image] = []
	for frame in range(arrival_frames):
		var image := await tick_frame()
		append_arrival_frame(arrival_trace, arrival_samples, frame, image)

	var final_image: Image
	var final_metric: Dictionary = {}
	for frame in range(settle_frames):
		final_image = await tick_frame()
		if frame == settle_frames - 1:
			final_metric = capture_vt_metrics("settle", frame)
	var final_sample := downsample_image(final_image)
	var final_path := save_image(final_image, "arrival-final.png")
	for index in arrival_trace.size():
		arrival_trace[index].merge(roi_metrics(arrival_samples[index], final_sample))
	var report := {
		"scene": scene_path,
		"feedback": {
			"surface_vt_feedback": terrain.surface_vt_feedback,
			"surface_svt_feedback": terrain.surface_svt_feedback,
		},
		"camera_pitch_degrees": -20.0,
		"yaw_snap_degrees": 180.0,
		"warm_ticks": warm_ticks,
		"arrival_frames": arrival_frames,
		"settle_frames": settle_frames,
		"sample_size": [SAMPLE_SIZE.x, SAMPLE_SIZE.y],
		"roi": {
			"left": ROI_LEFT,
			"right": ROI_RIGHT,
			"top": ROI_TOP,
			"bottom": ROI_BOTTOM,
			"description": "central 80 percent of the lower half",
		},
		"large_difference_threshold": LARGE_DIFFERENCE_THRESHOLD,
		"image_readback_per_arrival_frame": true,
		"reference": "last image after settle_frames at the fixed post-turn camera",
		"reference_image": final_path,
		"warm_last": warm_last,
		"final": final_metric,
		"arrival": arrival_trace,
		"failed": failed,
		"diagnostic": "Compare baseline and current runs with the same driver and resolution; PNG readback is not a frame-time measurement.",
	}
	write_report(report)
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS near-arrival frame sequence captured for baseline comparison")
	quit()
