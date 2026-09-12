# Run with a graphical rendering driver; see README.md in this directory.
#
# What one demand pass costs at the shipped defaults, and where that time goes.
# `Terrain3D::__physics_process()` runs the near-field and far-field demand passes on
# the main thread every physics tick, so every millisecond measured here is a
# millisecond the editor cannot spend on its UI or on the viewport.
#
# The interesting numbers are the cold pass (every page has to be produced), a settled
# pass (nothing changed, so the demand walk is pure overhead) and the pass after the
# camera moved by one region. A per-page cost above a few hundred microseconds in a
# debug build is what makes the editor stutter while the camera moves.
extends SceneTree

const REGION_SIZE := 256 # Terrain3D's default region size in metres.
const PAGES_PER_AXIS := 4
const PAGE := 256
const BORDER := 4
const PAGE_COUNT := 128 # Shipped default near-field atlas size.
const SVT_PAGE_WORLD := 512.0
const SVT_PAGE := 256
const SVT_BORDER := 4
const SVT_PAGE_COUNT := 256
const SVT_DISTANCE := 6144.0
const SETTLED_RUNS := 20
# A page is 264x264 texels at the shipped settings. Producing one is a resample of a
# region's payload, which is a memory-bound copy, not a computation: anything above
# this in a debug build means the producer is paying per-texel API overhead.
const MAX_US_PER_PAGE := 3000.0

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

func write_pattern(loc: Vector2i) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	for j in REGION_SIZE:
		for i in REGION_SIZE:
			bytes.encode_u16((j * REGION_SIZE + i) * 2, 1000 + ((i + j) & 0xFFF))
	terrain.data.get_region(loc).set_surface_map(
			Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))

func report(phase: String, usec: int, produced: int) -> void:
	var per_page := 0.0 if produced <= 0 else float(usec) / float(produced)
	print("VTPERF phase=%s ms=%.2f produced=%d us_per_page=%.1f" % [
			phase, float(usec) / 1000.0, produced, per_page])

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	# Verify the ID/weight residency contract separately from material baking.
	terrain.set_vt_debug_direct_material(true)
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.fov = 60.0
	camera.near = 0.1
	camera.far = 8000.0
	camera.position = Vector3(0.0, 200.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	terrain.region_size = REGION_SIZE
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame

	# A 5x5 block of regions. The near field's distance rule reaches 512 m, which is
	# 13 of these, so this is the resident set an editor session actually has.
	var locs: Array[Vector2i] = []
	for y in range(-2, 3):
		for x in range(-2, 3):
			locs.append(Vector2i(x, y))
	for loc in locs:
		terrain.data.add_region_blank(loc)
		write_pattern(loc)
	terrain.data.update_maps()
	await process_frame

	# ---- Near field (AVT), shipped defaults -------------------------------------
	terrain.surface_vt_page_size = PAGE
	terrain.surface_vt_page_border = BORDER
	terrain.surface_vt_page_count = PAGE_COUNT
	terrain.surface_vt_pages_per_axis = PAGES_PER_AXIS
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_feedback_enabled = false
	terrain.surface_vt_enabled = true
	await process_frame

	var vt := terrain.get_surface_vt()
	vt.clear()
	var start := Time.get_ticks_usec()
	var produced := terrain.update_surface_vt()
	var cold_usec := Time.get_ticks_usec() - start
	report("avt_cold", cold_usec, produced)
	require(produced > 0, "the cold near-field pass should produce pages, got " + str(produced))
	var cold_per_page := 0.0 if produced <= 0 else float(cold_usec) / float(produced)
	require(cold_per_page < MAX_US_PER_PAGE,
			"producing a page costs %.0f us, over the %.0f us budget" % [cold_per_page, MAX_US_PER_PAGE])

	# Nothing changed: the pass must be idle, and must stay cheap.
	vt.reset_stats()
	var settled_usec := 0
	var settled_produced := 0
	for i in SETTLED_RUNS:
		start = Time.get_ticks_usec()
		settled_produced += terrain.update_surface_vt()
		settled_usec += Time.get_ticks_usec() - start
	report("avt_settled_avg", settled_usec / SETTLED_RUNS, settled_produced)
	require(settled_produced == 0, "a settled near-field pass produced " + str(settled_produced) + " pages")
	require(int(vt.get_stats()["evict_count"]) == 0,
			"a settled pass evicted %d pages: the atlas is smaller than the working set" % int(vt.get_stats()["evict_count"]))

	# Move the target by one region: a fresh column of pages has to be produced.
	camera.position = Vector3(REGION_SIZE, 200.0, 0.0)
	terrain.set_clipmap_target(camera)
	await physics_frame
	await physics_frame
	start = Time.get_ticks_usec()
	produced = terrain.update_surface_vt()
	report("avt_after_move", Time.get_ticks_usec() - start, produced)

	terrain.surface_vt_enabled = false
	vt.clear()

	# ---- Far field (SVT), shipped defaults --------------------------------------
	terrain.surface_svt_page_world = SVT_PAGE_WORLD
	terrain.surface_svt_page_size = SVT_PAGE
	terrain.surface_svt_page_border = SVT_BORDER
	terrain.surface_svt_page_count = SVT_PAGE_COUNT
	terrain.surface_svt_distance = SVT_DISTANCE
	terrain.surface_svt_root_mips = 2
	terrain.surface_svt_enabled = true
	await process_frame

	var svt := terrain.get_surface_svt()
	svt.clear()
	start = Time.get_ticks_usec()
	produced = terrain.update_surface_svt()
	var svt_cold_usec := Time.get_ticks_usec() - start
	report("svt_cold", svt_cold_usec, produced)
	require(produced > 0, "the cold far-field pass should produce pages, got " + str(produced))
	var svt_per_page := 0.0 if produced <= 0 else float(svt_cold_usec) / float(produced)
	require(svt_per_page < MAX_US_PER_PAGE,
			"producing a far-field page costs %.0f us, over the %.0f us budget" % [svt_per_page, MAX_US_PER_PAGE])

	# Root scanning is deliberately bounded per call. Finish the finite cold
	# traversal before measuring idle cost; retain the strict zero-production check.
	var warmup_produced := 0
	for i in 16:
		warmup_produced += terrain.update_surface_svt()
	print("VTPERF svt_warmup_produced=%d" % warmup_produced)
	settled_usec = 0
	settled_produced = 0
	for i in SETTLED_RUNS:
		start = Time.get_ticks_usec()
		settled_produced += terrain.update_surface_svt()
		settled_usec += Time.get_ticks_usec() - start
	report("svt_settled_avg", settled_usec / SETTLED_RUNS, settled_produced)
	require(settled_produced == 0, "a settled far-field pass produced " + str(settled_produced) + " pages")

	camera.position = Vector3(REGION_SIZE + SVT_PAGE_WORLD, 200.0, 0.0)
	terrain.set_clipmap_target(camera)
	await physics_frame
	await physics_frame
	start = Time.get_ticks_usec()
	produced = terrain.update_surface_svt()
	report("svt_after_move", Time.get_ticks_usec() - start, produced)

	# ---- Indirection upload ------------------------------------------------------
	# `commit()` re-creates and re-uploads the whole mip chain whenever one texel
	# changed, and the demand pass commits every tick, so a page that changes costs
	# this on top of its own production.
	vt.clear()
	terrain.surface_vt_enabled = true
	await process_frame
	var loc := Vector2i(0, 0)
	vt.register_sector(loc, PAGES_PER_AXIS)
	vt.request_page(loc, 0, 0, 0)
	start = Time.get_ticks_usec()
	vt.commit()
	var commit_usec := Time.get_ticks_usec() - start
	report("indirection_commit", commit_usec, 1)

	print("VTPERF summary region_size=%d page=%d stored=%d pages_per_axis=%d atlas_pages=%d" % [
			REGION_SIZE, PAGE, PAGE + 2 * BORDER, PAGES_PER_AXIS, PAGE_COUNT])

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS virtual texture demand cost")
	quit()
