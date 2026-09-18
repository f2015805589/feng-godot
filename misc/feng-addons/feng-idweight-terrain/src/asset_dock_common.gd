# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D: the half both dock versions share.

# The dock ships as two scripts because the editor hosts it differently before and after Godot
# 4.6: asset_dock.gd puts itself in an EditorDock, asset_dock_45.gd creates its own slot and
# window. Everything above that boundary is the same dock - the same signals, the same controls,
# the same search, list switching, pin, highlight and window-focus handling - and it is here once.
#
# The two versions differ in three ways, and each overrides this file for all three:
#   * hosting - initialize(), remove_dock(), update_dock() and update_layout()
#   * which editor settings survive a session - load_editor_settings() and
#     save_editor_settings(), which is why that one is an empty override at the bottom of this
#     file rather than a shared body: 4.5 persists its slot, floating state and window geometry,
#     and 4.6 persists the tile size and the pin while erasing the 4.5 keys an older project left
#   * their own extras - 4.6 the Terrain management menu and the debug-view menu, 4.5 the slot,
#     floating and window controls
@tool
extends PanelContainer

signal confirmation_closed
signal confirmation_confirmed
signal confirmation_canceled

const ES_DOCK_TILE_SIZE: String = "terrain3d/dock/tile_size"
const ES_DOCK_PINNED: String = "terrain3d/dock/always_on_top"
const ES_DOCK_TAB: String = "terrain3d/dock/tab"

# The list and the tile live in their own scripts, shared with the other dock version. Both docks
# inherit them, so they stay addressable as a dock's ListContainer / ListEntry.
const ListContainer := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_container.gd")
const ListEntry := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_entry.gd")

# The two asset lists, and the one currently shown.
var texture_list: ListContainer
var mesh_list: ListContainer
var current_list: ListContainer
var _updating_list: bool

# The dock's own controls, wired by each version's initialize().
var pinned_btn: Button
var size_slider: HSlider
var box: BoxContainer
var buttons: BoxContainer
var textures_btn: Button
var meshes_btn: Button
var asset_container: ScrollContainer
var confirm_dialog: ConfirmationDialog
var _confirmed: bool = false
var search_box: TextEdit
var search_button: Button

# Set by the hosting plugin; `window` is the editor window a floating dock lives in.
var _initialized: bool = false
var plugin: EditorPlugin
var window: Window


## Dock button handlers

func _on_pin_changed(toggled: bool) -> void:
	if window:
		window.always_on_top = pinned_btn.button_pressed
	save_editor_settings()


func _on_slider_changed(value: float) -> void:
	# Set both lists so they match
	if texture_list:
		texture_list.set_entry_width(value)
	if mesh_list:
		mesh_list.set_entry_width(value)
	save_editor_settings()
	# Hack to trigger ScrollContainer::_reposition_children() to update size of scroll bar handle
	asset_container.layout_direction = Control.LAYOUT_DIRECTION_LTR
	asset_container.layout_direction = Control.LAYOUT_DIRECTION_INHERITED


func _on_textures_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_textures_pressed")
	if _updating_list or current_list == texture_list:
		return
	_updating_list = true
	current_list = texture_list
	texture_list.visible = true
	mesh_list.visible = false
	textures_btn.set_pressed_no_signal(true)
	meshes_btn.set_pressed_no_signal(false)
	texture_list.update_asset_list()
	if plugin.is_terrain_valid():
		EditorInterface.edit_node(plugin.terrain)
	save_editor_settings()
	_updating_list = false


func _on_meshes_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_meshes_pressed")
	if _updating_list or current_list == mesh_list:
		return
	_updating_list = true
	current_list = mesh_list
	mesh_list.visible = true
	texture_list.visible = false
	meshes_btn.set_pressed_no_signal(true)
	textures_btn.set_pressed_no_signal(false)
	mesh_list.update_asset_list()
	if plugin.is_terrain_valid():
		EditorInterface.edit_node(plugin.terrain)
	save_editor_settings()
	_updating_list = false


func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_tool_changed: ", p_tool, ", ", p_operation)
	remove_all_highlights()
	if p_tool == Terrain3DEditor.INSTANCER:
		_on_meshes_pressed()
	elif p_tool in [ Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS ]:
		_on_textures_pressed()


## Update dock contents

func update_assets() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: update_assets: ", plugin.terrain.assets if plugin.terrain else "")
	if not _initialized:
		return
	
	# Verify signals to individual lists
	if plugin.is_terrain_valid() and plugin.terrain.assets:
		if not plugin.terrain.assets.textures_changed.is_connected(texture_list.update_asset_list):
			plugin.terrain.assets.textures_changed.connect(texture_list.update_asset_list)
		if not plugin.terrain.assets.meshes_changed.is_connected(mesh_list.update_asset_list):
			plugin.terrain.assets.meshes_changed.connect(mesh_list.update_asset_list)

	current_list.update_asset_list()


func remove_all_highlights():
	if not plugin.terrain:
		return
	for i: int in texture_list.entries.size():
		var resource: Terrain3DTextureAsset = texture_list.entries[i].resource
		if resource and resource.is_highlighted():
			resource.set_highlighted(false)
	for i: int in mesh_list.entries.size():
		var resource: Terrain3DMeshAsset = mesh_list.entries[i].resource
		if resource and resource.is_highlighted():
			resource.set_highlighted(false)


## Search box and selection

func set_selected_by_asset_id(p_id: int) -> void:
	search_box.text = ""
	_on_search_text_changed()
	current_list.set_selected_id(p_id)


func _on_search_text_changed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_search_text_changed: ", search_box.text)
	search_box.text = search_box.text.strip_escapes()
	var len: int = search_box.text.length()
	if len > 0:
		search_box.set_caret_column(len)
		search_button.icon = get_theme_icon("Close", "EditorIcons")
	else:
		search_button.icon = get_theme_icon("Search", "EditorIcons")
		
	mesh_list.search_text = search_box.text
	texture_list.search_text = search_box.text
	current_list.update_asset_list()
	current_list.set_selected_id(0)


func _on_search_button_pressed() -> void:
	if plugin.debug:
		print("Terrain3DAssetDock: _on_search_button_pressed")
	if search_box.text.length() > 0:
		search_box.text = ""
		_on_search_text_changed()
	else:
		if plugin.debug:
			print("Terrain3DAssetDock: _on_search_button_pressed: Search box grabbing focus")
		search_box.grab_focus()


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if search_box.has_focus():
			if plugin.debug:
				print("Terrain3DAssetDock: _on_box_gui_input: search_box releasing focus")
			search_box.release_focus()


## Floating window focus

func _on_godot_window_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_window_entered")
	if is_instance_valid(window) and window.has_focus():
		plugin.godot_editor_window.grab_focus()


## Editor settings

# The two versions persist different keys; see the header.
func save_editor_settings() -> void:
	pass
