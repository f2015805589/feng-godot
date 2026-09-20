## GPU regression for strict AVT coverage with feedback disabled.
##
## This test deliberately uses the real project scene.  It records both the native plan
## counters and a quantised readback of every frame, because a plan can report no pending
## work while the material still exposes a missing-page diagnostic.  The scene is never
## saved: only the runtime feedback switch and the camera transform are changed.
extends SceneTree

const IMAGE_STEP := 8
const DEFAULT_STATIC_TICKS := 240
const DEFAULT_TURN_FRAMES := 180
const DEFAULT_POST_SETTLE_FRAMES := 120
const DEFAULT_TURNS := 4

var terrain: Terrain3D
var scene: Node
var camera: Camera3D
var origin: Transform3D
var failed := false
var output_dir := "user://vt-strict-coverage"

func _initialize() -> void:
	run.call_deferred()

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
	DirAccess.make_dir_recursive_absolute(output_dir)

func tick_frame() -> Image:
	await physics_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func image_metrics(image: Image) -> Dictionary:
	var total := 0
	var magenta := 0
	var sky_gray := 0
	for y in range(0, image.get_height(), IMAGE_STEP):
		for x in range(0, image.get_width(), IMAGE_STEP):
			var pixel := image.get_pixel(x, y)
			var peak := maxf(pixel.r, maxf(pixel.g, pixel.b))
			var floor := minf(pixel.r, minf(pixel.g, pixel.b))
			var spread := peak - floor
			# The fixture has a neutral grey sky.  Exclude only bright, low-saturation
			# pixels from the denominator; the magenta diagnostic is intentionally
			# saturated and can never be classified as sky here.
			if spread < 0.025 and peak > 0.12:
				sky_gray += 1
			if pixel.r > 0.42 and pixel.b > 0.42 and pixel.g < 0.28:
				magenta += 1
			total += 1
	var terrain_pixels := total - sky_gray
	var denominator := maxi(1, terrain_pixels)
	return {
		"image_samples": total,
		"terrain_pixels": terrain_pixels,
		"sky_gray_pixels": sky_gray,
		"magenta_pixels": magenta,
		"magenta_ratio": float(magenta) / float(denominator),
		"visible_image_fail": magenta > 0,
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

func capture_metrics(phase: String, frame: int, image: Image) -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	var sector: Dictionary = settings.get("avt_sector_stats", {})
	var missing := stat_int(settings, sector, "visible_missing_pages")
	var pending := stat_int(settings, sector, "visible_pending_pages")
	var plan_pages := stat_int(settings, sector, "visible_plan_pages")
	var denied := stat_int(settings, sector, "refinement_requests_denied")
	var requested := stat_int(settings, sector, "requested_physical_pages")
	var plan_budget := stat_int(settings, sector, "plan_budget")
	var result := image_metrics(image)
	result.merge({
		"phase": phase,
		"frame": frame,
		"visible_missing_pages": missing,
		"visible_pending_pages": pending,
		"visible_plan_pages": plan_pages,
		"refinement_requests_denied": denied,
		"requested_physical_pages": requested,
		"plan_budget": plan_budget,
		"capacity_mip_bias": stat_int(settings, sector, "capacity_mip_bias"),
		"sampling_density_scale": stat_float(settings, sector, "sampling_density_scale"),
		"plan_stats_available": missing >= 0 and pending >= 0 and plan_pages >= 0,
		"cpu_missing_zero": missing == 0,
		"vt_cpu_ms": float(settings.get("vt_cpu_ms", 0.0)),
		"fade_queue_size": int(settings.get("vt_page_fade_queue_size", 0)),
		"fade_held_slots": int(settings.get("vt_page_fade_held_slots", 0)),
		"fade_pending_slots": int(settings.get("vt_page_fade_pending_slots", 0)),
	})
	return result

func settled(metric: Dictionary) -> bool:
	return bool(metric.get("plan_stats_available", false)) \
			and int(metric.get("visible_missing_pages", -1)) == 0 \
			and int(metric.get("visible_pending_pages", -1)) == 0 \
			and not bool(metric.get("visible_image_fail", true))

func save_image(image: Image, name: String) -> String:
	var path := output_dir.path_join(name)
	var error := image.save_png(path)
	require(error == OK, "could not save image %s (error %d)" % [path, error])
	return path

func save_selected_image(metric: Dictionary, image: Image, name: String) -> void:
	metric["image_path"] = save_image(image, name)

func set_turn_view(turn: int) -> Dictionary:
	# Keep the 180-degree snap exact in yaw, while alternating a modest overhead view
	# and a grazing view.  The offset makes each repeat demand a different field instead
	# of reusing the original camera's already-resident pages.
	camera.transform = origin
	var yaw_degrees := 0
	if (turn & 1) != 0:
		camera.rotate_y(PI)
		yaw_degrees = 180
	var offset := Vector3(float(turn) * 96.0, float(turn) * 24.0, -float(turn) * 64.0)
	camera.position += offset
	return {
		"yaw_degrees": yaw_degrees,
		"pitch_degrees": -20,
		"position_offset": {"x": offset.x, "y": offset.y, "z": offset.z},
	}

func run_static(ticks: int) -> Dictionary:
	camera.transform = origin
	var trace: Array[Dictionary] = []
	var first_settled := -1
	for frame in ticks:
		var image := await tick_frame()
		var metric := capture_metrics("static", frame, image)
		if frame == 0 or frame == 31 or frame == 119 or frame == ticks - 1:
			save_selected_image(metric, image, "static-%03d.png" % frame)
		if first_settled < 0 and settled(metric):
			first_settled = frame
			save_selected_image(metric, image, "static-first-settled-%03d.png" % frame)
		trace.append(metric)
	var final_metric: Dictionary = trace.back() if not trace.is_empty() else {}
	require(first_settled >= 0, "static view did not reach a settled frame in %d ticks" % ticks)
	require(int(final_metric.get("terrain_pixels", 0)) > 0, "static image contains no sampled terrain pixels")
	require(settled(final_metric), "static final frame is not settled")
	require(not bool(final_metric.get("visible_image_fail", true)),
			"static final frame still exposes a magenta VT page")
	require(bool(final_metric.get("cpu_missing_zero", false)),
			"static final frame still reports visible missing pages")
	return {
		"ticks": ticks,
		"first_settled_frame": first_settled,
		"final_settled_frame": ticks - 1,
		"final": final_metric,
		"trace": trace,
	}

func run_turn(turn: int, frames: int, post_frames: int) -> Dictionary:
	var view := set_turn_view(turn)
	var trace: Array[Dictionary] = []
	var post_trace: Array[Dictionary] = []
	var first_settled := -1
	var first_settled_phase := ""
	for frame in frames:
		var image := await tick_frame()
		var metric := capture_metrics("turn", frame, image)
		if frame == 0 or frame == 31 or frame == 119 or frame == frames - 1:
			save_selected_image(metric, image, "turn-%02d-%03d.png" % [turn, frame])
		if first_settled < 0 and settled(metric):
			first_settled = frame
			first_settled_phase = "turn"
			save_selected_image(metric, image, "turn-%02d-first-settled-%03d.png" % [turn, frame])
		trace.append(metric)
	for frame in post_frames:
		var image := await tick_frame()
		var metric := capture_metrics("post_settle", frame, image)
		if frame == 0 or frame == 31 or frame == 119 or frame == post_frames - 1:
			save_selected_image(metric, image, "turn-%02d-post-%03d.png" % [turn, frame])
		if first_settled < 0 and settled(metric):
			first_settled = frames + frame
			first_settled_phase = "post_settle"
			save_selected_image(metric, image, "turn-%02d-first-settled-post-%03d.png" % [turn, frame])
		post_trace.append(metric)
	var final_metric: Dictionary = post_trace.back() if not post_trace.is_empty() else trace.back()
	require(first_settled >= 0, "turn %d did not reach a settled frame after %d + %d ticks" % [turn, frames, post_frames])
	require(int(final_metric.get("terrain_pixels", 0)) > 0,
			"turn %d final image contains no sampled terrain pixels" % turn)
	require(settled(final_metric), "turn %d final frame is not settled" % turn)
	require(not bool(final_metric.get("visible_image_fail", true)),
			"turn %d final settled frame still exposes a magenta VT page" % turn)
	require(bool(final_metric.get("cpu_missing_zero", false)),
			"turn %d final settled frame still reports visible missing pages" % turn)
	return {
		"turn": turn,
		"view": view,
		"frames": frames,
		"post_settle_frames": post_frames,
		"first_settled_frame": first_settled,
		"first_settled_phase": first_settled_phase,
		"final_settled_frame": frames + post_frames - 1,
		"final": final_metric,
		"trace": trace,
		"post_settle_trace": post_trace,
	}

func write_report(static_report: Dictionary, turns_report: Array[Dictionary], config: Dictionary) -> void:
	var report := {
		"scene": OS.get_environment("VT_TEST_SCENE"),
		"feedback_requested": false,
		"feedback_enabled": terrain.surface_vt_feedback if is_instance_valid(terrain) else null,
		"config": config,
		"static": static_report,
		"turns": turns_report,
		"failed": failed,
	}
	var report_path := output_dir.path_join("vt_strict_coverage.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("REGRESSION: could not write JSON report %s" % report_path)
		failed = true
		return
	file.store_string(JSON.stringify(report))
	file.close()
	print("VT_STRICT_REPORT path=%s" % report_path)

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
	# This is the only terrain setting changed by the diagnostic.  In particular, keep
	# auto capacity, pages per update, distance and all bake settings from the scene.
	terrain.surface_vt_feedback = false
	require(not terrain.surface_vt_feedback, "surface VT feedback could not be disabled")
	var page_limit := environment_int("VT_TEST_PAGE_COUNT", 0)
	if page_limit > 0:
		# Optional capacity stress exercises explicit CPU/GPU LOD agreement.
		terrain.vt_auto_capacity = false
		terrain.vt_page_count = page_limit
	# The real scene is a grazing camera.  A 20-degree downward pitch makes the
	# visible page boundary measurable at 1920x1080 while retaining the scene's
	# position and yaw.  Capture this as the origin before any snap is applied.
	camera.rotation.x = deg_to_rad(-20.0)
	origin = camera.transform
	var static_ticks := environment_int("VT_TEST_STATIC_TICKS",
			environment_int("VT_TEST_WINDOW", DEFAULT_STATIC_TICKS, 1), 1)
	var turn_frames := environment_int("VT_TEST_TURN_FRAMES", DEFAULT_TURN_FRAMES, 1)
	var post_frames := environment_int("VT_TEST_POST_SETTLE_FRAMES", DEFAULT_POST_SETTLE_FRAMES, 1)
	var turns := environment_int("VT_TEST_TURNS", DEFAULT_TURNS, 1)
	var config := {
		"page_count_override": page_limit,
		"static_ticks": static_ticks,
		"turn_frames": turn_frames,
		"post_settle_frames": post_frames,
		"turns": turns,
		"image_step": IMAGE_STEP,
		"image_readback_per_frame": true,
		"output_dir": output_dir,
	}
	var static_report := await run_static(static_ticks)
	var turns_report: Array[Dictionary] = []
	for turn in turns:
		turns_report.append(await run_turn(turn, turn_frames, post_frames))
	write_report(static_report, turns_report, config)
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS strict VT coverage settles feedback-off static and 180-degree views")
	quit()
