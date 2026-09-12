extends "res://vt_adaptive_base.gd"

func tick() -> int:
	var produced := terrain.update_surface_vt(1)
	await process_frame
	await RenderingServer.frame_post_draw
	return produced

func settle() -> void:
	var quiet := 0
	for i in 160:
		var produced := await tick()
		if produced == 0 and int(terrain.get_vt_settings().get("producer", {}).get("pending", 1)) == 0:
			quiet += 1
		else:
			quiet = 0
		if quiet >= 8:
			return
	require(false, "metric AVT did not settle")

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	DirAccess.make_dir_recursive_absolute("user://metric-terrain")
	terrain.data_directory = "user://metric-terrain"
	terrain.vt_page_size = 256
	# This view straddles four page quadrants at every mip. Retaining their
	# filtering parents needs more than 32 slots at 2048 texels/metre.
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 1
	terrain.surface_vt_selection_mode = 2
	terrain.surface_svt_auto_bake = false
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.2
	camera.position = Vector3(32.05, 1, 32.05)
	camera.rotation_degrees.x = -90
	camera.current = true
	scene.add_child(terrain)
	root.add_child(scene)
	root.add_child(camera)
	terrain.set_camera(camera)
	await process_frame
	terrain.set_process(false)
	terrain.set_physics_process(false)
	add_assets()
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.update_maps()
	terrain.surface_vt_enabled = true
	for density in [768.0, 1024.0, 2048.0]:
		terrain.surface_vt_texels_per_meter = density
		await settle()
		var stats: Dictionary = terrain.get_vt_settings().avt_sector_stats
		var block := terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO)
		require(block == (512 if density == 2048 else 256), "virtual block must be independent of 64-slot pool")
		require(stats.indirection_size == 2048, "AVT page table stays 2K")
		require(stats.base_virtual_resolution == 64.0 * density, "exact metric virtual image")
		var fine := false
		for page: Dictionary in sector_pages(Vector2i.ZERO):
			var rect: Rect2 = page.world_rect
			if is_equal_approx(rect.size.x, 256.0 / density) and page.ready:
				fine = true
		require(fine, "ready physical page must have exact target texels/metre")
		require(terrain.get_vt_pages().size() <= 64, "sparse physical residency")
		print("VT_METRIC density=", density, " block=", block, " resident=", terrain.get_vt_pages().size(), " page_metres=", 256.0 / density)
	# Widen the orthographic footprint: screen-space demand discards fine
	# entries while preserving ready world pages.
	terrain.surface_vt_texels_per_meter = 1024
	await settle()
	var previous_block := terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO)
	for footprint in [2.0, 4.0]:
		camera.size = footprint
		await settle()
		var block := terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO)
		require(block < previous_block, "larger screen footprint discards finest virtual entries")
		previous_block = block
	var cached := sector_pages(Vector2i.ZERO)
	camera.size = 0.2
	require(await tick() <= 1, "refinement obeys one-page production budget")
	var retained := false
	for old: Dictionary in cached:
		for page: Dictionary in sector_pages(Vector2i.ZERO):
			if old.slot == page.slot and old.world_rect == page.world_rect and page.ready:
				retained = true
	require(retained, "growing page table preserves ready coarse page world footprints")
	await settle()
	# SVT has its own density and can request a sub-metre mip-0 page even
	# though the terrain data region spans 512 metres.
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = true
	terrain.surface_svt_texels_per_meter = 768
	terrain.surface_svt_mip_distances = PackedFloat32Array([8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096])
	for i in 12:
		terrain.update_surface_svt(4)
		await process_frame
	var svt_fine := false
	for page: Dictionary in terrain.get_vt_pages():
		if page.kind == "SVT" and is_equal_approx(page.world_rect.size.x, 1.0 / 3.0):
			svt_fine = true
	require(svt_fine, "SVT independently requests 768 texels/metre")
	require(terrain.surface_vt_texels_per_meter == 1024, "SVT density must not change AVT density")
	terrain.surface_vt_enabled = true
	terrain.surface_vt_distance = 8
	terrain.set_physics_process(true)
	for i in 40:
		await process_frame
	terrain.set_physics_process(false)
	var kinds := {}
	for page: Dictionary in terrain.get_vt_pages():
		kinds[page.kind] = true
	require(kinds.has("AVT") and kinds.has("SVT"), "both enabled views must receive demand")
	require(terrain.get_vt_pages().size() <= 64, "combined views respect shared residency")
	# Whole-cell storage has a bounded source resolution. Check the evaluated
	# slope in its baked normal channel rather than old per-page staging bytes.
	terrain.surface_svt_texels_per_meter = 1
	var heights := PackedByteArray()
	heights.resize(512 * 512 * 4)
	for z in 512:
		for x in 512:
			heights.encode_float((z * 512 + x) * 4, x * 0.001 + z * 0.002)
	terrain.data.get_region(Vector2i.ZERO).set_height_map(Image.create_from_data(512,512,false,Image.FORMAT_RF,heights))
	terrain.data.update_maps()
	terrain.surface_svt_auto_bake = true
	terrain.set_physics_process(true)
	await create_timer(1.5).timeout
	terrain.set_physics_process(false)
	var checked_height := false
	for tile: Dictionary in terrain.get_svt_baked_pages():
		var file := FileAccess.open(tile.path, FileAccess.READ)
		var header: Dictionary = file.get_var()
		file.seek(header.index[2])
		var bytes := file.get_buffer(header.index[3]).decompress(512 * 512 * 8, FileAccess.COMPRESSION_ZSTD)
		var image := Image.create_from_data(512,512,false,Image.FORMAT_RGBAH,bytes)
		var sample := image.get_pixel(256,256)
		var actual := Vector3(sample.r,sample.g,sample.b).normalized()
		require(actual.dot(Vector3(-0.001,1,-0.002).normalized()) > 0.999, "cell source retains evaluated slope normal")
		require(header.resolution == 512, "one texel/metre produces a 512 cell source")
		checked_height = true
	require(checked_height, "sloped SVT cell was automatically persisted")
	print("VT_METRIC svt_fine=", svt_fine)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
	else:
		print("PASS metric VT density, sparse entries and mip reuse")
		quit(0)
