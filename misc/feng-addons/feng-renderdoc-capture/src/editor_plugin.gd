@tool
extends EditorPlugin

const SETTING_EXE := "renderdoc/capture/executable_path"

var button: Button
var _busy := false
var _capture_generation := 0
var _capture_forced_viewports: Array[Dictionary] = []


func _enter_tree() -> void:
	_setup_settings()
	EditorInterface.get_editor_settings().settings_changed.connect(_settings_changed)
	button = Button.new()
	button.icon = EditorInterface.get_base_control().get_theme_icon("Camera3D", "EditorIcons")
	button.flat = true
	button.tooltip_text = "Capture this editor frame and its current VT cache, then open RenderDoc."
	button.pressed.connect(_on_capture_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
	button.get_parent().move_child(button, 0)


func _exit_tree() -> void:
	# Retire pending waits and restore viewport modes before detaching.
	_finish_capture()
	var settings := EditorInterface.get_editor_settings()
	if settings.settings_changed.is_connected(_settings_changed):
		settings.settings_changed.disconnect(_settings_changed)
	if is_instance_valid(button):
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
		button.queue_free()
	button = null


func _setup_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_EXE):
		settings.set_setting(SETTING_EXE, FengRenderDoc.get_gui_path())
	settings.add_property_info({
		"name": SETTING_EXE,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*" if OS.get_name() == "Linux" else "*.exe",
	})
	settings.set_basic(SETTING_EXE, true)
	_settings_changed()
	if settings.has_setting("renderdoc/capture/enable_mount"):
		settings.erase("renderdoc/capture/enable_mount")
	# Old versions persisted mounting in project.godot, even for normal games.
	if ProjectSettings.has_setting("rendering/renderdoc/enable"):
		ProjectSettings.set_setting("rendering/renderdoc/enable", null)
		ProjectSettings.save()


func _settings_changed() -> void:
	var path := str(EditorInterface.get_editor_settings().get_setting(SETTING_EXE))
	if FengRenderDoc.set_editor_gui_path(path) != OK:
		push_warning("Could not save RenderDoc startup path.")


func _on_capture_pressed() -> void:
	if _busy:
		return
	var gui := FengRenderDoc.get_gui_path(str(EditorInterface.get_editor_settings().get_setting(SETTING_EXE)))
	if gui.is_empty():
		var gui_name := "qrenderdoc" if OS.get_name() == "Linux" else "qrenderdoc.exe"
		_warning("Set RenderDoc > Capture > Executable Path to " + gui_name + " in Editor Settings.")
		return
	if not FengRenderDoc.is_hooked():
		# Attachment happens before graphics-device creation.
		var reason := str(FengRenderDoc.get_mount_status())
		if reason.is_empty():
			reason = "RenderDoc was not mounted when this editor started."
		_warning(reason + " Editing the path takes effect the next time the editor starts.")
		return
	_busy = true
	_capture_generation += 1
	var generation := _capture_generation
	button.disabled = true
	# Keep visible scene viewports current during the capture.
	_prepare_capture_viewports()
	EditorInterface.get_base_control().queue_redraw()
	# Draw the scene synchronously while honoring normal terrain streaming budgets.
	var capture := str(RenderDocCapture.capture_frame(button.get_window().get_window_id()))
	if not capture.is_empty() and FileAccess.file_exists(capture):
		_finish_capture()
		_open_capture(gui, capture)
		return
	# Keep the same viewport lease for the queued fallback until completion.
	var previous_count := FengRenderDoc.get_capture_count()
	if not FengRenderDoc.trigger_capture(button.get_window().get_window_id()):
		_finish_capture()
		_warning("Could not trigger a capture in the current editor.")
		return
	EditorInterface.get_base_control().queue_redraw()
	var deadline := Time.get_ticks_msec() + 10000
	while generation == _capture_generation and is_inside_tree() and FengRenderDoc.get_capture_count() <= previous_count and Time.get_ticks_msec() < deadline:
		EditorInterface.get_base_control().queue_redraw()
		await get_tree().create_timer(0.1).timeout
	# A disabled/reloaded plugin retires this wait; it must not finish a newer capture.
	if generation != _capture_generation:
		return
	if not is_inside_tree():
		_finish_capture()
		return
	var capture_count := FengRenderDoc.get_capture_count()
	_finish_capture()
	if capture_count <= previous_count:
		_warning("RenderDoc did not record a frame.")
		return
	var queued_capture := FengRenderDoc.get_capture_path(previous_count)
	if queued_capture.is_empty() or not FileAccess.file_exists(queued_capture):
		_warning("RenderDoc did not produce a capture file.")
		return
	_open_capture(gui, queued_capture)


func _open_capture(p_gui: String, p_capture: String) -> void:
	var view_script := ProjectSettings.globalize_path(get_script().resource_path.get_base_dir().path_join("renderdoc_view.py"))
	if OS.create_process(p_gui, PackedStringArray(["--ui-python", view_script, p_capture])) <= 0:
		_warning("Could not launch RenderDoc. Capture saved to " + p_capture)
		return
	_status("Rendered frame opened in RenderDoc.")


func _status(message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(message)


func _warning(message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(message, EditorToaster.SEVERITY_WARNING)


func _prepare_capture_viewports() -> void:
	_restore_capture_viewports()
	for index in range(4):
		var viewport = EditorInterface.get_editor_viewport_3d(index)
		if not is_instance_valid(viewport):
			continue
		# SubViewport visibility belongs to its CanvasItem container.
		var container = viewport.get_parent()
		if container is CanvasItem and not container.is_visible_in_tree():
			continue
		var mode = viewport.get_update_mode()
		if mode == SubViewport.UPDATE_ALWAYS:
			continue
		_capture_forced_viewports.append({"viewport": viewport, "mode": mode})
		viewport.set_update_mode(SubViewport.UPDATE_ALWAYS)


func _restore_capture_viewports() -> void:
	for entry in _capture_forced_viewports:
		var viewport = entry["viewport"]
		if is_instance_valid(viewport):
			viewport.set_update_mode(entry["mode"])
	# Release the snapshot after restoration.
	_capture_forced_viewports.clear()


func _finish_capture() -> void:
	_restore_capture_viewports()
	_capture_generation += 1
	_busy = false
	if is_instance_valid(button):
		button.disabled = false
