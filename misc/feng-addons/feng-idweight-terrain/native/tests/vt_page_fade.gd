# Run with a graphical rendering driver; see README.md in this directory.
#
# A page that has just arrived has to come in over several ticks instead of appearing as a
# rectangular step.
#
# The near field refines in the grid its pages are: a finer page resolves its texels at full
# weight the frame its content lands, so the view switches from the level it replaced to the page
# itself in one frame, block by block. A turning camera makes that obvious, because the working
# set moves and pages land continuously.
#
# What is measured is the ramp itself: a page's content is dropped (which is what a lost encode, a
# rebuild that discards a page, or a page re-produced after an edit leaves behind), the engine
# re-produces it, and the ticks during which the engine publishes a fading slot are counted. With
# `vt_page_fade_frames` at 0 nothing may fade ever; with it at N the ramp has to run for N ticks
# and leave the view exactly where it started. That is the whole contract, and it is the mechanism
# the image depends on.
#
# The *image* half of it - a frame between the level that was there and the page that arrives - is
# measured at the sample the drop moved most, and that measurement has to be *made possible* by the
# scene. It is the camera's orthographic size that does it, because it decides which mip of a page the
# shader selects, and therefore whether the page draws something the source array does not:
#
#     camera.size = 192 m    a screen pixel covers ~0.6 m, the page mip averages the checkerboard to
#                            what the array draws, and the two differ by 0.0039 in red - measured by
#                            turning the virtual texture off and sampling the same row. Not measurable.
#     camera.size = 4 m      a screen pixel covers ~0.013 m, the page mip shows the checkerboard, and
#                            the level behind the dropped page differs from it by 0.15 in red.
#
# Three earlier explanations for why this half could not be measured were tested and are **wrong**;
# they are recorded here so they are not re-derived from the source:
#
#   * that a page's mip levels cannot differ, because a payload texel is an exact multiple of a page
#     texel on aligned grids. Raising the density until a payload texel *is* one page texel wide, so
#     that the level above spans two payload texels, changes which pages the plan holds and still
#     moved no sample.
#   * that the fade left the view mid-ramp when the shot was taken, so "settled" no longer meant the
#     view was showing the pages. Turning the fade off from the test side changed nothing.
#   * that the row was not virtual-texture resolved at all. It *was*, by a four-thousandth.
#
# Each measurement builds its own scene. Dropping a page reshapes the pool, so a second
# measurement in the same scene does not start from the state the first one did.
extends SceneTree

const REGION_SIZE := 64
# Stored surface payload texels per metre.
const DENSITY := 4
const GRID := 4
const PAGE_SIZE := 32
const PAGE_BORDER := 2
# Sized so the plan can hold the visible sector's whole mip chain. The planner leaves 128 pages of
# the pool for its retained tail and walks with the rest, so a pool of 128 leaves a 32-page walk -
# barely one level per sector - and a dropped page then has no level behind it to fall back to.
const PAGE_COUNT := 512
const VIEW_WORLD := Vector2(160.0, 160.0)
const FADE_FRAMES := 20
# A frame counts as "between" only when it is clear of both ends: the render is not bit exact frame
# to frame, and a value a shade away from the level behind is still that level.
const BETWEEN_LOW := 0.12
const BETWEEN_HIGH := 0.88
# Samples across the middle of the viewport, and how far one has to move when a page's content goes
# away to count as a level behind the page rather than render noise.
const ROW_SAMPLES := 33
const DIFFERENT := 0.01
# How far a frame may read below the one before it before the ramp counts as going backwards. The
# render is not bit exact frame to frame, so a shade of noise is not a flicker.
const RAMP_TOLERANCE := 0.02
# Ticks to let the view produce itself before a measurement. A dropped page takes a few demand
# passes to assemble again (~24 is what the recovery test measures).
const WARMUP := 240
# Ticks an arrival is observed for: the ~24 of a re-production plus the ramp.
const OBSERVE := 80

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func tick() -> void:
	# The engine's whole VT section, not one demand pass: the page-arrival fade is a phase of the
	# tick, because it is the demand passes' readiness checks that say a page arrived.
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	await process_frame
	await RenderingServer.frame_post_draw

func material_word(id: int) -> int:
	return (id << 11) | (id << 6)

func make_pattern(size: int, a: Color, b: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var gradient := float(x + y) / float(maxi(1, (size - 1) * 2))
			image.set_pixel(x, y, a.lerp(b, 0.25 + gradient * 0.45))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	var dark := Terrain3DTextureAsset.new()
	dark.albedo_texture = make_pattern(64, Color(0.02, 0.03, 0.04), Color(0.10, 0.07, 0.05))
	terrain.assets.set_texture_asset(0, dark)
	var bright := Terrain3DTextureAsset.new()
	bright.albedo_texture = make_pattern(64, Color(0.25, 0.85, 0.12), Color(0.98, 0.34, 0.06))
	terrain.assets.set_texture_asset(1, bright)

# A one-payload-texel checkerboard of the two materials, so a page's mip levels have something to
# subsample differently.
func fill_region(location: Vector2i) -> void:
	var side := REGION_SIZE * DENSITY
	var bytes := PackedByteArray()
	bytes.resize(side * side * 2)
	for y in side:
		for x in side:
			var id := 1 if ((x + y) & 1) == 0 else 0
			bytes.encode_u16((y * side + x) * 2, material_word(id))
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(side, side, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func build_scene() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)
	add_materials()
	camera = Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# 4 m across. This is the setting that makes the image half measurable, and it is worth saying why:
	# at 192 m across one screen pixel covers about 0.6 m, far coarser than the 0.25 m payload texel,
	# so the shader selects a coarse page mip that averages the checkerboard to very nearly what the
	# source array draws - measured at a four-thousandth of the red channel, which no threshold can
	# resolve. At 4 m a screen pixel covers about 0.013 m, the shader selects a page mip that shows the
	# checkerboard itself, and the level behind the page differs from it by 0.15 in red.
	camera.size = 4.0
	camera.position = Vector3(VIEW_WORLD.x, 180.0, VIEW_WORLD.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.region_size = REGION_SIZE
	terrain.surface_density = DENSITY
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_pages_per_update = 16
	# The resolution preset, not `surface_vt_pages_per_axis`: it is what links the page count per
	# axis to the texel density (512 over a 64 m sector at a 32 texel page is 16 pages per axis and
	# 8 texels per metre). Setting one without the other leaves the two disagreeing, and then the
	# scene is not the one this test reasons about.
	terrain.surface_vt_resolution = 512
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_selection_mode = 2
	terrain.surface_svt_enabled = false
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location)
	terrain.data.update_maps()
	# Only the notification this test sends drives the tick: the node's own physics processing
	# would run a second VT section per awaited frame, which would count the ramp down at twice
	# the rate the test asks for.
	terrain.set_physics_process(false)

func free_scene() -> void:
	scene.queue_free()
	await process_frame

func producer_stats() -> Dictionary:
	return terrain.get_vt_settings().get("producer", {})

func sample_center() -> Color:
	var image := root.get_texture().get_image()
	return image.get_pixel(image.get_width() / 2, image.get_height() / 2)

# A horizontal row across the middle of the viewport. One pixel is a coin flip: a page is read with
# the nearest source texel, so a fine and a coarse page texel resolve the same payload texel at some
# world positions and a different one a quarter of a texel away. The scene has positions where the
# level behind a dropped page differs from it, and the test's job is to find one rather than to hope
# the centre is one of them.
func sample_row() -> PackedColorArray:
	var image := root.get_texture().get_image()
	var y := image.get_height() / 2
	var row := PackedColorArray()
	for i in ROW_SAMPLES:
		row.append(image.get_pixel(int(float(i) / float(ROW_SAMPLES - 1) * float(image.get_width() - 1)), y))
	return row

# The index of the sample whose colour moved most when the page's content went away, or -1 when none
# moved: the level behind the dropped page resolves the same source texels as the page does, so this
# scene has nothing between the two ends of the ramp to show.
func differing_sample(before_row: PackedColorArray, after_row: PackedColorArray) -> int:
	var best := -1
	var best_distance := 0.0
	for i in before_row.size():
		var distance := Vector3(after_row[i].r - before_row[i].r, after_row[i].g - before_row[i].g,
				after_row[i].b - before_row[i].b).length()
		if distance > best_distance:
			best_distance = distance
			best = i
	return best if best_distance >= DIFFERENT else -1

func same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.002 and absf(a.g - b.g) < 0.002 and absf(a.b - b.b) < 0.002

# Whether a sampled colour is the missing-page diagnostic rather than material.
func is_diagnostic(color: Color) -> bool:
	return color.r > color.g * 1.5 and color.b > color.g * 1.5

# Where a sampled colour sits on the line from the level that was there to the page that arrives:
# 0 at the old level, 1 at the new one.
func position_of(value: Color, from: Color, to: Color) -> float:
	var axis := Vector3(to.r - from.r, to.g - from.g, to.b - from.b)
	if axis.length_squared() < 0.000001:
		return -1.0
	return Vector3(value.r - from.r, value.g - from.g, value.b - from.b).dot(axis) / axis.length_squared()

# The resident pages covering the view centre, finest first. They are the pages the demand pass
# checks for readiness, which is what a fade's start is recorded from.
func covering_pages() -> Array:
	var found: Array = []
	for page in terrain.get_vt_pages():
		if not bool(page.get("ready", false)):
			continue
		var rect: Rect2 = page.get("world_rect", Rect2())
		if not rect.has_point(VIEW_WORLD):
			continue
		found.append([rect.size.x, int(page.get("slot", -1))])
	found.sort()
	var slots: Array = []
	for entry in found:
		if not slots.has(entry[1]):
			slots.append(entry[1])
	return slots

# One measurement, on a scene of its own: build, settle, drop a page, count the ramp.
func measure(fade_frames: int) -> Dictionary:
	build_scene()
	terrain.vt_page_fade_frames = fade_frames
	terrain.surface_vt_enabled = true
	for _frame in WARMUP:
		await tick()
	var producer := producer_stats()
	var before := sample_center()
	var before_row := sample_row()
	var candidates := covering_pages()
	var active_ticks := 0
	var fading := 0
	var last := before
	var worst := before
	var coarse := before
	var between := 0
	var trace := ""
	var dropped := false
	# The sample the image half is measured on, and the two ends of its ramp.
	var sample_at := -1
	var sample_from := before
	# Where each observed frame sits between the two ends, so the shape of the ramp can be asserted
	# rather than only its endpoints.
	var ramp: Array = []
	# Every page that covers the view, not just the first. Which one the shader resolves at a given point
	# is its own choice, so dropping one leaves the others to answer with the same content; and a page
	# grid refining in blocks - the thing this feature exists for - means several pages arriving close
	# together, which is what invalidating them all measures.
	for slot in candidates:
		if terrain.debug_invalidate_vt_page(slot):
			dropped = true
	if dropped:
		# Let the fallback settle: the shader resolves the level behind the page from the frame the
		# page's content is gone, and that level is the ramp's other end.
		var coarse_row := before_row
		for _frame in 8:
			await tick()
			coarse = sample_center()
			coarse_row = sample_row()
		# Measure on the sample the drop actually moved. Which one that is depends on where the
		# coarse texel's centre lands relative to the payload texels, so it is found rather than
		# fixed - a single centre pixel is a coin flip in this scene, and one that lands the same
		# way makes the whole image half unmeasurable.
		sample_at = differing_sample(before_row, coarse_row)
		if sample_at >= 0:
			sample_from = coarse_row[sample_at]
		var frames: Array = []
		for _frame in OBSERVE:
			await tick()
			last = sample_center()
			if sample_at >= 0:
				frames.append(sample_row()[sample_at])
			if is_diagnostic(last):
				worst = last
			var active := int(terrain.get_vt_settings().get("vt_page_fade_active_slots", 0))
			fading = maxi(fading, active)
			if active > 0:
				active_ticks += 1
			if fade_frames > 0:
				trace += "%d:%d " % [_frame, active]
		# How many frames of the arrival landed strictly between the level that was there and the
		# page that arrived. A step has none; a ramp has one per fading tick.
		if sample_at >= 0:
			var target: Color = before_row[sample_at]
			for frame in frames:
				var at := position_of(frame, sample_from, target)
				ramp.append(at)
				if at > BETWEEN_LOW and at < BETWEEN_HIGH:
					between += 1
	var result := {"ready": int(producer.get("ready_pages", -1)), "before": before, "last": last,
			"coarse": coarse, "between": between, "fading": fading, "active_ticks": active_ticks,
			"dropped": dropped, "diagnostic": is_diagnostic(worst), "candidates": candidates,
			"sample_at": sample_at, "sample_from": sample_from,
			"sample_to": before_row[sample_at] if sample_at >= 0 else before, "ramp": ramp,
			"trace": trace}
	await free_scene()
	return result

# One measurement, repeated until its arrival actually happened. See the call site.
func measure_until(fade_frames: int, tries: int) -> Dictionary:
	var result: Dictionary = await measure(fade_frames)
	for _attempt in tries - 1:
		if int(result["active_ticks"]) > 0:
			break
		print("VTPAGEFADE frames=%d attempt produced no ramp, retrying" % fade_frames)
		result = await measure(fade_frames)
	return result

func run() -> void:
	var stepped: Dictionary = await measure(0)
	var ramped: Dictionary = await measure_until(FADE_FRAMES, 4)
	var longer: Dictionary = await measure_until(FADE_FRAMES * 2, 4)
	print("VTPAGEFADE step ready=%d dropped=%s candidates=%s active_ticks=%d fading=%d before=%s coarse=%s between=%d diagnostic=%s" % [
			int(stepped["ready"]), bool(stepped["dropped"]), stepped["candidates"],
			int(stepped["active_ticks"]), int(stepped["fading"]),
			stepped["before"], stepped["coarse"], int(stepped["between"]), bool(stepped["diagnostic"])])
	print("VTPAGEFADE ramp ready=%d dropped=%s candidates=%s active_ticks=%d fading=%d before=%s coarse=%s between=%d diagnostic=%s" % [
			int(ramped["ready"]), bool(ramped["dropped"]), ramped["candidates"],
			int(ramped["active_ticks"]), int(ramped["fading"]),
			ramped["before"], ramped["coarse"], int(ramped["between"]), bool(ramped["diagnostic"])])
	print("VTPAGEFADE trace ", ramped["trace"])
	print("VTPAGEFADE longer ready=%d dropped=%s active_ticks=%d fading=%d between=%d last=%s" % [
			int(longer["ready"]), bool(longer["dropped"]),
			int(longer["active_ticks"]), int(longer["fading"]), int(longer["between"]), longer["last"]])

	require(int(stepped["ready"]) > 0, "the settle phase produced no page")
	require(int(ramped["ready"]) > 0, "the settle phase produced no page")
	require(int(longer["ready"]) > 0, "the settle phase produced no page")
	require(bool(stepped["dropped"]), "a resident page covering the view must be available to drop")
	require(bool(ramped["dropped"]), "a resident page covering the view must be available to drop")
	require(bool(longer["dropped"]), "a resident page covering the view must be available to drop")
	# With the fade off nothing may ever fade, which is what makes the runs a controlled set.
	require(int(stepped["fading"]) == 0, "with the fade off no slot may be fading, got %d" % int(stepped["fading"]))
	require(int(stepped["active_ticks"]) == 0, "with the fade off the ramp must not run, ran for %d ticks" % int(stepped["active_ticks"]))
	# With it on, an arriving page publishes a ramp that runs over several frames: shorter and the
	# arrival is still a step, which is the whole complaint.
	require(int(ramped["fading"]) > 0, "an arriving page must publish a fading slot")
	require(int(ramped["active_ticks"]) >= 6,
			"the ramp must run over several frames, ran for %d" % int(ramped["active_ticks"]))
	# The setting is what decides how long it runs: an arrival cannot take the same number of
	# frames however long the ramp was asked for. The assertion is on the ordering rather than on
	# the exact count, because how many frames one tick is spread over belongs to the engine's
	# frame pacing, not to the fade.
	require(int(longer["active_ticks"]) > int(ramped["active_ticks"]),
			"asking for a longer fade must give a longer ramp: %d against %d" % [
				int(longer["active_ticks"]), int(ramped["active_ticks"])])
	# And the ramp has to end on the page that arrived: the view is exactly where it started.
	require(same(ramped["last"], ramped["before"]),
			"the ramp must finish on the page that arrived: %s against %s" % [ramped["last"], ramped["before"]])
	require(same(stepped["last"], stepped["before"]),
			"the arrival must finish on the page that arrived: %s against %s" % [stepped["last"], stepped["before"]])
	require(same(longer["last"], longer["before"]),
			"the arrival must finish on the page that arrived: %s against %s" % [longer["last"], longer["before"]])

	# The image half of the contract, measured at the sample the drop moved most. This is the assertion
	# the feature exists for: with the fade off an arrival is a step, and with it on the arrival passes
	# through frames that are neither the level behind nor the page.
	var measured := int(ramped["sample_at"]) >= 0
	print("VTPAGEFADE image_measurable=%s sample=%d from=%s to=%s" % [measured,
			int(ramped["sample_at"]), ramped["sample_from"], ramped["sample_to"]])
	require(measured, "the scene must have a sample the dropped page's fallback moves, or the image half is not tested")
	require(int(stepped["between"]) == 0,
			"with the fade off a page arrival must be a single step, but %d frames were in between" % int(stepped["between"]))
	require(int(ramped["between"]) >= 3,
			"with the fade on the arrival must pass through intermediate frames, got %d" % int(ramped["between"]))
	require(int(longer["between"]) > int(ramped["between"]),
			"a longer fade must spend more frames in between: %d against %d" % [
				int(longer["between"]), int(ramped["between"])])

	# The *shape* of the ramp, not only its endpoints. A fade whose value leaves one end and reaches
	# the other in a single frame is a step with extra bookkeeping, and one that goes backwards is the
	# flicker this whole feature exists to remove. The progression is printed so it can be read, and
	# required to be monotonic: the sample starts where the level behind it is, arrives at the page,
	# and never returns.
	var positions: Array = ramped["ramp"]
	print("VTPAGEFADE ramp_shape frames=%d " % positions.size(), positions)
	require(positions.size() > 0, "the ramp must have been sampled")
	var backwards := 0
	for index in range(1, positions.size()):
		if float(positions[index]) < float(positions[index - 1]) - RAMP_TOLERANCE:
			backwards += 1
	require(backwards == 0,
			"the ramp must not go backwards, which is a flicker: %d frame(s) did" % backwards)
	require(float(positions[positions.size() - 1]) > 1.0 - RAMP_TOLERANCE,
			"the ramp must reach the page that arrived, ended at %.3f" % float(positions[positions.size() - 1]))

	if failed:
		quit(1)
		return
	print("PASS a page arrival publishes a ramp instead of a step")
	quit()
