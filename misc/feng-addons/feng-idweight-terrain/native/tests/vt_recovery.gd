# Run with a graphical rendering driver; see README.md in this directory.
#
# A page whose content is lost while the view is still has to be produced again.
#
# The near field caches its plan: while the camera does not move and the pool's residency is
# unchanged, a demand pass reuses the plan instead of re-deriving it. That is what keeps a
# settled view free of main-thread work, and it is also where a lost page used to stay lost.
# The indirection entry keeps naming its slot, so the shader samples an empty layer, and with
# the plan reused nothing looked at the page again until the camera moved.
#
# This drives the sector planner (the default selection mode) with a camera that never moves,
# waits for the view to settle, then drops one produced page's readiness. That is exactly the
# state a failed block encode, a production dropped by a bundle rebuild, or a page lost to a
# dropped cache entry leaves behind: nothing about the page's address or its published slot
# changes, only its content is gone. A demand pass is the only thing that can repair it, so
# the test requires the page to be ready again within a bounded number of ticks.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const GRID := 6
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_COUNT := 128
const VIEW_WORLD := Vector2(160.0, 160.0)
const UNCOMPRESSED := 0
const BC7 := 1

var scene: Node3D

func _initialize() -> void:
	call_deferred("run")

func producer_stats() -> Dictionary:
	return terrain.get_vt_settings().get("producer", {})

func sector_stats() -> Dictionary:
	return terrain.get_vt_settings().get("avt_sector_stats", {})

# The demand pass the engine's own tick runs, driven explicitly so the test does not depend on
# the frame rate. The camera never moves, which is what puts the planner on its reuse path.
func tick() -> void:
	terrain.update_surface_vt(64)
	await process_frame

func fill_region(location: Vector2i, id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(id)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	var dark := Terrain3DTextureAsset.new()
	dark.albedo_texture = make_pattern(64, Color(0.035, 0.045, 0.055), Color(0.16, 0.10, 0.06))
	terrain.assets.set_texture_asset(0, dark)
	var bright := Terrain3DTextureAsset.new()
	bright.albedo_texture = make_pattern(64, Color(0.16, 0.72, 0.08), Color(0.95, 0.24, 0.04))
	terrain.assets.set_texture_asset(1, bright)

func configure_terrain() -> void:
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_distance = 512.0
	# The sector planner, which is the mode the shared pool and the cached plan belong to.
	terrain.surface_vt_selection_mode = 2
	# The far field is left off so the pool's residency can only move because of the near
	# field: a far-field allocation would break the cached plan for a reason that is not
	# under test here, and the page that has to be repaired is a near-field page.
	terrain.surface_svt_enabled = false
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location, 1 if location == Vector2i(1, 1) else 0)
	terrain.data.update_maps()

func ready_of(slot: int) -> bool:
	for page in terrain.get_vt_pages():
		if int(page.get("slot", -1)) == slot:
			return bool(page.get("ready", false))
	return false

func ready_count() -> int:
	return int(producer_stats().get("ready_pages", 0))

# The state the cached plan is reused in: something is resident, nothing the plan names is
# missing, and the planner is reusing its last plan instead of re-deriving it. Held for a few
# consecutive ticks before it counts, so a single transient pass cannot satisfy it.
func settle(max_ticks: int = 600) -> bool:
	var stable := 0
	for _tick_index in max_ticks:
		await tick()
		var sector := sector_stats()
		var settled := ready_count() > 0 \
				and int(sector.get("visible_missing_pages", -1)) == 0 \
				and bool(sector.get("plan_reused", false)) \
				and not bool(sector.get("planning_pending", false))
		stable = stable + 1 if settled else 0
		if stable >= 5:
			return true
	return false

# One codec's scenario: settle, lose a ready page, hold the camera still, and require the
# demand pass to produce it again.
func run_scenario(codec: int) -> void:
	terrain.vt_atlas_compression = codec
	for _frame in 5:
		await tick()
	var resolved: Dictionary = terrain.get_vt_settings()
	var available := int(resolved.get("vt_atlas_compression_available", -1))
	var name := String(resolved.get("vt_atlas_compression_name", "?"))
	print("VTRECOVERY codec=%d available=%d name=%s reason='%s'" % [
			codec, available, name, String(resolved.get("vt_atlas_compression_reason", ""))])
	if available != codec and codec != UNCOMPRESSED:
		print("VTRECOVERY skipped codec %d: this build cannot store pages in it" % codec)
		return

	require(await settle(), "the view must settle before a page can be lost (codec %d)" % codec)
	if failed:
		return
	var ready_before := ready_count()
	var sector: Dictionary = sector_stats()
	print("VTRECOVERY settled codec=%d ready=%d plan_reused=%s missing=%d pending=%d sampled=%d resident=%d" % [
			codec, ready_before, str(sector.get("plan_reused", false)),
			int(sector.get("visible_missing_pages", -1)), int(sector.get("visible_pending_pages", -1)),
			int(sector.get("sampled_pages", -1)), int(sector.get("requested_physical_pages", -1))])

	# A page the producer reports as ready and the indirection already names: losing its
	# content must not require a camera move to notice.
	var slot := -1
	for page in terrain.get_vt_pages():
		if bool(page.get("ready", false)):
			slot = int(page.get("slot", -1))
			break
	require(slot >= 0, "the settled view must have produced a page that can be lost (codec %d)" % codec)
	if slot < 0:
		return
	require(terrain.debug_lose_vt_page_readiness(slot),
			"the loss must apply to a ready page (slot %d, codec %d)" % [slot, codec])
	require(not ready_of(slot), "the lost page must not read as ready (slot %d)" % slot)

	# Nothing moves but the demand pass. The page has to come back on its own.
	var recovered := -1
	for tick_index in 240:
		await tick()
		# GPU readiness can change after this tick's CPU classification. Require both
		# halves of recovery within the same existing deadline, rather than reading
		# the previous classification immediately after an asynchronous completion.
		if ready_of(slot) and int(sector_stats().get("visible_missing_pages", -1)) == 0:
			recovered = tick_index + 1
			break
	var after: Dictionary = sector_stats()
	print("VTRECOVERY result codec=%d slot=%d recovered_ticks=%d ready=%d->%d missing=%d pending=%d late=%d" % [
			codec, slot, recovered, ready_before, ready_count(),
			int(after.get("visible_missing_pages", -1)), int(after.get("visible_pending_pages", -1)),
			int(after.get("visible_late_pages", -1))])
	require(recovered > 0,
			"a page whose content was lost while the view was still must be produced again (slot %d, codec %d, still missing after 240 ticks)" % [slot, codec])
	require(ready_count() >= ready_before,
			"the view must not lose resident pages while repairing one (codec %d: %d -> %d)" % [
				codec, ready_before, ready_count()])
	# The cached pass must stop claiming a settled view while the page is unaccounted for.
	require(int(after.get("visible_missing_pages", -1)) == 0,
			"the repaired view must report no missing page (codec %d, got %d)" % [
				codec, int(after.get("visible_missing_pages", -1))])

func run() -> void:
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
	camera.size = 192.0
	camera.position = Vector3(VIEW_WORLD.x, 180.0, VIEW_WORLD.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	configure_terrain()
	terrain.surface_vt_enabled = true
	for _frame in 5:
		await tick()
	if failed:
		quit(1)
		return

	for codec in [BC7, UNCOMPRESSED]:
		await run_scenario(codec)
		if failed:
			break

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS a page lost under a still view is produced again")
	quit()
