# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock for Terrain3D: the Godot 4.6+ half.

# This half hosts itself in an EditorDock and adds the Terrain management menu and the debug-view
# menu. The dock itself - signals, controls, search, list switching, pin, highlight and
# window-focus handling - is asset_dock_common.gd, which this script extends; so is the pre-4.6
# variant.
@tool
extends "res://addons/feng-idweight-terrain/src/asset_dock_common.gd"


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


var management_menu: MenuButton
var debug_menu: PopupMenu

var vt_editor: Window

# The pre-4.6 dock class reported a layout change through an engine callback carrying 1 vertical,
# 2 horizontal, 4 window. Nothing here implements it: this dock calls update_layout() from `resized`
# and from NOTIFICATION_ENTER_TREE instead. The class it belonged to is named at each call site below.
var _dock: MarginContainer #DEPRECATED 4.5 - Use EdDock


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

	_bind_common_controls()
	# Scale left column width to editor scale
	var editor_scale: float = EditorInterface.get_editor_scale()
	search_box.custom_minimum_size = Vector2(100. * editor_scale, 30. * editor_scale)
	_create_asset_lists()
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
	_connect_common_signals()
	_connect_search_signals()
	_create_confirm_dialog()
	_apply_dock_styles()

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


	
	


## Manage Editor Settings


func load_editor_settings() -> void:
	# Remove old editor settings
	const ES_DOCK: String = "terrain3d/dock/"
	for setting in [ "slot", "floating", "window_position", "window_size" ]:
		plugin.erase_setting(ES_DOCK + setting)
	pinned_btn.button_pressed = plugin.get_setting(ES_DOCK_PINNED, true)
	size_slider.value = plugin.get_setting(ES_DOCK_TILE_SIZE, 90)
	_on_slider_changed(size_slider.value)


func save_editor_settings() -> void:
	if not _initialized:
		return
	plugin.set_setting(ES_DOCK_TILE_SIZE, size_slider.value)
	plugin.set_setting(ES_DOCK_PINNED, pinned_btn.button_pressed)
