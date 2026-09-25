# Game-runtime capture for camera motion that crosses multiple clipmap texels per frame.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const LOD := 0
const ATLAS := 1
const QUALITY_STANDARD := 0
const QUALITY_PERFORMANCE := 1
const REGION_X_MIN := -2
const REGION_X_MAX := 25
const REGION_Z_MIN := -1
const REGION_Z_MAX := 2
const SPEEDS := [3.0, 10.0, 30.0, 60.0]
const FRAMES_PER_SPEED := 30
const SETTLE_CAP := 300

var painter: Terrain3DEditor
var terrain_node: Terrain3D
var camera_node: Camera3D
var target: Node3D
var landscape: Node3D
var capture: FrameCapture
var failed_probe := false
var quality_name := "Standard"


class FrameCapture extends Node:
	var terrain: Terrain3D
	var camera: Camera3D
	var target: Node3D
	var speed_mps := 0.0
	var enabled := false
	var implementation := "LOD"
	var frame_rows: Array[Array] = []
	var tick_rows: Array[Dictionary] = []
	var previous_frame_usec := 0
	var poll_total_ms := 0.0
	var cdlod_monitor := false
	var last_material_upload := 0
	var last_height_upload := 0

	func _process(delta: float) -> void:
		var now_usec := Time.get_ticks_usec()
		var wall_ms := 0.0 if previous_frame_usec == 0 else float(now_usec - previous_frame_usec) / 1000.0
		previous_frame_usec = now_usec
		if speed_mps != 0.0:
			var distance := speed_mps * delta
			camera.position.x += distance
			target.position.x += distance
		if not enabled:
			return
		var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		var physics_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
		var cdlod_ms := 0.0
		if cdlod_monitor:
			cdlod_ms = float(Performance.get_custom_monitor("terrain/cdlod_cpu")) * 1000.0
		var phase: Dictionary = tick_rows.back().get("phase", {}) if not tick_rows.is_empty() else {}
		frame_rows.append([delta * 1000.0, wall_ms, process_ms, physics_ms, cdlod_ms,
			float(phase.get("vt_cpu_ms", 0.0)), float(phase.get("clipmap", 0.0)),
			float(phase.get("detail", 0.0)), float(phase.get("service", 0.0)),
			float(phase.get("avt", 0.0)), float(phase.get("svt", 0.0)),
			float(phase.get("bake", 0.0)), float(phase.get("clipmap_consume", 0.0)),
			float(phase.get("clipmap_uniform", 0.0)), float(phase.get("clipmap_sync_update", 0.0)),
			float(phase.get("clipmap_detail_update", 0.0)), float(phase.get("detail_update_us", 0.0))])

	func _physics_process(_delta: float) -> void:
		if not enabled:
			return
		var started := Time.get_ticks_usec()
		var settings: Dictionary = terrain.get_vt_settings()
		var phase: Dictionary = settings.get("vt_phases", {})
		var phase_snapshot := phase.duplicate()
		phase_snapshot["vt_cpu_ms"] = float(settings.get("vt_cpu_ms", 0.0))
		var entry: Dictionary = settings.get("clipmap", {})
		var material: Dictionary = entry.get("material", {})
		var height: Dictionary = entry.get("height", {})
		var detail: Dictionary = material.get("detail", settings.get("detail_material", {}))
		var material_layout: Dictionary = material.get("layout", {})
		var material_diag: Dictionary = material_layout.get("update_diagnostics", {})
		var height_layout: Dictionary = height.get("layout", {})
		var height_diag: Dictionary = height_layout.get("update_diagnostics", {})
		var material_upload := int(material.get("upload_bytes", 0))
		var height_upload := int(height.get("upload_bytes", 0))
		var row := {
			"tick": tick_rows.size() + 1,
			"x": camera.position.x,
			"poll_ms": 0.0,
			"phase": phase_snapshot,
			"material_valid": _valid_units(material),
			"material_units": int(material.get("units", 0)),
			"material_pending": int(material.get("pending_jobs", 0)),
			"material_bake_pending": int(material.get("pending_bake_rects", 0)),
			"material_upload_delta": maxi(material_upload - last_material_upload, 0),
			"height_valid": _valid_units(height),
			"height_units": int(height.get("units", 0)),
			"height_pending": int(height.get("pending_jobs", 0)),
			"height_upload_delta": maxi(height_upload - last_height_upload, 0),
			"detail_missing": int(detail.get("missing_tiles", 0)),
			"detail_fallback": int(detail.get("fallback_tiles", 0)),
			"pages_pending": int(settings.get("pages_pending", 0)),
			"pages_late": int(settings.get("pages_late", 0)),
			"pages_ready": int(settings.get("pages_ready", 0)),
			"produced_texels": int(settings.get("clipmap_produced_texels", 0)),
			"worker_us": int(settings.get("clipmap_worker_usec", 0)),
			"material_source_us": float(material_diag.get("source_fill_us", 0.0)),
			"material_update_us": float(material_diag.get("update_us", 0.0)),
			"height_source_us": float(height_diag.get("source_fill_us", 0.0)),
			"height_update_us": float(height_diag.get("update_us", 0.0)),
		}
		row["poll_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
		last_material_upload = material_upload
		last_height_upload = height_upload
		poll_total_ms += float(row["poll_ms"])
		tick_rows.append(row)

	func _valid_units(entry: Dictionary) -> int:
		var count := 0
		for report: Dictionary in entry.get("unit_reports", []):
			if bool(report.get("valid", false)):
				count += 1
		return count


func add_assets() -> void:
	terrain_node.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		var color := Color(0.82, 0.18, 0.07, 1.0) if id == 0 else Color(0.10, 0.58, 0.16, 1.0)
		asset.albedo_texture = make_pattern(64, color, color.lerp(Color(0.74, 0.68, 0.40, 1.0), 0.48))
		asset.normal_texture = make_normal(64)
		terrain_node.assets.set_texture_asset(id, asset)


func height_profile(x: float, z: float) -> float:
	return 2.8 * sin(x * 0.045) * cos(z * 0.055) + 0.9 * sin((x + z) * 0.12)


func make_height_map(region_x: int, region_z: int) -> Image:
	var image := Image.create(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_RF)
	for z in REGION_SIZE:
		for x in REGION_SIZE:
			var wx := float(region_x * REGION_SIZE + x)
			var wz := float(region_z * REGION_SIZE + z)
			image.set_pixel(x, z, Color(height_profile(wx, wz), 0.0, 0.0, 1.0))
	return image


func make_surface_map(region_x: int, region_z: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	for z in REGION_SIZE:
		for x in REGION_SIZE:
			var material_id := ((x / 8 + z / 8 + region_x + region_z) & 1)
			var word := (material_id << 11) | (material_id << 6)
			bytes.encode_u16((z * REGION_SIZE + x) * 2, word)
	return Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes)


func make_scene() -> void:
	root.name = "ClipmapFastMotionProbe"
	landscape = Node3D.new()
	landscape.name = "Landscape"
	root.add_child(landscape)

	camera_node = Camera3D.new()
	camera_node.position = Vector3(0.0, 62.0, 74.0)
	camera_node.rotation_degrees = Vector3(-48.0, 0.0, 0.0)
	camera_node.fov = 70.0
	camera_node.current = true
	landscape.add_child(camera_node)
	target = Node3D.new()
	target.position = Vector3.ZERO
	landscape.add_child(target)

	terrain_node = Terrain3D.new()
	var requested_quality := QUALITY_STANDARD
	for argument in OS.get_cmdline_user_args():
		if argument == "quality=performance":
			requested_quality = QUALITY_PERFORMANCE
	quality_name = "Performance" if requested_quality == QUALITY_PERFORMANCE else "Standard"
	terrain_node.vt_clipmap_quality = requested_quality
	terrain_node.region_size = REGION_SIZE
	terrain_node.free_editor_textures = false
	terrain_node.surface_svt_auto_bake = false
	terrain_node.vt_page_fade_frames = 0
	terrain_node.vt_delivery_near_material = CLIPMAP
	terrain_node.vt_delivery_near_height = CLIPMAP
	terrain_node.vt_delivery_far_material = DIRECT
	terrain_node.vt_delivery_far_height = DIRECT
	add_assets()
	terrain_node.set_camera(camera_node)
	terrain_node.set_clipmap_target(target)
	landscape.add_child(terrain_node)
	# The Terrain3DData object receives its region size when Terrain3D enters the tree.
	terrain_node.region_size = REGION_SIZE
	terrain_node.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain_node)
	terrain_node.set_editor(painter)

	for region_z in range(REGION_Z_MIN, REGION_Z_MAX):
		for region_x in range(REGION_X_MIN, REGION_X_MAX):
			var region := terrain_node.data.add_region_blank(Vector2i(region_x, region_z), false)
			region.set_surface_map(make_surface_map(region_x, region_z))
			region.set_height_map(make_height_map(region_x, region_z))
			region.set_edited(true)
	terrain_node.data.update_maps()

	capture = FrameCapture.new()
	capture.name = "MotionCapture"
	capture.terrain = terrain_node
	capture.camera = camera_node
	capture.target = target
	landscape.add_child(capture)
	await process_frame
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -28.0, 0.0)
	landscape.add_child(light)
	await process_frame


func _valid_units(entry: Dictionary) -> int:
	var count := 0
	for report: Dictionary in entry.get("unit_reports", []):
		if bool(report.get("valid", false)):
			count += 1
	return count


func ring_settled() -> bool:
	var settings: Dictionary = terrain_node.get_vt_settings()
	var clipmap: Dictionary = settings.get("clipmap", {})
	for group: String in ["material", "height"]:
		var entry: Dictionary = clipmap.get(group, {})
		if _valid_units(entry) < int(entry.get("units", 0)):
			return false
		if int(entry.get("pending_jobs", 0)) > 0 or int(entry.get("pending_bake_rects", 0)) > 0:
			return false
	return true


func save_shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var image := root.get_texture().get_image()
	image.save_png(path)
	print("FASTCLIP_SHOT path=%s width=%d height=%d" % [path, image.get_width(), image.get_height()])


func print_phase_rows(impl: String, speed: float) -> void:
	for frame_index in capture.frame_rows.size():
		var row: Array = capture.frame_rows[frame_index]
		print("FASTCLIP_FRAME impl=%s speed_mps=%.1f sample=%d frame_ms=%.3f wall_ms=%.3f process_ms=%.3f physics_ms=%.3f cdlod_ms=%.3f vt_cpu_ms=%.3f clipmap_ms=%.3f detail_ms=%.3f service_ms=%.3f avt_ms=%.3f svt_ms=%.3f bake_ms=%.3f consume_ms=%.3f uniform_ms=%.3f sync_update_ms=%.3f detail_update_ms=%.3f detail_work_us=%.1f" % [
			impl, speed, frame_index + 1, row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7],
			row[8], row[9], row[10], row[11], row[12], row[13], row[14], row[15], row[16]])
	for row: Dictionary in capture.tick_rows:
		var phase: Dictionary = row.get("phase", {})
		print("FASTCLIP_TICK impl=%s speed_mps=%.1f tick=%d x=%.3f poll_ms=%.3f vt_cpu_ms=%.3f clipmap_ms=%.3f clipmap_setup_ms=%.3f clipmap_loop_ms=%.3f clipmap_arm_ms=%.3f clipmap_worker_ms=%.3f consume_ms=%.3f bake_ms=%.3f uniform_ms=%.3f schedule_ms=%.3f sync_update_ms=%.3f detail_update_ms=%.3f detail_ms=%.3f service_ms=%.3f avt_ms=%.3f svt_ms=%.3f fade_ms=%.3f topup_ms=%.3f pages_pending=%d pages_late=%d pages_ready=%d material_valid=%d/%d material_pending=%d material_bake_pending=%d material_upload_delta=%d material_source_us=%.1f material_update_us=%.1f height_valid=%d/%d height_pending=%d height_upload_delta=%d height_source_us=%.1f height_update_us=%.1f detail_missing=%d detail_fallback=%d produced=%d worker_us=%d" % [
			impl, speed, row.get("tick", 0), row.get("x", 0.0), row.get("poll_ms", 0.0),
			phase.get("vt_cpu_ms", 0.0), phase.get("clipmap", 0.0), phase.get("clipmap_setup", 0.0),
			phase.get("clipmap_loop", 0.0), phase.get("clipmap_arm", 0.0), phase.get("clipmap_worker", 0.0),
			phase.get("clipmap_consume", 0.0), phase.get("clipmap_bake", 0.0), phase.get("clipmap_uniform", 0.0),
			phase.get("clipmap_schedule", 0.0), phase.get("clipmap_sync_update", 0.0),
			phase.get("clipmap_detail_update", 0.0), phase.get("detail", 0.0), phase.get("service", 0.0),
			phase.get("avt", 0.0), phase.get("svt", 0.0), phase.get("fade", 0.0), phase.get("topup", 0.0),
			row.get("pages_pending", 0), row.get("pages_late", 0), row.get("pages_ready", 0),
			row.get("material_valid", 0), row.get("material_units", 0), row.get("material_pending", 0),
			row.get("material_bake_pending", 0), row.get("material_upload_delta", 0),
			row.get("material_source_us", 0.0), row.get("material_update_us", 0.0),
			row.get("height_valid", 0), row.get("height_units", 0), row.get("height_pending", 0),
			row.get("height_upload_delta", 0), row.get("height_source_us", 0.0), row.get("height_update_us", 0.0),
			row.get("detail_missing", 0), row.get("detail_fallback", 0),
			row.get("produced_texels", 0), row.get("worker_us", 0)])
	var avg_poll := capture.poll_total_ms / float(maxi(capture.tick_rows.size(), 1))
	print("FASTCLIP_RESULT quality=%s impl=%s speed_mps=%.1f frames=%d ticks=%d avg_poll_ms=%.4f x_end=%.3f" % [
		quality_name, impl, speed, capture.frame_rows.size(), capture.tick_rows.size(), avg_poll, camera_node.position.x])


func reset_capture(impl: int, impl_name: String) -> void:
	capture.enabled = false
	capture.speed_mps = 0.0
	terrain_node.vt_clipmap_implementation = impl
	camera_node.position.x = 0.0
	target.position.x = 0.0
	capture.frame_rows.clear()
	capture.tick_rows.clear()
	capture.poll_total_ms = 0.0
	var initial_clipmap: Dictionary = terrain_node.get_vt_settings().get("clipmap", {})
	capture.last_material_upload = int(initial_clipmap.get("material", {}).get("upload_bytes", 0))
	capture.last_height_upload = int(initial_clipmap.get("height", {}).get("upload_bytes", 0))
	var settled := false
	for _frame in SETTLE_CAP:
		await process_frame
		if ring_settled():
			settled = true
			break
	if not settled:
		print("FASTCLIP_SETUP settled=false impl=%s" % impl_name)
	for _frame in 20:
		await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2:
		await save_shot("%s/%s-before-1080p.png" % [args[1], impl_name.to_lower()])
	var custom_names := Performance.get_custom_monitor_names()
	capture.cdlod_monitor = custom_names.has("terrain/cdlod_cpu")
	var full_settings: Dictionary = terrain_node.get_vt_settings()
	var detail_settings: Dictionary = terrain_node.get_vt_detail_settings()
	var clipmap_settings: Dictionary = full_settings.get("clipmap", {})
	var material_settings: Dictionary = clipmap_settings.get("material", {})
	var height_settings: Dictionary = clipmap_settings.get("height", {})
	print("FASTCLIP_SETUP quality=%s settled=%s impl=%s monitor_cdlod=%s detail_exists=%s detail_enabled=%s detail_missing=%d detail_fallback=%d material_configured=%s material_size=%d material_units=%d height_configured=%s height_size=%d height_units=%d viewport=%s editor=%s" % [
		quality_name, str(settled), impl_name, str(capture.cdlod_monitor), str(detail_settings.get("exists", false)),
		str(detail_settings.get("enabled", false)), int(detail_settings.get("missing_tiles", 0)),
		int(detail_settings.get("fallback_tiles", 0)), str(material_settings.get("configured", false)),
		int(material_settings.get("size", 0)), int(material_settings.get("units", 0)),
		str(height_settings.get("configured", false)), int(height_settings.get("size", 0)),
		int(height_settings.get("units", 0)),
		str(root.get_visible_rect().size), str(Engine.is_editor_hint())])
	for speed: float in SPEEDS:
		capture.frame_rows.clear()
		capture.tick_rows.clear()
		capture.poll_total_ms = 0.0
		capture.implementation = impl_name
		capture.speed_mps = speed
		# Move for a few frames before recording so a speed-switch boundary and the prior
		# screenshot/readback cannot become a false frame-time spike in this speed's sample.
		capture.enabled = false
		for _warmup in 5:
			await process_frame
		var speed_clipmap: Dictionary = terrain_node.get_vt_settings().get("clipmap", {})
		capture.last_material_upload = int(speed_clipmap.get("material", {}).get("upload_bytes", 0))
		capture.last_height_upload = int(speed_clipmap.get("height", {}).get("upload_bytes", 0))
		capture.frame_rows.clear()
		capture.tick_rows.clear()
		capture.poll_total_ms = 0.0
		capture.previous_frame_usec = Time.get_ticks_usec()
		capture.enabled = true
		var wait_frames := 0
		while capture.frame_rows.size() < FRAMES_PER_SPEED and wait_frames < FRAMES_PER_SPEED + 10:
			await process_frame
			wait_frames += 1
		capture.enabled = false
		capture.speed_mps = 0.0
		print_phase_rows(impl_name, speed)
		await process_frame


func run() -> void:
	await make_scene()
	var viewport_size: Vector2i = root.get_visible_rect().size
	if viewport_size != Vector2i(1920, 1080):
		push_error("REGRESSION: expected 1920x1080 viewport; got %s" % str(viewport_size))
		failed_probe = true
	else:
		print("FASTCLIP_SCENE quality=%s regions=%d region_size=%d speeds=%s frames_per_speed=%d viewport=%s runtime=true" % [
			quality_name,
			( REGION_X_MAX - REGION_X_MIN ) * ( REGION_Z_MAX - REGION_Z_MIN ), REGION_SIZE,
			str(SPEEDS), FRAMES_PER_SPEED, str(viewport_size)])
	await reset_capture(LOD, "LOD")
	await reset_capture(ATLAS, "Atlas")
	if terrain_node != null:
		terrain_node.set_process(false)
		terrain_node.set_physics_process(false)
		terrain_node.set_editor(null)
		terrain_node.set_plugin(null)
	if painter != null:
		painter.free()
	if landscape != null:
		landscape.queue_free()
	await process_frame
	await process_frame
	if failed_probe:
		quit(1)
		return
	print("PASS clipmap fast motion capture")
	quit(0)
