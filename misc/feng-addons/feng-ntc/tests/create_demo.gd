extends SceneTree
## Run in a separate, already imported project containing the four source PNGs.
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const MaterialTools = preload("res://addons/feng-ntc/material_tools.gd")
const CompressionCache = preload("res://addons/feng-ntc/compression_cache.gd")
var results := []
var materials: Array[Material] = []

func _init() -> void: _run.call_deferred()

func _run() -> void:
	if not ClassDB.class_exists(&"FengNTCCodec"): GDExtensionManager.load_extension("res://addons/feng-ntc/tools/feng_ntc.gdextension")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://materials"))
	for name: String in ["gray_rocks", "grass_ground"]:
		var source := StandardMaterial3D.new()
		source.resource_name = name
		source.albedo_texture = load("res://textures/%s_diff_2k.png" % name)
		source.normal_texture = load("res://textures/%s_nor_gl_2k.png" % name)
		source.normal_enabled = true
		source.roughness = 0.85
		source.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		var snapshot := MaterialTools.snapshot(source)
		if not snapshot.get("ok", false): push_error(str(snapshot)); quit(1); return
		var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
		var started := Time.get_ticks_msec()
		var worker := Thread.new()
		worker.start(func() -> Dictionary: return CompressionCache.compress(codec, MaterialTools.pack(snapshot), 2.0, 16384))
		while worker.is_alive(): await process_frame
		var result: Dictionary = worker.wait_to_finish()
		if not result.get("ok", false): push_error(str(result)); quit(1); return
		var asset := TextureSet.new()
		asset.package = result.package
		var prefix := "res://materials/" + name
		if ResourceSaver.save(asset, prefix + ".ntc.res", ResourceSaver.FLAG_COMPRESS) != OK: quit(1); return
		asset.take_over_path(prefix + ".ntc.res")
		var compressed := MaterialTools.make_neural(source,asset)
		ResourceSaver.save(compressed, prefix + "_ntc.tres")
		compressed.take_over_path(prefix + "_ntc.tres")
		ResourceSaver.save(source, prefix + "_original.tres")
		source.take_over_path(prefix + "_original.tres")
		materials.append(source)
		materials.append(compressed)
		var record := {"name": name, "size": str(snapshot["size"]), "training_steps": 16384,
			"compression_ms": Time.get_ticks_msec() - started, "ntc_bytes": var_to_bytes(asset.package).size(),
			"actual_bpp": result.actual_bpp, "sdk_psnr_db": result.psnr,
			"reused_training": result.get("compression_cache_hit", false)}
		started = Time.get_ticks_msec()
		var session: RefCounted=asset.get_sample_session()
		while not session.ready and session.last_error.is_empty(): await process_frame
		record.incremental_gpu_load_ms = Time.get_ticks_msec() - started
		record.runtime = session.stats
		started = Time.get_ticks_msec()
		asset.get_sample_session()
		record.warm_load_ms = Time.get_ticks_msec() - started
		results.append(record)
		print("REAL_MATERIAL: ", JSON.stringify(record))
	_build_scene()
	var report := FileAccess.open("res://measurements.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(results, "\t"))
	report.close()
	print("DEMO_READY")
	quit()

func _owned(scene: Node, node: Node) -> void:
	scene.add_child(node)
	node.owner = scene

func _build_scene() -> void:
	var scene := Node3D.new()
	scene.name = "FengNTCComparison"
	scene.set_script(load("res://demo.gd"))
	var world := WorldEnvironment.new()
	world.name = "Environment"
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.09, 0.12, 0.17)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.7, 0.8, 1.0)
	world.environment.ambient_light_energy = 0.4
	world.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_owned(scene, world)
	var sun := DirectionalLight3D.new()
	sun.name = "KeyLight"
	sun.rotation_degrees = Vector3(-48, -25, 0)
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	_owned(scene, sun)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-35, 150, 0)
	fill.light_energy = 0.45
	_owned(scene, fill)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 7.5, 11)
	camera.rotation_degrees = Vector3(-32, 0, 0)
	camera.fov = 48
	camera.current = true
	_owned(scene, camera)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor"
	var box := BoxMesh.new()
	box.size = Vector3(16, 0.2, 14)
	floor_mesh.mesh = box
	floor_mesh.position.y = -0.1
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.18, 0.2, 0.24)
	floor_material.roughness = 0.9
	floor_mesh.material_override = floor_material
	_owned(scene, floor_mesh)
	for i in range(4):
		var x := -2.5 if i % 2 == 0 else 2.5
		var z := -1.8 if i < 2 else 2.0
		var sphere := MeshInstance3D.new()
		sphere.name = ("Rock" if i < 2 else "Grass") + ("Original" if i % 2 == 0 else "NTC")
		var mesh := SphereMesh.new()
		mesh.radius = 1.1
		mesh.height = 2.2
		mesh.radial_segments = 96
		mesh.rings = 48
		sphere.mesh = mesh
		sphere.position = Vector3(x, 1.1, z)
		sphere.material_override = materials[i]
		_owned(scene, sphere)
		var sample := MeshInstance3D.new()
		sample.name = sphere.name + "Tile"
		var tile := BoxMesh.new()
		tile.size = Vector3(2.5, 0.08, 2.5)
		sample.mesh = tile
		sample.position = Vector3(x, 0.05, z)
		sample.material_override = materials[i]
		_owned(scene, sample)
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	_owned(scene, hud)
	var label := Label.new()
	label.name = "Help"
	label.position = Vector2(26, 18)
	label.text = "Feng NTC / FRP    左：Godot 导入贴图    右：NTC 压缩数据直接采样\n2K 底色 + GL 法线。保留压缩潜变量与网络，不生成完整 RGBA8。\n1 原材质 · 2 NTC · 3 VT · 4 RGBA8 诊断。"
	label.add_theme_font_size_override("font_size", 22)
	hud.add_child(label)
	label.owner = scene
	var packed := PackedScene.new()
	packed.pack(scene)
	ResourceSaver.save(packed, "res://main.tscn")
	scene.free()
