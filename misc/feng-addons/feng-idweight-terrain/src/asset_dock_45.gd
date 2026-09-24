# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D: the pre-4.6 half.

# This half creates its own dock slot and window, because Godot 4.5 has no EditorDock to host it.
# The dock itself - signals, controls, search, list switching, pin, highlight and window-focus
# handling - is asset_dock_common.gd, which this script extends; so is the 4.6 variant.
@tool
extends "res://addons/feng-idweight-terrain/src/asset_dock_common.gd"


const ES_DOCK_SLOT: String = "terrain3d/dock/slot"
const ES_DOCK_FLOATING: String = "terrain3d/dock/floating"
const ES_DOCK_WINDOW_POSITION: String = "terrain3d/dock/window_position"
const ES_DOCK_WINDOW_SIZE: String = "terrain3d/dock/window_size"


var placement_opt: OptionButton
var floating_btn: Button

# Used only for editor, so change to single visible/hiddden
enum {
	HIDDEN = -1,
	SIDEBAR = 0,
	BOTTOM = 1,
	WINDOWED = 2,
}
var state: int = HIDDEN

enum {
	POS_LEFT_UL = 0,
	POS_LEFT_BL = 1,
	POS_LEFT_UR = 2,
	POS_LEFT_BR = 3,
	POS_RIGHT_UL = 4,
	POS_RIGHT_BL = 5,
	POS_RIGHT_UR = 6,
	POS_RIGHT_BR = 7,
	POS_BOTTOM = 8,
	POS_MAX = 9,
}
var slot: int = POS_RIGHT_BR
var _godot_last_state: Window.Mode = Window.MODE_FULLSCREEN


func initialize(p_plugin: EditorPlugin) -> void:
	if p_plugin:
		plugin = p_plugin
	
	_godot_last_state = plugin.godot_editor_window.mode
	placement_opt = $Box/Buttons/PlacementOpt
	floating_btn = $Box/Buttons/Floating
	floating_btn.owner = null # Godot complains about buttons that are reparented
	_bind_common_controls()
	_create_asset_lists()

	load_editor_settings()
	_connect_common_signals()
	placement_opt.item_selected.connect(set_slot)
	floating_btn.pressed.connect(make_dock_float)
	pinned_btn.visible = ( window != null )

	_initialized = true
	update_dock()
	update_layout()


func _ready() -> void:
	if not _initialized:
		return

	_apply_dock_styles()
	if EditorInterface.get_edited_scene_root() != self:
		floating_btn.icon = get_theme_icon("MakeFloating", "EditorIcons")
		floating_btn.text = ""

	_connect_search_signals()
	_create_confirm_dialog()


## Dock placement


func set_slot(p_slot: int) -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: set_slot: ", p_slot)
	p_slot = clamp(p_slot, 0, POS_MAX-1)
	
	if slot != p_slot:
		slot = p_slot
		placement_opt.selected = slot
		save_editor_settings()
		plugin.select_terrain()
		update_dock()


func remove_dock(p_force: bool = false) -> void:
	if state == SIDEBAR:
		plugin.remove_control_from_docks(self)
		state = HIDDEN

	elif state == BOTTOM:
		plugin.remove_control_from_bottom_panel(self)
		state = HIDDEN

	# If windowed and destination is not window or final exit, otherwise leave
	elif state == WINDOWED and p_force and window:
		var parent: Node = get_parent()
		if parent:
			parent.remove_child(self)
		plugin.godot_editor_window.mouse_entered.disconnect(_on_godot_window_entered)
		plugin.godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)
		plugin.godot_editor_window.focus_exited.disconnect(_on_godot_focus_exited)
		window.hide()
		window.queue_free()
		window = null
		floating_btn.button_pressed = false
		floating_btn.visible = true
		pinned_btn.visible = false
		placement_opt.visible = true
		state = HIDDEN
		update_dock() # return window to side/bottom


func update_dock() -> void:
	if not _initialized or window:
		return

	update_assets()

	# Move dock to new destination
	remove_dock()
	# Sidebar
	if slot < POS_BOTTOM:
		state = SIDEBAR
		plugin.add_control_to_dock(slot, self)
	# Bottom
	elif slot == POS_BOTTOM:
		state = BOTTOM
		plugin.add_control_to_bottom_panel(self, "Terrain3D")
		plugin.make_bottom_panel_item_visible(self)


func update_layout() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: update_layout")	
	if not _initialized:
		return

	# Detect if we have a new window from Make floating, grab it so we can free it properly
	if not window and get_parent() and get_parent().get_parent() is Window:
		window = get_parent().get_parent()
		make_dock_float()
		return # Will call this function again upon display

	# Vertical layout: buttons on top
	if size.x < 500 or ( not window and slot < POS_BOTTOM ):
		box.vertical = true
		buttons.vertical = false
		search_box.reparent(box)
		box.move_child(search_box, 1)
		size_slider.reparent(box)
		box.move_child(size_slider, 2)
		floating_btn.reparent(buttons)
		pinned_btn.reparent(buttons)
	else:
	# Wide layout: buttons on left
		box.vertical = false
		buttons.vertical = true
		search_box.reparent(buttons)
		buttons.move_child(search_box, 0)
		size_slider.reparent(buttons)
		buttons.move_child(size_slider, 4)
		floating_btn.reparent(box)
		pinned_btn.reparent(box)

	save_editor_settings()


	
	


## Window Management


func make_dock_float() -> void:
	# If not already created (eg from editor panel 'Make Floating' button)	
	if not window:
		remove_dock()
		create_window()

	state = WINDOWED
	visible = true # Asset dock contents are hidden when popping out of the bottom!
	pinned_btn.visible = true
	floating_btn.visible = false
	placement_opt.visible = false
	window.title = "Terrain3D Asset Dock"
	window.always_on_top = pinned_btn.button_pressed
	window.close_requested.connect(remove_dock.bind(true))
	window.window_input.connect(_on_window_input)
	window.focus_exited.connect(save_editor_settings)
	window.mouse_exited.connect(save_editor_settings)
	window.size_changed.connect(save_editor_settings)
	plugin.godot_editor_window.mouse_entered.connect(_on_godot_window_entered)
	plugin.godot_editor_window.focus_entered.connect(_on_godot_focus_entered)
	plugin.godot_editor_window.focus_exited.connect(_on_godot_focus_exited)
	plugin.godot_editor_window.grab_focus()
	update_assets()
	save_editor_settings()


func create_window() -> void:
	window = Window.new()
	window.wrap_controls = true
	var mc := MarginContainer.new()
	mc.set_anchors_preset(PRESET_FULL_RECT, false)
	mc.add_child(self, true)
	window.add_child(mc, true)
	window.set_transient(false)
	window.set_size(plugin.get_setting(ES_DOCK_WINDOW_SIZE, Vector2i(512, 512)))
	window.set_position(plugin.get_setting(ES_DOCK_WINDOW_POSITION, Vector2i(704, 284)))
	plugin.add_child(window, true)
	window.show()


func clamp_window_position() -> void:
	if window and window.visible:
		var bounds: Vector2i
		if EditorInterface.get_editor_settings().get_setting("interface/editor/single_window_mode"):
			bounds = EditorInterface.get_base_control().size
		else:
			bounds = DisplayServer.screen_get_position(window.current_screen)
			bounds += DisplayServer.screen_get_size(window.current_screen)
		var margin: int = 40
		window.position.x = clamp(window.position.x, -window.size.x + 2*margin, bounds.x - margin)
		window.position.y = clamp(window.position.y, 25, bounds.y - margin)


func _on_window_input(event: InputEvent) -> void:
	# Capture CTRL+S when doc focused to save scene
	if event is InputEventKey and event.keycode == KEY_S and event.pressed and event.is_command_or_control_pressed():
		save_editor_settings()
		EditorInterface.save_scene()


func _on_godot_focus_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_focus_entered")
	# If asset dock is windowed, and Godot was minimized, and now is not, restore asset dock window
	if is_instance_valid(window):
		if _godot_last_state == Window.MODE_MINIMIZED and plugin.godot_editor_window.mode != Window.MODE_MINIMIZED:
			window.show()
			_godot_last_state = plugin.godot_editor_window.mode
			plugin.godot_editor_window.grab_focus()


func _on_godot_focus_exited() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_focus_exited")
	if is_instance_valid(window) and plugin.godot_editor_window.mode == Window.MODE_MINIMIZED:
		window.hide()
		_godot_last_state = plugin.godot_editor_window.mode


## Manage Editor Settings


func load_editor_settings() -> void:
	floating_btn.button_pressed = plugin.get_setting(ES_DOCK_FLOATING, false)
	pinned_btn.button_pressed = plugin.get_setting(ES_DOCK_PINNED, true)
	size_slider.value = plugin.get_setting(ES_DOCK_TILE_SIZE, 90)
	_on_slider_changed(size_slider.value)
	set_slot(plugin.get_setting(ES_DOCK_SLOT, POS_BOTTOM))
	if floating_btn.button_pressed:
		make_dock_float()


func save_editor_settings() -> void:
	if not _initialized:
		return
	clamp_window_position()
	plugin.set_setting(ES_DOCK_SLOT, slot)
	plugin.set_setting(ES_DOCK_TILE_SIZE, size_slider.value)
	plugin.set_setting(ES_DOCK_FLOATING, floating_btn.button_pressed)
	plugin.set_setting(ES_DOCK_PINNED, pinned_btn.button_pressed)
	if window:
		plugin.set_setting(ES_DOCK_WINDOW_SIZE, window.size)
		plugin.set_setting(ES_DOCK_WINDOW_POSITION, window.position)
