@tool
extends EditorPlugin
var terrain: Terrain3D
func _enter_tree() -> void:
	call_deferred("run")
func run() -> void:
	await get_tree().create_timer(4).timeout
	EditorInterface.open_scene_from_path("res://render/test.tscn")
	await get_tree().create_timer(2).timeout
	EditorInterface.set_main_screen_editor("3D")
	terrain = EditorInterface.get_edited_scene_root().get_node("Terrain3D")
	terrain.surface_svt_enabled = false
	terrain.vt_editor_preview = false
	terrain.surface_vt_enabled = true
	terrain.surface_vt_distance = 4096
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 16
	terrain.assets = Terrain3DAssets.new()
	var asset := Terrain3DTextureAsset.new()
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.1, 0.7, 0.1))
	asset.albedo_texture = ImageTexture.create_from_image(image)
	image = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.5, 0.5, 1))
	asset.normal_texture = ImageTexture.create_from_image(image)
	terrain.assets.set_texture_asset(0, asset)
	for z in range(-1, 1):
		for x in range(-1, 1): terrain.data.add_region_blank(Vector2i(x, z))
	terrain.data.update_maps()
	OS.low_processor_usage_mode = true
	# No camera changes, manual terrain ticks, force_draw, or frame_post_draw waits.
	await get_tree().create_timer(20).timeout
	for location in terrain.data.get_region_locations(): terrain.invalidate_surface_pages(location)
	await get_tree().create_timer(12).timeout
	var settings := terrain.get_vt_settings()
	print("EDITOR_VT_IDLE ", settings)
	var producer: Dictionary = settings.get("producer", {})
	var failed := int(producer.get("ready_pages", 0)) <= 16 or int(producer.get("pending", -1)) != 0
	var viewport := EditorInterface.get_editor_viewport_3d()
	var result := viewport.get_texture().get_image()
	result.save_png("res://idle_result.png")
	var missing := 0
	for y in result.get_height():
		for x in result.get_width():
			var c := result.get_pixel(x, y)
			if c.r > 0.1 and c.r > c.g * 1.5 and c.b > c.g * 1.5 and minf(c.r, c.b) > maxf(c.r, c.b) * 0.65: missing += 1
	print("EDITOR_VT_IDLE missing_pixels=", missing)
	failed = failed or missing != 0
	if not failed: print("PASS editor stationary VT completion")
	get_tree().quit(1 if failed else 0)
