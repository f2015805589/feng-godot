@tool
extends EditorPlugin

## Graphical editor regression for the Terrain3D asset dock layout.
##
## The test plugin is copied into an isolated project by the test runner. It
## creates and selects a real Terrain3D node, then exercises the dock that the
## production terrain editor plugin instantiated. The project is launched
## with a real rendering driver; this is intentionally an editor test rather
## than a headless script check.

const MENU_TEXTURE_ARRAY: int = 1
const MENU_TERRAIN_MAPS: int = 2
const MENU_DEBUG_SHADED: int = 10
const MENU_DEBUG_HEIGHTMAP: int = 11
const MENU_DEBUG_CONTROL_IDS: int = 12
const MENU_DEBUG_CONTROL_WEIGHT: int = 13
const MENU_DEBUG_SLOPE: int = 14

var _finished: bool = false


func _enter_tree() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("EDITOR_DOCK_REGRESSION: " + message)
	get_tree().quit(1)


func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _wait_frames(count: int = 1) -> void:
	for _i in count:
		await get_tree().process_frame


func _wait_for_management_menu() -> MenuButton:
	var base := EditorInterface.get_base_control()
	for _i in 180:
		var candidate := base.find_child("ManagementMenu", true, false) as MenuButton
		if candidate:
			return candidate
		await get_tree().process_frame
	return null


func _dock_from_menu(menu: MenuButton) -> Control:
	var node: Node = menu
	while node:
		if node is PanelContainer and node.name == "Terrain3D":
			return node
		node = node.get_parent()
	return null


func _measure_layout(dock: Control, menu: MenuButton, width: float) -> Dictionary:
	# The editor's dock container owns the child size and would overwrite a test
	# width on the next sort. Temporarily put the real asset dock under the
	# editor base control so update_layout() sees the requested width verbatim.
	var old_parent: Node = dock.get_parent()
	var old_index: int = dock.get_index()
	var base: Control = EditorInterface.get_base_control()
	dock.reparent(base, false)
	dock.position = Vector2(-10000.0, -10000.0)
	dock.size = Vector2(width, 320.0)
	dock.call("update_layout")
	await _wait_frames(2)
	dock.size = Vector2(width, 320.0)
	dock.call("update_layout")
	await _wait_frames(2)
	var combined: Vector2 = dock.get_combined_minimum_size()
	var actual_size: Vector2 = dock.size
	var management_size: Vector2 = menu.size
	print("EDITOR_DOCK_MEASURE width=", width, " dock_size=", actual_size,
			" combined_min=", combined, " management_size=", management_size)
	dock.reparent(old_parent, false)
	old_parent.move_child(dock, old_index)
	await _wait_frames(1)
	return {"combined_min": combined, "dock_size": actual_size,
			"management_size": management_size}


func _assert_debug_state(terrain: Terrain3D, expected: int) -> bool:
	var view_index: int = expected - MENU_DEBUG_SHADED
	var heightmap := terrain.get_show_heightmap()
	var control_ids := terrain.get_show_control_texture()
	var control_weight := terrain.get_show_control_blend()
	var slope := terrain.get_show_slope()
	var expected_heightmap := view_index == 1
	var expected_control_ids := view_index == 2
	var expected_control_weight := view_index == 3
	var expected_slope := view_index == 4
	return _require(heightmap == expected_heightmap and
			control_ids == expected_control_ids and
			control_weight == expected_control_weight and
			slope == expected_slope,
			"debug menu id %d did not select the expected Terrain3D view" % expected)


func _run() -> void:
	# Let the production plugin finish its editor dock initialization and the
	# resource filesystem import before creating the test scene.
	await _wait_frames(40)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame

	var scene_root := Node3D.new()
	scene_root.name = "TerrainDockEditorTest"
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.id = id
		terrain.assets.set_texture_asset(id, asset)
	var mesh_asset := Terrain3DMeshAsset.new()
	terrain.assets.set_mesh_asset(0, mesh_asset)
	scene_root.add_child(terrain)
	terrain.owner = scene_root
	EditorInterface.add_root_node(scene_root)
	await _wait_frames(40)

	terrain.data.add_region_blank(Vector2i.ZERO)
	# Selection drives the real feng-idweight-terrain EditorPlugin _edit path,
	# which assigns the plugin terrain and updates its actual asset dock.
	EditorInterface.get_selection().add_node(terrain)
	await _wait_frames(40)
	var menu := await _wait_for_management_menu()
	if not _require(menu != null, "production asset dock ManagementMenu was not created"):
		return
	var dock := _dock_from_menu(menu)
	if not _require(dock != null, "could not find production Terrain3D asset dock"):
		return
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain,
			"selecting Terrain3D did not reach the production editor plugin"):
		return

	await _click(dock.meshes_btn)
	if not _require(dock.current_list == dock.mesh_list, "routed click on Meshes failed"):
		return
	await _click(dock.current_list.entries[0].button_enabled)
	if not _require(not mesh_asset.is_enabled(), "routed mesh visibility click did not disable asset"):
		return
	await _click(dock.textures_btn)
	if not _require(dock.current_list == dock.texture_list, "routed click on Textures failed"):
		return
	var asset: Terrain3DTextureAsset = terrain.assets.get_texture_asset(0)
	await _click(dock.current_list.entries[0].button_highlight)
	if not _require(asset.is_highlighted(), "routed Highlight click did not toggle asset"):
		return
	await _click(dock.current_list.entries[1].button_edit)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.assets.get_texture_asset(1), "routed Edit click did not inspect asset"):
		return
	await _click(dock.current_list.entries[1].button_clear)
	if not _require(dock.confirm_dialog.visible, "routed Clear click did not open confirmation"):
		return
	# The native confirmation window is off-screen in this fixture. Cancel
	# it explicitly after verifying the routed Clear click opened it.
	dock.confirm_dialog.canceled.emit()
	dock.confirm_dialog.hide()
	await _wait_frames(4)
	if not _require(not dock.confirm_dialog.visible and terrain.assets.get_texture_count() == 2, "cancel did not preserve texture assets"):
		return
	await _click(menu)
	if not _require(menu.get_popup().visible, "routed click on Terrain menu failed"):
		return
	menu.get_popup().hide()
	await _wait_frames(3)
	var wide_measure: Dictionary = await _measure_layout(dock, menu, 900.0)
	var wide_min: Vector2 = wide_measure["combined_min"]
	var wide_menu_size: Vector2 = wide_measure["management_size"]
	var narrow_measure: Dictionary = await _measure_layout(dock, menu, 500.0)
	var narrow_min: Vector2 = narrow_measure["combined_min"]
	var narrow_menu_size: Vector2 = narrow_measure["management_size"]
	if not _require(is_equal_approx(wide_measure["dock_size"].x, 900.0) and
			is_equal_approx(narrow_measure["dock_size"].x, 500.0),
			"editor dock container overwrote requested measurement widths: wide=%s narrow=%s" %
			[wide_measure["dock_size"], narrow_measure["dock_size"]]):
		return
	var editor_scale: float = EditorInterface.get_editor_scale()
	var row_limit: float = 48.0 * maxf(1.0, editor_scale)
	if not _require(wide_menu_size.y > 0.0 and wide_menu_size.y <= row_limit,
			"wide management menu is taller than one editor row: %s" % wide_menu_size):
		return
	if not _require(narrow_menu_size.y > 0.0 and narrow_menu_size.y <= row_limit,
			"narrow management menu is taller than one editor row: %s" % narrow_menu_size):
		return
	if not _require(wide_min.y < 220.0 * maxf(1.0, editor_scale) and
			narrow_min.y < 220.0 * maxf(1.0, editor_scale),
			"asset dock minimum height remains too large: wide=%s narrow=%s" % [wide_min, narrow_min]):
		return

	var management_popup := menu.get_popup()
	management_popup.id_pressed.emit(MENU_TEXTURE_ARRAY)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.assets,
			"Texture Array menu action did not inspect terrain.assets"):
		return
	management_popup.id_pressed.emit(MENU_TERRAIN_MAPS)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.data,
			"Terrain Maps menu action did not inspect terrain.data"):
		return

	var debug_menu := management_popup.find_child("DebugViews", true, false) as PopupMenu
	if not _require(debug_menu != null, "Debug Views submenu was not created"):
		return
	for debug_id in [MENU_DEBUG_SHADED, MENU_DEBUG_HEIGHTMAP, MENU_DEBUG_CONTROL_IDS,
			MENU_DEBUG_CONTROL_WEIGHT, MENU_DEBUG_SLOPE]:
		debug_menu.id_pressed.emit(debug_id)
		await _wait_frames(2)
		if not _assert_debug_state(terrain, debug_id):
			return

	print("PASS graphical Terrain3D asset dock layout and management menu actions")
	_finished = true
	get_tree().quit(0)


func _click(control: Control) -> void:
	await _wait_frames(4)
	var point := control.get_global_rect().get_center()
	var viewport := control.get_viewport()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	viewport.push_input(motion, true)
	await _wait_frames(1)
	if not _require(viewport.gui_get_hovered_control() == control, "mouse event did not reach %s at %s; hovered=%s" % [control.get_path(), point, viewport.gui_get_hovered_control()]):
		return
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		viewport.push_input(event, true)
		await _wait_frames(1)
