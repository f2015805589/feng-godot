## Near-field delivered-density diagnosis.
##
## The sector AVT can address up to `surface_vt_texels_per_meter` (1024 by
## default), but what a fragment actually gets is the finest *resident* page of
## the cell it lands in. This probe measures that: the tier/block the scan hands
## each visible sector, the plan's page selection by local mip, and the world
## footprint of every ready fine page - which is the only number a viewer sees.
##
## The assertions are the contract the plan's selection has to keep: the near
## ground reaches the density the view asks of it (half a metre pages or finer,
## and broadly rather than in one patch), the far cells keep their coarse pages,
## the fallback tier stays complete, and nothing is left missing at a settled
## pose. The readings below are what they were written against - measured on the
## span-breadth-first selection this test replaced, the same 496 resident pages
## held nothing finer than a metre.
extends "res://vt_probe_base.gd"

const SECTOR_WORLD := 64.0
const COARSE_OWNER := Vector2i(-2147483648, -2147483648)
const SETTLE_FRAMES := 360

var terrain_settings := {}
var material_rid := RID()
var saved_albedo: Variant
var saved_normal: Variant
var saved_params: Variant
var probe_albedo: Texture2DArray
var probe_normal: Texture2DArray
var probe_params: Texture2DArray


# A synthetic material array with one slot green and every other red, bound over the terrain's own
# arrays. What the shader resolves for a fragment is then a colour: the pages this test measured
# resident are the only thing the reading can come from.
func install_slot_probe(slot: int) -> bool:
	var pool_stats: Dictionary = terrain.get_surface_vt().get_stats()
	var layer_count := int(pool_stats.get("page_count", 0))
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
	probe_albedo = Texture2DArray.new()
	probe_normal = Texture2DArray.new()
	probe_params = Texture2DArray.new()
	probe_albedo.create_from_images(albedo_images)
	probe_normal.create_from_images(normal_images)
	probe_params.create_from_images(params_images)
	if not probe_albedo.get_rid().is_valid() or not probe_normal.get_rid().is_valid() or not probe_params.get_rid().is_valid():
		probe_albedo = null
		probe_normal = null
		probe_params = null
		return false
	material_rid = terrain.material.get_material_rid()
	saved_albedo = RenderingServer.material_get_param(material_rid, "_surface_material_albedo")
	saved_normal = RenderingServer.material_get_param(material_rid, "_surface_material_normal")
	saved_params = RenderingServer.material_get_param(material_rid, "_surface_material_params")
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", probe_albedo.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", probe_normal.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", probe_params.get_rid())
	return true


func restore_slot_probe() -> void:
	if material_rid.is_valid() and saved_albedo != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_albedo", saved_albedo)
	if material_rid.is_valid() and saved_normal != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_normal", saved_normal)
	if material_rid.is_valid() and saved_params != null:
		RenderingServer.material_set_param(material_rid, "_surface_material_params", saved_params)
	saved_albedo = null
	saved_normal = null
	saved_params = null
	probe_albedo = null
	probe_normal = null
	probe_params = null


func _tick(max_pages: int = 16) -> void:
	terrain.update_surface_vt(max_pages)
	await process_frame
	await RenderingServer.frame_post_draw


func page_density(record: Dictionary) -> float:
	var rect: Rect2 = record.get("world_rect", Rect2())
	if rect.size.x <= 0.0:
		return 0.0
	return float(terrain.vt_page_size) / rect.size.x


func is_coarse(owner: Dictionary) -> bool:
	return owner.get("sector", Vector2i.ZERO) == COARSE_OWNER


# The finest ready fine page covering one world point, as {density, slot, rect}. The density is the
# number a viewer sees: page texels over the world span the page covers.
func finest_ready_page_at(world: Vector2) -> Dictionary:
	var best: Dictionary = {}
	for record: Dictionary in terrain.get_vt_pages():
		if not bool(record.get("ready", false)):
			continue
		var fine := false
		for owner: Dictionary in record.get("owners", []):
			if String(owner.get("owner_type", "")) == "avt" and not is_coarse(owner):
				fine = true
		if not fine:
			continue
		var rect: Rect2 = record.get("world_rect", Rect2())
		if not rect.has_point(world):
			continue
		var density := page_density(record)
		if best.is_empty() or density > float(best.get("density", 0.0)):
			best = {"density": density, "slot": int(record.get("slot", -1)), "rect": rect}
	return best


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute("user://vt_near_density")

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = 64
	# Everything below is left at its shipped default on purpose: this probe
	# measures the configuration a project gets, not a fixture-tuned one.
	terrain.vt_auto_capacity = true
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_near_density"
	terrain.set_process(false)
	terrain.set_physics_process(false)
	print("NEAR_DENSITY defaults page_size=", terrain.vt_page_size, " border=", terrain.vt_page_border,
			" pool=", terrain.vt_page_count, " texels_per_meter=", terrain.surface_vt_texels_per_meter,
			" texels_per_pixel=", terrain.surface_vt_texels_per_pixel,
			" tiers=", terrain.surface_vt_mip_levels, " distance=", terrain.surface_vt_distance,
			" aniso=", terrain.surface_vt_anisotropy)

	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = 1024.0
	camera.position = Vector3(0.0, 1.7, 0.0)
	camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	camera.current = true
	root.get_viewport().set_anisotropic_filtering_level(3) # 8x, the shipped request
	root.add_child(camera)

	scene.add_child(terrain)
	root.add_child(scene)
	await process_frame
	terrain.region_size = 64
	add_assets()
	for x in range(-2, 3):
		for y in range(-2, 3):
			terrain.data.add_region_blank(Vector2i(x, y), false)
			set_region_material(Vector2i(x, y), 0)
	terrain.data.update_maps()

	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	terrain.set_process(false)
	terrain.set_physics_process(false)
	terrain.surface_vt_enabled = true

	for _frame in SETTLE_FRAMES:
		await _tick(16)

	var preview: Dictionary = terrain.get_avt_layout_preview(camera)
	print("NEAR_DENSITY preview size=", preview.get("size"), " levels=", preview.get("levels"),
			" coarse_texels_per_meter=", preview.get("coarse_texels_per_meter"),
			" fine_page_world=", preview.get("fine_page_world"),
			" fine_block_size=", preview.get("fine_block_size"),
			" fine_mip_levels=", preview.get("fine_mip_levels"))
	print("NEAR_DENSITY resolution_levels=", preview.get("resolution_levels"))
	for sector: Dictionary in preview.get("sectors", []):
		if bool(sector.get("visible", false)):
			print("NEAR_DENSITY sector rect=", sector.get("rect"), " level=", sector.get("level"),
					" block_size=", sector.get("block_size"), " logical_pages=", sector.get("logical_pages"),
					" allocated=", sector.get("allocated"))

	terrain_settings = terrain.get_vt_settings()
	var stats: Dictionary = terrain_settings.get("avt_sector_stats", {})
	print("NEAR_DENSITY stats plan_level_mips=", stats.get("plan_level_mips"),
			" visible_plan_pages=", stats.get("visible_plan_pages"),
			" plan_world_pages=", stats.get("plan_world_pages"),
			" fallback_plan_pages=", stats.get("fallback_plan_pages"),
			" fallback_ready_pages=", stats.get("fallback_ready_pages"),
			" finest_requested_texel_world=", stats.get("finest_requested_texel_world"))
	print("NEAR_DENSITY stats independent_sectors=", stats.get("independent_sectors"),
			" max_allocated_resolution=", stats.get("max_allocated_resolution"),
			" requested_physical_pages=", stats.get("requested_physical_pages"),
			" sampled_pages=", stats.get("sampled_pages"),
			" visible_missing_pages=", stats.get("visible_missing_pages"),
			" produced=", stats.get("produced"), " pool_pages=", stats.get("pool_pages"),
			" plan_budget=", stats.get("plan_budget"))
	print("NEAR_DENSITY service pool_pages=", terrain_settings.get("page_count"),
			" effective=", terrain_settings.get("effective_page_count"),
			" shared_pool=", terrain_settings.get("shared_pool"),
			" physical_cache_bytes=", terrain_settings.get("physical_cache_bytes"))

	var buckets := {}
	var ready_fine := 0
	var best := 0.0
	var best_rect := Rect2()
	var near_ready := 0
	var far_ready := 0
	var coarse_ready := 0
	var coarse_density := 0.0
	var camera_xz := Vector2(camera.position.x, camera.position.z)
	for record: Dictionary in terrain.get_vt_pages():
		if not bool(record.get("ready", false)):
			continue
		var density := page_density(record)
		var owners: Array = record.get("owners", [])
		for owner: Dictionary in owners:
			if String(owner.get("owner_type", "")) != "avt":
				continue
			if is_coarse(owner):
				coarse_ready += 1
				coarse_density = density if coarse_density <= 0.0 else minf(coarse_density, density)
				continue
			ready_fine += 1
			var bucket := int(round(log(maxf(density, 0.001)) / log(2.0)))
			buckets[bucket] = int(buckets.get(bucket, 0)) + 1
			if density >= 16.0:
				far_ready += 1
			if density > best:
				best = density
				best_rect = record.get("world_rect", Rect2())
			if density >= 256.0 and record.get("world_rect", Rect2()).get_center().distance_to(camera_xz) <= 24.0:
				near_ready += 1
	print("NEAR_DENSITY delivered ready_fine_pages=", ready_fine, " best_texels_per_meter=", best,
			" best_rect=", best_rect, " log2_buckets=", buckets)
	print("NEAR_DENSITY delivered near_ready=", near_ready, " far_ready=", far_ready,
			" coarse_ready=", coarse_ready, " coarse_texels_per_meter=", coarse_density)

	# 1. The plan must ask for the density the near ground's footprint does: at 1080p with the
	#    shipped 1024 texels/m the ground beside the camera asks for centimetre-scale pages, so the
	#    selection's own "finest requested texel" has to be at most half a metre per texel.
	var finest_requested := float(stats.get("finest_requested_texel_world", 0.0))
	require(finest_requested > 0.0 and finest_requested <= 0.5,
			"the near plan must request at least 512 texels/m, got %.5f m per texel" % finest_requested)
	# 2. And those requests must land: a settled view has to hold a page at 512 texels/m or finer
	#    near the camera, or the level the shader resolves is coarser than the one it asked for.
	require(best >= 512.0,
			"a settled near view must hold a 512 texels/m page or finer, best was %.1f" % best)
	require(best_rect.size.x > 0.0 and best_rect.get_center().distance_to(camera_xz) <= 8.0,
			"the finest ready page must be the near ground, got %s" % best_rect)
	# 3. Broadly, not one patch: the sharpening has to cover the ground the view samples, which the
	#    span-breadth-first selection could not do at all (it delivered 0 pages at this density).
	require(near_ready >= 64,
			"the near field must be sharp over its visible ground, got %d pages at 256+ texels/m within 24 m" % near_ready)
	# 4. The far cells keep their own coverage: a deficit-first order must not starve them.
	require(far_ready >= 40,
			"the outer cells must keep their coarse pages, got %d ready fine pages" % far_ready)
	# 5. The fallback tier stays complete and resident, and the settled view owes nothing.
	require(int(stats.get("fallback_ready_pages", 0)) == int(stats.get("fallback_plan_pages", -1)) and
			int(stats.get("fallback_ready_pages", 0)) > 0,
			"the dense fallback tier must be complete, got %s of %s ready" % [
				stats.get("fallback_ready_pages"), stats.get("fallback_plan_pages")])
	require(int(stats.get("visible_missing_pages", -1)) == 0,
			"a settled near view must owe no page, got %s missing" % stats.get("visible_missing_pages"))

	# 6. End to end, and after a pose change. A narrow orthographic footprint is below the page's own
	#    texel (0.5 m over 1080 rows is 0.00046 m a pixel against a 0.00098 m texel at 1024 texels/m),
	#    so the fragment's fractional mip blend cannot mix a coarser level in and the resolved page's
	#    colour is the whole reading: the finest resident page under the camera is green and every other
	#    page is red. The pose also moves the camera 100 m in XZ and switches the projection, which is
	#    the "the near field must follow the view" half of the contract.
	#
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.5
	camera.position = Vector3(100.3, 20.0, 100.7)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	terrain.set_clipmap_target(camera)
	var under_camera := Vector2(camera.position.x, camera.position.z)
	var rendered := finest_ready_page_at(under_camera)
	var chain_before := int(terrain.get_vt_settings().get("avt_sector_stats", {}).get("chain_ticks", 0))
	# The pose is driven through the terrain's own process/physics callbacks, not by calling
	# `update_surface_vt()` by hand: the plan's refresh interval is measured in *process frames*, and a
	# fixture that ticks many times inside one frame measures the interval rather than the product.
	# Driving it by hand here was measured to leave the standing game-view plan in place with the key
	# reported unchanged; driving it through the callbacks re-derives the pose's own selection
	# (`chain_ticks` +1, `plan_selected` 133, the histogram below) and lands a 1024 texels/m page under
	# the camera. The callbacks are the contract this phase asserts.
	terrain.set_process(true)
	terrain.set_physics_process(true)
	for _frame in 300:
		await process_frame
		await physics_frame
		rendered = finest_ready_page_at(under_camera)
	terrain.set_process(false)
	terrain.set_physics_process(false)
	for _frame in 30:
		await _tick(16)
		rendered = finest_ready_page_at(under_camera)
	var narrow_stats: Dictionary = terrain.get_vt_settings().get("avt_sector_stats", {})
	print("NEAR_DENSITY natural chain_before=", chain_before, " chain_after=", narrow_stats.get("chain_ticks"),
			" plan_selected=", narrow_stats.get("plan_selected"),
			" plan_level_mips=", narrow_stats.get("plan_level_mips"),
			" under_camera=", rendered.get("density", -1.0))
	print("NEAR_DENSITY rendered under_camera=", under_camera, " target=", rendered,
			" finest_requested_texel_world=", narrow_stats.get("finest_requested_texel_world"),
			" visible_missing_pages=", narrow_stats.get("visible_missing_pages"),
			" plan_level_mips=", narrow_stats.get("plan_level_mips"),
			" plan_reused=", narrow_stats.get("plan_reused"),
			" key_dirty=", narrow_stats.get("plan_key_dirty_component"),
			" plan_age_ms=", narrow_stats.get("plan_age_ms"),
			" visible_sectors=", narrow_stats.get("visible_sectors"))
	# The pose change has to re-plan: the scan hands the cells the new tier (`level=0`, block 256) and
	# the near field must hold the density that pose asks for under the camera - the failure this test
	# was written against is a near field that keeps serving the previous view.
	require(not rendered.is_empty() and float(rendered.get("density", 0.0)) >= 512.0,
			"a pose change must re-plan and hold a 512+ texels/m page under the camera, got %s" % rendered)
	require(int(narrow_stats.get("visible_missing_pages", -1)) == 0,
			"the re-planned pose must owe no page, got %s missing" % narrow_stats.get("visible_missing_pages"))
	if not rendered.is_empty():
		rendered = finest_ready_page_at(under_camera)
		await frame_image(2)
		if not rendered.is_empty() and install_slot_probe(int(rendered["slot"])):
			var label := ""
			for _attempt in 3:
				var shot := await frame_image(3)
				label = sample_area(shot, under_camera, 3)
				if label == "green":
					shot.save_png(output_dir.path_join("near-density-rendered.png"))
					break
			var centre := (await frame_image(1)).get_pixelv(screen_of(under_camera))
			print("NEAR_DENSITY rendered label=", label, " centre=", centre,
					" density=%.1f" % float(rendered["density"]))
			require(label == "green",
					"the shader must resolve the finest ready page under the camera (%.0f texels/m), got %s" % [
						float(rendered["density"]), label])
			restore_slot_probe()

	terrain.surface_vt_enabled = false
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS near field delivers the density its view asks for")
	quit(0)
