# Run with a graphical rendering driver; see README.md in this directory.
#
# A fast camera turn, measured two ways: what it paints, and what it costs.
#
# Painting. A pending far-field page has real source data behind it - the region
# payload the page is produced from - so the horizon must keep showing material while
# the camera sweeps. Magenta is counted per screen band, so a near-field miss and a
# far-field miss are told apart instead of being reported as one number.
#
# Cost. The VT section of the physics tick and CDLOD selection are read from the native
# statistics once per frame and reported as peaks. The sweep runs warm (every page the
# view needs is already resident), then cold (both atlases cleared, so every page in
# view is produced while the camera is still moving). The near-field radius is 256 m, so
# most of the frame is the far field and a far-field miss cannot hide behind the near one.
extends SceneTree

const REGION_SIZE := 256
const GRID := 3 # Regions -1..1, a 768 m world.
const GROUND_STEPS := REGION_SIZE # One height texel per metre at the default spacing.
const NEAR_DISTANCE := 256.0
const TURN_STEP := 6.0 # Degrees per frame: ten times a fast mouse swipe.
const SWEEP_FRAMES := 60 # One full revolution.
const SAMPLE_SIZE := Vector2i(160, 90)
const SETTLE_FRAMES := 300
const VT_BUDGET_MS := 0.1
const CDLOD_BUDGET_MS := 0.1

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
var output_dir := "user://"

var peak_vt_ms := 0.0
var total_vt_ms := 0.0
var peak_svt_ms := 0.0
var total_svt_ms := 0.0
var peak_tick_ms := 0.0
var total_tick_ms := 0.0
var peak_cdlod_ms := 0.0
var total_cdlod_ms := 0.0
var peak_cdlod_parts := Vector3.ZERO
var peak_upload_ms := 0.0
var peak_vt_phases := Vector4.ZERO
var timed_frames := 0
var last_magenta := Vector3i.ZERO

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func make_texture(color: Color) -> ImageTexture:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

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

# Magenta pixels per screen third, with the camera distance of a sample of them. The
# camera looks slightly down, so the horizon sits in the middle band and everything the
# near field covers fills the bottom one; the distances tell the two apart directly.
func scan_magenta() -> Dictionary:
	var image := root.get_texture().get_image()
	var full := Vector2(image.get_width(), image.get_height())
	image.resize(SAMPLE_SIZE.x, SAMPLE_SIZE.y, Image.INTERPOLATE_BILINEAR)
	var scale := full / Vector2(SAMPLE_SIZE)
	var top := 0
	var middle := 0
	var bottom := 0
	var near := 0
	var far := 0
	var nearest := 0.0
	var farthest := 0.0
	var measured := 0
	for y in SAMPLE_SIZE.y:
		for x in SAMPLE_SIZE.x:
			var color := image.get_pixel(x, y)
			if not (color.r > 0.1 and color.r > color.g * 1.5 and color.b > color.g * 1.5):
				continue
			if y < SAMPLE_SIZE.y / 3:
				top += 1
			elif y < SAMPLE_SIZE.y * 2 / 3:
				middle += 1
			else:
				bottom += 1
			if measured >= 24 or measured * 7 > top + middle + bottom:
				continue
			measured += 1
			var distance := ray_distance((Vector2(x, y) + Vector2(0.5, 0.5)) * scale)
			if distance < 0.0:
				continue
			if distance < NEAR_DISTANCE:
				near += 1
			else:
				far += 1
			nearest = distance if nearest == 0.0 else minf(nearest, distance)
			farthest = maxf(farthest, distance)
	return {"bands": Vector3i(top, middle, bottom), "near": near, "far": far,
			"nearest_m": nearest, "farthest_m": farthest}

# March the pixel's ray until it reaches the ground. Exponential steps keep this cheap;
# a ray that leaves the loaded world reaches height 0 at the world edge.
func ray_distance(screen: Vector2) -> float:
	var origin := camera.project_ray_origin(screen)
	var direction := camera.project_ray_normal(screen)
	var distance := 2.0
	while distance < 4000.0:
		var point := origin + direction * distance
		if point.y <= ground_height(Vector2(point.x, point.z)):
			return distance
		distance = distance * 1.05 + 1.0
	return -1.0

func tick(measure: bool) -> void:
	var started := Time.get_ticks_usec()
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	var tick_ms := float(Time.get_ticks_usec() - started) / 1000.0
	terrain.snap()
	if measure:
		var settings := terrain.get_vt_settings()
		var cdlod := terrain.get_cdlod_stats()
		peak_vt_ms = maxf(peak_vt_ms, float(settings.get("vt_cpu_ms", 0.0)))
		total_vt_ms += float(settings.get("vt_cpu_ms", 0.0))
		peak_svt_ms = maxf(peak_svt_ms, float(settings.get("svt_cpu_ms", 0.0)))
		total_svt_ms += float(settings.get("svt_cpu_ms", 0.0))
		peak_tick_ms = maxf(peak_tick_ms, tick_ms)
		total_tick_ms += tick_ms
		peak_cdlod_ms = maxf(peak_cdlod_ms, float(cdlod.get("cpu_update_ms", 0.0)))
		total_cdlod_ms += float(cdlod.get("cpu_update_ms", 0.0))
		peak_cdlod_parts.x = maxf(peak_cdlod_parts.x, float(cdlod.get("rebuild_ms", 0.0)))
		peak_cdlod_parts.y = maxf(peak_cdlod_parts.y, float(cdlod.get("cull_ms", 0.0)))
		peak_cdlod_parts.z = maxf(peak_cdlod_parts.z, float(cdlod.get("pack_ms", 0.0)))
		peak_upload_ms = maxf(peak_upload_ms, float(cdlod.get("upload_ms", 0.0)))
		var phases: Dictionary = settings.get("vt_phases", {})
		peak_vt_phases.x = maxf(peak_vt_phases.x, float(phases.get("service", 0.0)))
		peak_vt_phases.y = maxf(peak_vt_phases.y, float(phases.get("avt", 0.0)))
		peak_vt_phases.z = maxf(peak_vt_phases.z, float(phases.get("svt", 0.0)))
		peak_vt_phases.w = maxf(peak_vt_phases.w, maxf(float(phases.get("topup", 0.0)), float(phases.get("bake", 0.0))))
		timed_frames += 1
	await process_frame
	await RenderingServer.frame_post_draw

func turn(yaw: float) -> void:
	camera.rotation_degrees = Vector3(-4.0, yaw, 0.0)

# One revolution in TURN_STEP degree steps. Returns the worst magenta scan seen.
func sweep(label: String, yaw_start: float, measure: bool, sample: bool) -> Dictionary:
	var worst := {"bands": Vector3i.ZERO, "near": 0, "far": 0, "nearest_m": 0.0, "farthest_m": 0.0}
	for frame in SWEEP_FRAMES:
		turn(yaw_start + TURN_STEP * float(frame))
		await tick(measure)
		if not sample:
			continue
		var seen := scan_magenta()
		var total := int(seen["bands"].x) + int(seen["bands"].y) + int(seen["bands"].z)
		var worst_total := int(worst["bands"].x) + int(worst["bands"].y) + int(worst["bands"].z)
		if total > worst_total:
			worst = seen
		if total == 0:
			continue
		print("VT_TURNBUDGET magenta ", label, " frame=", frame, " ", seen,
				" svt_cpu_ms=", terrain.get_vt_settings().get("svt_cpu_ms", -1.0))
		if DirAccess.dir_exists_absolute(output_dir):
			root.get_texture().get_image().save_png(output_dir.path_join("%s_%d.png" % [label, frame]))
	return worst

# Waits for residency to settle, then samples once. Strict residency allows a diagnostic
# while a page is in production; a settled view must not keep one.
func settled_magenta(frames: int) -> int:
	for frame in frames:
		await tick(false)
	var seen := scan_magenta()
	return int(seen["bands"].x) + int(seen["bands"].y) + int(seen["bands"].z)

func reset_measurements() -> void:
	peak_vt_ms = 0.0
	total_vt_ms = 0.0
	peak_svt_ms = 0.0
	total_svt_ms = 0.0
	peak_tick_ms = 0.0
	total_tick_ms = 0.0
	peak_cdlod_ms = 0.0
	total_cdlod_ms = 0.0
	peak_cdlod_parts = Vector3.ZERO
	peak_upload_ms = 0.0
	peak_vt_phases = Vector4.ZERO
	timed_frames = 0

func report(label: String) -> void:
	var frames := maxi(1, timed_frames)
	var settings := terrain.get_vt_settings()
	var avt: Dictionary = settings.get("avt_sector_stats", {})
	print("VT_TURNBUDGET ", label, " frames=", timed_frames,
			" vt_peak_ms=%.4f vt_mean_ms=%.4f" % [peak_vt_ms, total_vt_ms / float(frames)],
			" svt_peak_ms=%.4f svt_mean_ms=%.4f" % [peak_svt_ms, total_svt_ms / float(frames)],
			" cdlod_peak_ms=%.4f cdlod_mean_ms=%.4f" % [peak_cdlod_ms, total_cdlod_ms / float(frames)],
			" cdlod_rebuild_peak_ms=%.4f cull_peak_ms=%.4f pack_peak_ms=%.4f upload_peak_ms=%.4f" % [peak_cdlod_parts.x, peak_cdlod_parts.y, peak_cdlod_parts.z, peak_upload_ms],
			" tick_peak_ms=%.4f tick_mean_ms=%.4f" % [peak_tick_ms, total_tick_ms / float(frames)])
	print("VT_TURNBUDGET ", label, " avt=", avt)
	print("VT_TURNBUDGET ", label, " vt_phase_peaks service=%.4f avt=%.4f svt=%.4f topup_or_bake=%.4f" % [
			peak_vt_phases.x, peak_vt_phases.y, peak_vt_phases.z, peak_vt_phases.w])

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://turn_budget_terrain")
	terrain.data_directory = "user://turn_budget_terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	# The region size only reaches the data once the terrain is in the tree, and every
	# region map is validated against it.
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
	turn(0.0)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	terrain.surface_vt_distance = NEAR_DISTANCE
	# The near field recovers a miss from a resident coarse page instead of diagnosing it,
	# which is the setting a session that navigates a world runs.
	terrain.surface_vt_feedback = true
	terrain.cdlod_enabled = true
	# The budget the VT section of one tick may spend. Set explicitly so the measurement
	# states the value it was taken at.
	terrain.vt_frame_budget_ms = VT_BUDGET_MS
	terrain.set_physics_process(false)
	await tick(false)
	# Settle: every page the first view needs is produced before anything is measured.
	for frame in SETTLE_FRAMES:
		await tick(false)
	var settled := terrain.get_vt_settings()
	print("VT_TURNBUDGET settled producer=", settled.get("producer", {}),
			" svt_visible_pages=", settled.get("svt_visible_pages", -1),
			" svt_root_pages=", settled.get("svt_root_pages", -1),
			" cdlod=", terrain.get_cdlod_stats())
	require(int(settled.get("producer", {}).get("ready_pages", 0)) > 0, "the settle phase produced no material page")
	require(int(terrain.get_cdlod_stats().get("selected_patches", 0)) > 0, "CDLOD selected no patch")

	# Warm sweep: report what the turn paints, then measure what it costs. A page that is
	# late while the camera sweeps fast is shown as the diagnostic on purpose - the
	# recovery switches are what fills such a fragment in - so only the settled state is
	# required to be diagnostic-free.
	var warm_paint := await sweep("warm", 0.0, false, true)
	print("VT_TURNBUDGET warm paint_worst=", warm_paint)
	reset_measurements()
	await sweep("warm", 0.0, true, false)
	report("warm")
	var warm_settled := await settled_magenta(30)
	require(warm_settled == 0, "a settled view kept missing-page diagnostics: " + str(warm_settled))
	require(peak_vt_ms < VT_BUDGET_MS,
			"warm turn VT streaming peaked at %.4f ms, over the %.2f ms budget" % [peak_vt_ms, VT_BUDGET_MS])
	require(peak_cdlod_ms < CDLOD_BUDGET_MS,
			"warm turn CDLOD peaked at %.4f ms, over the %.2f ms budget" % [peak_cdlod_ms, CDLOD_BUDGET_MS])

	# Far field alone: the near field is switched off, so every visible fragment is served
	# by the sparse world pyramid. A pending page here has to shade from the source array.
	terrain.surface_vt_enabled = false
	for frame in 120:
		await tick(false)
	var far_paint := await sweep("faronly", 90.0, false, true)
	print("VT_TURNBUDGET faronly paint_worst=", far_paint)
	reset_measurements()
	await sweep("faronly", 90.0, true, false)
	report("faronly")
	var far_settled := await settled_magenta(30)
	require(far_settled == 0, "a settled far field kept missing-page diagnostics: " + str(far_settled))
	require(peak_vt_ms < VT_BUDGET_MS,
			"far-field-only turn VT streaming peaked at %.4f ms, over the %.2f ms budget" % [peak_vt_ms, VT_BUDGET_MS])
	terrain.surface_vt_enabled = true

	# Isolate AVT and sample an abrupt opposite view while its cache is settled. This is the
	# real camera-turn contract: every direction inside reach already has an AVT terminal root.
	terrain.surface_svt_enabled = false
	turn(180.0)
	await tick(false)
	var jump_seen := scan_magenta()
	var jump_total := int(jump_seen["bands"].x) + int(jump_seen["bands"].y) + int(jump_seen["bands"].z)
	print("VT_TURNBUDGET warm_jump_avt=", jump_seen)
	require(jump_total == 0, "isolated AVT exposed polygons on a settled 180-degree turn: " + str(jump_seen))
	terrain.surface_svt_enabled = true

	# Cold sweep: a VT settings change deliberately destroys the shared pool. Its first frame
	# is allowed to diagnose while new physical content is produced; it must still settle.
	terrain.vt_page_border = 5
	var cold_paint := await sweep("cold", 180.0, false, true)
	var cold_settings := terrain.get_vt_settings()
	print("VT_TURNBUDGET cold producer=", cold_settings.get("producer", {}),
			" svt_visible_pages=", cold_settings.get("svt_visible_pages", -1),
			" bake_pending=", cold_settings.get("bake_pending", -1),
			" svt_source_pending=", cold_settings.get("svt_source_pending", -1))
	reset_measurements()
	await sweep("cold", 180.0, true, false)
	report("cold")
	var cold_settled := await settled_magenta(60)
	require(cold_settled == 0, "a rebuilt pool never recovered: " + str(cold_settled))

	print("VT_TURNBUDGET summary budget_ms=%.2f near_distance=%d regions=%d turn_step=%.1f" % [
			VT_BUDGET_MS, int(NEAR_DISTANCE), GRID * GRID, TURN_STEP])
	# Tear down in the order the node expects: a terrain still in the tree finds a camera
	# whenever it ticks, so freeing the camera first makes it report a missing target on the
	# way out - an engine error the harness reads as a failure of the code under test.
	scene.remove_child(terrain)
	terrain.queue_free()
	camera.queue_free()
	scene.queue_free()
	if failed:
		quit(1)
		return
	print("PASS camera turn painting and CPU budget")
	quit()
