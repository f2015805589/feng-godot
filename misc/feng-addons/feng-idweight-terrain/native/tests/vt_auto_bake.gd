# GPU integration for the shared AVT material cache and persistent SVT pages.
extends "res://vt_render_base.gd"

func ready_pages() -> int:
	var count := 0
	for page: Dictionary in terrain.get_vt_pages():
		if page.ready: count += 1
	return count

func settle() -> void:
	for frame in 240:
		await process_frame
		if frame > 20 and int(terrain.get_vt_settings().get("producer", {}).get("pending", 1)) == 0 and ready_pages() > 0:
			break
	await RenderingServer.frame_post_draw

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	var reload_mode := args.size() > 2 and args[2] == "reload"
	var unrelated := []
	if reload_mode:
		for i in 71: unrelated.append(RefCounted.new())
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 4
	terrain.surface_vt_selection_mode = 1
	terrain.surface_vt_region_grid = Vector2i(2, 2)
	terrain.surface_vt_pages_per_axis = 4
	terrain.surface_vt_distance = 2048
	terrain.surface_svt_page_world = 64
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_max_mip = 1
	terrain.surface_svt_distance = 96
	DirAccess.make_dir_recursive_absolute("user://terrain")
	terrain.data_directory = "user://terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = texture(32, Color.RED if id == 0 else Color.GREEN)
		asset.normal_texture = texture(32, Color(0.5, 0.5, 1, 1))
		terrain.assets.set_texture_asset(id, asset)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(64, 160, 32)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 160
	camera.current = true
	terrain.set_camera(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)
	terrain.region_size = 64
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	for x in [0, 8]:
		terrain.data.add_region_blank(Vector2i(x, 0))
		paint_region(Vector2i(x, 0), 1 if reload_mode and x == 0 else 0)
	terrain.data.update_maps()
	if reload_mode:
		# Runtime may discard authoring assets; persistent identity must survive it.
		terrain.assets.clear_textures(false)
		# The far field has to own the visible region: the near field is on by default and its
		# Target Grid claims every region it covers, after which the far field demands nothing
		# and can never serve a page from the persisted bake. This fixture is about the far
		# field, so its own settings name the view under test.
		terrain.surface_vt_enabled = false
		terrain.surface_svt_enabled = true
		for frame in 60: await process_frame
		var reloaded := terrain.get_vt_settings()
		print("AUTO_RELOADED ", reloaded)
		require(reloaded.producer.cached_uploads > 0 and reloaded.producer.baked_pages == 0,
				"new process must reuse SVT after source texture resources are released")
		require(ready_pages() > 0, "persisted pages must become ready without rebaking")
		terrain.set_editor(null)
		painter.free()
		scene.queue_free()
		for frame in 5: await process_frame
		if not failed: print("PASS cross-process SVT content identity")
		quit(1 if failed else 0)
		return
	terrain.surface_svt_enabled = true
	terrain.surface_svt_auto_bake = true
	await automatic_settle()
	var initial := terrain.get_vt_settings()
	print("AUTO_INITIAL ", initial)
	require(initial.bake_total > 0 and initial.bake_done == initial.bake_total and initial.bake_failed == 0,
			"initial missing SVT pages must bake automatically")
	var original: Dictionary = file_hashes()
	var baked_before: int = initial.cells_baked
	await create_timer(0.8).timeout
	await frame_image()
	require(terrain.get_vt_settings().cells_baked == baked_before, "idle SVT must not rebake")

	paint_region(Vector2i(0, 0), 1)
	await create_timer(0.1).timeout
	paint_region(Vector2i(0, 0), 0)
	await create_timer(0.1).timeout
	paint_region(Vector2i(0, 0), 1)
	require(terrain.get_vt_settings().cells_baked == baked_before, "continuous strokes must debounce baking")
	await automatic_settle()
	var edited := terrain.get_vt_settings()
	print("AUTO_EDITED ", edited)
	require(edited.bake_generation > initial.bake_generation, "each bake must publish a new UI completion generation")
	require(edited.bake_incremental and edited.bake_total < initial.bake_total, "one region edit must only bake affected pages and parents")
	require(edited.bake_done == edited.bake_total and edited.bake_failed == 0, "incremental job must complete")
	var changed := 0
	for tile: Dictionary in terrain.get_svt_baked_pages():
		var path := String(tile.get("path", ""))
		if path.is_empty():
			continue
		var rect: Rect2 = tile.world_rect
		var hash_now := FileAccess.get_sha256(path)
		if rect.position.x >= 512.0:
			require(hash_now == original[path], "distant unaffected SVT files must remain unchanged")
		elif hash_now != original[path]: changed += 1
	require(changed > 0, "edited SVT files must contain new material data")

	# The recovery action must regenerate every page even when cached files exist.
	var before_full: int = terrain.get_vt_settings().cells_baked
	var count := terrain.bake_svt()
	for frame in 360:
		await process_frame
		if terrain.get_vt_settings().bake_pending == 0: break
	require(terrain.get_vt_settings().bake_done == count, "manual full bake completes")
	require(terrain.get_vt_settings().cells_baked - before_full == count, "manual full bake must actually regenerate cached pages")
	# Offline SVT work shares a tiny cache with live AVT. Re-entering a viewed
	# region during a bake must still produce AVT, and the bake must finish.
	terrain.vt_page_count = 8
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	terrain.surface_vt_enabled = true
	camera.position.x = 32
	await settle()
	# `bake_pending` counts the queue and the waiting set, not the cell being baked, so it can
	# reach zero a frame before the job's last cell lands. Count the cells instead: the counter
	# is monotonic, so a later automatic job taking over the job-scoped progress numbers cannot
	# hide that this one finished every cell it queued (same idiom as the full bake above).
	var cells_before_pressure: int = terrain.get_vt_settings().cells_baked
	var pressure_count := terrain.bake_svt()
	terrain.invalidate_surface_pages(Vector2i.ZERO)
	for frame in 480:
		await process_frame
		if frame > 30 and terrain.get_vt_settings().cells_baked - cells_before_pressure >= pressure_count: break
	require(terrain.get_vt_settings().cells_baked - cells_before_pressure >= pressure_count,
			"SVT bake completes with live AVT in an eight-page cache")
	await settle()
	var avt_ready := false
	for page: Dictionary in terrain.get_vt_pages():
		if str(page.get("kind", "")).to_lower() == "avt" and page.ready: avt_ready = true
	require(avt_ready, "AVT continues producing while SVT bake shares the cache")
	terrain.set_editor(null)
	painter.free()
	scene.queue_free()
	for frame in 5: await process_frame
	if failed: quit(1)
	else:
		print("PASS automatic incremental SVT baking")
		quit()

func automatic_settle() -> void:
	await create_timer(0.65).timeout
	for frame in 360:
		await process_frame
		var settings := terrain.get_vt_settings()
		if settings.auto_pending_regions == 0 and settings.bake_pending == 0 and settings.bake_total > 0: break
	await RenderingServer.frame_post_draw

func file_hashes() -> Dictionary:
	var result := {}
	for tile: Dictionary in terrain.get_svt_baked_pages():
		var path := String(tile.get("path", ""))
		if path.is_empty():
			# A resident cell with no file behind it: the browser lists it, this test is
			# about the persisted bakes only.
			continue
		result[path] = FileAccess.get_sha256(path)
	return result
