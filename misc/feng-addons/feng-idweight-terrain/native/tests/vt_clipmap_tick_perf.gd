# Continuous physics-tick movement measurement for the near material clipmap phase.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const DIRECT := 0
const CLIPMAP := 2
const LOD := 0
const SHAPE_SIZE := 256
const SHAPE_LEVELS := 4
const SHAPE_BASE_WORLD := 256.0
const MOVE_METRES_PER_SECOND := 3.0
const SAMPLE_TICKS := 240
const SETTLE_CAP := 1200

var painter: Terrain3DEditor
var samples: Array[float] = []

func _initialize() -> void:
	call_deferred("run")

func add_assets() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = make_texture(Color(0.9, 0.04, 0.02, 1.0) if id == 0 else Color(0.02, 0.9, 0.04, 1.0))
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func settings() -> Dictionary:
	return terrain.get_vt_settings()

func material_entry() -> Dictionary:
	return (settings().get("clipmap", {}) as Dictionary).get("material", {})

func detail_entry() -> Dictionary:
	return material_entry().get("detail", settings().get("detail_material", {}))

func valid_levels() -> int:
	var count := 0
	for report: Dictionary in material_entry().get("unit_reports", []):
		count += 1 if bool(report.get("valid", false)) else 0
	return count

func ring_settled() -> bool:
	var entry := material_entry()
	return valid_levels() >= int(entry.get("units", 0)) \
			and int(entry.get("pending_jobs", 0)) == 0 \
			and int(entry.get("pending_bake_rects", 0)) == 0

func detail_settled() -> bool:
	var entry := detail_entry()
	return int(entry.get("missing_tiles", 1)) == 0 and int(entry.get("fallback_tiles", 1)) == 0

func setup() -> void:
	root.name = "ClipmapTickPerfProbe"
	scene = Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)
	await process_frame

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 12.0, 14.0)
	camera.rotation_degrees = Vector3(-40.0, 0.0, 0.0)
	camera.fov = 70.0
	camera.current = true
	root.add_child(camera)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	terrain.vt_clipmap_implementation = LOD
	terrain.vt_delivery_near_material = CLIPMAP
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_size = SHAPE_SIZE
	terrain.vt_clipmap_levels = SHAPE_LEVELS
	terrain.vt_clipmap_base_world = SHAPE_BASE_WORLD
	terrain.vt_clipmap_budget_texels = SHAPE_SIZE * SHAPE_SIZE
	add_assets()
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	for z in range(-1, 2):
		for x in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(x, z), false)
	terrain.data.update_maps()

func percentile(sorted_values: Array[float], p: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index := clampi(int(ceil(float(sorted_values.size() - 1) * p)), 0, sorted_values.size() - 1)
	return sorted_values[index]

func print_statistics() -> void:
	var sorted_values: Array[float] = samples.duplicate()
	sorted_values.sort()
	var total := 0.0
	var over_target := 0
	for value in samples:
		total += value
		over_target += 1 if value > 0.05 else 0
	var mean := total / float(maxi(samples.size(), 1))
	var median := percentile(sorted_values, 0.50)
	var p90 := percentile(sorted_values, 0.90)
	var p95 := percentile(sorted_values, 0.95)
	var p99 := percentile(sorted_values, 0.99)
	var minimum: float = float(sorted_values.front()) if not sorted_values.is_empty() else 0.0
	var peak: float = float(sorted_values.back()) if not sorted_values.is_empty() else 0.0
	print("CLIPMAP_TICK_STATS mode=continuous_lod ticks=%d move_mps=%.3f size=%d levels=%d base_world=%.3f mean_ms=%.6f median_ms=%.6f p90_ms=%.6f p95_ms=%.6f p99_ms=%.6f min_ms=%.6f peak_ms=%.6f over_0_05=%d" % [
		samples.size(), MOVE_METRES_PER_SECOND, SHAPE_SIZE, SHAPE_LEVELS, SHAPE_BASE_WORLD,
		mean, median, p90, p95, p99, minimum, peak, over_target])

func run() -> void:
	await setup()
	var settled := false
	var settle_ticks := 0
	while settle_ticks < SETTLE_CAP:
		await physics_frame
		settle_ticks += 1
		if ring_settled() and detail_settled():
			settled = true
			break
	if not settled:
		var failed_detail := detail_entry()
		var failed_detail_diag: Dictionary = terrain.get_vt_detail_arm().get("update_diagnostics", {})
		print("CLIPMAP_TICK_SETUP settled=false settle_ticks=%d detail_missing=%d detail_fallback=%d requested=%d resident=%d valid=%d pending=%d diagnostics=%s" % [
			settle_ticks, int(failed_detail.get("missing_tiles", -1)), int(failed_detail.get("fallback_tiles", -1)),
			int(failed_detail.get("requested_tiles", -1)), int(failed_detail.get("resident_tiles", -1)),
			int(failed_detail.get("valid_tiles", -1)), int(failed_detail.get("pending_tiles", -1)),
			str(failed_detail_diag)])
		push_error("REGRESSION: clipmap tick probe did not settle before movement")
		failed = true
	else:
		for _warmup in 10:
			await physics_frame
		var step := MOVE_METRES_PER_SECOND / float(Engine.physics_ticks_per_second)
		var previous_upload_bytes := int(material_entry().get("upload_bytes", 0))
		for tick in SAMPLE_TICKS:
			camera.position.x += step
			await physics_frame
			var current_settings := settings()
			var phase: Dictionary = current_settings.get("vt_phases", {})
			var clipmap_ms := float(phase.get("clipmap", 0.0))
			var clipmap_setup_ms := float(phase.get("clipmap_setup", 0.0))
			var clipmap_loop_ms := float(phase.get("clipmap_loop", 0.0))
			var clipmap_arm_ms := float(phase.get("clipmap_arm", 0.0))
			var detail_ms := float(phase.get("detail", 0.0))
			var consume_ms := float(phase.get("clipmap_consume", 0.0))
			var bake_ms := float(phase.get("clipmap_bake", 0.0))
			var uniform_ms := float(phase.get("clipmap_uniform", 0.0))
			var schedule_ms := float(phase.get("clipmap_schedule", 0.0))
			var sync_update_ms := float(phase.get("clipmap_sync_update", 0.0))
			var detail_update_ms := float(phase.get("clipmap_detail_update", 0.0))
			var detail_deferred := bool(phase.get("clipmap_detail_deferred", false))
			samples.append(clipmap_ms)
			var entry: Dictionary = (current_settings.get("clipmap", {}) as Dictionary).get("material", {})
			var upload_bytes := int(entry.get("upload_bytes", 0))
			var upload_delta := maxi(upload_bytes - previous_upload_bytes, 0)
			previous_upload_bytes = upload_bytes
			var layout: Dictionary = entry.get("layout", {})
			var diagnostics: Dictionary = layout.get("update_diagnostics", {})
			var detail_diagnostics: Dictionary = terrain.get_vt_detail_arm().get("update_diagnostics", {})
			var producer: Dictionary = current_settings.get("producer", {})
			print("CLIPMAP_TICK_ROW tick=%d x=%.3f clipmap_ms=%.6f clipmap_setup_ms=%.6f clipmap_loop_ms=%.6f clipmap_arm_ms=%.6f detail_ms=%.6f consume_ms=%.6f bake_ms=%.6f uniform_ms=%.6f schedule_ms=%.6f sync_update_ms=%.6f detail_update_ms=%.6f detail_deferred=%s clipmap_worker_us=%d produced=%d upload_delta=%d ring_update_us=%.3f rebuild_us=%.3f source_us=%.3f scatter_us=%.3f pack_us=%.3f publish_us=%.3f jobs=%d scheduled=%d completed=%d rows=%d packed=%d levels=%d layers=%d valid=%d pending=%d bake_pending=%d detail_update_us=%d storage_us=%d windows_us=%d band_fit_us=%d candidate_us=%d candidate_tests=%d candidates=%d residency_us=%d requested=%d released=%d source_submit_us=%d source_queue_us=%d source_poll_us=%d source_texture_upload_us=%d source_async_upload_us=%d source_uploads=%d offer_sort_us=%d bake_offers=%d directory_us=%d directories=%d ring_bake_lock_skips=%d" % [
				tick + 1, camera.position.x, clipmap_ms, clipmap_setup_ms, clipmap_loop_ms, clipmap_arm_ms, detail_ms,
				consume_ms, bake_ms, uniform_ms, schedule_ms, sync_update_ms, detail_update_ms, str(detail_deferred),
				int(current_settings.get("clipmap_worker_usec", 0)),
				int(current_settings.get("clipmap_produced_texels", 0)), upload_delta,
				float(diagnostics.get("update_us", 0.0)),
				float(diagnostics.get("rebuild_schedule_us", 0.0)),
				float(diagnostics.get("source_fill_us", 0.0)),
				float(diagnostics.get("ring_scatter_us", 0.0)),
				float(diagnostics.get("full_level_pack_us", 0.0)),
				float(diagnostics.get("gpu_publish_us", 0.0)),
				int(diagnostics.get("jobs_before", 0)),
				int(diagnostics.get("jobs_scheduled", 0)),
				int(diagnostics.get("jobs_completed", 0)),
				int(diagnostics.get("source_row_calls", 0)),
				int(diagnostics.get("packed_texels", 0)),
				int(diagnostics.get("levels_completed", 0)),
				int(diagnostics.get("published_layers", 0)),
				valid_levels(),
				int(entry.get("pending_jobs", 0)), int(entry.get("pending_bake_rects", 0)),
				int(detail_diagnostics.get("total_us", 0)),
				int(detail_diagnostics.get("storage_us", 0)),
				int(detail_diagnostics.get("windows_us", 0)),
				int(detail_diagnostics.get("band_fit_us", 0)),
				int(detail_diagnostics.get("candidate_walk_sort_us", 0)),
				int(detail_diagnostics.get("candidate_tests", 0)),
				int(detail_diagnostics.get("candidates", 0)),
				int(detail_diagnostics.get("residency_eviction_us", 0)),
				int(detail_diagnostics.get("requested", 0)),
				int(detail_diagnostics.get("released", 0)),
				int(detail_diagnostics.get("source_submit_us", 0)),
				int(detail_diagnostics.get("source_queue_us", 0)),
				int(detail_diagnostics.get("source_poll_upload_us", 0)),
				int(detail_diagnostics.get("source_texture_upload_us", 0)),
				int(detail_diagnostics.get("source_texture_upload_worker_us", 0)),
				int(detail_diagnostics.get("source_uploads", 0)),
				int(detail_diagnostics.get("offer_sort_us", 0)),
				int(detail_diagnostics.get("bake_offers_added", 0)),
				int(detail_diagnostics.get("directory_publish_us", 0)),
				int(detail_diagnostics.get("directories_published", 0)),
				int(producer.get("ring_bake_lock_skips", 0))])
		print("CLIPMAP_TICK_SETUP settled_ticks=%d detail_missing=%d detail_fallback=%d" % [
			settle_ticks, int(detail_entry().get("missing_tiles", 0)), int(detail_entry().get("fallback_tiles", 0))])
		print_statistics()
	if painter != null:
		painter.free()
	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		terrain.set_editor(null)
		terrain.set_plugin(null)
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS clipmap continuous tick perf")
	quit(0)
