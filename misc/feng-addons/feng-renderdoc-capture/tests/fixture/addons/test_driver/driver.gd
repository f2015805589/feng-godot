@tool
extends EditorPlugin
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
	var original_update_mode := viewport_3d.get_update_mode()
	plugin.button.pressed.emit()
	await get_tree().create_timer(0.5).timeout
	while plugin._busy:
		await get_tree().create_timer(0.2).timeout
	assert(viewport_3d.get_update_mode() == original_update_mode, "Capture must restore the editor viewport update mode")
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
	await get_tree().create_timer(15).timeout
	assert(FengRenderDoc.get_capture_count() == capture_count + 1, "No captures should continue after the click")
	get_tree().quit()
