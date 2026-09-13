@tool
extends EditorPlugin
var vt_baker: RefCounted
var vt_ids: Image
var vt_height: Image
var capture_terrain: Node
var capture_production: Dictionary

func _render_vt_test_pages():
	vt_baker.queue_page(0, vt_ids, vt_height, Rect2(0, 0, 64, 64), 1.0)
	var cached := Image.create(36, 36, false, Image.FORMAT_RGBAH)
	cached.fill(Color(0.25, 0.5, 0.75, 1))
	vt_baker.queue_cached_page(1, {"albedo_height": cached, "normal_roughness": cached, "params": cached})
	vt_baker.render_pending(vt_baker)

func _enter_tree():
	_run.call_deferred()
func _run():
	await get_tree().create_timer(2).timeout
	EditorInterface.open_scene_from_path("res://scene.tscn")
	await get_tree().create_timer(2).timeout
	assert(FengRenderDoc.is_hooked())
	var settings = EditorInterface.get_editor_settings()
	assert(settings.has_setting("renderdoc/capture/executable_path"))
	var found = false
	for prop in settings.get_property_list():
		if prop.name == "renderdoc/capture/executable_path":
			assert(prop.hint == PROPERTY_HINT_GLOBAL_FILE)
			found = true
	assert(found)
	var viewport_3d := EditorInterface.get_editor_viewport_3d(0)
	var camera = viewport_3d.get_camera_3d()
	camera.position = Vector3(3,3,3)
	camera.look_at(Vector3.ZERO)
	var scene_root := EditorInterface.get_edited_scene_root()
	assert(scene_root != null)
	var world_environment := scene_root.find_child("Environment", true, false) as WorldEnvironment
	assert(world_environment != null)
	var compositor := world_environment.compositor as FengCompositor
	assert(compositor != null)
	var renderer := compositor.renderer as FengRenderer
	assert(renderer != null)
	# Exercise the authored native/custom list that the RenderDoc validator
	# expects. Sky is moved to list slot 04 (after VT and Deferred Lighting's required
	# prerequisites), and Tint gets a UTF-8 resource name used for its GPU label.
	var authored: Array[FengPass] = []
	var sky: FengBuiltinPass = null
	var vt: FengBuiltinPass = null
	var tint: FengPass = null
	for value in renderer.passes:
		assert(value is FengPass)
		var pass_entry := value as FengPass
		authored.append(pass_entry)
		if pass_entry is FengBuiltinPass and (pass_entry as FengBuiltinPass).native_id == 7:
			sky = pass_entry as FengBuiltinPass
		if pass_entry is FengBuiltinPass and (pass_entry as FengBuiltinPass).native_id == 16:
			vt = pass_entry as FengBuiltinPass
		if String(pass_entry.stable_id) == "library:tint":
			tint = pass_entry
	assert(sky != null)
	assert(vt != null)
	assert(tint != null)
	authored.erase(sky)
	authored.insert(4, sky)
	# There are no registered VT producers in this fixture. Keep this enabled
	# and rename it so the capture proves an idle configured pass still emits its
	# authored label without submitting page work.
	vt.resource_name = "VT Idle Marker"
	tint.resource_name = "RenderDoc Tint 中文"
	renderer.passes = authored
	renderer.apply(compositor)
	await get_tree().process_frame
	assert(renderer.passes.find(sky) == 4)
	assert(renderer.passes.find(vt) == 0)
	assert(vt.resource_name == "VT Idle Marker")
	assert(tint.resource_name == "RenderDoc Tint 中文")
	var pending: Array[Node] = [get_tree().root]
	var plugin: Node
	while not pending.is_empty():
		var node = pending.pop_back()
		pending.append_array(node.get_children())
		if node.get_script() and node.get_script().resource_path.ends_with("feng-renderdoc-capture/src/editor_plugin.gd"):
			plugin = node
			break
	assert(plugin != null)
	print("UI_TEST_BEFORE pid=", OS.get_process_id(), " gui=", settings.get_setting("renderdoc/capture/executable_path"))
	# This label exists only in the live editor UI, never in the saved scene.
	# Seeing it in the capture proves we captured this editor's frame.
	var marker = Label.new()
	marker.text = "LIVE EDITOR FRAME " + str(OS.get_process_id())
	marker.add_theme_font_size_override("font_size", 32)
	marker.position = Vector2(40, 80)
	EditorInterface.get_base_control().add_child(marker)
	marker.z_index = 4096
	await get_tree().create_timer(0.3).timeout
	var capture_count = FengRenderDoc.get_capture_count()
	if OS.get_environment("FENG_TEST_VT_WORK") == "1":
		vt_baker = ClassDB.instantiate("Terrain3DSurfaceBaker")
		vt_baker.configure(32, 2, 8)
		vt_baker.set_materials(RID(), RID(), PackedColorArray([Color.WHITE]),
			PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(),
			PackedFloat32Array(), PackedFloat32Array(), PackedVector2Array(), PackedVector3Array())
		vt_ids = Image.create(36, 36, false, 39)
		vt_ids.fill(Color(0, 0, 0, 1))
		vt_height = Image.create(36, 36, false, Image.FORMAT_RF)
		vt_height.fill(Color(0, 0, 0, 1))
		RenderingServer.virtual_texture_set_update_callback(get_instance_id(), _render_vt_test_pages)
		# Capture ongoing updates after resource/pipeline creation, as in an
		# already-open terrain scene. Keep the fixture viewport rendering here.
		var warmup_mode := viewport_3d.get_update_mode()
		viewport_3d.set_update_mode(SubViewport.UPDATE_ALWAYS)
		await get_tree().create_timer(1.0).timeout
		viewport_3d.set_update_mode(warmup_mode)
	if OS.get_environment("FENG_TEST_VT_TERRAIN") == "1":
		var terrain: Node
		if not OS.get_environment("FENG_TEST_TERRAIN_PROJECT").is_empty():
			var authored_terrain: Node = load("res://render/test.tscn").instantiate()
			terrain = authored_terrain.get_node("Terrain3D")
			terrain.surface_svt_auto_bake = false
			scene_root.add_child(authored_terrain)
		else:
			terrain = ClassDB.instantiate("Terrain3D")
			scene_root.add_child(terrain)
			terrain.data.add_region_blank(Vector2i.ZERO)
		terrain.vt_editor_preview = false
		terrain.surface_svt_auto_bake = false
		terrain.vt_page_count = 256
		terrain.material.world_background = 0
		terrain.surface_vt_enabled = true
		terrain.set_camera(camera)
		camera.position = Vector3(256, 20, 256) if OS.get_environment("FENG_TEST_TERRAIN_PROJECT").is_empty() else Vector3(-849, 80, 64)
		camera.rotation_degrees = Vector3(-35, 0, 0)
		var mode := viewport_3d.get_update_mode()
		viewport_3d.set_update_mode(SubViewport.UPDATE_ALWAYS)
		for frame in 100:
			terrain.update_surface_vt(4)
			await get_tree().process_frame
		viewport_3d.set_update_mode(mode)
		terrain.set_physics_process(false)
		for frame in 8: await get_tree().process_frame
		capture_terrain = terrain
		capture_production = terrain.get_vt_settings().producer.duplicate()
		assert(terrain.get_vt_pages().size() > 0)
		print("UI_TEST_TERRAIN ready pages=", terrain.get_vt_pages().size())
	var original_update_mode := viewport_3d.get_update_mode()
	var capture_start := Time.get_ticks_msec()
	plugin.button.pressed.emit()
	print("UI_TEST_CAPTURE duration_ms=", Time.get_ticks_msec() - capture_start)
	await get_tree().create_timer(0.5).timeout
	while plugin._busy:
		await get_tree().create_timer(0.2).timeout
	assert(viewport_3d.get_update_mode() == original_update_mode, "Capture must restore the editor viewport update mode")
	if capture_terrain:
		var after: Dictionary = capture_terrain.get_vt_settings().producer
		assert(after.baked_pages == capture_production.baked_pages, "Capture must not rebake all resident AVT pages")
		assert(after.cached_uploads == capture_production.cached_uploads, "Capture must not reupload all resident SVT pages")
		print("UI_TEST_TERRAIN capture preserved resident production counters")
	if vt_baker:
		RenderingServer.virtual_texture_remove_update_callback(get_instance_id())
	assert(FengRenderDoc.is_hooked())
	assert(FengRenderDoc.get_capture_count() == capture_count + 1)
	assert(FengRenderDoc.get_overlay_bits() == 0)
	var result = ConfigFile.new()
	result.set_value("capture", "path", FengRenderDoc.get_capture_path(capture_count))
	result.set_value("capture", "pid", OS.get_process_id())
	result.set_value("capture", "overlay", FengRenderDoc.get_overlay_bits())
	result.set_value("pipeline", "sky_index", renderer.passes.find(sky))
	result.set_value("pipeline", "tint_name", tint.resource_name)
	result.set_value("pipeline", "viewport_update_mode", viewport_3d.get_update_mode())
	result.save("res://capture_result.cfg")
	print("UI_TEST_AFTER actual editor captured, main PID=", OS.get_process_id())
	var close_deadline := Time.get_ticks_msec() + 60000
	while not FileAccess.file_exists("res://capture_analyzer_closed") and Time.get_ticks_msec() < close_deadline:
		await get_tree().create_timer(0.2).timeout
	assert(FileAccess.file_exists("res://capture_analyzer_closed"), "Analyzer lifecycle check timed out")
	await get_tree().create_timer(1).timeout
	assert(FengRenderDoc.get_capture_count() == capture_count + 1, "No captures should continue after the click")
	get_tree().quit()
