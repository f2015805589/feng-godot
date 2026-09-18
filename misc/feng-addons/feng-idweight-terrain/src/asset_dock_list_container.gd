# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock list: the scrollable tile grid, its search filter, the selection
# model and the resource add/remove/edit actions. Shared by the Godot 4.6 dock
# (EditorDock) and the pre-4.6 dock, which differ only in how the dock itself is
# hosted. Tile metrics and the pair-role hover labels follow the editor scale.
@tool
class_name Terrain3DAssetDockContainer
extends Container

const ListEntry := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_entry.gd")


var plugin: EditorPlugin
var type := Terrain3DAssets.TYPE_TEXTURE
var entries: Array[ListEntry]
var selected_id: int = 0
var height: float = 0.
var width: float = 90.
var focus_style: StyleBox
var _clearing_resource: bool = false
var search_text: String = ""


func _ready() -> void:
	set_v_size_flags(SIZE_EXPAND_FILL)
	set_h_size_flags(SIZE_EXPAND_FILL)
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_shadow_color", Color.BLACK)
	add_theme_constant_override("shadow_offset_x", 1)
	add_theme_constant_override("shadow_offset_y", 1)


func clear() -> void:
	for e in entries:
		e.get_parent().remove_child(e)
		e.queue_free()
	entries.clear()


func update_asset_list() -> void:
	if plugin.debug:
		print("Terrain3DListContainer ", name, ": update_asset_list")
	clear()
	
	# Grab terrain
	var t: Terrain3D = plugin.get_terrain()
	if not (t and t.assets):
		return
	
	if type == Terrain3DAssets.TYPE_TEXTURE:
		var texture_count: int = t.assets.get_texture_count()
		for i in texture_count:
			var texture: Terrain3DTextureAsset = t.assets.get_texture_asset(i)
			add_item(texture)
		if texture_count < Terrain3DAssets.MAX_TEXTURES:
			add_item()
	else:
		if plugin.terrain:
			plugin.terrain.assets.create_mesh_thumbnails()
		var mesh_count: int = t.assets.get_mesh_count()
		for i in mesh_count:
			var mesh: Terrain3DMeshAsset = t.assets.get_mesh_asset(i)
			add_item(mesh)
		if mesh_count < Terrain3DAssets.MAX_MESHES:
			add_item()
	set_selected_id(selected_id)


func add_item(p_resource: Resource = null) -> void:
	var entry: ListEntry = ListEntry.new()
	entry.focus_style = focus_style
	entry.set_edited_resource(p_resource)
	if not entry.get_resource_name().containsn(search_text) and not search_text == "":
		entry.free()
		return

	var res_id: int = p_resource.id if p_resource else entries.size()
	entry.hovered.connect(_on_resource_hovered.bind(res_id))
	entry.clicked.connect(clicked_id.bind(entries.size()))
	entry.role_selected.connect(_on_role_selected)
	entry.inspected.connect(_on_resource_inspected)
	entry.changed.connect(_on_resource_changed.bind(res_id))
	entry.type = type
	add_child(entry, true)
	entries.push_back(entry)
	
	if p_resource:
		if not p_resource.id_changed.is_connected(set_selected_after_swap):
			p_resource.id_changed.connect(set_selected_after_swap)


func _on_role_selected(p_role: int, p_entry: ListEntry) -> void:
	# IdWeight pair painting. p_role 0 is the left mouse button and 1 is
	# the right one. The packed chain writes the left-clicked layer into the
	# Background pair field (the base layer) and the right-clicked layer into
	# the Overlay field (the layer the Weight slider fades in), so a left click
	# carries background_id and a right click overlay_id. The displayed naming
	# is the other way round on purpose, and this dock keeps that reversed
	# naming for its markers, so assert the fields, not the labels.
	# The clicked entry carries the role; the pair state lives in the UI.
	if not is_instance_valid(p_entry):
		return
	# Read the clicked asset before change_tool(): that call reaches the dock's
	# _on_textures_pressed() -> update_asset_list(), which frees every entry in
	# this list. Looking p_entry up afterwards returns -1, and the old code then
	# skipped set_selected_id() entirely, leaving the brush data on the previous
	# pair while the dock displayed the new one.
	var res_id: int = p_entry.get_resource_id()
	var clicked_resource: Resource = p_entry.resource
	if plugin.ui:
		plugin.select_terrain()
		plugin.ui.toolbar.change_tool("PaintTexture")
		plugin.ui.set_visible(true)
		plugin.ui.pair_active_role = p_role
		# Show the clicked texture asset in the Inspector so its properties
		# (albedo, normal, UV scale, colors, slope params) are editable.
		if clicked_resource:
			EditorInterface.edit_resource(clicked_resource)
		# Do not depend on the separate clicked signal: child controls can
		# consume it. Re-resolve the entry by asset id because the rebuild above
		# may have replaced it.
		var entry_index: int = _index_of_asset(res_id)
		if entry_index >= 0:
			set_selected_id(entry_index)
		if role_writes_overlay_field(p_role):
			plugin.ui.pair_overlay_id = res_id
		else:
			plugin.ui.pair_background_id = res_id
		if entry_index >= 0:
			# set_selected_id() refreshed the brush data while the previous role
			# was still assigned, so publish the final pair now. This is only
			# safe while the dock selection is the clicked asset, because
			# _on_setting_changed() re-derives the role from that selection.
			plugin.ui._on_setting_changed()
	# set_selected_id() refreshed the highlights with the previous pair, so
	# re-apply them now that the pair ids are final.
	_restore_role_highlights()


# Index of the entry showing p_res_id, or -1. Used instead of entries.find()
# because update_asset_list() frees and replaces every entry.
func _index_of_asset(p_res_id: int) -> int:
	for i in entries.size():
		var entry: Object = entries[i]
		if is_instance_valid(entry) and entry.resource and entry.get_resource_id() == p_res_id:
			return i
	return -1


# IdWeight pair roles. p_role is 0 for the left mouse button and 1 for the right
# one.
#
# The packed chain writes the left-clicked layer into the Background pair field
# (the base layer) and the right-clicked layer into the Overlay field (the layer
# the Weight slider fades in), so role 0 writes the background field and role 1
# writes the overlay field. The displayed layer-grid label names the two roles
# the other way round on purpose, and this dock keeps that reversed naming for
# its markers and for the brush-bar readout. Assert the fields, not the labels.
static func role_writes_overlay_field(p_role: int) -> bool:
	return p_role != 0


func _on_resource_hovered(p_id: int):
	if type == Terrain3DAssets.TYPE_MESH:
		if plugin.terrain:
			plugin.terrain.assets.create_mesh_thumbnails(p_id, Vector2i(512, 512), true)


func set_selected_after_swap(p_type: Terrain3DAssets.AssetType, p_old_id: int, p_new_id: int) -> void:
	EditorInterface.mark_scene_as_unsaved()
	set_selected_id(clamp(p_new_id, 0, entries.size() - 2))


func clicked_id(p_id: int) -> void:
	# Select Tool if clicking an asset
	plugin.select_terrain()
	if type == Terrain3DAssets.TYPE_TEXTURE and \
			not plugin.editor.get_tool() in [ Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS ]:
		plugin.ui.toolbar.change_tool("PaintTexture")
	elif type == Terrain3DAssets.TYPE_MESH and plugin.editor.get_tool() != Terrain3DEditor.INSTANCER:
		plugin.ui.toolbar.change_tool("InstanceMeshes")
	set_selected_id(p_id)


# The last entry that can hold an asset. The "Add new" tile is the final entry, and it only exists
# while the search box is blank - so a filtered list has no selectable slot at its end, and an
# unfiltered one has exactly one. `set_selected_id()` and `get_selected_asset_id()` have to agree on
# this bound: the first clamps the selection to it, the second reads the selection back through it.
func _max_selectable_id() -> int:
	return max(0, entries.size() - (1 if search_text else 2))


func set_selected_id(p_id: int) -> void:
	var max_id: int = _max_selectable_id()
	if plugin.debug:
		print("Terrain3DListContainer ", name, ": set_selected_id: ", selected_id, " to ", clamp(p_id, 0, max_id))
	selected_id = clamp(p_id, 0, max_id)
	for i in entries.size():
		var entry: ListEntry = entries[i]
		entry.set_selected(i == selected_id)
	_restore_role_highlights()
	plugin.ui._on_setting_changed()


func _restore_role_highlights() -> void:
	# IdWeight pair role highlights survive list rebuilds
	if type != Terrain3DAssets.TYPE_TEXTURE or not plugin.ui:
		return
	for e in entries:
		e.role_flags = 0
	for e in entries:
		if not e.resource:
			continue
		e.role_flags = _role_flags_for(e.get_resource_id())
	redraw()


# The layer grid marks the left-click role white and the right-click role blue,
# and the packed chain writes those clicks into the Background and Overlay pair
# fields respectively. Bind the marker bits to the mouse button rather than to
# the field name so the dock keeps matching the rendered result.
# Bit 1 = white (left click), bit 2 = blue (right click).
func _role_flags_for(p_res_id: int) -> int:
	var flags: int = 0
	if p_res_id == plugin.ui.pair_background_id:
		flags |= 1
	if p_res_id == plugin.ui.pair_overlay_id:
		flags |= 2
	return flags


func get_selected_asset_id() -> int:
	var max_id: int = _max_selectable_id()
	var id: int = clamp(selected_id, 0, max_id)
	if plugin.debug:
		print("Terrain3DListContainer ", name, ": get_selected_asset_id: selected_id: ", selected_id, ", clamped: ", id, ", entries: ", entries.size())
	if id >= entries.size():
		return 0
	var res: Resource = entries[id].resource
	if not res:
		return 0
	if type == Terrain3DAssets.TYPE_MESH:
		return (res as Terrain3DMeshAsset).id
	else:
		return (res as Terrain3DTextureAsset).id


func _on_resource_inspected(p_resource: Resource) -> void:
	await get_tree().process_frame
	EditorInterface.edit_resource(p_resource)


func _on_resource_changed(p_resource: Resource, p_id: int) -> void:
	if not p_resource and _clearing_resource:
		return
	if not p_resource:
		if plugin.debug:
			print("Terrain3DListContainer ", name, ": _on_resource_changed: removing asset ID: ", p_id)
		_clearing_resource = true
		# The dock is this widget's host and owns the confirmation dialog: asset list -> ScrollContainer
		# -> Box -> dock. The chain is the contract between the two files; `plugin.asset_dock` names the
		# same node, and neither is checked, so the host has to keep that shape.
		var asset_dock: Control = get_parent().get_parent().get_parent()
		if type == Terrain3DAssets.TYPE_TEXTURE:
			asset_dock.confirm_dialog.dialog_text = "Are you sure you want to clear this texture?"
		else:
			asset_dock.confirm_dialog.dialog_text = "Are you sure you want to clear this mesh and delete all instances?"
		asset_dock.confirm_dialog.popup_centered()
		await asset_dock.confirmation_closed
		if not asset_dock._confirmed:
			update_asset_list()
			_clearing_resource = false
			return
		
	if not plugin.is_terrain_valid():
		plugin.select_terrain()
		await get_tree().process_frame

	if plugin.is_terrain_valid():
		if type == Terrain3DAssets.TYPE_TEXTURE:
			plugin.terrain.assets.set_texture_asset(p_id, p_resource)
		else:
			plugin.terrain.assets.set_mesh_asset(p_id, p_resource)

		# If removing an entry, clear inspector
		if not p_resource:
			EditorInterface.inspect_object(null)			
	_clearing_resource = false


func set_entry_width(value: float) -> void:
	var min_width: float = 90.0 * max(1.0, EditorInterface.get_editor_scale())
	width = clamp(value, min_width, 512.0)
	redraw()


func get_entry_width() -> float:
	return width


func redraw() -> void:
	height = 0
	var id: int = 0
	var separation: float = 2.
	var columns: int = 3
	columns = clamp(size.x / width, 1, 100)
	var tile_size: Vector2 = Vector2(width, width) - Vector2(separation, separation)
	var count_font_size := int(clamp(tile_size.x/11., 11., 16.) * EditorInterface.get_editor_scale())
	var name_font_size := int(clamp(tile_size.x/12., 12., 16.) * EditorInterface.get_editor_scale())
	for c in get_children():
		if is_instance_valid(c):
			c.size = tile_size
			c.position = Vector2(id % columns, id / columns) * width + \
				Vector2(separation / columns, separation / columns)
			height = max(height, c.position.y + width)
			id += 1
			if type == Terrain3DAssets.TYPE_MESH:
				c.count_label.add_theme_font_size_override("font_size", count_font_size)
			c.name_label.add_theme_font_size_override("font_size", name_font_size)


# Needed to enable ScrollContainer scroll bar
func _get_minimum_size() -> Vector2:
	return Vector2(0, height)

	
func _notification(p_what) -> void:
	if p_what == NOTIFICATION_SORT_CHILDREN:
		redraw()
