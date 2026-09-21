extends "res://vt_adaptive_base.gd"

func run() -> void:
	var reload_mode := OS.get_cmdline_user_args().has("reload")
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.vt_page_size = 32
	terrain.vt_page_count = 32
	terrain.surface_svt_texels_per_meter = 1
	terrain.surface_svt_auto_bake = false
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_max_mip = 2
	terrain.surface_svt_mip_distances = PackedFloat32Array([0.01, 0.02, 10000])
	DirAccess.make_dir_recursive_absolute("user://mix")
	terrain.data_directory = "user://mix"
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	terrain.region_size = 64
	for x in [-1, 0, 1]:
		terrain.data.add_region_blank(Vector2i(x,0))
		set_region_material(Vector2i(x,0), 1 if x == 1 else 0)
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.position = Vector3(32, 100, 32)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 240
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_svt_enabled = true
	await process_frame
	if not reload_mode:
		require(terrain.bake_svt() == 3, "three cells queue three sources")
		for frame in 400:
			await process_frame
			if terrain.get_vt_settings().bake_pending == 0:
				break
	var shot := await frame_image(60)
	require(sample_area(shot, Vector2(-32,32),1) == "red", "negative cell source is correctly addressed")
	require(sample_area(shot, Vector2(32,32),1) == "red", "left half of composite page is red")
	require(sample_area(shot, Vector2(96,32),1) == "green", "right half of same composite page is green")
	var composite := false
	for page: Dictionary in terrain.get_vt_pages():
		if page.ready and page.kind == "SVT" and page.world_rect.has_point(Vector2(32,32)) and page.world_rect.has_point(Vector2(96,32)):
			composite = true
	print("MIXDIAG skips=%d cells=%d roots=%d baked=%d pages=%s" % [
			int(terrain.get_vt_settings().get("svt_persist_probe_skips", -1)),
			int(terrain.get_vt_settings().get("svt_persist_probe_cells", -1)),
			int(terrain.get_vt_settings().get("svt_root_pages", -1)),
			int(terrain.get_vt_settings().producer.baked_pages),
			str(terrain.get_vt_pages())])
	require(composite, "one runtime page combines two independently baked cells")
	require(terrain.get_vt_settings().producer.baked_pages == 0, "compositing does not rebake materials")
	require(terrain.get_svt_baked_pages().size() == 3, "three source files contain all mips")
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	await process_frame
	camera.queue_free()
	await process_frame
	if not failed:
		print("PASS SVT cell sources " + ("reload" if reload_mode else "bake"))
	quit(1 if failed else 0)
