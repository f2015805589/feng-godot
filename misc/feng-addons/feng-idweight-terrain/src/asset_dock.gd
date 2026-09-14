# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D
@tool
extends PanelContainer

signal confirmation_closed
signal confirmation_confirmed
signal confirmation_canceled

const ES_DOCK_TILE_SIZE: String = "terrain3d/dock/tile_size"
const ES_DOCK_PINNED: String = "terrain3d/dock/always_on_top"
const ES_DOCK_TAB: String = "terrain3d/dock/tab"
const VT_EDITOR_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_editor.gd")

const MENU_INITIALIZE: int = 3
const MENU_TEXTURE_ARRAY: int = 1
const MENU_TERRAIN_MAPS: int = 2
const MENU_VT_EDITOR: int = 4
const MENU_DEBUG_SHADED: int = 10
const MENU_DEBUG_HEIGHTMAP: int = 11
const MENU_DEBUG_CONTROL_IDS: int = 12
const MENU_DEBUG_CONTROL_WEIGHT: int = 13
const MENU_DEBUG_SLOPE: int = 14


# The list and the tile live in their own scripts, shared with the other dock
# version. They stay addressable as this script's ListContainer / ListEntry.
const ListContainer := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_container.gd")
const ListEntry := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_entry.gd")

var management_menu: MenuButton
var debug_menu: PopupMenu
var texture_list: ListContainer
var mesh_list: ListContainer
var current_list: ListContainer
var _updating_list: bool

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
var vt_editor: Window

#DEPRECATED 4.5
#class EdDock extends EditorDock:
	#func _update_layout(layout: int) -> void:
		#layout 1 vertical, 2 horizontal, 4 window
		#print("Terrain3DAssetDock: _update_layout called with: ", layout)

var _dock: MarginContainer #DEPRECATED 4.5 - Use EdDock
var _initialized: bool = false
var plugin: EditorPlugin
var window: Window


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		await get_tree().process_frame
		update_layout()
		
		
func initialize(p_plugin: EditorPlugin) -> void:
	if p_plugin:
		plugin = p_plugin

	_dock = ClassDB.instantiate("EditorDock") #DEPRECATED 4.5 - EdDock.new()
	_dock.title = "Terrain3D"
	_dock.dock_icon = preload("../icons/terrain3d.svg")
	_dock.default_slot = 8 #DEPRECATED 4.5 - EditorDock.DockSlot.DOCK_SLOT_BOTTOM
	_dock.closable = false
	_dock.available_layouts = 0x7 #DEPRECATED 4.5 - EditorDock.DOCK_LAYOUT_ALL
	_dock.add_child(self)
	plugin.add_dock(_dock)
	_dock.open()
	_dock.make_visible()

	pinned_btn = $Box/Buttons/Pinned
	size_slider = $Box/Buttons/SizeSlider
	size_slider.owner = null
	box = $Box
	buttons = $Box/Buttons
	textures_btn = $Box/Buttons/TexturesBtn
	meshes_btn = $Box/Buttons/MeshesBtn
	asset_container = $Box/ScrollContainer
	search_box = $Box/Buttons/SearchBox
	search_box.owner = null
	# Scale left column width to editor scale
	var editor_scale: float = EditorInterface.get_editor_scale()
	search_box.custom_minimum_size = Vector2(100. * editor_scale, 30. * editor_scale)
	search_button = $Box/Buttons/SearchBox/SearchButton
	
	texture_list = ListContainer.new()
	texture_list.name = "TextureList"
	texture_list.plugin = plugin
	texture_list.type = Terrain3DAssets.TYPE_TEXTURE
	asset_container.add_child(texture_list, true)
	mesh_list = ListContainer.new()
	mesh_list.name = "MeshList"
	mesh_list.plugin = plugin
	mesh_list.type = Terrain3DAssets.TYPE_MESH
	mesh_list.visible = false
	asset_container.add_child(mesh_list, true)
	current_list = texture_list
	# Keep the management controls in one menu item. A row of buttons inside the
	# narrow vertical Buttons column wraps and makes the bottom dock grow several
	# rows tall before the asset list gets any space.
	management_menu = MenuButton.new()
	management_menu.name = "ManagementMenu"
	management_menu.text = "Terrain"
	management_menu.tooltip_text = "Open terrain asset, map, and debug view controls."
	management_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(management_menu)
	var management_popup := management_menu.get_popup()
	management_popup.add_item("Initialize Terrain…", MENU_INITIALIZE)
	management_popup.add_item("Texture Array", MENU_TEXTURE_ARRAY)
	management_popup.add_item("Terrain Maps", MENU_TERRAIN_MAPS)
	management_popup.add_item("Surface VT Editor…", MENU_VT_EDITOR)
	management_popup.add_separator()
	debug_menu = PopupMenu.new()
	debug_menu.name = "DebugViews"
	debug_menu.add_radio_check_item("Shaded", MENU_DEBUG_SHADED)
	debug_menu.add_radio_check_item("Heightmap", MENU_DEBUG_HEIGHTMAP)
	debug_menu.add_radio_check_item("Material IDs", MENU_DEBUG_CONTROL_IDS)
	debug_menu.add_radio_check_item("Material Weight", MENU_DEBUG_CONTROL_WEIGHT)
	debug_menu.add_radio_check_item("Slope", MENU_DEBUG_SLOPE)
	debug_menu.set_item_checked(0, true)
	debug_menu.id_pressed.connect(_on_debug_view_selected)
	debug_menu.about_to_popup.connect(_sync_debug_view_menu)
	management_popup.add_submenu_node_item("Debug Views", debug_menu)
	management_popup.id_pressed.connect(_on_management_menu_selected)
	management_popup.about_to_popup.connect(func():
		var terrain = plugin.get_terrain()
		management_popup.set_item_disabled(management_popup.get_item_index(MENU_INITIALIZE),
			not terrain or terrain.data.get_region_count() > 0))

	# The role legend lives in the brush settings bar
	# (Terrain3DToolSettings "pair_roles" / "pair_click_hint") and on each tile's
	# hover label, not as a fourth managed child of Box. update_layout() below
	# reparents and reindexes Box children with hardcoded slots 1/2/3 for
	# SearchBox, SizeSlider and ManagementMenu, so an extra row here would fight
	# that layout in both the narrow and the wide dock arrangement.

	load_editor_settings()

	# Connect signals
	resized.connect(update_layout)
	textures_btn.pressed.connect(_on_textures_pressed)
	meshes_btn.pressed.connect(_on_meshes_pressed)
	pinned_btn.toggled.connect(_on_pin_changed)
	pinned_btn.owner = null
	size_slider.value_changed.connect(_on_slider_changed)
	plugin.ui.toolbar.tool_changed.connect(_on_tool_changed)

	meshes_btn.add_theme_font_size_override("font_size", int(16. * EditorInterface.get_editor_scale()))
	textures_btn.add_theme_font_size_override("font_size", int(16. * EditorInterface.get_editor_scale()))

	search_box.text_changed.connect(_on_search_text_changed)
	search_button.pressed.connect(_on_search_button_pressed)
	
	confirm_dialog = ConfirmationDialog.new()
	add_child(confirm_dialog, true)
	confirm_dialog.hide()
	confirm_dialog.confirmed.connect(func(): _confirmed = true; \
		confirmation_closed.emit(); \
		confirmation_confirmed.emit() )
	confirm_dialog.canceled.connect(func(): _confirmed = false; \
		confirmation_closed.emit(); \
		confirmation_canceled.emit() )

	# Setup styles
	set("theme_override_styles/panel", get_theme_stylebox("panel", "Panel"))
	# Avoid saving icon resources in tscn when editing w/ a tool script
	if EditorInterface.get_edited_scene_root() != self:
		pinned_btn.icon = get_theme_icon("Pin", "EditorIcons")
		pinned_btn.text = ""
		search_button.icon = get_theme_icon("Search", "EditorIcons")

	_initialized = true
	update_dock()
	update_layout()


func _on_management_menu_selected(p_id: int) -> void:
	var terrain = plugin.get_terrain()
	if not terrain:
		return
	match p_id:
		MENU_INITIALIZE:
			plugin.terrain_setup.request(terrain, true)
		MENU_TEXTURE_ARRAY:
			EditorInterface.edit_resource(terrain.assets)
		MENU_TERRAIN_MAPS:
			EditorInterface.inspect_object(terrain.data)
		MENU_VT_EDITOR:
			_open_vt_editor(terrain)


func _open_vt_editor(p_terrain: Object) -> void:
	if not p_terrain:
		return
	if not vt_editor or not is_instance_valid(vt_editor):
		vt_editor = VT_EDITOR_SCRIPT.new()
		vt_editor.initialize(plugin)
		plugin.add_child(vt_editor)
	vt_editor.open_for_terrain(p_terrain)


func _on_debug_view_selected(p_id: int) -> void:
	var terrain = plugin.get_terrain()
	if not terrain:
		return
	var view_index: int = p_id - MENU_DEBUG_SHADED
	if view_index < 0 or view_index > 4:
		return
	_set_debug_view_checked(view_index)
	terrain.set_show_heightmap(view_index == 1)
	terrain.set_show_control_texture(view_index == 2)
	terrain.set_show_control_blend(view_index == 3)
	terrain.set_show_slope(view_index == 4)


func _set_debug_view_checked(p_index: int) -> void:
	if not debug_menu:
		return
	for item_index in debug_menu.item_count:
		debug_menu.set_item_checked(item_index, item_index == p_index)


func _sync_debug_view_menu() -> void:
	var terrain = plugin.get_terrain()
	if not terrain:
		_set_debug_view_checked(0)
		return
	var view_index: int = 0
	if terrain.get_show_heightmap():
		view_index = 1
	elif terrain.get_show_control_texture():
		view_index = 2
	elif terrain.get_show_control_blend():
		view_index = 3
	elif terrain.get_show_slope():
		view_index = 4
	_set_debug_view_checked(view_index)


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if search_box.has_focus():
			if plugin.debug:
				print("Terrain3DAssetDock: _on_box_gui_input: search_box releasing focus")
			search_box.release_focus()


## Dock placement


func remove_dock(p_force: bool = false) -> void:
	if vt_editor and is_instance_valid(vt_editor):
		vt_editor.queue_free()
		vt_editor = null
	plugin.remove_dock(_dock)
	# plugin.remove_dock() only unregisters _dock; it was created here via
	# ClassDB.instantiate() and is owned by this script, not the scene tree.
	# Without an explicit free it leaks at editor shutdown along with its
	# dock_icon (terrain3d.svg) and the backing Texture + CanvasItem RIDs.
	# `self` is a child of _dock, so detach before freeing (editor_plugin.gd
	# still queue_free()s `self` afterward).
	if is_instance_valid(_dock):
		if get_parent() == _dock:
			_dock.remove_child(self)
		_dock.free()
		_dock = null


func update_dock() -> void:
	if not _initialized:
		return
	update_assets()
	_dock.make_visible()


func update_layout() -> void:
	if not _initialized:
		return
	if plugin.debug > 1:
		print("Terrain3DAssetDock: update_layout")	

	## Detect if we have a new window from `Make floating` and grab it
	if not window:
		if get_parent().get_parent().get_parent() is Window:
			window = get_parent().get_parent().get_parent()
			_on_pin_changed(pinned_btn.button_pressed)
			plugin.godot_editor_window.mouse_entered.connect(_on_godot_window_entered)
			return # Displaying will call this function again
		# Check if window was just freed. Freed objects have a different hash than null
		elif hash(window) != hash(null):
			window = null
			plugin.godot_editor_window.mouse_entered.disconnect(_on_godot_window_entered)
			return # Will call this function again upon display

	## Vertical layout: buttons on top
	if size.x < 700:
		box.vertical = true
		buttons.vertical = false
		management_menu.reparent(box)
		search_box.reparent(box)
		box.move_child(search_box, 1)
		size_slider.reparent(box)
		box.move_child(size_slider, 2)
		box.move_child(management_menu, 3)
		pinned_btn.reparent(buttons)
	else:
	# Wide layout: buttons on left
		box.vertical = false
		buttons.vertical = true
		management_menu.reparent(buttons)
		search_box.reparent(buttons)
		buttons.move_child(search_box, 0)
		size_slider.reparent(buttons)
		buttons.move_child(size_slider, 3)
		pinned_btn.reparent(box)

	pinned_btn.visible = is_instance_valid(window)
	save_editor_settings()


# When a floating asset dock has focus and the mouse returns, grab focus so cursor decal works
func _on_godot_window_entered() -> void:
	if plugin.debug > 1:
		print("Terrain3DAssetDock: _on_godot_window_entered")
	if is_instance_valid(window) and window.has_focus():
		plugin.godot_editor_window.grab_focus()


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


## Dock Button handlers


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


## Update Dock Contents


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


## Manage Editor Settings


func load_editor_settings() -> void:
	# Remove old editor settings
	const ES_DOCK: String = "terrain3d/dock/"
	for setting in [ "slot", "floating", "window_position", "window_size" ]:
		plugin.erase_setting(ES_DOCK + setting)
	pinned_btn.button_pressed = plugin.get_setting(ES_DOCK_PINNED, true)
	size_slider.value = plugin.get_setting(ES_DOCK_TILE_SIZE, 90)
	_on_slider_changed(size_slider.value)
	# TODO Don't save tab until thumbnail generation more reliable
	#if plugin.get_setting(ES_DOCK_TAB, 0) == 1:
	#	_on_meshes_pressed()


func save_editor_settings() -> void:
	if not _initialized:
		return
	plugin.set_setting(ES_DOCK_TILE_SIZE, size_slider.value)
	plugin.set_setting(ES_DOCK_PINNED, pinned_btn.button_pressed)
	# TODO Don't save tab until thumbnail generation more reliable
	# plugin.set_setting(ES_DOCK_TAB, 0 if current_list == texture_list else 1)
