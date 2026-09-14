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

func shader_has_parameter(name: String) -> bool:
	for parameter in RenderingServer.get_shader_parameter_list(terrain.material.get_shader_rid()):
		if String(parameter.get("name", "")) == name:
			return true
	return false

func texture(size: int, format: Image.Format, color: Color, mipmaps: bool) -> ImageTexture:
	var image = Image.create(size, size, false, format)
	image.fill(color)
	if mipmaps:
		image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func set_ramp(gradient: float) -> void:
	for z in 64:
		for x in 64:
			terrain.data.set_height(Vector3(x, 0, z), float(x - 32) * gradient)
	terrain.data.update_maps(Terrain3DRegion.TYPE_HEIGHT)
	# A raw data write bypasses the editor's edit path (add_edited_area() ->
	# invalidate_surface_pages()), so the cached material pages still hold the height-derived
	# slope term of the previous ramp and the MIX overlay never engages. The editor is the
	# documented owner of that invalidation, so a direct data write has to ask for it.
	terrain.invalidate_surface_pages(Vector2i.ZERO)

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
	require(not shader_has_parameter("heightmap_black_height"), "disabled debug view leaked heightmap uniforms into the base shader")
	terrain.set_show_heightmap(true)
	await frame_image()
	require(shader_has_parameter("heightmap_black_height"), "heightmap debug insert was not generated when enabled")
	terrain.set_show_heightmap(false)
	await frame_image()
	require(not shader_has_parameter("heightmap_black_height"), "heightmap debug insert remained after disabling")
	print("PASS debug shader inserts toggle with their view")
	for normal in [false, true]:
		var a = array_layer(normal, 0)
		var b = array_layer(normal, 1)
		require(a.get_format() == b.get_format() and a.get_size() == b.get_size(), "user texture layers differ")
	require(array_layer(false, 0).get_format() == Image.FORMAT_BPTC_RGBA, "BC7 was not applied")
	terrain.assets.texture_array_compression = Terrain3DAssets.ARRAY_UNCOMPRESSED
	terrain.assets.texture_array_size = 64
	terrain.assets.texture_array_mipmaps = false
	require(array_layer(false, 0).get_format() == Image.FORMAT_RGBA8, "uncompressed option failed")
	require(array_layer(false, 1).get_size() == Vector2i(64, 64) and not array_layer(false, 1).has_mipmaps(), "array settings ignored")
	terrain.assets.texture_array_size = 0
	terrain.assets.texture_array_mipmaps = true
	terrain.assets.texture_array_compression = Terrain3DAssets.ARRAY_BC7
	print("PASS array BC7/uncompressed, size and mipmap controls")
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
	var blue = array_layer(false, 2)
	if blue.is_compressed():
		blue.decompress()
	require(blue.get_pixel(0,0).b > 0.9, "third layer could not be populated")
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
	var picked = terrain.data.get_texture_id(Vector3(32, 0, 32))
	require(picked.x == 0 and picked.y == 1 and picked.z > 0.99, "eyedropper did not read painted ID map")
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
	# A shared authoring resource must create a separate array owner per terrain.
	var other = Terrain3D.new()
	other.free_editor_textures = false
	other.assets = terrain.assets
	other.set_camera(camera)
	scene.add_child(other)
	require(other.assets != terrain.assets, "two terrains share array ownership")
	other.assets.texture_array_size = 64
	require(terrain.assets.texture_array_size == 0, "second terrain changed first array settings")
	other.free()
	print("PASS per-terrain array ownership")
	var replacement = Terrain3DTextureAsset.new()
	replacement.id = 0
	replacement.albedo_texture = texture(32, Image.FORMAT_RGBA8, Color.RED, true)
	var authored: Array[Terrain3DTextureAsset] = [replacement, second, null]
	terrain.assets.texture_list = authored
	require(terrain.assets.get_texture_asset(0) == replacement, "inspector array replacement ignored")
	require(terrain.assets.get_texture_asset(2) != null, "empty inspector layer not initialized")
	first = replacement
	print("PASS inspector layer list replacement and empty slots")


	# MIX mode uses geometric slope: the same painted pair is red on flat
	# ground and green on a ramp, with neutral normal maps.
	first.slope_blend_sharpness = 100.0
	second.slope_based_damp = 0.0
	# The shader declares `uniform vec3 _texture_slope_params_array[32]` and the
	# R16 map can name any MaterialId in 0..31, so the CPU side must always fill
	# all 32 slots -- authored materials with their own values, the rest with
	# Slope default (blendSharpness 1000, both damps 0).
	var slope_params = terrain.assets.get_texture_slope_params()
	require(slope_params.size() == 32, "slope constant buffer must expose all 32 material slots")
	require(slope_params[0].x == 100.0, "slot 0 must carry the authored blend sharpness")
	require(slope_params[31] == Vector3(1000.0, 0.0, 0.0), "unused slots must carry the slope default")
	print("PASS 32-slot slope parameter constant buffer")
	painter.set_brush_data({"brush": [brush, ImageTexture.create_from_image(brush)], "size": 20.0, "strength": 100.0, "mouse_pressure": 1.0, "asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 0, "pair_mode": 3, "pair_weight_level": 4})
	painter.start_operation(Vector3(32, 0, 32))
	painter.operate(Vector3(32, 0, 32), 0.0)
	painter.stop_operation()
	var flat = await frame_image()
	# normal_depth must not manufacture a tilt on a neutral normal map. The old
	# decode scaled (nU, nH) and re-derived nV, so any depth != 1 tilted a FLAT
	# surface: at depth 0 it produced (0, 0, 1), which the additive projection
	# turned into nDotUp 0.707 and flipped the flat ground to a full overlay.
	# Scaling the two sampled tilts instead leaves (0, 1, 0) untouched.
	second.normal_depth = 0.0
	var flat_scaled = await frame_image()
	second.normal_depth = 1.0
	require(flat_scaled.get_pixelv(center).r > flat_scaled.get_pixelv(center).g, "normal_depth must not tilt a neutral normal map")
	print("SLOPE flat_scaled=", flat_scaled.get_pixelv(center))
	# Two ramps pin the slope math end to end, not just "something changed".
	# The 3 weight bits double as the slope-threshold index
	# ({0,.125,.25,.375,.5,.625,.75,.98}[level-1]), so level 4 puts the low
	# threshold at 0.375 and slope_blend_sharpness 100 (0.1) puts the high
	# threshold at 0.475.
	#   gradient 0.25 -> atan(0.25) = 0.2450 rad, tangent approx 0.2500 -> BELOW
	#                    0.375, so MIX must keep the background.
	#   gradient 1.00 -> atan(1) = 0.7854 rad, tangent approx 0.9786 -> far above
	#                    0.475, so MIX must saturate to a full overlay.
	# This only holds if the sampled normal is composed the way the evaluator does:
	# an additive `g + normalPS` (the previous code) biased both ramps toward
	# straight up and measured the 45-degree ramp at nDotUp 0.92 instead of 0.707.
	set_ramp(0.25)
	var shallow = await frame_image()
	set_ramp(1.0)
	var ramp = await frame_image()
	print("SLOPE flat=", flat.get_pixelv(center), " shallow=", shallow.get_pixelv(center), " ramp=", ramp.get_pixelv(center))
	require(flat.get_pixelv(center).r > flat.get_pixelv(center).g, "flat MIX slope should retain background")
	require(shallow.get_pixelv(center).r > shallow.get_pixelv(center).g, "sub-threshold ramp must stay below the slope threshold")
	require(ramp.get_pixelv(center).g > ramp.get_pixelv(center).r, "45-degree ramp MIX slope must engage the overlay")
	print("PASS actual rendered slope blend (threshold + tangent)")
	# The Weight level doubles as the slope-threshold index, so raising it also
	# raises the angle where Add/Sub/Mix start to act: level 4 thresholds at 0.375,
	# level 8 at 0.98 -- right at the 0.9786 tangent of this 45-degree ramp. On
	# ground flatter than the level's threshold angle nothing engages, so Add and
	# Sub render exactly like Set and Mix drops the overlay. That conflation of
	# the weight level with the slope threshold index is part of the packed
	# format, not a port slip: the vertical weight thresholds on the slope
	# threshold decoded from the same 3 bits the brush writes as the overlay
	# weight. This pins the threshold rise so the "Add/Sub/Mix look linear"
	# report is answered by evidence.
	painter.set_brush_data({"brush": [brush, ImageTexture.create_from_image(brush)], "size": 20.0, "strength": 100.0, "mouse_pressure": 1.0, "asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 0, "pair_mode": 3, "pair_weight_level": 8})
	painter.start_operation(Vector3(32, 0, 32))
	painter.operate(Vector3(32, 0, 32), 0.0)
	painter.stop_operation()
	var level8_ramp = await frame_image()
	print("SLOPE level8_ramp=", level8_ramp.get_pixelv(center))
	require(level8_ramp.get_pixelv(center).g < ramp.get_pixelv(center).g, "raising the Weight level must raise the slope threshold and cut the overlay contribution on the same ramp")
	print("PASS Weight level doubles as the slope threshold")
	for view in ["show_heightmap", "show_control_texture", "show_control_blend", "show_slope"]:
		terrain.set(view, true)
		await frame_image()
		terrain.set(view, false)
	print("PASS height/ID/weight/slope debug shaders")
	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	quit()
