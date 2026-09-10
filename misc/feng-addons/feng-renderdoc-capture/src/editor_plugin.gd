@tool
extends EditorPlugin

const SETTING_EXE := "renderdoc/capture/executable_path"

var button: Button
var _busy := false
var _capture_forced_viewports: Array = []


func _enter_tree() -> void:
	_setup_settings()
	EditorInterface.get_editor_settings().settings_changed.connect(_settings_changed)
	button = Button.new()
	button.icon = EditorInterface.get_base_control().get_theme_icon("Camera3D", "EditorIcons")
	button.flat = true
	button.tooltip_text = "Capture an actual frame rendered by this editor and open it in RenderDoc."
	button.pressed.connect(_on_capture_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
	button.get_parent().move_child(button, 0)


func _exit_tree() -> void:
	# A plugin can be disabled or hot-reloaded while the capture wait is still
	# suspended. Restore the editor's original update modes before the nodes are
	# detached so an interrupted capture cannot leave a viewport running forever.
	_restore_capture_viewports(_capture_forced_viewports)
	EditorInterface.get_editor_settings().settings_changed.disconnect(_settings_changed)
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
		"hint_string": "*.exe",
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
		_warning("Set RenderDoc > Capture > Executable Path to qrenderdoc.exe in Editor Settings.")
		return
	if not FengRenderDoc.is_hooked():
		_warning("This editor's rendering device is not connected to RenderDoc. Capturing an existing device requires RenderDoc to be initialized when the editor starts.")
		return
	_busy = true
	button.disabled = true
	var previous_count := FengRenderDoc.get_capture_count()
	# The editor deliberately stops rendering unchanged viewports while it is
	# idle.  A static scene can therefore miss the one Present that RenderDoc
	# waits for, or leave the scene SubViewport stale while the editor chrome is
	# redrawn.  Keep the visible 3D editor viewports alive for this one capture.
	var forced_viewports: Array = _prepare_capture_viewports()
	_capture_forced_viewports = forced_viewports
	EditorInterface.get_base_control().queue_redraw()
	if not FengRenderDoc.trigger_capture(button.get_window().get_window_id()):
		_restore_capture_viewports(forced_viewports)
		_busy = false
		button.disabled = false
		_warning("Could not trigger a capture in the current editor.")
		return
	# TriggerCapture queues the next presented frame of this process. Wait for
	# the completed file before launching the analyzer, not a second engine.
	EditorInterface.get_base_control().queue_redraw()
	var deadline := Time.get_ticks_msec() + 30000
	while is_inside_tree() and FengRenderDoc.get_capture_count() <= previous_count and Time.get_ticks_msec() < deadline:
		# Keep a static editor scene producing Presents while RenderDoc waits for
		# the capture boundary.  This also covers viewports that were already in
		# UPDATE_ALWAYS but would otherwise go idle after one redraw.
		EditorInterface.get_base_control().queue_redraw()
		await get_tree().create_timer(0.1).timeout
	if not is_inside_tree():
		_restore_capture_viewports(forced_viewports)
		return
	var capture_count := FengRenderDoc.get_capture_count()
	_restore_capture_viewports(forced_viewports)
	_busy = false
	button.disabled = false
	if capture_count <= previous_count:
		_warning("RenderDoc did not capture a presented editor frame within 30 seconds.")
		return
	var capture := FengRenderDoc.get_capture_path(previous_count)
	if capture.is_empty() or not FileAccess.file_exists(capture):
		_warning("RenderDoc did not produce a capture file.")
		return
	if OS.create_process(gui, PackedStringArray([capture])) <= 0:
		_warning("Could not launch RenderDoc. Capture saved to " + capture)
		return
	_status("Current editor frame opened in RenderDoc.")


func _status(message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(message)


func _warning(message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(message, EditorToaster.SEVERITY_WARNING)


func _prepare_capture_viewports() -> Array:
	var forced: Array = []
	for index in range(4):
		var viewport = EditorInterface.get_editor_viewport_3d(index)
		if viewport == null or not is_instance_valid(viewport):
			continue
		# SubViewport is a Node rather than a CanvasItem, so visibility must be
		# checked on its container when that container exposes CanvasItem's API.
		var container = viewport.get_parent()
		if container is CanvasItem and not container.is_visible_in_tree():
			continue
		var mode = viewport.get_update_mode()
		if mode == SubViewport.UPDATE_ALWAYS:
			continue
		forced.append({"viewport": viewport, "mode": mode})
		viewport.set_update_mode(SubViewport.UPDATE_ALWAYS)
	return forced


func _restore_capture_viewports(forced: Array) -> void:
	for entry in forced:
		var viewport = entry.get("viewport")
		if viewport != null and is_instance_valid(viewport):
			viewport.set_update_mode(entry.get("mode", SubViewport.UPDATE_WHEN_VISIBLE))
	# Clearing the member makes restoration idempotent and releases stale node
	# references after a completed or interrupted capture.
	_capture_forced_viewports.clear()
