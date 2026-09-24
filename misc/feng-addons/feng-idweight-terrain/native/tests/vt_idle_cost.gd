# Run with a graphical rendering driver; see README.md in this directory.
#
# What a settled view costs. Every other VT test measures a moving camera, so the cost
# they report is production; this one holds the camera still until both tiers have
# produced everything in view, then measures the ticks that follow. A settled view must
# be near free: it re-marks its resident pages as demanded and verifies them, and it must
# not run the planner, the demand walk or a second production pass.
#
# The budget is per phase and in the same units the editor's profiler shows, so a
# regression that puts a walk back in front of an idle gate is reported as the phase it
# landed in rather than as one number for the whole section.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 256
const GRID := 3
const GROUND_STEPS := REGION_SIZE
const NEAR_DISTANCE := 256.0
const SETTLE_TICKS := 400
const MEASURE_TICKS := 150
# The near field's settled cost is its resident-set verification and the statistics of the
# tick. Measured at 0.021 ms per tick with 99 resident pages; the budget leaves room for
# machine variation while staying far under the per-tick cost a settled view is complained
# about at (the phase is not supposed to be measurable next to production work).
const AVT_MEAN_BUDGET_MS := 0.05
# The far field re-verifies its roots and its detail set every tick; batching the producer
# query is what keeps that from being one lock per page.
const SVT_MEAN_BUDGET_MS := 0.08
# The top-up must be skipped outright once the near field has settled the tick: it used to
# repeat the near field's whole resident walk, its statistics and its Time call.
const TOPUP_MEAN_BUDGET_MS := 0.005
const TOTAL_MEAN_BUDGET_MS := 0.15

var scene: Node3D

func _initialize() -> void:
	call_deferred("run")

func add_assets() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 3:
		var asset := Terrain3DTextureAsset.new()
		var color := Color(0.30, 0.42, 0.16, 1.0) if id == 0 else (Color(0.46, 0.40, 0.28, 1.0) if id == 1 else Color(0.62, 0.60, 0.58, 1.0))
		asset.albedo_texture = make_texture(color)
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func write_region(location: Vector2i) -> void:
	var heights := PackedFloat32Array()
	heights.resize(GROUND_STEPS * GROUND_STEPS)
	for z in GROUND_STEPS:
		for x in GROUND_STEPS:
			var wx := float(location.x * REGION_SIZE) + float(x)
			var wz := float(location.y * REGION_SIZE) + float(z)
			var ridge := 42.0 * exp(-pow(wx / 130.0, 2.0) - pow((wz - 180.0) / 190.0, 2.0))
			var knoll := 26.0 * exp(-pow((wx - 210.0) / 90.0, 2.0) - pow((wz + 120.0) / 110.0, 2.0))
			heights[z * GROUND_STEPS + x] = ridge + knoll
	terrain.data.get_region(location).set_height_map(
			Image.create_from_data(GROUND_STEPS, GROUND_STEPS, false, Image.FORMAT_RF, heights.to_byte_array()))

func ground_height(at: Vector2) -> float:
	var spacing: float = terrain.vertex_spacing
	var grid := at / spacing
	var cell := grid.floor()
	var fraction := grid - cell
	var a := terrain.data.get_height(Vector3(cell.x * spacing, 0, cell.y * spacing))
	var b := terrain.data.get_height(Vector3((cell.x + 1) * spacing, 0, cell.y * spacing))
	var c := terrain.data.get_height(Vector3(cell.x * spacing, 0, (cell.y + 1) * spacing))
	var d := terrain.data.get_height(Vector3((cell.x + 1) * spacing, 0, (cell.y + 1) * spacing))
	return a + (b - a) * fraction.x + (d - b) * fraction.y if fraction.x > fraction.y else a + (d - c) * fraction.x + (c - a) * fraction.y

func tick() -> void:
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	terrain.snap()
	await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://idle_cost_terrain")
	terrain.data_directory = "user://idle_cost_terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.region_size = REGION_SIZE
	add_assets()
	for z in range(-1, GRID - 1):
		for x in range(-1, GRID - 1):
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			write_region(location)
	terrain.data.calc_height_range(true)
	terrain.data.update_maps()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	light.light_energy = 1.2
	scene.add_child(light)
	camera = Camera3D.new()
	camera.fov = 60.0
	camera.near = 0.1
	camera.far = 8000.0
	camera.current = true
	root.add_child(camera)
	camera.position = Vector3(8.0, 0.0, 200.0)
	camera.position.y = ground_height(Vector2(camera.position.x, camera.position.z)) + 2.0
	camera.rotation_degrees = Vector3(-4.0, 0.0, 0.0)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	terrain.surface_vt_distance = NEAR_DISTANCE
	terrain.surface_vt_feedback = true
	terrain.set_physics_process(false)
	await tick()

	# Settle: the camera never moves again, so every page the view needs is produced here
	# and the measured ticks below are the settled ones.
	for _frame in SETTLE_TICKS:
		await tick()
	var settled := terrain.get_vt_settings()
	var producer: Dictionary = settled.get("producer", {})
	var avt: Dictionary = settled.get("avt_sector_stats", {})
	print("VT_IDLE_COST settled ready=", producer.get("ready_pages", -1),
			" svt_visible=", settled.get("svt_visible_pages", -1),
			" svt_roots=", settled.get("svt_root_pages", -1),
			" plan_reused=", avt.get("plan_reused", false),
			" resident=", avt.get("visible_plan_pages", -1))
	require(int(producer.get("ready_pages", 0)) > 0, "the settle phase produced no material page")
	require(int(producer.get("pending", 1)) == 0, "the settle phase left %s pages pending" % producer.get("pending"))

	var avt_total := 0.0
	var svt_total := 0.0
	var service_total := 0.0
	var topup_total := 0.0
	var bake_total := 0.0
	var total := 0.0
	var avt_peak := 0.0
	var svt_peak := 0.0
	var produced := 0
	var idle_ticks := 0
	for _frame in MEASURE_TICKS:
		await tick()
		var settings := terrain.get_vt_settings()
		var phases: Dictionary = settings.get("vt_phases", {})
		var phase_avt := float(phases.get("avt", 0.0))
		var phase_svt := float(phases.get("svt", 0.0))
		avt_total += phase_avt
		svt_total += phase_svt
		service_total += float(phases.get("service", 0.0))
		topup_total += float(phases.get("topup", 0.0))
		bake_total += float(phases.get("bake", 0.0))
		total += float(settings.get("vt_cpu_ms", 0.0))
		avt_peak = maxf(avt_peak, phase_avt)
		svt_peak = maxf(svt_peak, phase_svt)
		var stats: Dictionary = settings.get("avt_sector_stats", {})
		produced += int(stats.get("produced", 0))
		if bool(stats.get("plan_reused", false)):
			idle_ticks += 1

	var frames := float(MEASURE_TICKS)
	print("VT_IDLE_COST avt_mean_ms=%.4f avt_peak_ms=%.4f svt_mean_ms=%.4f svt_peak_ms=%.4f service_mean_ms=%.4f topup_mean_ms=%.4f bake_mean_ms=%.4f total_mean_ms=%.4f" % [
			avt_total / frames, avt_peak, svt_total / frames, svt_peak, service_total / frames,
			topup_total / frames, bake_total / frames, total / frames])
	print("VT_IDLE_COST produced=%d idle_ticks=%d of %d resident=%s" % [
			produced, idle_ticks, MEASURE_TICKS, avt.get("visible_plan_pages", -1)])
	require(produced == 0, "a settled view produced %d pages" % produced)
	require(idle_ticks == MEASURE_TICKS, "only %d of %d settled ticks were recognised as idle" % [idle_ticks, MEASURE_TICKS])
	require(avt_total / frames < AVT_MEAN_BUDGET_MS,
			"settled near field cost %.4f ms per tick, over the %.3f ms budget" % [avt_total / frames, AVT_MEAN_BUDGET_MS])
	require(svt_total / frames < SVT_MEAN_BUDGET_MS,
			"settled far field cost %.4f ms per tick, over the %.3f ms budget" % [svt_total / frames, SVT_MEAN_BUDGET_MS])
	require(topup_total / frames < TOPUP_MEAN_BUDGET_MS,
			"settled top-up cost %.4f ms per tick, over the %.3f ms budget" % [topup_total / frames, TOPUP_MEAN_BUDGET_MS])
	require(total / frames < TOTAL_MEAN_BUDGET_MS,
			"settled VT section cost %.4f ms per tick, over the %.3f ms budget" % [total / frames, TOTAL_MEAN_BUDGET_MS])

	scene.remove_child(terrain)
	terrain.queue_free()
	camera.queue_free()
	scene.queue_free()
	if failed:
		quit(1)
		return
	print("PASS a settled view costs almost nothing")
	quit()
