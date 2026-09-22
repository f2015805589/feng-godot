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
#
# What the wall-clock phase means can and cannot say, measured. Nine runs of this test on one
# machine, *every one* with byte-identical work counters at the warm report - `sector_ticks` 421,
# `reuse_ticks` 402, `chain_ticks` 19, `plan_refresh_skips` 108, `requested_physical_pages` 157,
# `retained_requests` 93 - reported these warm near-field means: 0.1299, 0.1142, 0.0863, 0.0874,
# 0.1432, 0.1068, 0.1189, 0.1213, 0.0912 ms, and these slow ones: 0.1056, 0.0799, 0.0774, 0.0801,
# 0.0833, 0.0871, 0.0938, 0.1275, 0.1098 ms. The two sweeps swap sides between runs - the last one
# has the warm sweep inside the budget and the slow one over it, the one before the reverse - with
# the counters unmoved in both. The same sweep on the same binary moves by 66%, and the mean of the
# *service* phase, whose whole work is a few microseconds of cache checks, moves with it (0.0096 to
# 0.0150 ms) while its counters also do not change. The variable is the main thread being descheduled
# inside a phase, not the code: a phase is wall time on one thread, and one 3 ms stall in a 60 frame
# sweep is worth 0.05 ms of its mean. So `VT_BUDGET_MS` is a *shape* check - a change that alters the
# work moves every number together - and a single threshold on a 60 frame mean will sit on the wrong
# side of it on a loaded machine about as often as not. Read the counters and the stage sums before
# believing a red or a green, and see README.md for the same table and for the session drift that
# makes a run comparable only to one taken under the same machine state.
extends SceneTree

const REGION_SIZE := 256
const GRID := 3 # Regions -1..1, a 768 m world.
const GROUND_STEPS := REGION_SIZE # One height texel per metre at the default spacing.
const NEAR_DISTANCE := 256.0
const TURN_STEP := 6.0 # Degrees per frame: ten times a fast mouse swipe.
# A realistic sweep rate, for the number a session actually runs at. `TURN_STEP` is a stress: at
# 2160 degrees per second the plan key changes on every frame, so every frame pays the planner's
# whole re-plan chain, and the working set never settles. A normal fast turn is a few tens of
# degrees per second, which is what this measures.
const TURN_STEP_SLOW := 1.5
# How close to the camera the per-cell readiness report samples, in metres. A point this close has a
# pixel footprint of a few millimetres, so anything answered at 0.02 m per texel or coarser is a
# visible patch rather than detail.
const NEAR_PROBE_RADIUS := 16.0
# The bound the report asserts. A cell's whole-cell page is 64 m of world in one 256-texel page, i.e.
# 0.25 m per texel, and two cells at the same distance must not differ by a whole level of the
# pyramid: one refined and its neighbour left at the root. Ordering the plan's walk by page span
# instead of by distance or local mip descends every cell one world level before any cell descends
# two, which is what this bound checks. It is deliberately not the pixel footprint: a complete
# quadtree chain to a few millimetres costs 1+4+16+... entries per cell and the plan holds ~128 for
# the whole reach, so the reachable contract is uniformity, not full detail everywhere.
const NEAR_TEXEL_BOUND := 0.2
const SWEEP_FRAMES := 60 # One full revolution.
const SAMPLE_SIZE := Vector2i(160, 90)
const SETTLE_FRAMES := 300
const VT_BUDGET_MS := 0.1
# `vt_frame_budget_ms` is re-armed at the start of every phase, so it bounds one pass rather
# than the whole section: what a profiler attributes a peak to is a phase, and that is what
# this test requires to stay inside the budget. The section as a whole can therefore spend up
# to one phase budget for each of the three phases that run.
const VT_SECTION_BUDGET_MS := 3.0 * VT_BUDGET_MS
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
# Per-phase sums, so the report carries means beside the peaks. A peak on this machine can be the
# wall-clock reading of a phase the main thread was descheduled in, which says nothing about what
# the phase costs; the mean is the number a budget should be argued from.
var sum_phases := Vector4.ZERO
var sum_fade_ms := 0.0

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
		var phases: Dictionary = get_phases(settings)
		peak_vt_phases.x = maxf(peak_vt_phases.x, float(phases.get("service", 0.0)))
		peak_vt_phases.y = maxf(peak_vt_phases.y, float(phases.get("avt", 0.0)))
		peak_vt_phases.z = maxf(peak_vt_phases.z, float(phases.get("svt", 0.0)))
		peak_vt_phases.w = maxf(peak_vt_phases.w, maxf(float(phases.get("topup", 0.0)), float(phases.get("bake", 0.0))))
		sum_phases.x += float(phases.get("service", 0.0))
		sum_phases.y += float(phases.get("avt", 0.0))
		sum_phases.z += float(phases.get("svt", 0.0))
		sum_phases.w += maxf(float(phases.get("topup", 0.0)), float(phases.get("bake", 0.0)))
		sum_fade_ms += float(phases.get("fade", 0.0))
		timed_frames += 1
	await process_frame
	await RenderingServer.frame_post_draw

func turn(yaw: float) -> void:
	camera.rotation_degrees = Vector3(-4.0, yaw, 0.0)

# The phase dictionary of one tick, through one accessor so every reader is looking at the same
# keys.
func get_phases(settings: Dictionary) -> Dictionary:
	return settings.get("vt_phases", {})

# One revolution in `p_step` degree steps. Returns the worst magenta scan seen.
func sweep(label: String, yaw_start: float, measure: bool, sample: bool, p_step: float = TURN_STEP) -> Dictionary:
	var worst := {"bands": Vector3i.ZERO, "near": 0, "far": 0, "nearest_m": 0.0, "farthest_m": 0.0}
	for frame in SWEEP_FRAMES:
		turn(yaw_start + p_step * float(frame))
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
	sum_phases = Vector4.ZERO
	sum_fade_ms = 0.0
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
	print("VT_TURNBUDGET ", label, " cdlod_peak_parts=", terrain.get_cdlod_stats())
	print("VT_TURNBUDGET ", label, " avt_peak_stats=", settings.get("avt_peak_stats", {}),
			" age_ms=", settings.get("avt_peak_age_ms", -1.0))
	# `svt_stats` is the far field's worst pass *since startup*, not this sweep's: it is only
	# rewritten when a pass beats the record, so it is identical in every report below. The
	# frame it happened on is printed beside it so a settle-time burst cannot be read as the
	# sweep's cost - `avt_peak_age_ms` exists for the same reason on the near-field side.
	print("VT_TURNBUDGET ", label, " svt_stats=", settings.get("svt_stats", {}),
			" svt_worst_frames_ago=", settings.get("svt_worst_frames_ago", -1.0))
	print("VT_TURNBUDGET ", label, " vt_phase_peaks service=%.4f avt=%.4f svt=%.4f topup_or_bake=%.4f" % [
			peak_vt_phases.x, peak_vt_phases.y, peak_vt_phases.z, peak_vt_phases.w])
	print("VT_TURNBUDGET ", label, " vt_phase_means service=%.4f avt=%.4f svt=%.4f topup_or_bake=%.4f fade=%.4f" % [
			sum_phases.x / float(frames), sum_phases.y / float(frames), sum_phases.z / float(frames),
			sum_phases.w / float(frames), sum_fade_ms / float(frames)])
	# The assertion is on the mean, not the peak. A peak here is a wall-clock reading, and on a loaded
	# machine it is dominated by the main thread being descheduled rather than by the phase's work:
	# the near field's peak and mean differ by 6x. The mean is what a budget is about, and it is what
	# the release template meets - measured 0.080 ms for the near field with the release library
	# against 0.122 ms with the debug one, so this suite's debug numbers run about 1.5x high.
	var means := Vector4(sum_phases.x / float(frames), sum_phases.y / float(frames),
			sum_phases.z / float(frames), sum_phases.w / float(frames))
	require(means.x < VT_BUDGET_MS, "%s turn shared service averaged %.4f ms, over the %.2f ms budget" % [label, means.x, VT_BUDGET_MS])
	require(means.y < VT_BUDGET_MS, "%s turn near field averaged %.4f ms, over the %.2f ms budget (debug template; the release one measures about 1.5x lower)" % [label, means.y, VT_BUDGET_MS])
	require(means.z < VT_BUDGET_MS, "%s turn far field averaged %.4f ms, over the %.2f ms budget" % [label, means.z, VT_BUDGET_MS])
	require(means.w < VT_BUDGET_MS, "%s turn top-up/bake averaged %.4f ms, over the %.2f ms budget" % [label, means.w, VT_BUDGET_MS])
	require(total_vt_ms / float(frames) < VT_SECTION_BUDGET_MS,
			"%s turn VT streaming averaged %.4f ms, over the %.2f ms three-phase section budget" % [label, total_vt_ms / float(frames), VT_SECTION_BUDGET_MS])

# The finest page that is *ready* and covers one world point, and whether only the coarse tier covers
# it. This is the reading the per-cell blur report is made of: a point a few metres away that has no
# ready fine page is a point the shader draws from the coarse grid or from its cell's whole-cell page.
func finest_ready_at(p: Vector2) -> Dictionary:
	var best := {"texel": 1e9, "page_world": -1.0, "coarse_only": true, "pages": 0}
	var page_size := float(terrain.get_surface_vt().get_page_size())
	for record: Dictionary in terrain.get_vt_pages():
		if not bool(record.get("ready", false)):
			continue
		var rect: Rect2 = record.get("world_rect", Rect2())
		if not rect.has_area() or not rect.has_point(p):
			continue
		var coarse := false
		var fine := false
		for owner: Dictionary in record.get("owners", []):
			if String(owner.get("owner_type", "")) != "avt":
				continue
			if owner.get("sector", Vector2i.ZERO) == Vector2i(-2147483648, -2147483648):
				coarse = true
			else:
				fine = true
		var texel := rect.size.x / page_size
		if texel < float(best["texel"]):
			best["texel"] = texel
			best["page_world"] = rect.size.x
			best["coarse_only"] = not fine
		if fine:
			best["pages"] = int(best["pages"]) + 1
	return best


# Every cell point within `NEAR_PROBE_RADIUS` of the camera, and what actually answers it once the
# view has settled. Prints one line per sample so a coarse patch beside a sharp one is visible as
# numbers rather than as an impression, and asserts the property the report exists to check: ground
# this close must be answered by a ready *fine* page, not by the coarse grid or a whole-cell page.
func near_ready_report() -> void:
	var origin := camera.position
	var page_size := float(terrain.get_surface_vt().get_page_size())
	# The two explanations the point report cannot tell apart: the plan never asked for the finer
	# pages, or it asked and the pool could not give them a slot. `plan_level_mips` and the missing
	# counts answer the first, the pool's own counters answer the second.
	var settings_now: Dictionary = terrain.get_vt_settings()
	var avt: Dictionary = settings_now.get("avt_sector_stats", {})
	var pool: Dictionary = terrain.get_surface_vt().get_stats()
	print("VT_TURNBUDGET near plan requested=", avt.get("requested_physical_pages", -1),
			" sampled=", avt.get("sampled_pages", -1), " missing=", avt.get("visible_missing_pages", -1),
			" pending=", avt.get("visible_pending_pages", -1),
			" dropped=", avt.get("plan_dropped", -1), " carried=", avt.get("plan_carried", -1),
			" slot_wait=", avt.get("produce_slot_wait", -1), " source_wait=", avt.get("produce_source_wait", -1))
	print("VT_TURNBUDGET near level_mips=", avt.get("plan_level_mips", []))
	# The plan's own size against what it was allowed, and where its pages sit in world resolution.
	# The span histogram says which limiter stopped the walk: a budget left unused means the demand
	# gate stopped it, a budget spent means the plan is too small for the resolution it is being asked
	# for - and those two have different fixes.
	var spans := {}
	for record: Dictionary in terrain.get_vt_pages():
		if not bool(record.get("ready", false)):
			continue
		var fine := false
		for owner: Dictionary in record.get("owners", []):
			if String(owner.get("owner_type", "")) == "avt" and owner.get("sector", Vector2i.ZERO) != Vector2i(-2147483648, -2147483648):
				fine = true
		if not fine:
			continue
		var rect: Rect2 = record.get("world_rect", Rect2())
		var key := "%.2f" % (rect.size.x / page_size)
		spans[key] = int(spans.get(key, 0)) + 1
	var span_keys := spans.keys()
	span_keys.sort_custom(func(a, b): return float(a) < float(b))
	var span_text := ""
	for k: String in span_keys:
		span_text += "%s m/texel x%d  " % [k, int(spans[k])]
	print("VT_TURNBUDGET near budget=", avt.get("plan_budget", -1), " pool=", avt.get("pool_pages", -1),
			" allowance=", avt.get("allowance", -1), " used=", avt.get("requested_physical_pages", -1),
			" coarse_pages=", avt.get("avt_coarse_pages", -1))
	print("VT_TURNBUDGET near spans ", span_text)
	print("VT_TURNBUDGET near pool page_count=", pool.get("page_count", -1), " free=", pool.get("free_count", -1),
			" evict=", pool.get("evict_count", -1), " miss=", pool.get("miss_count", -1),
			" protected=", pool.get("protected_count", -1), " reserved=", pool.get("reserved_count", -1),
			" reserved_blocked=", pool.get("reserved_block_count", -1),
			" protected_blocked=", pool.get("protected_block_count", -1))
	var coarse_texel := 1.0
	# The settled reading, then the same readings after a small move: the reported symptom is a patch
	# changing as a whole when the camera moves, so the contract has to be checked after one.
	var before := near_scan(true)
	camera.position.z -= 3.0
	for frame in 60:
		await tick(false)
	var after := near_scan(false)
	print("VT_TURNBUDGET near move before_worst=%.5f after_worst=%.5f before_unanswered=%d after_unanswered=%d" % [
			float(before["worst"]), float(after["worst"]), int(before["unanswered"]), int(after["unanswered"])])
	var regressed := 0
	var worst_ratio := 0.0
	for key: String in before["offsets"].keys():
		if not after["offsets"].has(key):
			continue
		var was := float(before["offsets"][key])
		var now := float(after["offsets"][key])
		worst_ratio = maxf(worst_ratio, now / maxf(was, 1e-9))
		if now > was * 2.0 + 1e-6:
			regressed += 1
	print("VT_TURNBUDGET near move regressed_points=", regressed, " worst_ratio=%.2f" % worst_ratio)
	# The turn half of the same contract: a cell that leaves the frustum on a small yaw is the case the
	# plan's own per-cell answer could starve, and the symptom is that it comes back as a coarse patch.
	turn(6.0)
	for frame in 60:
		await tick(false)
	var turned := near_scan(false)
	var turn_regressed := 0
	var turn_ratio := 0.0
	for key: String in before["offsets"].keys():
		if not turned["offsets"].has(key):
			continue
		var was := float(before["offsets"][key])
		var now := float(turned["offsets"][key])
		turn_ratio = maxf(turn_ratio, now / maxf(was, 1e-9))
		if now > was * 2.0 + 1e-6:
			turn_regressed += 1
	print("VT_TURNBUDGET near turn after_worst=%.5f after_unanswered=%d regressed_points=%d worst_ratio=%.2f" % [
			float(turned["worst"]), int(turned["unanswered"]), turn_regressed, turn_ratio])
	require(int(turned["unanswered"]) == 0,
			"after a 6 degree turn, %d of %d points within %d m of the camera had no ready fine page finer than %.3f m (worst texel %.5f m)" % [
				int(turned["unanswered"]), int(turned["samples"]), int(NEAR_PROBE_RADIUS), NEAR_TEXEL_BOUND, float(turned["worst"])])
	require(turn_regressed == 0,
			"%d points lost a whole level of near-field resolution after a 6 degree turn (worst ratio %.2f)" % [
				turn_regressed, turn_ratio])
	print("VT_TURNBUDGET near summary samples=", int(before["samples"]), " unanswered=", int(before["unanswered"]),
			" worst_texel_m=%.5f" % float(before["worst"]), " bound_m=%.3f" % NEAR_TEXEL_BOUND,
			" page_size=", page_size, " coarse_texel_m=%.5f" % coarse_texel)
	require(int(before["samples"]) > 0, "the near-field probe sampled no point")
	require(int(before["unanswered"]) == 0,
			"%d of %d points within %d m of the camera had no ready fine page finer than %.3f m (worst texel %.5f m): a cell beside the frustum's edge is left at its whole-cell page" % [
				int(before["unanswered"]), int(before["samples"]), int(NEAR_PROBE_RADIUS), NEAR_TEXEL_BOUND, float(before["worst"])])
	require(int(after["unanswered"]) == 0,
			"after a 3 m move, %d of %d points within %d m of the camera had no ready fine page finer than %.3f m (worst texel %.5f m)" % [
				int(after["unanswered"]), int(after["samples"]), int(NEAR_PROBE_RADIUS), NEAR_TEXEL_BOUND, float(after["worst"])])
	require(regressed == 0,
			"%d points lost a whole level of near-field resolution after a 3 m camera move (worst ratio %.2f): a patch changed as a whole instead of following the view" % [
				regressed, worst_ratio])


# One pass of the near-field point scan. The per-offset finest ready texel is returned so two scans can
# be compared point by point: a patch that sharpens or blurs as a whole when the camera moves is the
# symptom this measures, and it shows up as points whose texel doubles while their neighbours do not.
func near_scan(verbose: bool) -> Dictionary:
	var origin := camera.position
	var preview := terrain.get_avt_layout_preview(camera)
	var result := {"samples": 0, "unanswered": 0, "worst": 0.0, "offsets": {}}
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var p := Vector2(origin.x + float(dx) * 4.0, origin.z + float(dz) * 4.0)
			if p.distance_to(Vector2(origin.x, origin.z)) > NEAR_PROBE_RADIUS:
				continue
			result["samples"] = int(result["samples"]) + 1
			var at := finest_ready_at(p)
			var texel := float(at["texel"])
			result["worst"] = maxf(float(result["worst"]), texel)
			result["offsets"]["%d,%d" % [dx, dz]] = texel
			var key := Vector2i((p / 64.0).floor())
			var level := -1
			var visible := false
			for cell: Dictionary in preview.get("sectors", []):
				var rect: Rect2 = cell.get("rect", Rect2())
				if rect.has_point(p):
					level = int(cell.get("level", -1))
					visible = bool(cell.get("visible", false))
					break
			if verbose:
				print("VT_TURNBUDGET near point=", p, " cell=", key, " cell_level=", level,
						" cell_visible=", visible, " finest_texel_m=%.5f" % texel,
						" page_world=%.1f" % float(at["page_world"]), " fine_pages=", int(at["pages"]),
						" coarse_only=", bool(at["coarse_only"]))
			if bool(at["coarse_only"]) or texel > NEAR_TEXEL_BOUND:
				result["unanswered"] = int(result["unanswered"]) + 1
	return result


# Temporal stability of a grazing view. A stationary camera must not shimmer: the reported symptom is
# distant sloped ground flickering, which is what sampling a mip finer than the view can carry looks
# like frame to frame. Measured as the mean absolute per-pixel change between consecutive frames, with
# the distant (upper) and near (lower) screen halves kept apart so one cannot hide behind the other.
func stability_report() -> void:
	turn(0.0)
	for frame in 40:
		await tick(false)
	var previous: Image
	var far_sum := 0.0
	var near_sum := 0.0
	var far_worst := 0.0
	var pairs := 0
	for frame in 6:
		await tick(false)
		var image := root.get_texture().get_image()
		image.resize(SAMPLE_SIZE.x, SAMPLE_SIZE.y, Image.INTERPOLATE_BILINEAR)
		if previous != null:
			pairs += 1
			for y in SAMPLE_SIZE.y:
				for x in SAMPLE_SIZE.x:
					var d := absf(image.get_pixel(x, y).r - previous.get_pixel(x, y).r)
					if y < SAMPLE_SIZE.y / 2:
						far_sum += d
						far_worst = maxf(far_worst, d)
					else:
						near_sum += d
		previous = image
	var divisor := float(SAMPLE_SIZE.x * SAMPLE_SIZE.y / 2) * float(maxi(1, pairs))
	print("VT_TURNBUDGET stability pairs=", pairs, " far_mean=%.6f" % (far_sum / divisor),
			" far_worst=%.4f" % far_worst, " near_mean=%.6f" % (near_sum / divisor))


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
	# What the settled view actually has near the camera, cell by cell, before anything is measured.
	await near_ready_report()
	await stability_report()

	# Warm sweep: report what the turn paints, then measure what it costs. A page that is
	# late while the camera sweeps fast is shown as the diagnostic on purpose - the
	# recovery switches are what fills such a fragment in - so only the settled state is
	# required to be diagnostic-free.
	var warm_paint := await sweep("warm", 0.0, false, true)
	print("VT_TURNBUDGET warm paint_worst=", warm_paint)
	reset_measurements()
	await sweep("warm", 0.0, true, false)
	report("warm")
	# The same revolution at a rate a session actually runs at. This is the sweep the phase means are
	# worth reading from: a stress-rate turn re-plans every frame by construction, so it measures the
	# re-plan chain rather than the streaming a player sees.
	reset_measurements()
	await sweep("slow", 0.0, true, false, TURN_STEP_SLOW)
	report("slow")
	var warm_settled := await settled_magenta(30)
	require(warm_settled == 0, "a settled view kept missing-page diagnostics: " + str(warm_settled))
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
