extends "res://vt_adaptive_base.gd"

func capture(label: String) -> Image:
	for frame in 8:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output_dir.path_join(label + ".png"))
	return image

func run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 1: output_dir = arguments[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	scene.add_child(terrain)
	root.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(16, 30, 48)
	camera.current = true
	root.add_child(camera)
	camera.look_at(Vector3(16, 0, 16))
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	terrain.set_physics_process(false)
	add_assets()
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.data.add_region_blank(Vector2i.ZERO)
	var asset := Terrain3DMeshAsset.new()
	asset.generated_type = Terrain3DMeshAsset.TYPE_TEXTURE_CARD
	asset.generated_size = Vector2(2, 4)
	asset.generated_faces = 2
	asset.set_lod_range(0, 1000.0)
	asset.height_offset = 0.0
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { ALBEDO = COLOR.rgb; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	asset.material_override = material
	terrain.assets.set_mesh_asset(0, asset)
	var transforms: Array[Transform3D] = []
	var colors := PackedColorArray()
	for z in 6:
		for x in 6:
			var basis := Basis.from_euler(Vector3(0.05 * z, 0.2 * x, 0.04 * x))
			basis = basis.scaled(Vector3(0.5 + x * 0.1, 0.8 + z * 0.07, 1.0))
			transforms.append(Transform3D(basis, Vector3(3 + x * 5, 0, 3 + z * 5)))
			colors.append(Color(0.2 + x * 0.13, 0.2 + z * 0.13, 0.8, 1))
	terrain.instancer.add_transforms(0, transforms, colors)
	var initial := await capture("instances")
	var colored_pixels := 0
	for y in initial.get_height():
		for x in initial.get_width():
			var pixel := initial.get_pixel(x, y)
			if pixel.b > pixel.r * 1.2 and pixel.b > 0.3: colored_pixels += 1
	require(colored_pixels > 200, "fixture actually renders colored instances")
	require(asset.get_instance_count() == 36, "all generated instances reach rendering")
	terrain.instancer.update_mmis(-1, Vector2i(2147483647, 2147483647), true)
	var rebuilt := await capture("rebuilt")
	require(initial.get_data() == rebuilt.get_data(), "rebuild preserves transforms and colors")
	var region := terrain.data.get_region(Vector2i.ZERO)
	var before: Dictionary = region.get_instances().duplicate(true)
	# The brush visits the occupied cell but its circle misses every instance.
	terrain.instancer.remove_instances(Vector3(1, 0, 1), {"asset_id": 0, "size": 0.5, "strength": 100.0})
	if OS.get_environment("TERRAIN_VT_REFERENCE") != "1":
		require(region.get_instances() == before, "missed removal leaves cell payload and dirty flag unchanged")
	var missed := await capture("missed_removal")
	require(initial.get_data() == missed.get_data(), "missed removal preserves rendered output")
	# Probability is clamped above one, making the one selected removal deterministic.
	terrain.instancer.remove_instances(Vector3(3, 0, 3), {"asset_id": 0, "size": 1.0, "strength": 100.0})
	await capture("removed")
	require(asset.get_instance_count() == 35, "removal updates the instance count")
	terrain.instancer.clear_by_mesh(0)
	await capture("cleared")
	require(asset.get_instance_count() == 0, "clearing releases all instances")
	# Interleave cells so batching cannot rely on contiguous input. Append twice
	# to exercise both creation and extension of existing packed color arrays.
	var interleaved: Array[Transform3D] = []
	var batch_colors := PackedColorArray()
	for i in 300:
		interleaved.append(Transform3D(Basis.IDENTITY, Vector3((i % 3) * 32 + 1, i * 0.01, 1)))
		batch_colors.append(Color(i / 300.0, 0.5, 0.25, 1))
	for batch in 2:
		terrain.instancer.append_region(region, 0, interleaved, batch_colors, false)
	var cells: Dictionary = region.get_instances()[0]
	require(cells.keys() == [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], "batch preserves first-seen cell order")
	for cell in 3:
		var triple: Array = cells[Vector2i(cell, 0)]
		require(triple[0].size() == 200 and triple[1].size() == 200, "batch appends all transforms and colors")
		for i in 200:
			var source := (i % 100) * 3 + cell
			require(triple[0][i] == interleaved[source] and triple[1][i] == batch_colors[source], "batch preserves each cell's transform/color order")
	terrain.instancer.clear_by_mesh(0)
	for location in [Vector2i(-1, 0), Vector2i(1, 0)]:
		terrain.data.add_region_blank(location, false)
	asset.height_offset = 2.0
	var global_batch: Array[Transform3D] = []
	for i in 6:
		var region_x: int = [1, -1, 0][i % 3]
		global_batch.append(Transform3D(Basis.IDENTITY, Vector3(region_x * 512 + 4, i, 4)))
	terrain.instancer.add_transforms(0, global_batch, PackedColorArray([Color.RED]), false)
	for i in 6:
		var region_x: int = [1, -1, 0][i % 3]
		var stored: Array = terrain.data.get_region(Vector2i(region_x, 0)).get_instances()[0][Vector2i.ZERO]
		var index := i / 3
		require(stored[0][index].origin == Vector3(4, i + 2, 4), "region grouping preserves localization and height offset")
		require(stored[1][index] == (Color.RED if i == 0 else Color.WHITE), "region grouping preserves missing-color defaults")
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if not failed: print("PASS terrain instancer output and edits")
	quit(1 if failed else 0)
