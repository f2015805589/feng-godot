# RenderDoc Capture - Editor plugin
# Adds a camera button to the top 3D viewport menu bar (left of the Terrain3D
# menu) that captures a frame with RenderDoc.
#
# Mounting renderdoc.dll is done by the engine module `feng_renderdoc` at
# startup (before the graphics API is initialized). Enable it in
#   Editor Settings > RenderDoc Capture > Enable RenderDoc Mounting
# then restart the editor. After that the camera button captures instantly
# without any restart, like Unity's RenderDoc integration.
@tool
extends EditorPlugin

const SETTING_ENABLE := "renderdoc/capture/enable_mount"

var button: Button


func _enter_tree() -> void:
	_setup_settings()
	button = Button.new()
	button.icon = get_editor_interface().get_base_control().get_theme_icon("Camera3D", "EditorIcons")
	button.flat = true
	button.tooltip_text = _button_tooltip()
	button.pressed.connect(_on_capture_pressed)
	# Top menu bar of the 3D viewport, left of the Terrain3D menu button.
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
	button.get_parent().move_child(button, 0)
	_refresh_button()


func _exit_tree() -> void:
	if button:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
		button.queue_free()
		button = null


func _setup_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTING_ENABLE):
		es.set_setting(SETTING_ENABLE, false)
	es.add_property_info({
		"name": SETTING_ENABLE,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
	})
	# Mark as a basic setting so it shows in the Editor Settings list without
	# searching (the dialog's default view only lists basic settings).
	es.set_basic(SETTING_ENABLE, true)
	# Bridge the editor setting into project settings, which the engine
	# module reads at startup (SERVERS level, before the graphics API).
	_sync_to_project()
	es.settings_changed.connect(_sync_to_project)


func _sync_to_project() -> void:
	var es := EditorInterface.get_editor_settings()
	ProjectSettings.set_setting("rendering/renderdoc/enable", bool(es.get_setting(SETTING_ENABLE)))
	ProjectSettings.save()


func _refresh_button() -> void:
	if not button:
		return
	button.tooltip_text = _button_tooltip()


func _button_tooltip() -> String:
	if _is_hooked():
		return "Capture a frame with RenderDoc"
	return "RenderDoc is not mounted.\nEnable it in Editor Settings > RenderDoc Capture and restart the editor."


func _is_hooked() -> bool:
	return FengRenderDoc.is_hooked()


func _on_capture_pressed() -> void:
	if not _is_hooked():
		_push_warning("RenderDoc is not mounted. Enable RenderDoc Capture in Editor Settings and restart the editor.")
		return
	if FengRenderDoc.trigger_capture():
		_push_status("RenderDoc: frame captured. Open the RenderDoc UI to inspect it.")
		_try_open_renderdoc_ui()
	else:
		_push_warning("RenderDoc trigger failed")


func _try_open_renderdoc_ui() -> void:
	var gui := FengRenderDoc.get_gui_path()
	if gui.is_empty():
		_push_status("Tip: open renderdoc.exe manually to inspect captures.")
		return
	OS.create_process(gui, PackedStringArray())


func _push_status(p_msg: String) -> void:
	EditorInterface.get_editor_toaster().popup_str(p_msg)


func _push_warning(p_msg: String) -> void:
	EditorInterface.get_editor_toaster().popup_str(p_msg, EditorInterface.get_editor_toaster().Severity.SEVERITY_WARNING)
