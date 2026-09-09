# Run with a graphical rendering driver; see README.md in this directory.
extends SceneTree

var terrain: Terrain3D
var painter: Terrain3DEditor
var undo_action: Callable
var redo_action: Callable
var scene: Node3D
var ui: Node
var output_dir: String = "user://"

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

func create_undo_action(_name: String) -> void:
	pass
func add_undo_method(action: Callable) -> void:
	undo_action = action
func add_do_method(action: Callable) -> void:
	redo_action = action
func commit_action(_execute: bool) -> void:
	pass

func frame_image() -> Image:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func array_layer(normal: bool, layer: int) -> Image:
	var name = "_texture_array_normal" if normal else "_texture_array_albedo"
	var rid = RenderingServer.material_get_param(terrain.material.get_material_rid(), name)
	require(rid is RID and rid.is_valid(), "missing " + name)
	var image = RenderingServer.texture_2d_layer_get(rid, layer)
	require(image != null and not image.is_empty(), "missing GPU layer " + str(layer))
	return image

func texture(size: int, format: Image.Format, color: Color, mipmaps: bool) -> ImageTexture:
	var image = Image.create(size, size, false, format)
	image.fill(color)
	if mipmaps:
		image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func run() -> void:
	ui = root
	var args = OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	if not args.is_empty() and not args[0].is_empty():
		scene = load(args[0]).instantiate()
		terrain = scene.get_node("Terrain3D")
	else:
		scene = Node3D.new()
		terrain = Terrain3D.new()
		scene.add_child(terrain)
		terrain.assets = Terrain3DAssets.new()
		for id in 2:
			var asset = Terrain3DTextureAsset.new()
			var format = Image.FORMAT_RGBA8 if id == 0 else Image.FORMAT_RGB8
			asset.albedo_texture = texture(32, format, Color.RED if id == 0 else Color.GREEN, true)
			asset.normal_texture = texture(32, format, Color(0.5, 0.5, 1, 1), true)
			terrain.assets.set_texture_asset(id, asset)
	terrain.free_editor_textures = false
	var camera = Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(32, 40, 32)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 60
	camera.current = true
	terrain.set_camera(camera)
	var light = DirectionalLight3D.new()
	scene.add_child(light)
	light.rotation_degrees = Vector3(-60, -20, 0)
	root.add_child(scene)
	terrain.region_size = 64
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	await frame_image()
	for normal in [false, true]:
		var a = array_layer(normal, 0)
		var b = array_layer(normal, 1)
		require(a.get_format() == b.get_format() and a.get_size() == b.get_size(), "user texture layers differ")
	print("PASS RGB/RGBA textures uploaded as matching two-layer GPU arrays")
	var first = terrain.assets.get_texture_asset(0)
	var second = terrain.assets.get_texture_asset(1)
	require(first.albedo_texture.get_image().get_format() == Image.FORMAT_RGBA8, "first source changed")
	require(second.albedo_texture.get_image().get_format() == Image.FORMAT_RGB8, "second source changed")
	first.albedo_texture = texture(32, Image.FORMAT_RGBA8, Color(1, 0, 0, 0.5), true)
	first.normal_texture = texture(32, Image.FORMAT_RGBA8, Color(0.5, 0.5, 1, 1), true)
	second.albedo_texture = texture(16, Image.FORMAT_RGB8, Color(0, 1, 0), false)
	second.normal_texture = texture(16, Image.FORMAT_RGB8, Color(0.5, 0.5, 1), false)
	for normal in [false, true]:
		var layer = array_layer(normal, 1)
		require(layer.get_size() == Vector2i(32, 32) and layer.has_mipmaps(), "size/mipmap normalization failed")
	require(second.albedo_texture.get_width() == 16 and not second.albedo_texture.get_image().has_mipmaps(), "original texture mutated")
	print("PASS mixed sizes/formats/mipmaps normalized without modifying source assets")
	var empty = Terrain3DTextureAsset.new()
	terrain.assets.set_texture_asset(2, empty)
	array_layer(false, 2)
	array_layer(true, 2)
	require(empty.albedo_texture == null and empty.normal_texture == null, "placeholder was saved into source asset")
	empty.albedo_texture = texture(16, Image.FORMAT_RGB8, Color.BLUE, false)
	require(array_layer(false, 2).get_pixel(0,0).b > 0.9, "third layer could not be populated")
	print("PASS empty layer insertion and later texture assignment")
	var before = await frame_image()
	before.save_png(output_dir.path_join("before-paint.png"))
	var brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({"brush": [brush, ImageTexture.create_from_image(brush)], "size": 20.0, "strength": 100.0, "mouse_pressure": 1.0, "asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 0, "pair_mode": 0, "pair_weight_level": 8})
	var original_surface = terrain.data.get_surface_maps()[0].get_data()
	painter.start_operation(Vector3(32, 0, 32))
	painter.operate(Vector3(32, 0, 32), 0.0)
	painter.stop_operation()
	var cpu = terrain.data.get_surface_maps()[0]
	var packed = roundi(cpu.get_pixel(32, 32).r * 65535.0)
	require((packed >> 11) == 1, "brush did not write layer 1")
	var after = await frame_image()
	var gpu = RenderingServer.texture_2d_layer_get(terrain.data.get_surface_maps_rid(), 0)
	require(roundi(gpu.get_pixel(32, 32).r * 65535.0) == packed, "paint not uploaded to GPU")
	after.save_png(output_dir.path_join("after-paint.png"))
	var center = Vector2i(after.get_width()/2, after.get_height()/2)
	print("CENTER before=", before.get_pixelv(center), " after=", after.get_pixelv(center))
	require(before.get_pixelv(center).r > before.get_pixelv(center).g, "first layer was not rendered red")
	require(after.get_pixelv(center).g > after.get_pixelv(center).r, "painted second layer was not rendered green")
	print("PASS brush CPU write, GPU upload, and rendered second material")
	undo_action.call()
	require(terrain.data.get_surface_maps()[0].get_data() == original_surface, "undo did not restore all painted texels")
	redo_action.call()
	require(roundi(terrain.data.get_surface_maps()[0].get_pixel(32,32).r*65535.0) == packed, "redo failed")
	print("PASS texture brush undo/redo")
	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	quit()
