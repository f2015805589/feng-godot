# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Asset Dock tile: one resource tile, its buttons, its hover/selection state and
# the Hydra IdWeight pair-role markers.
@tool
class_name Terrain3DAssetDockEntry
extends MarginContainer


signal hovered()
signal clicked()
signal role_selected(role: int, entry: Terrain3DAssetDockEntry)
signal changed(resource: Resource)
signal inspected(resource: Resource)

var resource: Resource
var type := Terrain3DAssets.TYPE_TEXTURE
var _thumbnail: Texture2D
var drop_data: bool = false
var is_hovered: bool = false
var is_selected: bool = false
var is_highlighted: bool = false
# Hydra IdWeight pair role markers: 0 = none, 1 = white (the left-click role,
# displayed as Overlay), 2 = blue (the right-click role, displayed as
# Background), 3 = both. The colours match Hydra's DrawRoleBorder; see
# ListContainer._role_flags_for for which pair field each marker tracks.
var role_flags: int = 0

var name_label: Label
var count_label: Label
var button_row: FlowContainer
var button_enabled: TextureButton
var button_highlight: TextureButton
var button_edit: TextureButton
var spacer: Control 
var button_clear: TextureButton

@onready var focus_style: StyleBox = get_theme_stylebox("focus", "Button").duplicate()
@onready var background: StyleBox = get_theme_stylebox("pressed", "Button")
@onready var clear_icon: Texture2D = get_theme_icon("Close", "EditorIcons")
@onready var edit_icon: Texture2D = get_theme_icon("Edit", "EditorIcons")
@onready var enabled_icon: Texture2D = get_theme_icon("GuiVisibilityVisible", "EditorIcons")
@onready var disabled_icon: Texture2D = get_theme_icon("GuiVisibilityHidden", "EditorIcons")
@onready var highlight_icon: Texture2D = get_theme_icon("PreviewSun", "EditorIcons")
@onready var add_icon: Texture2D = get_theme_icon("Add", "EditorIcons")


func _ready() -> void:
	name = "Terrain3DAssetDockEntry"
	custom_minimum_size = Vector2i(86., 86.)
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("margin_top", 5)
	add_theme_constant_override("margin_left", 5)
	add_theme_constant_override("margin_right", 5)

	if resource:
		is_highlighted = resource.is_highlighted()

	setup_buttons()
	setup_label()
	setup_count_label()
	focus_style.set_border_width_all(2)
	focus_style.set_border_color(Color(1, 1, 1, .67))


func setup_buttons() -> void:
	destroy_buttons()
	
	button_row = FlowContainer.new()
	button_enabled = TextureButton.new() 
	button_highlight = TextureButton.new() 
	button_edit = TextureButton.new() 
	spacer = Control.new()
	button_clear = TextureButton.new()
	
	var icon_size: Vector2 = Vector2(12, 12)
	
	button_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button_row.alignment = FlowContainer.ALIGNMENT_CENTER
	button_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(button_row, true)

	# Icon clicks must not reach the tile selection handler: it refreshes
	# the list on press, before these buttons receive their release.
	if type == Terrain3DAssets.TYPE_MESH:
		button_enabled.set_texture_normal(enabled_icon)
		button_enabled.set_texture_pressed(disabled_icon)
		button_enabled.set_custom_minimum_size(icon_size)
		button_enabled.set_h_size_flags(Control.SIZE_SHRINK_END)
		button_enabled.set_visible(resource != null)
		button_enabled.tooltip_text = "Enable Instances"
		button_enabled.toggle_mode = true
		button_enabled.mouse_filter = Control.MOUSE_FILTER_STOP
		button_enabled.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button_enabled.pressed.connect(_on_enable)
		button_row.add_child(button_enabled, true)
		
	button_highlight.set_texture_normal(highlight_icon)
	button_highlight.set_custom_minimum_size(icon_size)
	button_highlight.set_h_size_flags(Control.SIZE_SHRINK_END)
	button_highlight.set_visible(resource != null)
	button_highlight.tooltip_text = "Highlight " + ( "Instances" if type == Terrain3DAssets.TYPE_MESH else "Texture" )
	button_highlight.toggle_mode = true
	button_highlight.mouse_filter = Control.MOUSE_FILTER_STOP
	button_highlight.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_highlight.set_pressed_no_signal(is_highlighted)
	button_highlight.pressed.connect(_on_highlight)
	button_row.add_child(button_highlight, true)
	
	button_edit.set_texture_normal(edit_icon)
	button_edit.set_custom_minimum_size(icon_size)
	button_edit.set_h_size_flags(Control.SIZE_SHRINK_END)
	button_edit.set_visible(resource != null)
	button_edit.tooltip_text = "Edit Asset"
	button_edit.mouse_filter = Control.MOUSE_FILTER_STOP
	button_edit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_edit.pressed.connect(_on_edit)
	button_row.add_child(button_edit, true)

	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_PASS
	button_row.add_child(spacer, true)
	
	button_clear.set_texture_normal(clear_icon)
	button_clear.set_custom_minimum_size(icon_size)
	button_clear.set_h_size_flags(Control.SIZE_SHRINK_END)
	button_clear.set_visible(resource != null)
	button_clear.tooltip_text = "Clear Asset"
	button_clear.mouse_filter = Control.MOUSE_FILTER_STOP
	button_clear.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button_clear.pressed.connect(_on_clear)
	button_row.add_child(button_clear, true)
	

func destroy_buttons() -> void:
	if button_row:
		button_row.free()
		button_row = null
	if button_enabled:
		button_enabled.free()
		button_enabled = null
	if button_highlight:
		button_highlight.free()
		button_highlight = null
	if button_edit:
		button_edit.free()
		button_edit = null
	if spacer:
		spacer.free()
		spacer = null
	if button_clear:
		button_clear.free()
		button_clear = null


func get_resource_name() -> StringName:
	if resource:
		if resource is Terrain3DMeshAsset:
			return (resource as Terrain3DMeshAsset).get_name()
		elif resource is Terrain3DTextureAsset:
			return (resource as Terrain3DTextureAsset).get_name()
	return ""


func get_resource_id() -> int:
	if resource:
		if resource is Terrain3DMeshAsset:
			return (resource as Terrain3DMeshAsset).id
		elif resource is Terrain3DTextureAsset:
			return (resource as Terrain3DTextureAsset).id
	return -1


# Names the pair roles held by this tile using Hydra's display naming, which
# is reversed against its own pair fields: the white left-click marker is
# shown as "Overlay" and the blue right-click marker as "Background"
# (TerrainSurfaceIdWeightLayerGrid.cs:99 "trick").
func get_role_label() -> String:
	if type != Terrain3DAssets.TYPE_TEXTURE:
		return ""
	var roles: PackedStringArray = PackedStringArray()
	if role_flags & 1:
		roles.push_back("Overlay")
	if role_flags & 2:
		roles.push_back("Background")
	return " + ".join(roles)


func setup_label() -> void:
	name_label = Label.new()
	name_label.name = "MeshLabel"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", int(14. * EditorInterface.get_editor_scale()))
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	name_label.add_theme_constant_override("shadow_offset_x", 1)
	name_label.add_theme_constant_override("shadow_offset_y", 1)
	name_label.visible = false
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS	
	add_child(name_label, true)


func setup_count_label() -> void:
	count_label = Label.new()
	count_label.name = "CountLabel"
	count_label.text = ""
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	count_label.add_theme_font_size_override("font_size", int(14. * EditorInterface.get_editor_scale()))
	count_label.add_theme_color_override("font_color", Color.WHITE)
	count_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	count_label.add_theme_constant_override("shadow_offset_x", 1)
	count_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(count_label, true)
	var mesh_resource: Terrain3DMeshAsset = resource as Terrain3DMeshAsset
	if not mesh_resource: 
		return
	mesh_resource.instance_count_changed.connect(update_count_label)
	update_count_label()


func update_count_label() -> void:
	if not type == Terrain3DAssets.AssetType.TYPE_MESH or \
			( resource and not resource.is_enabled() ):
		count_label.text = ""
		return
	var mesh_resource: Terrain3DMeshAsset = resource as Terrain3DMeshAsset
	if not mesh_resource:
		count_label.text = str(0)
	else:
		count_label.text = _format_number(mesh_resource.get_instance_count())


func _notification(p_what) -> void:
	match p_what:
		NOTIFICATION_PREDELETE:
			destroy_buttons()
		NOTIFICATION_DRAW:
			# Hide spacer if icons are crowding small textures
			spacer.visible = size.x > 94. or type == Terrain3DAssets.TYPE_TEXTURE
			var rect: Rect2 = Rect2(Vector2.ZERO, get_size())
			if !resource:
				draw_style_box(background, rect)
				draw_texture(add_icon, (get_size() / 2) - (add_icon.get_size() / 2))
			else:
				_thumbnail = resource.get_thumbnail()
				if _thumbnail:
					draw_texture_rect(_thumbnail, rect, false)
					texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
				else:
					draw_rect(rect, Color(.15, .15, .15, 1.))
				if type == Terrain3DAssets.TYPE_TEXTURE:
					self_modulate = resource.get_highlight_color() if is_highlighted else resource.get_albedo_color()
				else:
					button_enabled.set_pressed_no_signal(!resource.is_enabled())
					self_modulate = resource.get_highlight_color()
				button_highlight.self_modulate = Color("FC7F7F") if is_highlighted else Color.WHITE
			if drop_data:
				draw_style_box(focus_style, rect)
			if is_hovered:
				draw_rect(rect, Color(1, 1, 1, 0.2))
			if is_selected and type != Terrain3DAssets.TYPE_TEXTURE:
				draw_style_box(focus_style, rect)
			# Draw role markers on separate halves so both roles remain visible.
			if role_flags == 1:
				draw_rect(rect, Color(1, 1, 1, 0.95), false, 3.0)
			elif role_flags == 2:
				draw_rect(rect, Color(0.35, 0.68, 1.0, 0.95), false, 3.0)
			elif role_flags == 3:
				# Split only the outer border; leave the center seam absent.
				var mid_x := rect.position.x + rect.size.x * 0.5
				var left := rect.position.x
				var right := rect.end.x
				var top := rect.position.y
				var bottom := rect.end.y
				var white := Color(1, 1, 1, 0.95)
				var blue := Color(0.35, 0.68, 1.0, 0.95)
				draw_line(Vector2(left, top), Vector2(mid_x, top), white, 3.0)
				draw_line(Vector2(left, bottom), Vector2(mid_x, bottom), white, 3.0)
				draw_line(Vector2(left, top), Vector2(left, bottom), white, 3.0)
				draw_line(Vector2(mid_x, top), Vector2(right, top), blue, 3.0)
				draw_line(Vector2(mid_x, bottom), Vector2(right, bottom), blue, 3.0)
				draw_line(Vector2(right, top), Vector2(right, bottom), blue, 3.0)
		NOTIFICATION_MOUSE_ENTER:
			if not resource:
				name_label.visible = false
			else:
				name_label.visible = true
			is_hovered = true
			# Name the role on the tile itself so the white/blue borders are
			# readable without consulting the legend.
			var display_name: String = get_resource_name()
			var role_text: String = get_role_label()
			if not role_text.is_empty():
				display_name = "%s [%s]" % [ display_name, role_text ]
			name_label.text = display_name
			tooltip_text = display_name
			emit_signal("hovered")
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			name_label.visible = false
			is_hovered = false
			drop_data = false
			queue_redraw()


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton:
		if p_event.is_pressed():
			match p_event.get_button_index():
				MOUSE_BUTTON_LEFT:
					# If `Add new` is clicked
					if !resource:
						if type == Terrain3DAssets.TYPE_TEXTURE:
							set_edited_resource(Terrain3DTextureAsset.new(), false)
						else:
							set_edited_resource(Terrain3DMeshAsset.new(), false)
						_on_edit()
					else:
						# Hydra's label: left click is the Overlay role.
						# Hydra's chain: left click is the Background field.
						if type == Terrain3DAssets.TYPE_TEXTURE:
							role_selected.emit(0, self)
						emit_signal("clicked")
				MOUSE_BUTTON_RIGHT:
					if resource:
						# Hydra's label: right click is the Background role.
						# Hydra's chain: right click is the Overlay field.
						if type == Terrain3DAssets.TYPE_TEXTURE:
							role_selected.emit(1, self)
							emit_signal("clicked")
						else:
							_on_edit()
				MOUSE_BUTTON_MIDDLE:
					if resource:
						_on_clear()


func _can_drop_data(p_at_position: Vector2, p_data: Variant) -> bool:
	drop_data = false
	if typeof(p_data) == TYPE_DICTIONARY:
		if p_data.files.size() == 1:
			queue_redraw()
			drop_data = true
	return drop_data

	
func _drop_data(p_at_position: Vector2, p_data: Variant) -> void:
	if typeof(p_data) == TYPE_DICTIONARY:
		var res: Resource = load(p_data.files[0])
		if res is Texture2D and type == Terrain3DAssets.TYPE_TEXTURE:
			var ta := Terrain3DTextureAsset.new()
			if resource is Terrain3DTextureAsset:
				ta.id = resource.id
			ta.set_albedo_texture(res)
			set_edited_resource(ta, false)
			resource = ta
		elif res is Terrain3DTextureAsset and type == Terrain3DAssets.TYPE_TEXTURE:
			if resource is Terrain3DTextureAsset:
				res.id = resource.id
			set_edited_resource(res, false)
		elif res is PackedScene and type == Terrain3DAssets.TYPE_MESH:
			if not resource:
				resource = Terrain3DMeshAsset.new()		
			set_edited_resource(resource, false)
			resource.set_scene_file(res)
		elif res is Terrain3DMeshAsset and type == Terrain3DAssets.TYPE_MESH:
			if resource is Terrain3DMeshAsset:
				res.id = resource.id
			set_edited_resource(res, false)
		emit_signal("clicked")
		emit_signal("inspected", resource)


func set_edited_resource(p_res: Resource, p_no_signal: bool = true) -> void:
	resource = p_res
	if resource:
		if not resource.setting_changed.is_connected(_on_resource_changed):
			resource.setting_changed.connect(_on_resource_changed)
		if resource is Terrain3DTextureAsset:
			if not resource.file_changed.is_connected(_on_resource_changed):
				resource.file_changed.connect(_on_resource_changed)
		elif resource is Terrain3DMeshAsset:
			if not resource.instancer_setting_changed.is_connected(_on_resource_changed):
				resource.instancer_setting_changed.connect(_on_resource_changed)
	
	if button_clear:
		button_clear.set_visible(resource != null)
		
	queue_redraw()
	if not p_no_signal:
		emit_signal("changed", resource)


func _on_resource_changed(_value: int = 0) -> void:
	queue_redraw()
	emit_signal("changed", resource)


func set_selected(value: bool) -> void:
	if not is_inside_tree():
		#push_error("not in tree")
		return
	is_selected = value
	if is_selected:
		# Handle scrolling to show the selected item
		await get_tree().process_frame
		if is_inside_tree():
			get_parent().get_parent().get_v_scroll_bar().ratio = position.y / get_parent().size.y
	queue_redraw()


func _on_clear() -> void:
	if resource:
		name_label.hide()
		set_edited_resource(null, false)
		update_count_label()


func _on_edit() -> void:
	emit_signal("clicked")
	emit_signal("inspected", resource)


func _on_enable() -> void:
	if resource is Terrain3DMeshAsset:
		resource.set_enabled(!resource.is_enabled())


func _on_highlight() -> void:
	is_highlighted = !is_highlighted
	resource.set_highlighted(is_highlighted)


func _format_number(num: int) -> String:
	var is_negative: bool = num < 0
	var str_num: String = str(abs(num))
	var result: String = ""
	var length: int = str_num.length()
	for i in length:
		result = str_num[length - 1 - i] + result
		if i < length - 1 and (i + 1) % 3 == 0:
			result = "," + result
	return "-" + result if is_negative else result
