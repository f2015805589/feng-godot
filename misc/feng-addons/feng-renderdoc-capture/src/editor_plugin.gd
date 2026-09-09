@tool
extends EditorPlugin

const SETTING_EXE := "renderdoc/capture/executable_path"

var button: Button
var _busy := false


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
	if not FengRenderDoc.trigger_capture(button.get_window().get_window_id()):
		_busy = false
		button.disabled = false
		_warning("Could not trigger a capture in the current editor.")
		return
	# TriggerCapture queues the next presented frame of this process. Wait for
	# the completed file before launching the analyzer, not a second engine.
	EditorInterface.get_base_control().queue_redraw()
	var deadline := Time.get_ticks_msec() + 30000
	while is_inside_tree() and FengRenderDoc.get_capture_count() <= previous_count and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout
	if not is_inside_tree():
		return
	_busy = false
	button.disabled = false
	if FengRenderDoc.get_capture_count() <= previous_count:
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
