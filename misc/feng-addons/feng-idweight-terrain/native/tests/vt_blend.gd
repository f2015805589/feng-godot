extends "res://vt_adaptive_base.gd"

func run() -> void:
	await check_page_budget()
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.region_size = 64
	terrain.vt_page_size = 32
	terrain.vt_page_count = 128
	terrain.surface_vt_texels_per_meter = 32
	terrain.surface_svt_texels_per_meter = 8
	DirAccess.make_dir_recursive_absolute("user://blend-terrain")
	terrain.data_directory = "user://blend-terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	terrain.region_size = 64
	terrain.surface_density = 1
	terrain.data.add_region_blank(Vector2i.ZERO)
	var bytes := PackedByteArray()
	bytes.resize(64 * 64 * 2)
	for z in 64:
		for x in 64:
			var id := 1 if x >= 33 else 0
			bytes.encode_u16((z * 64 + x) * 2, (id << 11) | (id << 6))
	terrain.data.get_region(Vector2i.ZERO).set_surface_map(Image.create_from_data(64,64,false,Image.FORMAT_R16,bytes))
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	camera.position = Vector3(32.5,5,32.5)
	camera.rotation_degrees.x = -90
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	var direct := await frame_image(12)
	var left := direct.get_pixelv(screen_of(Vector2(32.2,32.25)))
	var right := direct.get_pixelv(screen_of(Vector2(32.8,32.25)))
	require(right.g - left.g > 0.1 and left.r - right.r > 0.1, "reference contains a real material gradient")
	direct.save_png(output_dir.path_join("direct.png"))
	terrain.surface_vt_enabled = true
	for i in 220: await process_frame
	print("BLEND_STATS ", terrain.get_vt_settings())
	var material_rid := terrain.material.get_material_rid()
	var source = RenderingServer.material_get_param(material_rid, "_texture_array_albedo")
	var blue := Image.create(32,32,false,Image.FORMAT_RGBA8)
	blue.fill(Color.BLUE)
	var poison := Texture2DArray.new()
	poison.create_from_images([blue,blue])
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	var avt := await frame_image(12)
	avt.save_png(output_dir.path_join("avt.png"))
	check_gradient(direct, avt, "AVT")
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", source)
	terrain.surface_svt_enabled = true
	require(terrain.bake_svt() > 0, "SVT cell bake queued")
	for i in 300:
		await process_frame
		if terrain.get_vt_settings().bake_pending == 0: break
	terrain.surface_vt_enabled = false
	for i in 160: await process_frame
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	var svt := await frame_image(12)
	svt.save_png(output_dir.path_join("svt.png"))
	check_gradient(direct, svt, "SVT")
	# Reconfigure while SVT jobs can still be queued. Reload baked cells through
	# the worker and prove the result is usable without direct-material fallback.
	terrain.vt_page_size = 64
	await frame_image(2)
	terrain.vt_page_size = 32
	for i in 240: await process_frame
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", poison.get_rid())
	check_gradient(direct, await frame_image(12), "SVT async reconfigure")
	# A missing AVT page in the normal AVT/SVT blend band must remain diagnostic,
	# even though SVT and original material textures are available.
	terrain.set_physics_process(false)
	camera.position = Vector3(-23.5, 40, 32.5)
	camera.look_at(Vector3(32.5, 0, 32.5))
	await frame_image(12)
	RenderingServer.material_set_param(material_rid, "_texture_array_albedo", source)
	RenderingServer.material_set_param(material_rid, "_surface_vt_enabled", true)
	RenderingServer.material_set_param(material_rid, "_avt_sectors_enabled", true)
	RenderingServer.material_set_param(material_rid, "_avt_coverage_distance", 64.0)
	RenderingServer.material_set_param(material_rid, "_avt_directory_mask", 0)
	var missing_avt := await frame_image(2)
	missing_avt.save_png(output_dir.path_join("strict-missing-avt.png"))
	var diagnostic := missing_avt.get_pixelv(missing_avt.get_size() / 2)
	print("STRICT color=", diagnostic, " required=", RenderingServer.material_get_param(material_rid, "_surface_material_required"), " avt=", RenderingServer.material_get_param(material_rid, "_surface_vt_enabled"), " dir=", RenderingServer.material_get_param(material_rid, "_avt_directory_mask"))
	require(diagnostic.r > diagnostic.g * 1.5 and diagnostic.b > diagnostic.g * 1.5, "missing AVT cannot fall back to available SVT in blend band")
	RenderingServer.material_set_param(material_rid, "_surface_vt_enabled", false)
	RenderingServer.material_set_param(material_rid, "_surface_svt_enabled", false)
	var missing_both := await frame_image(2)
	diagnostic = missing_both.get_pixelv(missing_both.get_size() / 2)
	require(diagnostic.r > diagnostic.g * 1.5 and diagnostic.b > diagnostic.g * 1.5, "missing VT cannot fall back to original editor materials")
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed: quit(1)
	else:
		print("PASS VT source corner blending")
		quit(0)

func check_gradient(reference: Image, actual: Image, mode: String) -> void:
	for x in [32.2,32.35,32.5,32.65,32.8]:
		var p := screen_of(Vector2(x,32.25))
		var a := actual.get_pixelv(p)
		var b := reference.get_pixelv(p)
		var error := maxf(absf(a.r-b.r), absf(a.g-b.g))
		print("VT_BLEND ", mode, " x=", x, " error=", error)
		require(error < 0.12, mode + " matches direct triangle gradient")

func check_page_budget() -> void:
	var producer := Terrain3DSurfaceBaker.new()
	producer.configure(8, 2, 32)
	producer.set_materials(RID(), RID(), PackedColorArray([Color.WHITE]), PackedFloat32Array([1]), PackedFloat32Array([1]), PackedFloat32Array([1]), PackedFloat32Array([0]), PackedFloat32Array([1]), PackedVector2Array([Vector2.ZERO]), PackedVector3Array([Vector3.ZERO]))
	var channel := Image.create(12,12,false,Image.FORMAT_RGBAH)
	channel.fill(Color(0,1,0,1))
	var channels := {"albedo_height": channel, "normal_roughness": channel, "params": channel}
	for slot in 32: producer.queue_cached_page(slot, channels)
	# Two callbacks queued together must still share the same frame budget.
	for i in 2:
		RenderingServer.call_on_render_thread(Callable(producer,"render_pending").bind(producer))
	await RenderingServer.frame_post_draw
	var first := int(producer.get_stats().cached_uploads)
	print("VT_BUDGET first=", first, " stats=", producer.get_stats())
	require(first > 0 and first <= 16, "render callbacks share a 16-page frame limit")
	for i in 4:
		await process_frame
		RenderingServer.call_on_render_thread(Callable(producer,"render_pending").bind(producer))
		await RenderingServer.frame_post_draw
	require(int(producer.get_stats().cached_uploads) == 32, "deferred pages eventually complete")
	producer.clear()
