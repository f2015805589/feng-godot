# Render and cost sweep for per-group height clipmap shapes.
extends "res://vt_scene_base.gd"

const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const LOD := 0
const SHAPES: Array[Dictionary] = [
	{"label": "s64-l7-b2", "size": 64, "levels": 7, "base": 2.0},
	{"label": "high-density-reference-s256-l11-b0_25", "size": 256, "levels": 11, "base": 0.25},
	{"label": "s16-l10-b0_25", "size": 16, "levels": 10, "base": 0.25},
	{"label": "s32-l9-b0_5", "size": 32, "levels": 9, "base": 0.5},
	{"label": "s64-l8-b1", "size": 64, "levels": 8, "base": 1.0},
	{"label": "s128-l7-b2", "size": 128, "levels": 7, "base": 2.0},
	{"label": "s256-l6-b4", "size": 256, "levels": 6, "base": 4.0},
	{"label": "s64-l5-b16", "size": 64, "levels": 5, "base": 16.0},
	{"label": "s64-l6-b1", "size": 64, "levels": 6, "base": 1.0},
	{"label": "s64-l10-b1", "size": 64, "levels": 10, "base": 1.0},
]

var scene: Node3D
var target: Node3D
var output_dir := "user://"


func _initialize() -> void:
	call_deferred("run")


func settle(frames: int) -> void:
	for _frame in frames:
		await process_frame


func frame_image() -> Image:
	for _frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func height_profile(x: float, z: float) -> float:
	return 6.0 * sin(x * 0.45) * cos(z * 0.42) + 0.05 * x


func setup() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(32.0, 200.0, 32.0)
	camera.rotation_degrees.x = -90.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 40.0
	camera.current = true
	root.add_child(camera)
	target = Node3D.new()
	target.position = Vector3(32.0, 0.0, 32.0)
	root.add_child(target)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_clipmap_implementation = LOD
	terrain.vt_clipmap_detail_enabled = false
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.assets = Terrain3DAssets.new()
	var asset := Terrain3DTextureAsset.new()
	asset.albedo_texture = make_texture(Color(0.38, 0.48, 0.32, 1.0))
	asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0, 1.0))
	terrain.assets.set_texture_asset(0, asset)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(target)
	scene.add_child(terrain)

	# The orthographic 1080p view extends beyond the center region. Keep a continuous 3x3
	# neighborhood so a candidate's outer boundary is the only source of image differences.
	for rz in range(-1, 2):
		for rx in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(rx, rz), false)
	for z in 64:
		for x in 64:
			terrain.data.set_height(Vector3(float(x), 0.0, float(z)), height_profile(float(x), float(z)))
	terrain.data.update_maps()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	await settle(8)


func valid_units(entry: Dictionary) -> int:
	var result := 0
	for unit: Dictionary in entry.get("unit_reports", []):
		result += 1 if bool(unit.get("valid", false)) else 0
	return result


func height_entry() -> Dictionary:
	return (terrain.get_vt_settings().get("clipmap", {}) as Dictionary).get("height", {})


func settle_ring() -> void:
	for _attempt in 512:
		var entry := height_entry()
		if int(entry.get("pending_jobs", 1)) == 0 and valid_units(entry) >= int(entry.get("units", 1)):
			break
		terrain.call("debug_update_vt_clipmap", HEIGHT)
		await process_frame
	await process_frame


func image_delta(a: Image, b: Image) -> Dictionary:
	var total := 0.0
	var worst := 0.0
	var changed := 0
	var strong := 0
	var pixels := 0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var pixel_worst := 0.0
			for channel in 3:
				var delta := absf(ca[channel] - cb[channel])
				pixel_worst = maxf(pixel_worst, delta)
				total += delta
			worst = maxf(worst, pixel_worst)
			changed += 1 if pixel_worst > 0.0 else 0
			strong += 1 if pixel_worst > 0.05 else 0
			pixels += 1
	return {"mean": total / float(maxi(pixels * 3, 1)), "max": worst,
			"changed": changed, "strong": strong, "pixels": pixels}


func moving_cost(shape: Dictionary) -> Dictionary:
	var settings := terrain.get_vt_settings()
	var before := int(height_entry().get("upload_bytes", 0))
	var produced_before := int(height_entry().get("produced_texels", 0))
	var values: Array[float] = []
	var start_x := target.position.x
	for tick in 30:
		target.position.x = start_x + float(tick + 1) / 30.0
		camera.position.x = target.position.x
		await physics_frame
		settings = terrain.get_vt_settings()
		var phases: Dictionary = settings.get("vt_phases", {})
		values.append(float(phases.get("clipmap", 0.0)))
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	var over := 0
	for value in values:
		total += value
		over += 1 if value > 0.05 else 0
	var entry := height_entry()
	var layout: Dictionary = entry.get("layout", {})
	var produced := int(entry.get("produced_texels", 0)) - produced_before
	return {
		"mean": total / float(maxi(values.size(), 1)),
		"median": sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0,
		"p95": sorted[clampi(int(ceil(float(sorted.size() - 1) * 0.95)), 0, sorted.size() - 1)] if not sorted.is_empty() else 0.0,
		"peak": sorted.back() if not sorted.is_empty() else 0.0,
		"min": sorted.front() if not sorted.is_empty() else 0.0,
		"over": over,
		"upload_delta": maxi(int(entry.get("upload_bytes", 0)) - before, 0),
		"produced_delta": produced,
		"worker_us": int(layout.get("update_diagnostics", {}).get("update_us", 0.0)),
		"samples": values.size(),
	}


func run_shape(shape: Dictionary, direct_image: Image) -> void:
	terrain.vt_delivery_near_height = DIRECT
	await process_frame
	terrain.vt_clipmap_height_size = int(shape["size"])
	terrain.vt_clipmap_height_levels = int(shape["levels"])
	terrain.vt_clipmap_height_base_world = float(shape["base"])
	terrain.vt_clipmap_budget_texels = int(shape["size"]) * int(shape["size"]) * int(shape["levels"])
	target.position = Vector3(32.0, 0.0, 32.0)
	camera.position = Vector3(32.0, 200.0, 32.0)
	await process_frame
	terrain.vt_delivery_near_height = CLIPMAP
	await settle(6)
	await settle_ring()
	var entry := height_entry()
	var units: Array = entry.get("unit_reports", [])
	var densities: Array[float] = []
	for unit: Dictionary in units:
		densities.append(float(unit.get("density", 0.0)))
	var image := await frame_image()
	if output_dir != "user://":
		image.save_png(output_dir.path_join("height-" + str(shape["label"]) + "-1080p.png"))
	var delta := image_delta(direct_image, image)
	var cost := await moving_cost(shape)
	var size := int(shape["size"])
	var levels := int(shape["levels"])
	var channels := int(entry.get("channels", 1))
	var bytes_gpu := size * size * levels * channels * 4
	# Persistent CPU storage is the per-level RF payload plus its reusable RF staging image.
	# Temporary worker snapshots and task-local arrays are not included in this ring footprint.
	var bytes_cpu := size * size * (levels + 1) * channels * 4
	var valid := valid_units(height_entry())
	print("CLIPMAP_HEIGHT_SWEEP label=%s size=%d levels=%d base=%.5f finest=%.2f coarsest=%.5f densities=%s world_side=%.2f coverage_radius=%.2f valid=%d pending=%d image=%dx%d diff_pixels=%d strong_pixels=%d mean_rgb=%.8f max_rgb=%.6f movement_ticks=%d tick_mean_ms=%.6f tick_median_ms=%.6f tick_p95_ms=%.6f tick_peak_ms=%.6f tick_min_ms=%.6f tick_over_0_05=%d worker_update_us=%d upload_bytes=%d moved_texels=%d gpu_storage_bytes=%d cpu_storage_bytes=%d total_storage_bytes=%d" % [
		str(shape["label"]), size, levels, float(shape["base"]),
		densities[0] if not densities.is_empty() else 0.0,
		densities.back() if not densities.is_empty() else 0.0,
		str(densities), float(shape["base"]) * pow(2.0, float(levels - 1)),
		float(shape["base"]) * pow(2.0, float(levels - 1)) * 0.5,
		valid, int(entry.get("pending_jobs", -1)), image.get_width(), image.get_height(),
		int(delta["changed"]), int(delta["strong"]), float(delta["mean"]), float(delta["max"]),
		int(cost["samples"]), float(cost["mean"]), float(cost["median"]), float(cost["p95"]),
		float(cost["peak"]), float(cost["min"]), int(cost["over"]), int(cost["worker_us"]), int(cost["upload_delta"]),
		int(cost["produced_delta"]), bytes_gpu, bytes_cpu, bytes_gpu + bytes_cpu])
	if str(shape["label"]) == "high-density-reference-s256-l11-b0_25" and output_dir != "user://":
		var delta_file := FileAccess.open(output_dir.path_join("direct-reference-delta.txt"), FileAccess.WRITE)
		if delta_file != null:
			delta_file.store_string("high_density_reference_vs_direct " + str(delta) + "\n")
			delta_file.close()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	await setup()
	var direct_image := await frame_image()
	if output_dir != "user://":
		direct_image.save_png(output_dir.path_join("height-direct-1080p.png"))
	for shape in SHAPES:
		await run_shape(shape, direct_image)
	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
	if scene != null:
		scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS clipmap height resolution sweep")
	quit(0)
