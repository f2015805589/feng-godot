# Run with a graphical rendering driver; see vt_lifetime_runner.py.
#
# This keeps one real AVT scene alive for a configurable number of physics ticks. The stationary
# phase repeatedly invalidates resident pages without moving the camera; the ping-pong phase moves
# the camera between two targets while doing the same. The script prints the native CPU phase,
# fade FIFO length/capacity, and Godot's static-memory monitor at fixed intervals so a runner can
# compare the beginning and end of a long process without relying on a one-shot benchmark.
extends "res://vt_render_base.gd"

const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_COUNT := 128
const FADE_FRAMES := 12
const WARMUP_TICKS := 240
const INVALIDATE_EVERY := 24
const SAMPLE_EVERY := 20
const MOVE_EVERY := 96
const REGION_GRID := 4
const REGIONS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
	Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1),
	Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2),
	Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3), Vector2i(3, 3),
]

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func tick() -> void:
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	await process_frame
	await RenderingServer.frame_post_draw

func write_region(location: Vector2i, asset_id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := (asset_id << 11) | (asset_id << 6)
	for index in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(index * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(
			REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func setup_scene() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	terrain.region_size = REGION_SIZE
	scene.add_child(terrain)
	terrain.set_physics_process(false)

	terrain.assets = Terrain3DAssets.new()
	for asset_id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, Color(0.12, 0.28, 0.82) if asset_id == 0 else Color(0.78, 0.22, 0.08))
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(asset_id, asset)

	camera = Camera3D.new()
	camera.position = Vector3(128.0, 240.0, 128.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 96.0
	camera.near = 0.1
	camera.far = 2000.0
	camera.current = true
	scene.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)

	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_auto_capacity = false
	terrain.vt_pages_per_update = 8
	terrain.vt_page_fade_frames = FADE_FRAMES
	terrain.surface_vt_resolution = 512
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_selection_mode = 2
	terrain.surface_svt_enabled = false
	await process_frame
	await process_frame
	terrain.region_size = REGION_SIZE
	terrain.change_surface_density(1)
	for location in REGIONS:
		terrain.data.add_region_blank(location)
		write_region(location, (location.x + location.y) & 1)
	terrain.data.update_maps()
	# Keep the test driven by the explicit tick below. The native service still runs from the
	# normal physics notification, but the scene must not add a second automatic tick per frame.
	terrain.set_physics_process(false)
	await process_frame
	await process_frame
	terrain.surface_vt_enabled = true
	terrain.set_physics_process(false)
	await process_frame

func snapshot() -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	var producer: Dictionary = settings.get("producer", Dictionary())
	var phases: Dictionary = settings.get("vt_phases", Dictionary())
	var residency: Dictionary = settings.get("residency", Dictionary())
	var page_count := int(settings.get("page_count", residency.get("page_count", 0)))
	return {
		"cpu": float(settings.get("vt_cpu_ms", 0.0)),
		"fade_cpu": float(phases.get("fade", 0.0)),
		"queue": int(settings.get("vt_page_fade_queue_size", -1)),
		"capacity": int(settings.get("vt_page_fade_queue_capacity", -1)),
		"active": int(settings.get("vt_page_fade_active_slots", 0)),
		"pending": int(settings.get("vt_page_fade_pending_slots", 0)),
		"held": int(settings.get("vt_page_fade_held_slots", 0)),
		"starts": int(settings.get("vt_page_fade_starts", 0)),
		"ticks_max": int(settings.get("vt_page_fade_ticks_max", 0)),
		"ready": int(producer.get("ready_pages", 0)),
		"page_count": page_count,
		"memory": Performance.get_monitor(Performance.MEMORY_STATIC),
	}

func ready_slots() -> Array[int]:
	var slots: Array[int] = []
	for page: Dictionary in terrain.get_vt_pages():
		if String(page.get("kind", "")) != "AVT" or not bool(page.get("ready", false)):
			continue
		var slot := int(page.get("slot", -1))
		if slot >= 0 and not slots.has(slot):
			slots.append(slot)
	return slots

func invalidate_resident_pages() -> int:
	var invalidated := 0
	for slot in ready_slots():
		if terrain.debug_invalidate_vt_page(slot):
			invalidated += 1
		if invalidated >= 4:
			break
	return invalidated

func wait_for_fade_arrival(max_ticks: int = 240) -> Dictionary:
	var before := int(snapshot()["starts"])
	for _tick in max_ticks:
		await tick()
		var stats := snapshot()
		if int(stats["starts"]) > before:
			return stats
	return snapshot()

func fade_weight(slot: int) -> float:
	var rid: RID = terrain.material.get_shader_param("_surface_vt_page_fade")
	var image := RenderingServer.texture_2d_get(rid)
	require(image != null and slot >= 0 and slot < image.get_width(),
			"the material must publish a fade byte for the tested physical slot")
	return image.get_pixel(slot, 0).r if image != null and slot < image.get_width() else -1.0

func test_fade_controls() -> void:
	# Disabling the fade must discard all old physical-slot state. Re-enabling starts with a
	# fresh pool, so a slot reused after this point cannot inherit an armed arrival.
	terrain.vt_page_fade_frames = 0
	await tick()
	var disabled := snapshot()
	require(int(disabled["active"]) == 0, "disabling fade left an active ramp")
	require(int(disabled["queue"]) == 0, "disabling fade left armed queue entries")
	terrain.vt_page_fade_frames = FADE_FRAMES
	await tick()
	var warm_streak := 0
	for _tick in 120:
		var warm := snapshot()
		if int(warm["pending"]) == 0 and int(warm["held"]) == 0 and int(warm["active"]) == 0 and int(warm["queue"]) == 0 and int(warm["ready"]) > 0:
			warm_streak += 1
		else:
			warm_streak = 0
		if warm_streak >= 4:
			break
		await tick()
	var candidates := ready_slots()
	require(candidates.size() > 0, "fade control test has no resident page to invalidate")
	if candidates.is_empty():
		return
	var starts_before := int(snapshot()["starts"])
	require(terrain.debug_invalidate_vt_page(candidates[0]), "fade control page invalidation failed")
	var arrived := await wait_for_fade_arrival()
	require(int(arrived["starts"]) > starts_before, "fade control invalidation produced no arrival")
	require(int(arrived["active"]) == 0,
			"the first release frame must remain at fade zero, active=%d" % int(arrived["active"]))
	require(is_zero_approx(fade_weight(candidates[0])),
			"the first released page must publish an actual zero blend byte")
	# Shrinking a live ramp must preserve its normalized position and keep the published counter
	# inside the new range, rather than wrapping a uint8 value.
	var shorter := maxi(1, FADE_FRAMES / 2)
	terrain.vt_page_fade_frames = shorter
	await tick()
	var resized := snapshot()
	require(int(resized["ticks_max"]) <= shorter,
			"shortening fade left ticks_max=%d above new frames=%d" % [int(resized["ticks_max"]), shorter])
	var weight := fade_weight(candidates[0])
	require(weight > 0.0 and weight <= 1.0 / float(shorter) + 1.0 / 255.0,
			"shortening a zero-weight ramp must advance one step, not wrap its byte: %f" % weight)
	terrain.vt_page_fade_frames = 0
	await tick()
	var reset := snapshot()
	require(int(reset["queue"]) == 0 and int(reset["active"]) == 0,
			"fade reset must clear live queue and active ramps")
	terrain.vt_page_fade_frames = FADE_FRAMES
	await tick()

func sample_line(mode: String, tick_index: int, stats: Dictionary, invalidated: int) -> void:
	print("VTLIFETIME mode=%s tick=%d invalidated=%d cpu_ms=%.4f fade_ms=%.4f queue=%d capacity=%d active=%d pending=%d held=%d starts=%d ticks_max=%d ready=%d page_count=%d memory=%d" % [
			mode, tick_index, invalidated, float(stats["cpu"]), float(stats["fade_cpu"]),
			int(stats["queue"]), int(stats["capacity"]), int(stats["active"]),
			int(stats["pending"]), int(stats["held"]), int(stats["starts"]),
			int(stats["ticks_max"]), int(stats["ready"]), int(stats["page_count"]),
			int(stats["memory"])])

func run_window(mode: String, ticks: int) -> Dictionary:
	var samples: Array[Dictionary] = []
	var invalidations := 0
	var starts_before := int(snapshot()["starts"])
	var max_active := 0
	var max_queue := 0
	var queue_capacity := -1
	var first_cpu := -1.0
	var last_cpu := 0.0
	for tick_index in ticks:
		if mode == "pingpong" and tick_index % MOVE_EVERY == 0:
			var side := int(tick_index / MOVE_EVERY)
			var target := Vector3(64.0 if (side & 1) == 0 else 192.0, 240.0,
					64.0 if (side & 1) == 0 else 192.0)
			camera.position = target
			terrain.set_clipmap_target(camera)
		var invalidated_this_tick := 0
		if tick_index % INVALIDATE_EVERY == 0:
			invalidated_this_tick = invalidate_resident_pages()
			invalidations += invalidated_this_tick
		await tick()
		var stats := snapshot()
		var current_cpu := float(stats["cpu"])
		if first_cpu < 0.0:
			first_cpu = current_cpu
		last_cpu = current_cpu
		max_active = maxi(max_active, int(stats["active"]))
		max_queue = maxi(max_queue, int(stats["queue"]))
		if queue_capacity < 0:
			queue_capacity = int(stats["capacity"])
		elif int(stats["capacity"]) != queue_capacity:
			require(false, "%s queue capacity changed from %d to %d" % [mode, queue_capacity, int(stats["capacity"])])
		if int(stats["queue"]) > int(stats["capacity"]):
			require(false, "%s live queue exceeds its slot capacity" % mode)
		if int(stats["capacity"]) > 0 and int(stats["page_count"]) > 0 and int(stats["capacity"]) > int(stats["page_count"]):
			require(false, "%s fade queue capacity %d exceeds physical page count %d" % [mode, int(stats["capacity"]), int(stats["page_count"])])
		if tick_index % SAMPLE_EVERY == 0 or invalidated_this_tick > 0:
			samples.append(stats)
			sample_line(mode, tick_index, stats, invalidated_this_tick)
	var after := snapshot()
	var cpu_ratio := 0.0 if first_cpu <= 0.001 else last_cpu / first_cpu
	print("VTLIFETIME window=%s ticks=%d invalidations=%d starts_delta=%d max_active=%d max_queue=%d capacity=%d first_cpu_ms=%.4f last_cpu_ms=%.4f cpu_ratio=%.3f samples=%d" % [
			mode, ticks, invalidations, int(after["starts"]) - starts_before, max_active,
			max_queue, queue_capacity, first_cpu, last_cpu, cpu_ratio, samples.size()])
	require(invalidations > 0, "%s window did not invalidate a resident page" % mode)
	require(int(after["starts"]) > starts_before, "%s invalidations produced no fade arrival" % mode)
	require(max_active > 0, "%s arrivals never exposed an active fade" % mode)
	require(queue_capacity >= 0, "%s did not publish fade queue capacity" % mode)
	return {"samples": samples, "invalidations": invalidations, "starts": int(after["starts"]),
			"first_cpu": first_cpu, "last_cpu": last_cpu, "capacity": queue_capacity}

func run() -> void:
	var ticks_env := OS.get_environment("VT_LIFETIME_TICKS")
	var ticks := maxi(2000, int(ticks_env) if ticks_env != "" else 2000)
	await setup_scene()
	var idle_streak := 0
	for _frame in WARMUP_TICKS:
		await tick()
		var stats := snapshot()
		if int(stats["pending"]) == 0 and int(stats["ready"]) > 0:
			idle_streak += 1
		else:
			idle_streak = 0
		if idle_streak >= 12:
			break
	var warm := snapshot()
	print("VTLIFETIME warmup ready=%d pending=%d queue=%d capacity=%d cpu_ms=%.4f memory=%d" % [
			int(warm["ready"]), int(warm["pending"]), int(warm["queue"]), int(warm["capacity"]),
			float(warm["cpu"]), int(warm["memory"])])
	require(int(warm["ready"]) > 0, "warmup produced no resident AVT pages")
	require(int(warm["capacity"]) > 0, "warmup did not create a fade queue capacity")
	await test_fade_controls()
	await run_window("static", ticks)
	await run_window("pingpong", ticks)
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS VT fade lifetime keeps CPU diagnostics and page-arrival FIFO bounded over static and ping-pong windows")
	quit()
