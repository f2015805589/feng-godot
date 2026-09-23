## Focused GPU regression for the dense AVT mip-chain contract.
##
## AVT keeps a fixed 64 metre world sector while choosing one of the configured
## sector-resolution tiers (three by default, ten at the upper contract edge).
## Every tier owns a complete local page-mip chain; the tier count is therefore
## independent of the local mip count of its allocated block.  The outer mip
## 1+ fallback remains a dense resident grid in the ordinary Surface VT table,
## owned by its sentinel sector.  This fixture keeps the world small enough to
## finish quickly, but uses negative coordinates, poisoned and synthetic source
## pages, and camera motion so the shader and CPU records agree.
extends "res://vt_avt_dense_base.gd"

const DENSE_REGION_SIZE := 64
const COARSE_OWNER := Vector2i(-2147483648, -2147483648)
const PAGE_POOL := 128
const DEFAULT_RADIUS := 384.0
const SECTOR_WORLD := 64.0
const DEFAULT_DENSITY := 1024.0

var material_rid := RID()
var saved_source_array: Variant
var saved_surface_albedo: Variant
var saved_surface_normal: Variant
var saved_surface_params: Variant
var probe_albedo_array: Texture2DArray
var probe_normal_array: Texture2DArray
var probe_params_array: Texture2DArray


func _require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


func _tick(max_pages: int = 16) -> int:
	var produced := terrain.update_surface_vt(max_pages)
	await process_frame
	await RenderingServer.frame_post_draw
	return produced


func _page_records() -> Array:
	return terrain.get_vt_pages()


func _is_avt_owner(owner: Dictionary) -> bool:
	return String(owner.get("owner_type", "")) == "avt"


func _is_coarse_owner(owner: Dictionary) -> bool:
	return _is_avt_owner(owner) and owner.get("sector", Vector2i.ZERO) == COARSE_OWNER


func _owner_local_mip(owner: Dictionary, record: Dictionary = {}) -> int:
	# New metadata spells this out as local_mip.  Keep the record's historical
	# `mip` spelling as a compatibility fallback while the native DLL rolls over.
	return int(owner.get("local_mip", owner.get("mip", record.get("mip", -1))))


func _owner_sector_level(owner: Dictionary, preview: Dictionary = {}) -> int:
	# A retained page can outlive the currently proposed preview tier. Prefer the
	# explicit owner field when present; otherwise map the fixed world-sector key
	# through the read-only preview. Never derive a sector tier from local mip.
	for key in ["resolution_level", "sector_level", "level"]:
		if owner.has(key):
			return int(owner[key])
	var sector: Vector2i = owner.get("sector", Vector2i.ZERO)
	for cell: Dictionary in preview.get("sectors", []):
		var rect: Rect2 = cell.get("rect", Rect2())
		if rect.position == Vector2(sector) * SECTOR_WORLD and is_equal_approx(rect.size.x, SECTOR_WORLD):
			return int(cell.get("level", -1))
	return -1


func _next_power_of_two(value: float) -> int:
	var result := 1
	while float(result) < value:
		result <<= 1
	return result


func _expected_tier_block(density: float, level: int, physical_page_size: int) -> int:
	return _next_power_of_two(maxf(1.0, SECTOR_WORLD * density / float(physical_page_size) / pow(2.0, level)))


func _preview_sector(preview: Dictionary, sector: Vector2i) -> Dictionary:
	var expected_position := Vector2(sector) * SECTOR_WORLD
	for cell: Dictionary in preview.get("sectors", []):
		var rect: Rect2 = cell.get("rect", Rect2())
		if rect.position == expected_position and is_equal_approx(rect.size.x, SECTOR_WORLD):
			return cell
	return {}


func _record_has_coarse_owner(record: Dictionary) -> bool:
	for owner: Dictionary in record.get("owners", []):
		if _is_coarse_owner(owner):
			return true
	return false


func _record_has_fine_owner(record: Dictionary) -> bool:
	for owner: Dictionary in record.get("owners", []):
		if _is_avt_owner(owner) and owner.get("sector", Vector2i.ZERO) != COARSE_OWNER:
			return true
	return false


func _coarse_records(ready_only: bool = false) -> Array:
	var result: Array = []
	for record: Dictionary in _page_records():
		if not _record_has_coarse_owner(record):
			continue
		if ready_only and not bool(record.get("ready", false)):
			continue
		result.append(record)
	return result


func _fine_records(ready_only: bool = false) -> Array:
	var result: Array = []
	for record: Dictionary in _page_records():
		if not _record_has_fine_owner(record):
			continue
		if ready_only and not bool(record.get("ready", false)):
			continue
		result.append(record)
	return result


func _wait_ready(max_frames: int = 140, require_new_plan: bool = true) -> bool:
	var quiet := 0
	var initial_stats: Dictionary = terrain.get_vt_settings().get("avt_sector_stats", {})
	var initial_chain := int(initial_stats.get("chain_ticks", 0))
	# A setting/camera change can leave the previous plan quiet for several
	# frames before the worker publishes its replacement.  Four quiet frames
	# alone accepted that old plan in the narrow density probe.
	var minimum_frames := 24
	for frame in max_frames:
		var produced := await _tick(16)
		var ready_coarse := _coarse_records(true)
		var ready_fine := _fine_records(true)
		var settings: Dictionary = terrain.get_vt_settings()
		var producer: Dictionary = settings.get("producer", {})
		var avt: Dictionary = settings.get("avt_sector_stats", {})
		var pending := int(producer.get("pending", 1))
		var chain_started := not require_new_plan or int(avt.get("chain_ticks", 0)) > initial_chain
		var planning_pending := bool(avt.get("planning_pending", false))
		var visible_missing := int(avt.get("visible_missing_pages", 0))
		var visible_pending := int(avt.get("visible_pending_pages", 0))
		if frame >= minimum_frames and chain_started and not planning_pending and \
				ready_coarse.size() > 0 and ready_fine.size() > 0 and pending == 0 and \
				visible_missing == 0 and visible_pending == 0 and produced == 0:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 4:
			return true
	return false


func _make_region(location: Vector2i, material_id: int) -> void:
	terrain.data.add_region_blank(location, false)
	set_region_material(location, material_id)


func _setup_terrain() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = DENSE_REGION_SIZE
	# The AVT contract uses the shared 256 texel physical page.  At 1024
	# texels/metre that makes a 64 metre section's logical base block 256 pages,
	# while the resident outer grid remains bounded by the pool.
	terrain.vt_auto_capacity = false
	terrain.vt_page_size = 256
	terrain.vt_page_border = 2
	terrain.vt_page_count = PAGE_POOL
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_selection_mode = 2
	terrain.surface_vt_texels_per_pixel = 0.25
	terrain.surface_vt_texels_per_meter = 1024.0
	terrain.surface_vt_distance = DEFAULT_RADIUS
	terrain.surface_vt_mip_levels = 3
	terrain.vt_page_fade_frames = 0
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	# This fixture drives AVT ticks explicitly. Disable the automatic physics
	# callback before the node enters the tree, while the camera is not attached.
	terrain.set_process(false)
	terrain.set_physics_process(false)
	DirAccess.make_dir_recursive_absolute("user://vt_avt_dense")
	terrain.data_directory = "user://vt_avt_dense"
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 96.0
	camera.position = Vector3(-32.0, 120.0, 0.0)
	camera.near = 0.1
	camera.far = 512.0
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	# Terrain3D enables its physics callback when it enters the tree. Put the
	# active camera in the tree first so its first callback has a valid target.
	root.add_child(camera)

	scene.add_child(terrain)
	root.add_child(scene)
	await process_frame
	# Terrain3DData receives the final region size on tree entry.  Re-apply it
	# before constructing the deliberately sparse negative/positive test world.
	terrain.region_size = DENSE_REGION_SIZE
	add_assets()
	for location in [
		Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(2, -1), Vector2i(3, -1), Vector2i(4, -1),
		Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0),
		Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0), Vector2i(8, 0),
		Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
		Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1)]:
		_make_region(location, 1 if location == Vector2i(8, 0) else 0)
	terrain.data.update_maps()

	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	terrain.set_process(false)
	terrain.set_physics_process(false)


func _check_layer_controls() -> void:
	var probe := Terrain3D.new()
	_require(probe.surface_vt_mip_levels == 3, "new AVT scenes default to three sector resolution tiers")
	probe.surface_vt_mip_levels = 0
	_require(probe.surface_vt_mip_levels == 3, "legacy mip level zero migrates to the default three tiers")
	probe.surface_vt_mip_levels = 1
	_require(probe.surface_vt_mip_levels == 2, "AVT tier setter clamps the minimum to two")
	probe.surface_vt_mip_levels = 99
	_require(probe.surface_vt_mip_levels == 16, "AVT tier setter clamps the maximum to sixteen")
	probe.surface_vt_mip_levels = 5
	_require(is_equal_approx(probe.surface_vt_distance, DEFAULT_RADIUS),
			"new AVT scenes default to a 384 metre coverage radius")
	var settings5: Dictionary = probe.get_vt_settings()
	var base_block := int(settings5.get("avt_base_block_size", 0))
	var local_cap := int(settings5.get("avt_mip_level_cap", -1))
	_require(base_block > 0 and local_cap >= 0, "AVT publishes the independent local block chain")
	_require(local_cap == int(round(log(float(base_block)) / log(2.0))),
			"AVT local mip cap follows the allocated base block, not the tier setting")
	_require(int(settings5.get("avt_local_mip_levels", 0)) == local_cap + 1,
			"AVT reports all local page mips separately from sector tiers")
	_require(int(settings5.get("avt_sector_resolution_levels", 0)) == 5 and
				int(settings5.get("avt_effective_mip_levels", 0)) == 5,
			"AVT settings expose the requested sector tier count")
	probe.surface_vt_mip_levels = 3
	var settings3: Dictionary = probe.get_vt_settings()
	probe.surface_vt_mip_levels = 10
	var settings10: Dictionary = probe.get_vt_settings()
	_require(int(settings10.get("avt_mip_level_cap", -1)) == int(settings3.get("avt_mip_level_cap", -2)),
			"changing sector tier count does not truncate the local mip chain")
	_require(int(settings10.get("avt_local_mip_levels", 0)) == int(settings3.get("avt_local_mip_levels", 0)),
			"local page mip count is stable across three and ten tier presets")
	_require(int(settings10.get("avt_sector_resolution_levels", 0)) == 10 and
				int(settings10.get("avt_effective_mip_levels", 0)) == 10,
			"ten configured tiers remain ten effective sector resolution tiers")
	var packed := PackedScene.new()
	_require(packed.pack(probe) == OK, "AVT mip level setting can be packed")
	var restored := packed.instantiate() as Terrain3D
	_require(restored != null and restored.surface_vt_mip_levels == 10,
			"AVT mip level setting survives scene persistence")
	if restored:
		restored.free()
	probe.free()


func _check_preview_read_only() -> Dictionary:
	var before_pages := _page_records().size()
	var before_stats: Dictionary = terrain.get_surface_vt().get_stats()
	var before_allocs := int(before_stats.get("alloc_count", 0))
	var before_pool_count := int(before_stats.get("page_count", PAGE_POOL))
	var preview: Dictionary = terrain.get_avt_layout_preview(camera)
	var preview_again: Dictionary = terrain.get_avt_layout_preview(camera)
	_require(preview.has("bounds") and preview.has("page_world") and preview.has("fine_cells"),
			"AVT inspector preview exposes the layout contract")
	_require(preview.get("camera", Vector2.ZERO) is Vector2, "AVT preview reports a Vector2 camera")
	_require(preview.get("bounds", Rect2()).has_point(Vector2(-32.0, 0.0)),
			"negative camera coordinates lie inside the proposed AVT bounds")
	var preview_settings: Dictionary = terrain.get_vt_settings()
	var requested_tiers := int(preview_settings.get("avt_sector_resolution_levels", 3))
	_require(int(preview.get("requested_levels", 0)) == requested_tiers and
				int(preview.get("levels", 0)) == requested_tiers,
			"AVT preview reports the configured sector tier count")
	_require(int(preview.get("resident_pages", 0)) > 0,
			"AVT preview reports a positive dense resident page count")
	var resolution_levels: Array = preview.get("resolution_levels", [])
	_require(resolution_levels.size() == requested_tiers,
			"AVT preview exposes one resolution entry for every configured tier")
	var preview_density := float(preview_settings.get("avt_effective_texels_per_meter", DEFAULT_DENSITY))
	var physical_page_size := int(terrain.get_surface_vt().get_page_size())
	for level in resolution_levels.size():
		var tier: Dictionary = resolution_levels[level]
		var expected_resolution := SECTOR_WORLD * preview_density / pow(2.0, level)
		var expected_block := _expected_tier_block(preview_density, level, physical_page_size)
		_require(int(tier.get("level", -1)) == level,
				"AVT preview resolution entries retain their tier index")
		_require(is_equal_approx(float(tier.get("resolution", 0.0)), expected_resolution),
				"AVT preview reports the fixed-sector resolution for each tier")
		_require(int(tier.get("block_size", 0)) == expected_block,
				"AVT preview reports the next-power-of-two block for each tier")
	_require(int(preview.get("fine_mip_levels", 0)) ==
				int(preview_settings.get("avt_local_mip_levels", 0)),
			"AVT preview keeps local chain length separate from sector tier count")
	if preview.has("coarse_pages"):
		var coarse_preview: Array = preview.get("coarse_pages", [])
		_require(coarse_preview.size() == int(preview.get("resident_pages", 0)),
				"AVT preview exposes one world rectangle per proposed dense page")
		for page: Dictionary in coarse_preview:
			_require(page.has("rect") and page.has("mip"),
					"AVT preview coarse pages retain mip and world rectangle fields")
	_require(preview.get("bounds", Rect2()).size.x > 0.0 and float(preview.get("page_world", 0.0)) > 0.0,
			"AVT preview reports positive world geometry")
	var fine_section_world := float(preview.get("fine_section_world", DENSE_REGION_SIZE))
	_require(fine_section_world > 0.0, "AVT preview reports a positive fine page span")
	var fine_cells: Array = preview.get("fine_cells", [])
	_require(fine_cells.size() > 0, "AVT preview exposes visible fixed-size fine cells")
	var sectors: Array = preview.get("sectors", [])
	_require(sectors.size() > 0, "AVT preview exposes fixed 64 metre world sectors")
	var offscreen_apron := 0
	for cell: Dictionary in sectors:
		var rect: Rect2 = cell.get("rect", Rect2())
		var level := int(cell.get("level", -1))
		var logical_pages := float(cell.get("logical_pages", 0.0))
		var expected_logical := SECTOR_WORLD * preview_density / float(physical_page_size) / pow(2.0, level)
		if not bool(cell.get("visible", true)):
			offscreen_apron += 1
		_require(is_equal_approx(rect.size.x, SECTOR_WORLD) and is_equal_approx(rect.size.y, SECTOR_WORLD),
				"each AVT demand sector remains fixed at 64 metres")
		_require(level >= 0 and level < requested_tiers,
				"each AVT sector selects one configured resolution tier")
		_require(is_equal_approx(logical_pages, expected_logical),
				"AVT sector logical page demand keeps fractional tier resolution")
		_require(int(cell.get("block_size", 0)) == _expected_tier_block(preview_density, level, physical_page_size),
				"AVT sector block follows its selected tier")
		if bool(cell.get("allocated", false)):
			var allocation: Rect2 = cell.get("allocation_rect", Rect2())
			_require(is_equal_approx(allocation.size.x, float(cell.get("block_size", 0))) and
						is_equal_approx(allocation.size.y, float(cell.get("block_size", 0))),
					"allocated AVT sector reports its real page-table block")
	# The near field keeps a page for every cell inside its reach, on screen or not. That is the
	# additional-feedback guarantee a snap turn lands on - the reference implementation adds one
	# coarsest page per resident virtual image every frame - and it replaced the eight cell offscreen
	# apron this used to assert, which left a 180 degree turn naming ground no plan had ever held.
	# The bound that matters now is the reach itself: the scan may not enumerate a cell outside the
	# square the reach circle is inscribed in.
	var reach: float = max(64.0, float(terrain.get_surface_vt_distance()))
	var reach_span: int = int(ceil(reach / SECTOR_WORLD)) * 2 + 1
	_require(offscreen_apron > 0,
			"AVT keeps off-frustum cells addressable for a turn")
	_require(sectors.size() <= reach_span * reach_span,
			"AVT scans no cell outside the near field's own reach")
	_require(preview == preview_again, "repeating the read-only AVT preview is deterministic")
	var after_stats: Dictionary = terrain.get_surface_vt().get_stats()
	_require(_page_records().size() == before_pages and int(after_stats.get("alloc_count", 0)) == before_allocs and
				int(after_stats.get("page_count", PAGE_POOL)) == before_pool_count,
			"AVT inspector preview does not allocate physical pages")
	return preview


func _sector_from_rect(rect: Rect2) -> Vector2i:
	return Vector2i(roundi(rect.position.x / SECTOR_WORLD), roundi(rect.position.y / SECTOR_WORLD))


func _sector_page_rects(sector: Vector2i) -> Array:
	var result: Array = []
	for record: Dictionary in _fine_records(true):
		for owner: Dictionary in record.get("owners", []):
			if _is_avt_owner(owner) and owner.get("sector", Vector2i.ZERO) == sector:
				result.append(record.get("world_rect", Rect2()))
				break
	return result


func _check_resolution_tiers() -> void:
	# A broad view selects a coarse sector tier while the same world sector in a
	# narrow view selects tier 0.  The world sector rectangle must remain 64 m in
	# both plans even though its virtual block is resized.
	terrain.surface_vt_mip_levels = 3
	camera.size = 96.0
	camera.position = Vector3(-32.0, 120.0, 0.0)
	terrain.set_clipmap_target(camera)
	_require(await _wait_ready(220, false), "three-tier broad AVT view settles")
	var broad := terrain.get_avt_layout_preview(camera)
	var chosen: Dictionary = {}
	for cell: Dictionary in broad.get("sectors", []):
		if bool(cell.get("allocated", false)) and int(cell.get("level", -1)) > 0:
			chosen = cell
			break
	_require(not chosen.is_empty(), "broad AVT view allocates a non-finest sector tier")
	if chosen.is_empty():
		return
	var sector := _sector_from_rect(chosen.get("rect", Rect2()))
	var broad_rect: Rect2 = chosen.get("rect", Rect2())
	var broad_block := int(chosen.get("block_size", 0))
	var before_payload := _sector_page_rects(sector)
	_require(broad_rect.size == Vector2(SECTOR_WORLD, SECTOR_WORLD),
			"broad AVT demand uses the fixed 64 metre world sector")

	# Ten tiers expose the full 64k..128 resolution ladder at 1024 texels/metre.
	terrain.surface_vt_mip_levels = 10
	_require(await _wait_ready(220), "ten-tier AVT configuration settles without rebuilding the world pool")
	var ten := terrain.get_avt_layout_preview(camera)
	var ten_levels: Array = ten.get("resolution_levels", [])
	_require(ten_levels.size() == 10, "ten-tier preview reports all sector resolution levels")
	if ten_levels.size() == 10:
		var base_resolution := 64.0 * float(ten.get("effective_texels_per_meter", DEFAULT_DENSITY))
		_require(is_equal_approx(float((ten_levels[0] as Dictionary).get("resolution", 0.0)), base_resolution),
				"tier zero represents the full 64k sector resolution")
		_require(is_equal_approx(float((ten_levels[9] as Dictionary).get("resolution", 0.0)), base_resolution / 512.0),
				"tier nine reaches the 128 texel sector resolution")
	var ten_sector := _preview_sector(ten, sector)
	_require(not ten_sector.is_empty() and ten_sector.get("rect", Rect2()).size == broad_rect.size,
			"changing tier count preserves the same world sector payload rectangle")

	# Return to the default three-tier contract and zoom in.  The same sector's
	# block grows to the tier-0 size while its world rectangle and page payload
	# stay in the same fixed sector.
	terrain.surface_vt_mip_levels = 3
	camera.size = 0.1
	terrain.set_clipmap_target(camera)
	_require(await _wait_ready(240), "three-tier narrow AVT view settles after the tier-count resize")
	var narrow := terrain.get_avt_layout_preview(camera)
	var narrow_sector := _preview_sector(narrow, sector)
	_require(not narrow_sector.is_empty(), "the same world sector remains in the narrow AVT preview")
	if not narrow_sector.is_empty():
		var narrow_block := int(narrow_sector.get("block_size", 0))
		_require(narrow_sector.get("rect", Rect2()).size == Vector2(SECTOR_WORLD, SECTOR_WORLD),
				"narrow AVT demand keeps the same 64 metre world sector")
		_require(narrow_block != broad_block,
				"projected density selects a different allocated block for the same world sector")
		_require(terrain.get_surface_vt().has_sector(sector) and
					terrain.get_surface_vt().get_sector_block_size(sector) == narrow_block,
					"the physical AVT directory allocates the preview block size")
		var sector_rect := Rect2(Vector2(sector) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD))
		for rect: Rect2 in _sector_page_rects(sector):
			_require(sector_rect.encloses(rect),
					"resizing a sector keeps every resident page payload in its world sector")
		_require(before_payload.size() == 0 or _sector_page_rects(sector).size() > 0,
				"resizing a sector preserves resident payload records when pages were present")


func _install_parent_probe(target: Dictionary, parent: Dictionary) -> bool:
	var pool_stats: Dictionary = terrain.get_surface_vt().get_stats()
	var layer_count := int(pool_stats.get("page_count", PAGE_POOL))
	var target_slot := int(target.get("record", {}).get("slot", -1))
	var parent_slot := int(parent.get("record", {}).get("slot", -1))
	if target_slot < 0 or parent_slot < 0 or target_slot >= layer_count or parent_slot >= layer_count:
		return false
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var params_images: Array[Image] = []
	for layer in layer_count:
		var albedo := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		var color := Color(0.90, 0.04, 0.02, 1.0)
		if layer == target_slot:
			color = Color(0.02, 0.90, 0.04, 1.0)
		elif layer == parent_slot:
			color = Color(0.02, 0.08, 0.95, 1.0)
		albedo.fill(color)
		albedo_images.append(albedo)
		var normal := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		normal.fill(Color(0.5, 0.5, 1.0, 1.0))
		normal_images.append(normal)
		var params := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		params.fill(Color(0.0, 1.0, 0.0, 1.0))
		params_images.append(params)
	probe_albedo_array = Texture2DArray.new()
	probe_normal_array = Texture2DArray.new()
	probe_params_array = Texture2DArray.new()
	probe_albedo_array.create_from_images(albedo_images)
	probe_normal_array.create_from_images(normal_images)
	probe_params_array.create_from_images(params_images)
	if not probe_albedo_array.get_rid().is_valid() or not probe_normal_array.get_rid().is_valid() or not probe_params_array.get_rid().is_valid():
		return false
	material_rid = terrain.material.get_material_rid()
	saved_surface_albedo = RenderingServer.material_get_param(material_rid, "_surface_material_albedo")
	saved_surface_normal = RenderingServer.material_get_param(material_rid, "_surface_material_normal")
	saved_surface_params = RenderingServer.material_get_param(material_rid, "_surface_material_params")
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", probe_albedo_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", probe_normal_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", probe_params_array.get_rid())
	return true


func _rebind_parent_probe() -> bool:
	# Material.update() can replace the VT bundle while the camera plan changes.
	# Reuse the already-created probe arrays without overwriting the saved real
	# arrays; _restore_fine_slot_probe() still owns restoration at teardown.
	if not material_rid.is_valid() or probe_albedo_array == null or probe_normal_array == null or probe_params_array == null:
		return false
	if not probe_albedo_array.get_rid().is_valid() or not probe_normal_array.get_rid().is_valid() or not probe_params_array.get_rid().is_valid():
		return false
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", probe_albedo_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", probe_normal_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", probe_params_array.get_rid())
	return true


func _find_ready_owner_slot(sector: Vector2i, local_mip: int, slot: int) -> Dictionary:
	for record: Dictionary in _page_records():
		if int(record.get("slot", -1)) != slot or not bool(record.get("ready", false)):
			continue
		for owner: Dictionary in record.get("owners", []):
			if _is_avt_owner(owner) and owner.get("sector", Vector2i.ZERO) == sector and _owner_local_mip(owner, record) == local_mip:
				return record
	return {}


func _check_turn_local_parent() -> void:
	# The narrow view gives the shader a genuine local-mip-0 target.  Find any
	# ready coarser page covering that point rather than assuming mip 1: a full
	# chain may legitimately skip a page while retaining mip 2 or the block's
	# whole-span page.  A turn is applied in sub-25-degree steps so it exercises
	# the angular lead instead of the intentional snap/discard path.
	terrain.surface_vt_mip_levels = 3
	terrain.surface_vt_texels_per_meter = DEFAULT_DENSITY
	terrain.surface_vt_texels_per_pixel = 1.0
	camera.size = 0.1
	var sample_world := Vector2(-32.0, 0.0)
	var orbit_radius := 80.0
	camera.position = Vector3(sample_world.x + orbit_radius, 120.0, sample_world.y)
	camera.look_at(Vector3(sample_world.x, 0.0, sample_world.y), Vector3.UP)
	terrain.set_clipmap_target(camera)
	_require(await _wait_ready(260), "narrow local-mip turn fixture settles")
	var target := _find_fine_at(sample_world)
	if target.is_empty():
		var target_density := await _wait_for_fine_density(DEFAULT_DENSITY, 180)
		target = target_density
	_require(not target.is_empty(), "turn fixture finds a ready local-mip-0 page")
	if target.is_empty():
		return
	var parent := _find_ready_local_parent(target)
	_require(not parent.is_empty(), "turn fixture finds a ready coarser local parent")
	if parent.is_empty():
		return
	var target_world: Vector2 = target["rect"].get_center()
	_require(parent["rect"].has_point(target_world), "local parent covers the fine page sample")
	_require(_install_parent_probe(target, parent), "turn fixture can colour fine and parent physical layers")
	var before := await frame_image(3)
	var before_color := sample_area(before, target_world, 2)
	_require(before_color == "green", "turn fixture initially samples local mip 0")

	# Orbit around the probe so it stays at the screen centre while the camera's
	# forward vector changes.  Each step is 20 degrees and remains below the
	# native snap threshold.
	for angle in [20.0, 40.0, 60.0, 80.0]:
		var radians := deg_to_rad(angle)
		camera.position = Vector3(target_world.x + orbit_radius * cos(radians), 120.0,
				target_world.y + orbit_radius * sin(radians))
		camera.look_at(Vector3(target_world.x, 0.0, target_world.y), Vector3.UP)
		await _tick(16)

	# Freeze after the turn, remove only the fine mapping, and render immediately.
	# The ready parent remains a valid AVT page, so a red dense/SVT result means
	# the shader skipped the local parent chain.
	terrain.set_process(false)
	terrain.set_physics_process(false)
	var vt := terrain.get_surface_vt()
	var sector: Vector2i = target["sector"]
	var address: Vector2i = target["address"]
	var local_mip := int(target.get("local_mip", 0))
	_require(local_mip == 0, "turn target is local mip 0")
	var parent_slot := int(parent["record"].get("slot", -1))
	var parent_mip := int(parent.get("local_mip", -1))
	var parent_address: Vector2i = parent.get("address", Vector2i(-1, -1))
	var parent_mapping := vt.lookup_page(sector, parent_mip, parent_address.x, parent_address.y)
	var parent_record := _find_ready_owner_slot(sector, parent_mip, parent_slot)
	_require(parent_mapping == parent_slot,
			"turned view keeps the original local parent exact address mapped to the same slot")
	_require(not parent_record.is_empty(),
			"turned view keeps the original local parent ready in the same physical slot")
	if parent_mapping != parent_slot or parent_record.is_empty():
		print("VT_AVT_DENSE_TURN_PARENT_LOST sector=", sector, " mip=", parent_mip,
				" address=", parent_address, " expected_slot=", parent_slot,
				" mapped_slot=", parent_mapping)
		_restore_fine_slot_probe()
		return
	_require(_rebind_parent_probe(),
			"turn fixture rebinds its existing parent probe arrays after the camera plan update")
	var mapped_target := vt.lookup_page(sector, local_mip, address.x, address.y)
	if mapped_target >= 0:
		_require(vt.release_page(sector, local_mip, address.x, address.y),
				"turn fixture can remove the cold fine mapping")
	else:
		print("VT_AVT_DENSE_TURN_FINE_ALREADY_MISSING sector=", sector, " address=", address)
	vt.commit()
	var fallback_image := await frame_image(4)
	var fallback_color := sample_area(fallback_image, target_world, 2)
	print("VT_AVT_DENSE_TURN target_mip=", local_mip, " parent_mip=", parent_mip,
			" parent_slot=", parent_slot, " sample=", fallback_color)
	_require(fallback_color == "blue",
			"a turned view uses the nearest ready local parent instead of the outer dense/SVT fallback")
	_restore_fine_slot_probe()


func _validate_records(settings: Dictionary) -> Dictionary:
	var all_records := _page_records()
	var coarse_ready := _coarse_records(true)
	var fine_ready := _fine_records(true)
	var coarse_pages := int(settings.get("avt_coarse_pages", 0))
	var coarse_size := int(settings.get("avt_coarse_size", 0))
	var sector_levels := int(settings.get("avt_sector_resolution_levels", settings.get("avt_effective_mip_levels", 0)))
	var effective_levels := int(settings.get("avt_effective_mip_levels", 0))
	var local_levels := int(settings.get("avt_local_mip_levels", 0))
	var local_cap := int(settings.get("avt_mip_level_cap", -1))
	var pool: Dictionary = terrain.get_surface_vt().get_stats()
	var pool_count := int(pool.get("page_count", PAGE_POOL))
	var physical_page_size := int(terrain.get_surface_vt().get_page_size())
	var requested_density := float(settings.get("avt_effective_texels_per_meter", settings.get("avt_texels_per_meter", 0.0)))
	var base_block := int(settings.get("avt_base_block_size", 0))
	var preview := terrain.get_avt_layout_preview(camera)
	_require(pool_count <= PAGE_POOL, "AVT physical pool does not grow beyond the configured capacity")
	_require(all_records.size() <= pool_count, "resident AVT records fit inside the physical pool")
	_require(coarse_pages > 0 and coarse_size > 0, "AVT reports a dense coarse grid")
	_require(coarse_pages <= maxi(1, pool_count / 4),
			"dense AVT coarse pages fit within one quarter of the AVT share")
	_require(sector_levels >= 2 and sector_levels == int(settings.get("avt_mip_levels", sector_levels)),
			"AVT effective levels count sector resolution tiers")
	_require(effective_levels == sector_levels,
			"compatibility effective_mip_levels reports sector tiers, not local mips")
	_require(local_levels == local_cap + 1 and local_cap == int(round(log(float(maxi(1, base_block))) / log(2.0))),
			"AVT local mip chain follows the full base block")
	_require(float(settings.get("avt_effective_texels_per_meter", 0.0)) <=
				float(settings.get("avt_texels_per_meter", 0.0)) + 0.001,
			"AVT effective base density stays within the requested density")
	_require(base_block == _expected_tier_block(requested_density, 0, physical_page_size),
			"AVT base block follows the exact 64 metre tier-0 density/page-size ratio")
	_require(int(settings.get("avt_max_adaptive_level", 0)) == 1,
			"AVT MaxAdaptiveLevel stays fixed at one")
	# The threshold that decides which table answers a sample is derived, not configured, so it is
	# checked against the two texel sizes it is derived from rather than against a constant: the
	# level between the fallback tier's texels-per-metre and the upgrade tier's is exactly
	# log2(upgrade / fallback).
	var coarse_texels_per_meter := float(settings.get("avt_coarse_texels_per_meter", 0.0))
	var upgrade_texels_per_meter := float(settings.get("avt_texels_per_meter", 0.0))
	_require(coarse_texels_per_meter > 0.0 and upgrade_texels_per_meter > coarse_texels_per_meter,
			"AVT reports both tiers' texel sizes for the threshold to be derived from")
	_require(is_equal_approx(float(settings.get("avt_adaptive_threshold_level", 0.0)),
				log(upgrade_texels_per_meter / coarse_texels_per_meter) / log(2.0)),
			"AVT adaptive threshold level is the level between the two tiers' texel sizes")
	# The plan's half of that one number: it must be the number the report publishes, and the plan
	# must hold no upgrade page at or above it. A settled view that disagrees here is the plan and
	# the shader's read order deriving from two different thresholds.
	var sector_stats: Dictionary = settings.get("avt_sector_stats", {})
	_require(is_equal_approx(float(sector_stats.get("plan_adaptive_threshold_level", -1.0)),
				float(settings.get("avt_adaptive_threshold_level", -2.0))),
			"AVT plan classifies against the adaptive threshold the report publishes")
	_require(int(sector_stats.get("plan_upgrade_above_level", -1)) == 0,
			"AVT plan holds no upgrade page at or above the fallback threshold")
	_require(terrain.get_surface_vt().has_sector(COARSE_OWNER),
			"dense AVT mip 1+ grid owns the reserved sentinel sector")
	_require(terrain.get_surface_vt().get_sector_block_size(COARSE_OWNER) == coarse_size * 2,
			"dense AVT owner reserves the outer grid's mip-0 address space")
	_require(coarse_ready.size() == coarse_pages,
			"every reported dense coarse page is physically resident and ready")
	_require(fine_ready.size() > 0, "AVT warmup has ready sparse pages")
	var seen_coarse_mips := {}
	var protected_coarse := 0
	var negative_fine := false
	var fine_lookup_checks := 0
	var coarse_lookup_checks := 0
	var seen_fine_mips := {}
	var seen_fine_levels := {}
	var tier_block_sizes := {}
	for record: Dictionary in all_records:
		if _record_has_coarse_owner(record) or _record_has_fine_owner(record):
			_require(record.get("kind", "") == "AVT" and record.has("world_rect"),
					"AVT page records publish kind and world rectangles")
		var slot := int(record.get("slot", -1))
		if slot < 0:
			continue
		for owner: Dictionary in record.get("owners", []):
			if not _is_avt_owner(owner):
				continue
			var mip := _owner_local_mip(owner, record)
			var sector: Vector2i = owner.get("sector", Vector2i.ZERO)
			var address: Vector2i = record.get("address", Vector2i(-1, -1))
			if sector == COARSE_OWNER:
				if mip >= 1:
					seen_coarse_mips[mip] = true
					var coarse_block := terrain.get_surface_vt().get_sector_block_size(COARSE_OWNER)
					var coarse_side := maxi(1, coarse_block >> mip)
					_require(address.x >= 0 and address.x < coarse_side and address.y >= 0 and address.y < coarse_side,
							"dense coarse owner address stays inside its mip table")
					_require(terrain.get_surface_vt().lookup_page(COARSE_OWNER, mip, address.x, address.y) == slot,
							"dense coarse page has an exact mip-table mapping")
					coarse_lookup_checks += 1
					if bool(record.get("ready", false)) and terrain.get_surface_vt().is_page_protected(slot):
						protected_coarse += 1
			else:
				seen_fine_mips[mip] = true
				var level := _owner_sector_level(owner, preview)
				_require(level >= 0 and level < sector_levels,
						"fine owner publishes or maps to a valid sector resolution tier")
				_require(mip >= 0, "fine owner local mip is non-negative")
				if level >= 0:
					seen_fine_levels[level] = true
				negative_fine = negative_fine or sector.x < 0 or sector.y < 0
				_require(terrain.get_surface_vt().has_sector(sector),
						"sparse AVT fine owner remains registered")
				var fine_block := terrain.get_surface_vt().get_sector_block_size(sector)
				_require(level >= 0 and fine_block == _expected_tier_block(requested_density, level, physical_page_size),
						"fine owner uses the exact logical block implied by its tier")
				if level >= 0:
					tier_block_sizes[level] = fine_block
				_require(mip <= int(round(log(float(maxi(1, fine_block))) / log(2.0))),
						"fine owner local mip stays inside its allocated block chain")
				var fine_side := maxi(1, fine_block >> mip)
				_require(address.x >= 0 and address.x < fine_side and address.y >= 0 and address.y < fine_side,
						"sparse AVT owner address stays inside its local mip block")
				_require(terrain.get_surface_vt().lookup_page(sector, mip, address.x, address.y) == slot,
						"sparse AVT page has an exact local mapping")
				fine_lookup_checks += 1
	_require(seen_coarse_mips.has(1), "resident coarse records include mip 1")
	_require(seen_fine_mips.size() > 0, "resident sparse records include a local fine mip")
	_require(coarse_lookup_checks > 0 and fine_lookup_checks > 0,
			"AVT records expose both dense and sparse exact mappings")
	_require(protected_coarse == coarse_pages,
			"every ready dense AVT page remains pinned")
	_require(negative_fine, "AVT sparse owners preserve negative world coordinates")
	print("VT_AVT_DENSE records=", all_records.size(), " coarse_ready=", coarse_ready.size(),
			" fine_ready=", fine_ready.size(), " coarse_pages=", coarse_pages,
			" coarse_size=", coarse_size, " tiers=", sector_levels,
			" local_levels=", local_levels, " tier_blocks=", tier_block_sizes,
			" pool=", pool_count, " protected_coarse=", protected_coarse)
	return {
		"coarse": coarse_ready,
		"fine": fine_ready,
		"pool": pool_count,
		"levels": seen_fine_levels,
		"tier_blocks": tier_block_sizes,
	}


func _find_ready_fine_density(density: float) -> Dictionary:
	var physical_page_size := int(terrain.get_surface_vt().get_page_size())
	var expected_span := float(physical_page_size) / density
	var camera_world := Vector2(camera.position.x, camera.position.z)
	var preview := terrain.get_avt_layout_preview(camera)
	var result: Dictionary = {}
	var best_distance := INF
	for record: Dictionary in _fine_records(true):
		var rect: Rect2 = record.get("world_rect", Rect2())
		if not is_equal_approx(rect.size.x, expected_span) or not is_equal_approx(rect.size.y, expected_span):
			continue
		for owner: Dictionary in record.get("owners", []):
			if not _is_avt_owner(owner) or owner.get("sector", Vector2i.ZERO) == COARSE_OWNER:
				continue
			var local_mip := _owner_local_mip(owner, record)
			if local_mip != 0:
				continue
			var level := _owner_sector_level(owner, preview)
			var distance := rect.get_center().distance_squared_to(camera_world)
			if distance < best_distance:
				best_distance = distance
				result = {"record": record, "owner": owner, "rect": rect,
						"sector": owner.get("sector", Vector2i.ZERO),
						"address": record.get("address", Vector2i(-1, -1)),
						"level": level,
						"local_mip": local_mip}
	return result


func _wait_for_fine_density(density: float, max_frames: int = 160) -> Dictionary:
	var result := _find_ready_fine_density(density)
	for _frame in max_frames:
		if not result.is_empty():
			return result
		await _tick(16)
		result = _find_ready_fine_density(density)
	_require(not result.is_empty(), "the current AVT plan eventually publishes the requested local mip-0 page")
	return result


func _install_fine_slot_probe(slot: int) -> bool:
	var pool_stats: Dictionary = terrain.get_surface_vt().get_stats()
	var layer_count := int(pool_stats.get("page_count", PAGE_POOL))
	if slot < 0 or slot >= layer_count:
		return false
	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var params_images: Array[Image] = []
	for layer in layer_count:
		var albedo := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		albedo.fill(Color(0.02, 0.9, 0.04, 1.0) if layer == slot else Color(0.9, 0.04, 0.02, 1.0))
		albedo_images.append(albedo)
		var normal := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		normal.fill(Color(0.5, 0.5, 1.0, 1.0))
		normal_images.append(normal)
		var params := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		params.fill(Color(0.0, 1.0, 0.0, 1.0))
		params_images.append(params)
	probe_albedo_array = Texture2DArray.new()
	probe_normal_array = Texture2DArray.new()
	probe_params_array = Texture2DArray.new()
	probe_albedo_array.create_from_images(albedo_images)
	probe_normal_array.create_from_images(normal_images)
	probe_params_array.create_from_images(params_images)
	if not probe_albedo_array.get_rid().is_valid() or not probe_normal_array.get_rid().is_valid() or not probe_params_array.get_rid().is_valid():
		probe_albedo_array = null
		probe_normal_array = null
		probe_params_array = null
		return false
	saved_surface_albedo = RenderingServer.material_get_param(material_rid, "_surface_material_albedo")
	saved_surface_normal = RenderingServer.material_get_param(material_rid, "_surface_material_normal")
	saved_surface_params = RenderingServer.material_get_param(material_rid, "_surface_material_params")
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", probe_albedo_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", probe_normal_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", probe_params_array.get_rid())
	return true


func _restore_fine_slot_probe() -> void:
	if material_rid.is_valid() and saved_surface_albedo != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_albedo", saved_surface_albedo)
	if material_rid.is_valid() and saved_surface_normal != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_normal", saved_surface_normal)
	if material_rid.is_valid() and saved_surface_params != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_params", saved_surface_params)
	saved_surface_albedo = null
	saved_surface_normal = null
	saved_surface_params = null
	probe_albedo_array = null
	probe_normal_array = null
	probe_params_array = null


func _check_actual_fine_density(density: float) -> void:
	# A narrow orthographic footprint is required to walk all the way to local
	# mip 0. Keep the page demand explicit so a settings-only implementation
	# cannot satisfy this check while leaving the physical page at a coarser span.
	terrain.surface_vt_texels_per_meter = density
	terrain.surface_vt_texels_per_pixel = 1.0
	if not material_rid.is_valid():
		material_rid = terrain.material.get_material_rid()
	camera.size = 0.1
	camera.position = Vector3(-32.0, 120.0, 0.0)
	terrain.set_clipmap_target(camera)
	_require(await _wait_ready(220), "narrow AVT view settles at the requested fine density")
	var target := await _wait_for_fine_density(density, 160)
	# Property changes can re-enable the node callbacks. Freeze scheduling again
	# before replacing one material layer so a trailing plan cannot republish the
	# generated material bundle over the shader probe.
	terrain.set_process(false)
	terrain.set_physics_process(false)
	var physical_page_size := int(terrain.get_surface_vt().get_page_size())
	_require(physical_page_size == 256, "AVT fine mip 0 uses the 256 texel physical page")
	_require(not target.is_empty(), "narrow AVT view produces a ready physical mip-0 page at the requested density")
	if target.is_empty():
		camera.size = 96.0
		terrain.surface_vt_texels_per_pixel = 0.25
		return
	var rect: Rect2 = target["rect"]
	var expected_span := float(physical_page_size) / density
	var expected_texel := 1.0 / density
	var target_level := int(target.get("level", -1))
	_require(target_level == 0,
			"the narrow density probe selects the finest sector resolution tier")
	_require(is_equal_approx(rect.size.x, expected_span),
			"ready fine mip-0 record spans exactly page_size / density metres")
	_require(is_equal_approx(rect.size.x / float(physical_page_size), expected_texel),
			"ready fine mip-0 record exposes the requested texel world size")
	_require(float(target["sector"].x) < 0.0 or float(target["sector"].y) < 0.0,
			"narrow fine demand retains a negative world sector")
	var expected_block := _expected_tier_block(density, target_level, physical_page_size)
	_require(terrain.get_surface_vt().get_sector_block_size(target["sector"]) == expected_block,
			"fine physical record belongs to the exact tier-0 logical density block")

	var sample_world := rect.get_center()
	camera.position = Vector3(sample_world.x, 120.0, sample_world.y)
	await frame_image(2)
	# Recolour only the selected physical material layer. The dense sentinel
	# pages remain red, so the render result distinguishes a genuine fine AVT
	# lookup from a settings or record-only check. The normal and parameter
	# arrays stay on their real ready pages.
	var vt := terrain.get_surface_vt()
	var slot := int(target["record"].get("slot", -1))
	_require(_install_fine_slot_probe(slot), "a ready fine AVT layer can be recoloured for the shader probe")
	var fine_image := await frame_image(4)
	var fine_colour := sample_area(fine_image, sample_world, 2)
	print("VT_AVT_DENSE_FINE density=", density, " sample=", fine_colour,
			" rect=", rect, " page_size=", physical_page_size,
			" sector=", target["sector"], " address=", target["address"])
	_require(fine_colour == "green",
			"near mip-0 shader sampling reads the rewritten fine AVT page")

	var sector: Vector2i = target["sector"]
	var address: Vector2i = target["address"]
	var removed := vt.release_page(sector, 0, address.x, address.y)
	vt.commit()
	_require(removed, "the probed fine mip-0 mapping can be removed")
	var fallback_image := await frame_image(4)
	var fallback_colour := sample_area(fallback_image, sample_world, 2)
	print("VT_AVT_DENSE_FINE_FALLBACK density=", density, " sample=", fallback_colour)
	_require(fallback_colour == "red",
			"missing fine AVT mapping falls back to the ready dense coarse page")
	var saved_directory_mask: Variant = RenderingServer.material_get_param(material_rid, "_avt_directory_mask")
	RenderingServer.material_set_param(material_rid, "_avt_directory_mask", 0)
	var directory_image := await frame_image(4)
	var directory_colour := sample_area(directory_image, sample_world, 2)
	_require(directory_colour == "red",
			"missing fine AVT directory entry still falls back to the dense coarse page")
	RenderingServer.material_set_param(material_rid, "_avt_directory_mask", saved_directory_mask)
	_restore_fine_slot_probe()
	camera.position = Vector3(-32.0, 120.0, 0.0)
	camera.size = 96.0
	terrain.surface_vt_texels_per_pixel = 0.25
	terrain.set_clipmap_target(camera)


func _find_fine_at(world: Vector2) -> Dictionary:
	for record: Dictionary in _fine_records(true):
		var rect: Rect2 = record.get("world_rect", Rect2())
		if not rect.has_point(world):
			continue
		for owner: Dictionary in record.get("owners", []):
			if _is_avt_owner(owner) and _owner_local_mip(owner, record) == 0 and owner.get("sector", Vector2i.ZERO) != COARSE_OWNER:
				return {"record": record, "owner": owner, "rect": rect,
					"sector": owner.get("sector", Vector2i.ZERO),
					"address": record.get("address", Vector2i(-1, -1)),
					"local_mip": 0}
	return {}


func _find_ready_local_parent(target: Dictionary) -> Dictionary:
	var world: Vector2 = target.get("rect", Rect2()).get_center()
	var sector: Vector2i = target.get("sector", Vector2i.ZERO)
	var target_mip := int(target.get("local_mip", 0))
	var best_mip := 999
	var result: Dictionary = {}
	for record: Dictionary in _fine_records(true):
		var rect: Rect2 = record.get("world_rect", Rect2())
		if not rect.has_point(world):
			continue
		for owner: Dictionary in record.get("owners", []):
			if not _is_avt_owner(owner) or owner.get("sector", Vector2i.ZERO) != sector:
				continue
			var local_mip := _owner_local_mip(owner, record)
			if local_mip <= target_mip or local_mip >= best_mip:
				continue
			best_mip = local_mip
			result = {"record": record, "owner": owner, "rect": rect,
					"sector": sector, "local_mip": local_mip,
					"address": record.get("address", Vector2i(-1, -1))}
	return result


func _poison_source_and_check_fallback() -> void:
	var target := _find_fine_at(Vector2(-32.0, 0.0))
	if target.is_empty():
		for record: Dictionary in _fine_records(true):
			for owner: Dictionary in record.get("owners", []):
				if _is_avt_owner(owner) and _owner_local_mip(owner, record) == 0 and owner.get("sector", Vector2i.ZERO) != COARSE_OWNER:
					target = {"record": record, "owner": owner, "rect": record.get("world_rect", Rect2()),
						"sector": owner.get("sector", Vector2i.ZERO),
						"address": record.get("address", Vector2i(-1, -1)), "local_mip": 0}
					break
			if not target.is_empty():
				break
	_require(not target.is_empty(), "a ready sparse mip-0 page covers the negative-coordinate view")
	if target.is_empty():
		return

	var poison_image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	poison_image.fill(Color(0.02, 0.04, 0.98, 1.0))
	poison_image.generate_mipmaps()
	var poison := Texture2DArray.new()
	poison.create_from_images([poison_image, poison_image])
	material_rid = terrain.material.get_material_rid()
	saved_source_array = RenderingServer.material_get_param(material_rid, "_texture_array_albedo")
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())

	var source_vt := terrain.get_surface_vt()
	var sector: Vector2i = target["sector"]
	var address: Vector2i = target["address"]
	var removed := source_vt.release_page(sector, 0, address.x, address.y)
	source_vt.commit()
	_require(removed, "a sparse mip-0 page can be removed to exercise dense fallback")
	var rect: Rect2 = target["rect"]
	var sample_world := rect.get_center()
	var image := await frame_image(4)
	var colour := sample_area(image, sample_world, 2)
	print("VT_AVT_DENSE_FALLBACK sample=", colour, " rect=", rect, " sector=", sector,
			" address=", address)
	_require(colour == "red", "missing AVT mip-0 mapping falls back to a ready dense page")
	var saved_directory_mask: Variant = RenderingServer.material_get_param(material_rid, "_avt_directory_mask")
	RenderingServer.material_set_param(material_rid, "_avt_directory_mask", 0)
	var directory_missing := await frame_image(4)
	var directory_colour := sample_area(directory_missing, sample_world, 2)
	print("VT_AVT_DENSE_DIRECTORY_MISS sample=", directory_colour, " mask=0")
	_require(directory_colour == "red",
			"a missing AVT fine directory entry falls back to the dense mip chain")
	RenderingServer.material_set_param(material_rid, "_avt_directory_mask", saved_directory_mask)
	if material_rid.is_valid():
		RenderingServer.material_set_param(material_rid, "_texture_array_albedo", saved_source_array)


func _coarse_snapshot() -> Array:
	var result: Array = []
	for record: Dictionary in _coarse_records(true):
		var owner_mip := int(record.get("mip", -1))
		for owner: Dictionary in record.get("owners", []):
			if _is_coarse_owner(owner):
				owner_mip = int(owner.get("mip", owner_mip))
				break
		result.append({
			"slot": int(record.get("slot", -1)),
			"mip": owner_mip,
			"rect": record.get("world_rect", Rect2()),
			"address": record.get("address", Vector2i(-1, -1)),
		})
	return result


func _check_camera_move(before: Array, expected_coarse_pages: int) -> void:
	camera.position.x = 256.0
	terrain.set_clipmap_target(camera)
	_require(await _wait_ready(), "AVT camera move settles within the bounded fixture budget")
	var after := _coarse_snapshot()
	var settings: Dictionary = terrain.get_vt_settings()
	var pool_stats: Dictionary = terrain.get_surface_vt().get_stats()
	_require(int(settings.get("avt_coarse_pages", 0)) == expected_coarse_pages,
			"camera motion keeps the dense coarse page count fixed")
	_require(after.size() > 0 and after.size() <= int(pool_stats.get("page_count", PAGE_POOL)),
			"camera motion keeps dense residency inside the physical pool")
	var overlap := 0
	var same_slot := 0
	for old: Dictionary in before:
		var old_rect: Rect2 = old["rect"]
		for current: Dictionary in after:
			var current_rect: Rect2 = current["rect"]
			if int(old["mip"]) != int(current["mip"]) or not old_rect.intersects(current_rect):
				continue
			overlap += 1
			if int(old["slot"]) == int(current["slot"]):
				same_slot += 1
				_require(terrain.get_surface_vt().is_page_protected(int(current["slot"])),
						"overlapping dense coarse page remains pinned after camera motion")
				break
	_require(overlap > 0, "camera move retains overlapping dense coarse world rectangles")
	_require(same_slot > 0, "camera move reuses at least one pinned dense coarse physical page")
	print("VT_AVT_DENSE_MOVE before=", before.size(), " after=", after.size(),
			" overlap=", overlap, " same_slot=", same_slot)


func run() -> void:
	_check_layer_controls()
	await _setup_terrain()
	var preview := _check_preview_read_only()
	_require(float(preview.get("radius", 0.0)) == DEFAULT_RADIUS,
			"new AVT scenes use the 384 metre coverage radius")
	var settings_before: Dictionary = terrain.get_vt_settings()
	_require(int(settings_before.get("avt_mip_levels", 0)) == 3,
			"runtime AVT settings expose the default sector tier count")
	_require(int(settings_before.get("avt_max_adaptive_level", 0)) == 1,
			"runtime AVT settings expose the fixed adaptive level")

	terrain.surface_vt_enabled = true
	_require(await _wait_ready(), "initial AVT dense/sparse demand settles")
	var settings: Dictionary = terrain.get_vt_settings()
	var checked := _validate_records(settings)
	var baseline := await frame_image(3)
	_require(sample_area(baseline, Vector2(-32.0, 0.0), 3) == "red",
			"ready negative-coordinate AVT material remains visible")
	await _check_resolution_tiers()
	await _check_actual_fine_density(1024.0)
	await _poison_source_and_check_fallback()

	var coarse_before: Array = _coarse_snapshot()
	var coarse_count := int(settings.get("avt_coarse_pages", 0))
	await _check_camera_move(coarse_before, coarse_count)

	# Changing density is a runtime reconfiguration. Sector tier count is tested
	# above independently; the local page chain stays full at both densities.
	terrain.surface_vt_texels_per_meter = 768.0
	_require(await _wait_ready(), "AVT density downgrade and mip-chain upgrade settle at runtime")
	var changed: Dictionary = terrain.get_vt_settings()
	_require(int(changed.get("avt_mip_levels", 0)) == 3 and
				int(changed.get("avt_sector_resolution_levels", 0)) == 3,
			"runtime AVT density change leaves the configured sector tier count intact")
	_require(float(changed.get("avt_effective_texels_per_meter", 0.0)) > 0.0,
			"runtime AVT density downgrade retains a positive effective density")
	_require(is_equal_approx(terrain.surface_vt_texels_per_meter, 768.0),
			"runtime AVT density downgrade persists the requested density")
	_validate_records(changed)
	await _check_actual_fine_density(768.0)
	await _check_turn_local_parent()

	if material_rid.is_valid():
		RenderingServer.material_set_param(material_rid, "_texture_array_albedo", saved_source_array)
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS dense AVT sector tiers, full local mip chain, sparse fallback, bounded residency and camera reuse")
	quit(0)
