# Run with a graphical rendering driver; see README.md in this directory.
#
# GPU page demand. The compute pass projects every candidate page, measures its screen
# extent and writes the local mip that would put about one page texel on one screen
# pixel, or NO_REQUEST when the page is behind the camera, off screen or too small.
#
# The whole grid is compared against an independently restated version of that rule
# computed in GDScript, so this pins the projection, the off-screen cull and the mip
# maths rather than just "some numbers came back". It also checks that the readback is
# genuinely deferred: the result is not available when it is requested.
extends SceneTree

const GRID_CHUNKS := 24
const PAGES_PER_AXIS := 4
const REGION_SIZE := 64.0
const PAGE_WORLD := REGION_SIZE / float(PAGES_PER_AXIS) # 16 m
# 64 texels, not 16: the mip is chosen from page_size / screen_extent, so a 16 texel
# page over 16 m would keep every visible page above 8 px and the whole grid would
# correctly ask for mip 0, leaving no gradient to verify.
const PAGE_SIZE := 64
const MAX_LOCAL_MIP := 2
const VIEWPORT := Vector2i(1280, 720)
# 4 px, not 8: the mip 1 band is a screen extent of (4, 8] px, so a higher floor would
# reject exactly the pages the gradient test needs.
const MIN_EXTENT := 4.0

var camera: Camera3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# The same rule the compute shader implements, written out separately.
func expected_mip(vp: Projection, origin: Vector2) -> int:
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for i in 4:
		var corner: Vector2 = origin + Vector2(float(i & 1), float((i >> 1) & 1)) * PAGE_WORLD
		var clip: Vector4 = vp * Vector4(corner.x, 0.0, corner.y, 1.0)
		if clip.w <= 0.0:
			return -1
		var uv := Vector2(clip.x, clip.y) / clip.w * 0.5 + Vector2(0.5, 0.5)
		mn = mn.min(uv)
		mx = mx.max(uv)
	if mx.x < 0.0 or mx.y < 0.0 or mn.x > 1.0 or mn.y > 1.0:
		return -1
	var extent_px := (mx - mn).max(Vector2.ZERO) * Vector2(VIEWPORT)
	var extent := maxf(extent_px.x, extent_px.y)
	if extent < MIN_EXTENT:
		return -1
	# GDScript has no log2(); the shader uses GLSL's log2, so restate it the same way.
	var mip := int(floor(log(maxf(float(PAGE_SIZE) / extent, 1.0)) / log(2.0)))
	return clampi(mip, 0, MAX_LOCAL_MIP)

func run() -> void:
	camera = Camera3D.new()
	root.add_child(camera)
	camera.fov = 60.0
	camera.near = 0.1
	camera.far = 4000.0
	# Tilted rather than straight down, and looking along +Z at the grid: a top-down
	# camera 100 m up only sees about 115 m of ground, so every visible page would
	# legitimately want mip 0 and there would be no gradient to check. A Godot camera
	# looks down -Z, so Y = 180 turns it toward the grid.
	camera.position = Vector3(REGION_SIZE * 0.5 * GRID_CHUNKS, 40.0, -120.0)
	camera.rotation_degrees = Vector3(-12.0, 180.0, 0.0)
	await process_frame

	var grid_width := GRID_CHUNKS * PAGES_PER_AXIS
	var feedback := Terrain3DVTFeedback.new()
	var err := feedback.initialize(grid_width, grid_width)
	require(err == OK, "feedback should initialize, got " + str(err))
	require(feedback.is_initialized(), "feedback should report initialized")
	if failed:
		quit(1)
		return

	var vp: Projection = camera.get_camera_projection() * Projection(camera.global_transform.affine_inverse())
	var origin := Vector2i.ZERO
	err = feedback.dispatch(vp, PAGES_PER_AXIS, REGION_SIZE, PAGE_WORLD, PAGE_SIZE, MAX_LOCAL_MIP,
			origin, VIEWPORT, MIN_EXTENT)
	require(err == OK, "dispatch should succeed, got " + str(err))
	require(int(feedback.get_stats()["dispatch_count"]) == 1, "one dispatch should be counted")

	# The readback is deferred: asking for it must not block and must not have a result.
	err = feedback.request_readback()
	require(err == OK, "readback request should succeed, got " + str(err))
	require(feedback.is_readback_pending(), "the readback should be pending")
	require(not feedback.has_result(), "the readback must not have a result immediately")

	# A local rendering device has no frame advance of its own, so sync() is where the
	# queued download is transferred and the callback fires. The result is therefore
	# one frame behind the dispatch, which is the usual feedback latency.
	err = feedback.sync()
	require(err == OK, "sync should succeed, got " + str(err))
	require(feedback.has_result(), "the readback should have completed after sync")
	require(not feedback.is_readback_pending(), "the readback should no longer be pending")
	require(int(feedback.get_stats()["readback_count"]) == 1, "one readback should be counted")
	if not failed:
		print("PASS vt feedback readback is deferred and completes on sync")

	# Every cell against the independently computed rule.
	var mismatches := 0
	var first := ""
	var requested := 0
	var finest := 99
	var coarsest := -1
	for gy in grid_width:
		for gx in grid_width:
			var chunk := origin + Vector2i(gx / PAGES_PER_AXIS, gy / PAGES_PER_AXIS)
			var page := Vector2i(gx % PAGES_PER_AXIS, gy % PAGES_PER_AXIS)
			var page_origin: Vector2 = Vector2(chunk) * REGION_SIZE + Vector2(page) * PAGE_WORLD
			var want := expected_mip(vp, page_origin)
			var got: int = feedback.get_mip(gx, gy)
			if got != want:
				mismatches += 1
				if first == "":
					first = "cell (%d,%d) chunk %s page %s got %d want %d" % [gx, gy, chunk, page, got, want]
			if got >= 0:
				requested += 1
				finest = mini(finest, got)
				coarsest = maxi(coarsest, got)
	require(mismatches == 0, "%d of %d cells disagree with the expected rule, first %s" % [mismatches, grid_width * grid_width, first])
	# Histogram of the raw output, so a failure says which branch the shader took.
	var hist := {}
	for gy in grid_width:
		for gx in grid_width:
			var raw: int = feedback.get_raw(gx, gy)
			var key := "mip%d" % (raw - 1) if raw < 0xFFFFFFFC else "0x%08X" % raw
			hist[key] = int(hist.get(key, 0)) + 1
	print("FEEDBACK raw histogram=", hist)
	require(requested > 0, "some pages should be requested")
	require(requested < grid_width * grid_width, "pages off screen or too small must not be requested")
	require(finest == 0, "the pages under the camera should want mip 0, finest was " + str(finest))
	require(coarsest > finest, "distant pages should want a coarser mip, got " + str(coarsest))
	require(feedback.get_request_count() == requested, "request count should match the decoded grid")
	print("FEEDBACK requested=", requested, " of ", grid_width * grid_width,
			" mips ", finest, "..", coarsest, " stats=", feedback.get_stats())
	if not failed:
		print("PASS vt feedback projects every page and matches the expected mip rule")

	# A camera looking away must request nothing: the cull is what makes this better
	# than a distance rule, which cannot see the view direction at all.
	camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	await process_frame
	var away_vp: Projection = camera.get_camera_projection() * Projection(camera.global_transform.affine_inverse())
	feedback.dispatch(away_vp, PAGES_PER_AXIS, REGION_SIZE, PAGE_WORLD, PAGE_SIZE, MAX_LOCAL_MIP,
			origin, VIEWPORT, MIN_EXTENT)
	feedback.request_readback()
	feedback.sync()
	require(feedback.has_result(), "the second readback should have completed")
	require(feedback.get_request_count() == 0,
			"a camera pointing away must request no pages, got " + str(feedback.get_request_count()))
	if not failed:
		print("PASS vt feedback requests nothing when the pages are off screen")

	feedback.clear()
	require(not feedback.is_initialized(), "clear should release the device and resources")
	feedback.free()
	camera.free()
	if failed:
		quit(1)
		return
	print("PASS virtual texture GPU feedback")
	quit()
