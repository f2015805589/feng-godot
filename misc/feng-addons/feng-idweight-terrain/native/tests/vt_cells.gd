extends "res://vt_adaptive_base.gd"

func run() -> void:
	var reload_mode := OS.get_cmdline_user_args().has("reload")
	scene = Node3D.new()
	terrain = Terrain3D.new()
	require(terrain.surface_svt_texels_per_meter == 1, "SVT defaults to 1 texel/metre")
	# Keep the high-resolution cell bake and reload regression explicit.
	terrain.surface_svt_texels_per_meter = 8
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_count = 32
	terrain.surface_svt_mip_distances = PackedFloat32Array([10000])
	DirAccess.make_dir_recursive_absolute("user://cells")
	terrain.data_directory = "user://cells"
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	terrain.data.add_region_blank(Vector2i.ZERO)
	if reload_mode:
		paint_cell_green()
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.position = Vector3(256, 100, 256)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 16
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_svt_enabled = true
	await process_frame
	if not reload_mode:
		require(terrain.bake_svt() == 1, "one 512 m cell is one bake job")
		for frame in 900:
			await process_frame
			var settings := terrain.get_vt_settings()
			if settings.bake_done + settings.bake_failed == 1:
				require(settings.bake_failed == 0, "4096 cell bake succeeds: " + str(settings))
				break
	var shot := await frame_image(80)
	require(sample_area(shot, Vector2(256, 256), 2) == ("green" if reload_mode else "red"), "GPU cell copy renders persisted red source")
	var path := "user://cells/svt_cells/0_0_0.vtcell"
	require(FileAccess.file_exists(path), "one persisted cell source exists")
	require(not DirAccess.dir_exists_absolute("user://cells/svt"), "no per-page disk cache is generated")
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		var header: Dictionary = file.get_var()
		require(header.resolution == 4096 and header.density == 8, "512 m cell contains 4096 x 4096 source")
		require(header.levels == 13 and header.index.size() == 78, "one file indexes all 13 mips of three source channels")
		# Read only the 1x1 final mip, without loading mip0.
		for channel in 3:
			file.seek(header.index[12 * 6 + channel * 2])
			var bytes := file.get_buffer(header.index[12 * 6 + channel * 2 + 1]).decompress(8, FileAccess.COMPRESSION_ZSTD)
			require(bytes.size() == 8, "coarse source mip can be read independently")
		file.close()
	var settings := terrain.get_vt_settings()
	require(settings.producer.baked_pages == 0 and settings.producer.cached_uploads > 0, "runtime copies cells without material rebaking")
	# Runtime page geometry must not invalidate the offline source image.
	terrain.vt_page_size = 128
	shot = await frame_image(80)
	require(terrain.surface_svt_texels_per_meter == 8, "page size preserves source density")
	require(sample_area(shot, Vector2(256, 256), 2) == ("green" if reload_mode else "red"), "same cell source supplies a different physical page size")
	require(terrain.get_svt_baked_pages().size() == 1, "browser lists one cell source")
	if not reload_mode:
		var generation: int = terrain.get_vt_settings().bake_generation
		paint_cell_green()
		terrain.data.update_maps()
		terrain.invalidate_surface_pages(Vector2i.ZERO)
		terrain.surface_svt_auto_bake = true
		for frame in 900:
			await process_frame
			var status := terrain.get_vt_settings()
			if status.bake_generation > generation and status.bake_pending == 0 and status.bake_done > 0:
				require(status.bake_failed == 0, "edited cell source replaces old bake")
				break
		shot = await frame_image(40)
		require(sample_area(shot, Vector2(256,256),2) == "green", "edited cell becomes green through persisted source")
		terrain.surface_svt_auto_bake = false
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	await process_frame
	camera.queue_free()
	await process_frame
	if not failed:
		print("PASS SVT cell sources " + ("reload" if reload_mode else "bake"))
	quit(1 if failed else 0)

func paint_cell_green() -> void:
	var bytes := PackedByteArray()
	bytes.resize(512 * 512 * 2)
	for i in 512 * 512:
		bytes.encode_u16(i * 2, (1 << 11) | (1 << 6))
	terrain.data.get_region(Vector2i.ZERO).set_surface_map(Image.create_from_data(512,512,false,Image.FORMAT_R16,bytes))
