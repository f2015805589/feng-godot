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
	for x in 2:
		terrain.data.add_region_blank(Vector2i(x, 0))
		paint_region(Vector2i(x, 0), x)
	terrain.data.update_maps()
	var baseline := await frame_image()
	require(sample_area(baseline, Vector2(32, 32)) == "r", "direct terrain starts red")
	require(sample_area(baseline, Vector2(96, 32)) == "g", "direct terrain starts green")
	terrain.surface_vt_enabled = true
	terrain.set_surface_vt_force_mip(true, 0)
	await settle()
	print("VT_STATS ", terrain.get_vt_settings())
	require(ready_pages() >= 16, "AVT produces ready GPU material pages")
	require(terrain.get_vt_settings().shared_pool, "AVT and SVT use unified residency")
	require(terrain.get_vt_settings().callback_registered, "VT Pass callback is registered")
	var cached := await frame_image()
	cached.save_png(output_dir.path_join("avt-material.png"))
	require(sample_area(cached, Vector2(32, 32)) == "r", "AVT renders red terrain")
	require(sample_area(cached, Vector2(96, 32)) == "g", "AVT renders green terrain")
	var settled_bakes: int = terrain.get_vt_settings().producer.baked_pages
	for frame in 12: await process_frame
	require(int(terrain.get_vt_settings().producer.baked_pages) == settled_bakes, "stationary AVT does not rebake unchanged pages")
	# Destroy the source material bindings without invalidating the cache. The
	# already baked pages must keep their colours: a fallback-only shader fails.
	var shader_material: RID = terrain.material.get_material_rid()
	var source: Variant = RenderingServer.material_get_param(shader_material, "_texture_array_albedo")
	var poison := Texture2DArray.new()
	var poison_image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	poison_image.fill(Color.BLUE)
	poison.create_from_images([poison_image, poison_image])
	RenderingServer.material_set_param(shader_material, "_texture_array_albedo", poison.get_rid())
	var proof := await frame_image()
	require(sample_area(proof, Vector2(32, 32)) == "r", "ready AVT bypasses source material sampling")
	RenderingServer.material_set_param(shader_material, "_texture_array_albedo", source)
	paint_region(Vector2i.ZERO, 1)
	terrain.data.update_maps()
	await settle()
	var edited := await frame_image()
	require(sample_area(edited, Vector2(32, 32)) == "g", "painting invalidates and rebakes AVT")
	terrain.set_surface_vt_force_mip(false)
	# Enter region (0,0) before measuring. The sweep below stays inside one AVT grid cell, and
	# x=64 is that cell's edge: measuring from there would hand region (1,0) to the far field on
	# the first step and let this cell claim the capacity it frees, which is a density re-plan
	# and a legitimate production burst, not same-grid movement.
	camera.position.x = 32.0
	await settle() # Adaptive mode fills its coverage mip chain before measuring idle work.
	require(terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO) == 4,
			"one target-grid cell keeps the whole 4-page AVT block")
	# The page budget fills that chain a couple of pages per physics tick, and `producer.pending`
	# is already zero between ticks, so idle means the bake counter standing still.
	var idle_frames := 0
	var last_bakes := int(terrain.get_vt_settings().producer.baked_pages)
	for frame in 600:
		await physics_frame
		var bakes_now := int(terrain.get_vt_settings().producer.baked_pages)
		if bakes_now == last_bakes: idle_frames += 1
		else: idle_frames = 0
		last_bakes = bakes_now
		if idle_frames >= 10: break
	var stable_bakes: int = terrain.get_vt_settings().producer.baked_pages
	# A region is the AVT grid cell at this region_size (64 m), so these positions all stay
	# inside region (0,0): moving within one grid cell must not re-plan the density or rebake.
	for x in [8.0, 16.0, 48.0, 60.0]:
		camera.position.x = x
		for frame in 3: await physics_frame
		require(terrain.get_surface_vt().get_sector_block_size(Vector2i.ZERO) == 4,
				"movement inside the same terrain grid does not change AVT density")
	require(int(terrain.get_vt_settings().producer.baked_pages) == stable_bakes, "same-grid camera motion does not rebake")
	camera.position.x = 128
	for frame in 4: await physics_frame
	require(not terrain.get_surface_vt().has_sector(Vector2i.ZERO), "crossing a region boundary moves the AVT grid")
	camera.position.x = 64
	await settle()
	# Visibility mode must select a region in front of the camera even when
	# there is no terrain beneath it. No downward ray is involved.
	terrain.surface_vt_selection_mode = 0
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	camera.position = Vector3(-160, 100, 32)
	camera.look_at(Vector3(32, 0, 32))
	await settle()
	require(terrain.get_surface_vt().has_sector(Vector2i.ZERO), "visible AVT selects the terrain being viewed, not the camera's ground cell")
	require(not terrain.get_surface_vt().has_sector(Vector2i(1, 0)), "1x1 visible grid limits AVT to one region")
	camera.look_at(camera.position + Vector3(-1, 0, 0))
	for frame in 4: await physics_frame
	require(not terrain.get_surface_vt().has_sector(Vector2i.ZERO), "terrain entirely outside the frustum does not occupy AVT")
	terrain.surface_vt_selection_mode = 1
	terrain.surface_vt_region_grid = Vector2i(2, 2)
	camera.position = Vector3(64, 160, 32)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	await settle()
	var bake_count := terrain.bake_svt()
	require(bake_count >= 2, "offline SVT queues world tiles and their mip hierarchy")
	for frame in 360:
		await process_frame
		if terrain.get_vt_settings().bake_pending == 0: break
	require(terrain.get_vt_settings().bake_done == bake_count, "offline SVT completes")
	var tiles: Array = terrain.get_svt_baked_pages()
	require(tiles.size() >= 2, "SVT exposes baked geographical tiles")
	for tile: Dictionary in tiles:
		var preview: Image = tile.preview
		require(preview != null and not preview.is_empty(), "tile contains actual baked colour")
		require(FileAccess.file_exists(tile.path), "SVT tile is saved to disk")
	terrain.surface_vt_enabled = false
	await settle()
	var before_load: int = terrain.get_vt_settings().producer.cached_uploads
	terrain.invalidate_surface_pages(Vector2i.ZERO)
	await settle()
	require(int(terrain.get_vt_settings().producer.cached_uploads) > before_load, "SVT reloads persisted tiles without compute baking")
	var svt := await frame_image()
	require(sample_area(svt, Vector2(32, 32)) == "g", "SVT alone renders baked terrain")
	RenderingServer.material_set_param(shader_material, "_texture_array_albedo", poison.get_rid())
	var svt_proof := await frame_image()
	require(sample_area(svt_proof, Vector2(32, 32)) == "g", "SVT material pages bypass direct source shading")
	RenderingServer.material_set_param(shader_material, "_texture_array_albedo", source)
	print("VT_FINAL_STATS ", terrain.get_vt_settings())
	var capture_uploads := int(terrain.get_vt_settings().producer.cached_uploads)
	require(terrain.prepare_vt_capture() > 0, "idle SVT capture must queue resident uploads")
	await settle()
	require(int(terrain.get_vt_settings().producer.cached_uploads) > capture_uploads, "capture replays SVT uploads")
	require(sample_area(await frame_image(), Vector2(32, 32)) == "g", "SVT capture preserves material")
	# Reconfigure live resources while another offline bake is queued. No stale
	# output/page-table RID may survive and cancelled work must leave no hang.
	terrain.bake_svt()
	terrain.vt_page_size = 48
	terrain.vt_page_border = 3
	terrain.vt_page_count = 64
	terrain.surface_svt_page_world = 32
	terrain.surface_svt_max_mip = 2
	terrain.surface_vt_enabled = true
	terrain.set_surface_vt_force_mip(true, 0)
	await settle()
	require(terrain.get_vt_settings().bake_pending == 0, "reconfiguration cancels incompatible offline work")
	require(terrain.get_vt_settings().bake_failed > 0, "cancelled bake is reported")
	require(terrain.get_surface_vt().get_page_size() == 48 and terrain.get_surface_svt().get_page_size() == 48, "both views adopt new shared dimensions")
	var resized := await frame_image()
	require(sample_area(resized, Vector2(32, 32)) == "g", "terrain renders after live cache reconfiguration")
	var capture_bakes := int(terrain.get_vt_settings().producer.baked_pages)
	require(terrain.prepare_vt_capture() > 0, "idle AVT capture must queue resident bakes")
	await settle()
	require(int(terrain.get_vt_settings().producer.baked_pages) > capture_bakes, "capture replays AVT baking")
	require(sample_area(await frame_image(), Vector2(32, 32)) == "g", "AVT capture preserves material")
	terrain.set_editor(null)
	painter.free()
	scene.queue_free()
	for frame in 5: await process_frame
	if not failed: print("PASS AVT material and SVT persistence integration")
	quit(1 if failed else 0)
