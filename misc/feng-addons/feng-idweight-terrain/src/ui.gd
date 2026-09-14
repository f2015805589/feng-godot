# Copyright 漏 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# UI for Terrain3D
extends Node


# Includes
const TerrainMenu: Script = preload("res://addons/feng-idweight-terrain/menu/terrain_menu.gd")
const TerrainToolbar: Script = preload("res://addons/feng-idweight-terrain/src/toolbar.gd")
const TerrainToolSettings: Script = preload("res://addons/feng-idweight-terrain/src/tool_settings.gd")
const OperationBuilder: Script = preload("res://addons/feng-idweight-terrain/src/operation_builder.gd")
const GradientOperationBuilder: Script = preload("res://addons/feng-idweight-terrain/src/gradient_operation_builder.gd")
const TerrainUIDecal: Script = preload("res://addons/feng-idweight-terrain/src/ui_decal.gd")
const LIVE_INFO_PANEL: String = "res://addons/feng-idweight-terrain/src/live_info_panel.tscn"

const OP_NONE: int = 0x0
const OP_POSITIVE_ONLY: int = 0x01
const OP_NEGATIVE_ONLY: int = 0x02

var plugin: EditorPlugin # Actually Terrain3DEditorPlugin, but Godot still has CRC errors
var toolbar: TerrainToolbar
var tool_settings: TerrainToolSettings
var terrain_menu: TerrainMenu
var live_info_panel: Terrain3DLiveInfoPanel
var setting_has_changed: bool = false
var visible: bool = false
var picking: int = Terrain3DEditor.TOOL_MAX
var picking_callback: Callable
var brush_data: Dictionary
var operation_builder: OperationBuilder
var active_tool: Terrain3DEditor.Tool = Terrain3DEditor.TOOL_MAX
var _selected_tool: Terrain3DEditor.Tool = Terrain3DEditor.TOOL_MAX
var active_operation: Terrain3DEditor.Operation = Terrain3DEditor.OP_MAX
var _selected_operation: Terrain3DEditor.Operation = Terrain3DEditor.OP_MAX
var _tool_state_initialized: bool = false
var inverted_input: bool = false

# IdWeight pair painting state: which role the next stroke paints.
# 0 = the left-mouse role, 1 = the right-mouse role. The dock labels them the
# opposite way round from the packed fields ("Left click: Overlay    Right
# click: Background"), because that on-screen naming is deliberately reversed
# against the field order, so the left-click role writes pair_background_id (the
# base layer) and the right-click role writes pair_overlay_id (the layer the
# Weight slider fades in). Border colours follow the same convention:
# left = white, right = blue.
var pair_active_role: int = 0
# The packed R16 pair fields. pair_overlay_id is the layer the Weight slider
# fades in; pair_background_id is the layer it fades over.
var pair_overlay_id: int = 0
var pair_background_id: int = 0

# 3 Editor decals live in `ui_decal.gd`: the cursor quad, its brush texture, the
# gradient markers and the shader parameters that draw them. `decal` reads the tool,
# brush and pointer state this node owns and turns it into one shader update, so the
# UI is the only place that knows about tools and the dock keeps drawing them.
var decal: TerrainUIDecal


func _enter_tree() -> void:
	if plugin.debug:
		print("Terrain3DUI: _enter_tree()")

	toolbar = TerrainToolbar.new()
	toolbar.plugin = plugin
	toolbar.hide()
	toolbar.tool_changed.connect(_on_tool_changed)
	
	tool_settings = TerrainToolSettings.new()
	tool_settings.setting_changed.connect(_on_setting_changed)
	tool_settings.picking.connect(_on_picking)
	tool_settings.plugin = plugin
	tool_settings.hide()

	# Built before the first _on_tool_changed(), which can already request a decal.
	decal = TerrainUIDecal.new()
	add_child(decal)
	decal.setup(plugin, self)

	terrain_menu = TerrainMenu.new()
	terrain_menu.plugin = plugin
	terrain_menu.hide()

	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, terrain_menu)

	_on_tool_changed(Terrain3DEditor.TOOL_MAX, Terrain3DEditor.OP_MAX)
	
	setup_live_info_panel()


func _exit_tree() -> void:
	if plugin.debug:
		print("Terrain3DUI: _exit_tree()")
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, toolbar)
	plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, tool_settings)
	toolbar.queue_free()
	tool_settings.queue_free()
	terrain_menu.queue_free()
	decal.queue_free()
	live_info_panel.queue_free()


func set_visible(p_visible: bool, p_menu_only: bool = false) -> void:
	if plugin.debug:
		print("Terrain3DUI: set_visible(%s, %s)" % [ p_visible, p_menu_only ])

	terrain_menu.set_visible(p_visible)

	if p_menu_only:
		toolbar.set_visible(false)
		tool_settings.set_visible(false)
	else:
		visible = p_visible
		toolbar.set_visible(p_visible)
		tool_settings.set_visible(p_visible)
		live_info_panel.set_visible(p_visible)

	if plugin.editor and plugin.terrain and p_visible:
			await get_tree().process_frame # Won't work, otherwise
			if plugin.debug:
				print("Terrain3DUI: set_visible: calling _on_tool_changed()")
			_on_tool_changed(_selected_tool, _selected_operation)
			if _selected_tool in [ Terrain3DEditor.REGION, Terrain3DEditor.NAVIGATION ]:
				plugin.terrain.material.update(Terrain3DMaterial.FULL_REBUILD)

	
func set_menu_visibility(p_list: Control, p_visible: bool) -> void:
	if p_list:
		p_list.get_parent().get_parent().visible = p_visible
	

func _on_tool_changed(p_tool: Terrain3DEditor.Tool, p_operation: Terrain3DEditor.Operation) -> void:
	if plugin.debug:
		print("Terrain3DUI: _on_tool_changed: ", p_tool, ", ", p_operation)
	if _tool_state_initialized and active_tool == p_tool and active_operation == p_operation:
		return
	_tool_state_initialized = true
	_selected_tool = p_tool
	_selected_operation = p_operation
	if p_tool == Terrain3DEditor.TOOL_MAX and plugin.editor and plugin.editor.is_operating():
		plugin.editor.stop_operation()
	clear_picking()
	set_menu_visibility(tool_settings.advanced_list, p_tool != Terrain3DEditor.TOOL_MAX)
	set_menu_visibility(tool_settings.scale_list, false)
	set_menu_visibility(tool_settings.rotation_list, false)
	set_menu_visibility(tool_settings.height_list, false)
	set_menu_visibility(tool_settings.color_list, false)
	set_menu_visibility(tool_settings.collision_list, false)

	# Select which settings to show. Options in tool_settings.gd:_ready
	var to_show: PackedStringArray = []
	
	match _selected_tool:
		Terrain3DEditor.REGION:
			to_show.push_back("instructions")
			to_show.push_back("invert")
			set_menu_visibility(tool_settings.advanced_list, false)

		Terrain3DEditor.SCULPT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			if _selected_operation in [Terrain3DEditor.ADD, Terrain3DEditor.SUBTRACT]:
					to_show.push_back("invert")
			elif _selected_operation == Terrain3DEditor.GRADIENT:
				to_show.push_back("gradient_points")
				to_show.push_back("drawable")

		Terrain3DEditor.HEIGHT:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("height")
			to_show.push_back("height_picker")
			to_show.push_back("invert")

		Terrain3DEditor.TEXTURE:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("enable_texture")
			to_show.push_back("texture_picker")
			if _selected_operation == Terrain3DEditor.ADD:
				to_show.push_back("strength")
				to_show.push_back("invert")
			to_show.push_back("pair_mode")
			to_show.push_back("pair_weight_level")
			to_show.push_back("pair_roles")
			to_show.push_back("pair_click_hint")
			to_show.push_back("slope_blend_sharpness")
			to_show.push_back("slope_based_damp")
			to_show.push_back("slope_based_normal_damp")
			to_show.push_back("slope")
			# The IdWeight R16 contract stores no per-texel UV rotation or
			# scale (Overlay:5 | Background:5 | Mode:2 | Weight:3 | UV:1, and UV
			# variant 0 is the only valid value), so the legacy Angle/Scale brush
			# controls have nothing left to write. Per-material UV scale comes
			# from the texture asset instead (edit it in the asset dock).

		Terrain3DEditor.COLOR:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("color")
			to_show.push_back("color_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Terrain3DEditor.ROUGHNESS:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("roughness")
			to_show.push_back("roughness_picker")
			to_show.push_back("slope")
			to_show.push_back("texture_filter")
			to_show.push_back("margin")
			to_show.push_back("invert")

		Terrain3DEditor.AUTOSHADER, Terrain3DEditor.HOLES, Terrain3DEditor.NAVIGATION:
			to_show.push_back("brush")
			to_show.push_back("size")
			to_show.push_back("invert")

		Terrain3DEditor.INSTANCER:
			to_show.push_back("size")
			to_show.push_back("strength")
			to_show.push_back("slope")
			to_show.push_back("mesh_picker")
			set_menu_visibility(tool_settings.height_list, true)
			to_show.push_back("height_offset")
			to_show.push_back("random_height")
			set_menu_visibility(tool_settings.scale_list, true)
			to_show.push_back("fixed_scale")
			to_show.push_back("random_scale")
			set_menu_visibility(tool_settings.rotation_list, true)
			to_show.push_back("fixed_spin")
			to_show.push_back("random_spin")
			to_show.push_back("fixed_tilt")
			to_show.push_back("random_tilt")
			to_show.push_back("align_to_normal")
			set_menu_visibility(tool_settings.color_list, true)
			to_show.push_back("vertex_color")
			to_show.push_back("random_darken")
			to_show.push_back("random_hue")
			set_menu_visibility(tool_settings.collision_list, true)
			to_show.push_back("on_collision")
			to_show.push_back("raycast_height")
			to_show.push_back("invert")

		_:
			pass

	# Advanced menu settings are editing controls too. Keep them hidden while
	# None is selected so no brush or add/remove-region action is armed.
	if _selected_tool != Terrain3DEditor.TOOL_MAX:
		to_show.push_back("auto_regions")
		to_show.push_back("align_to_view")
		to_show.push_back("show_brush_texture")
		to_show.push_back("gamma")
		to_show.push_back("brush_spin_speed")
	tool_settings.show_settings(to_show)

	if plugin.debug:
		print("Terrain3DUI: _on_tool_changed: calling _on_setting_changed()")
	_on_setting_changed()


func _on_setting_changed(p_setting: Variant = null) -> void:
	if plugin.debug:
		print("Terrain3DUI: _on_setting_changed: ", p_setting if p_setting else "update all")
	if not plugin.asset_dock: # Skip function if not _ready()
		return
	brush_data = tool_settings.get_settings()
	brush_data["asset_id"] = plugin.asset_dock.current_list.get_selected_asset_id()
	# IdWeight pair painting: keep the selected overlay/background roles
	# stable across asset selection changes, and apply the current role's asset.
	if plugin.editor and plugin.editor.get_tool() == Terrain3DEditor.TEXTURE:
		# pair_active_role is the role of the last dock click: 0 = left mouse,
		# 1 = right mouse. The packed chain writes the left-clicked layer into the
		# Background pair field (the base) and the right-clicked layer into the
		# Overlay field (the layer the Weight slider fades in), so the
		# button-to-field mapping is the mirror of the role names the dock shows.
		if pair_active_role == 1:
			pair_overlay_id = brush_data["asset_id"]
		else:
			pair_background_id = brush_data["asset_id"]
		brush_data["pair_overlay_id"] = pair_overlay_id
		brush_data["pair_background_id"] = pair_background_id
		brush_data["pair_mode"] = tool_settings.get_setting("pair_mode")
		brush_data["pair_weight_level"] = tool_settings.get_setting("pair_weight_level")
		_update_pair_role_readout()
		# Each slope parameter belongs to a pair ROLE, not to whichever asset
		# is selected: the shader reads blendSharpness from the Background
		# (Horizontal) material and both damps from the Overlay (Vertical)
		# material, so the brush edits exactly backgroundSettings.blendSharpness
		# plus overlaySettings.slopeBasedDamp.
		# Writing all three to the selected asset silently edited the parameter of
		# whichever role was not selected, so the edit never reached the shader.
		_sync_slope_setting("slope_blend_sharpness", pair_background_id, p_setting)
		_sync_slope_setting("slope_based_damp", pair_overlay_id, p_setting)
		_sync_slope_setting("slope_based_normal_damp", pair_overlay_id, p_setting)

	if plugin.debug:
		print("Terrain3DUI: _on_setting_changed: selected resource ID: ", brush_data["asset_id"])
	if plugin.editor:
		plugin.editor.set_brush_data(brush_data)
	inverted_input = brush_data.get("invert", false)
	if p_setting is CheckBox and p_setting.name == &"Invert":
		plugin._read_input() # Revalidate keyboard input for modifier_ctrl
	set_active_operation()
	update_decal()


# IdWeight pair role readout for the brush bar. The layer grid names the active
# role ("Current Pair Selection: <slot> · <id>: <name>"), but the asset dock
# only draws role borders, so which material was the overlay and which was the
# background was invisible while painting. The slots name the packed pair
# fields: the
# Overlay slot is the layer the Weight slider fades in and the Background slot is
# the layer it fades over. Role ids index the texture asset list, and id 0 is a
# valid material, so a slot only reports as missing when no asset exists.
func _update_pair_role_readout() -> void:
	if not tool_settings:
		return
	tool_settings.set_pair_roles_text(
		_describe_pair_role(pair_overlay_id), _describe_pair_role(pair_background_id))


func _describe_pair_role(p_asset_id: int) -> String:
	var tex: Terrain3DTextureAsset = null
	if plugin.terrain and plugin.terrain.assets:
		tex = plugin.terrain.assets.get_texture_asset(p_asset_id)
	if not tex:
		return "%d: (no texture asset)" % p_asset_id
	return "%d: %s" % [ tex.id, tex.get_name() ]


# Keeps one slope slider bound to the pair role that owns it. The shader reads
# blendSharpness from the Background material and slopeBasedDamp /
# slopeBasedNormalDamp from the Overlay material, so a slider edit must land on
# that role's asset and the slider must display that role's value. Editing the
# selected asset instead let a change silently miss the shader whenever the
# selected asset held the other role.
func _sync_slope_setting(p_key: String, p_asset_id: int, p_changed: Variant) -> void:
	var control: Object = tool_settings.settings.get(p_key)
	if not control is Range:
		return
	var tex: Terrain3DTextureAsset = null
	if plugin.terrain and plugin.terrain.assets:
		tex = plugin.terrain.assets.get_texture_asset(p_asset_id)
	if not tex:
		return
	if control == p_changed:
		tex.set(p_key, tool_settings.get_setting(p_key))
		EditorInterface.mark_scene_as_unsaved()
	else:
		# Selection or unrelated brush changes must never overwrite the owning
		# material's saved slope settings with the toolbar defaults.
		(control as Range).set_value_no_signal(tex.get(p_key))


# Change tool/operation based on modifiers. Called from:
# * editor_plugin.gd:_read_input() - when a modifier key is pressed
# * _on_tool_changed() via:
# * _on_setting_changed() eg. Touchscreen Invert
func set_active_operation() -> void:
	var inverted: bool = plugin.modifier_ctrl || inverted_input
	if _selected_tool == Terrain3DEditor.TOOL_MAX:
		active_tool = Terrain3DEditor.TOOL_MAX
		active_operation = Terrain3DEditor.OP_MAX
		operation_builder = null
		toolbar.show_add_buttons(true)
		if plugin.editor:
			plugin.editor.set_tool(active_tool)
			plugin.editor.set_operation(active_operation)
		return

	# Toggle toolbar buttons
	toolbar.show_add_buttons(not inverted)
	
	# If Shift, Smoothness
	if plugin.modifier_shift and not inverted:
		match _selected_tool:
			Terrain3DEditor.SCULPT, Terrain3DEditor.HEIGHT, Terrain3DEditor.HOLES, \
			Terrain3DEditor.INSTANCER:
				active_tool = Terrain3DEditor.SCULPT
				active_operation = Terrain3DEditor.AVERAGE
			Terrain3DEditor.TEXTURE:
				active_tool = Terrain3DEditor.TEXTURE
				active_operation = Terrain3DEditor.AVERAGE
			Terrain3DEditor.COLOR:
				active_tool = Terrain3DEditor.COLOR
				active_operation = Terrain3DEditor.AVERAGE
			Terrain3DEditor.ROUGHNESS:
				active_tool = Terrain3DEditor.ROUGHNESS
				active_operation = Terrain3DEditor.AVERAGE
	
	# Else if Ctrl/Invert checked, opposite
	elif _selected_operation == Terrain3DEditor.ADD and inverted:
		active_tool = _selected_tool
		active_operation = Terrain3DEditor.SUBTRACT
	elif _selected_operation == Terrain3DEditor.SUBTRACT and not inverted:
		active_tool = _selected_tool
		active_operation = Terrain3DEditor.ADD

	# Else use default and set
	else:
		active_tool = _selected_tool
		active_operation = _selected_operation

	# Initiate Multipoint operation
	operation_builder = null
	if active_operation == Terrain3DEditor.GRADIENT:
		operation_builder = GradientOperationBuilder.new()
		operation_builder.tool_settings = tool_settings

	if plugin.editor:
		plugin.editor.set_tool(active_tool)
		plugin.editor.set_operation(active_operation)


# The decal renderer owns its shader state; these three entry points stay on the UI
# node because Terrain3DEditor and the editor plugin reach the decal through it.
func update_decal() -> void:
	decal.update_decal()


func hide_decal() -> void:
	decal.hide_decal()


func set_decal_rotation(p_rot: float) -> void:
	decal.set_decal_rotation(p_rot)


func _on_picking(p_type: Terrain3DEditor.Tool, p_callback: Callable) -> void:
	picking = p_type
	picking_callback = p_callback
	if picking == Terrain3DEditor.Tool.INSTANCER:
		if not get_tree().process_frame.is_connected(_update_picker_highlight):
			get_tree().process_frame.connect(_update_picker_highlight)
	else:
		if get_tree().process_frame.is_connected(_update_picker_highlight):
			get_tree().process_frame.disconnect(_update_picker_highlight)

		
func _update_picker_highlight() -> void:
	var mesh_asset_id: int = -1
	if plugin.terrain.data.has_regionp(plugin.mouse_global_position):
		mesh_asset_id = plugin.terrain.instancer.get_closest_mesh_id(plugin.mouse_global_position)
	for i: int in plugin.terrain.assets.get_mesh_count():
		var ma: Terrain3DMeshAsset = plugin.terrain.assets.get_mesh_asset(i)
		if ma:
			ma.set_highlighted(i == mesh_asset_id)
		

func clear_picking() -> void:
	picking = Terrain3DEditor.TOOL_MAX
	if get_tree().process_frame.is_connected(_update_picker_highlight):
		get_tree().process_frame.disconnect(_update_picker_highlight)
		for i: int in range(0,  plugin.terrain.assets.get_mesh_count()):
			var ma: Terrain3DMeshAsset = plugin.terrain.assets.get_mesh_asset(i)
			if ma:
				ma.set_highlighted(false)
		plugin.asset_dock.update_dock()


func is_picking() -> bool:
	if picking != Terrain3DEditor.TOOL_MAX:
		return true
	
	if operation_builder and operation_builder.is_picking():
		return true
	
	return false


func pick(p_global_position: Vector3) -> void:
	if picking != Terrain3DEditor.TOOL_MAX:
		var color: Color
		match picking:
			Terrain3DEditor.HEIGHT, Terrain3DEditor.SCULPT:
				color = Color(plugin.terrain.data.get_height(p_global_position), 0., 0., 1.)
			Terrain3DEditor.ROUGHNESS:
				color = plugin.terrain.data.get_pixel(Terrain3DRegion.TYPE_COLOR, p_global_position)
			Terrain3DEditor.COLOR:
				color = plugin.terrain.data.get_color(p_global_position)
			Terrain3DEditor.ANGLE:
				color = Color(plugin.terrain.data.get_control_angle(p_global_position), 0., 0., 1.)
			Terrain3DEditor.SCALE:
				color = Color(plugin.terrain.data.get_control_scale(p_global_position), 0., 0., 1.)
			Terrain3DEditor.INSTANCER:
				var mesh_asset_id: int = plugin.terrain.instancer.get_closest_mesh_id(p_global_position)
				color = Color(mesh_asset_id, 0., 0., 1.)
			Terrain3DEditor.TEXTURE:
				var texture_blend_data: Vector3 = plugin.terrain.data.get_texture_id(p_global_position)
				if not texture_blend_data.is_finite():
					return
				if texture_blend_data.z < 0.65:
					color = Color(texture_blend_data.x, 0., 0., 1.)
				else:
					color = Color(texture_blend_data.y, 0., 0., 1.)
			_:
				push_error("Unsupported picking type: ", picking)
				return
		if picking_callback.is_valid():
			picking_callback.call(picking, color, p_global_position)
			picking_callback = Callable()
		clear_picking()
	
	elif operation_builder and operation_builder.is_picking():
		operation_builder.pick(p_global_position, plugin.terrain)


func set_button_editor_icon(p_button: Button, p_icon_name: String) -> void:
	p_button.icon = EditorInterface.get_base_control().get_theme_icon(p_icon_name, "EditorIcons")


func setup_live_info_panel() -> void:
	live_info_panel = load(LIVE_INFO_PANEL).instantiate()
	live_info_panel.plugin = plugin
	var main_screen = EditorInterface.get_editor_main_screen()
	if not main_screen:
		push_error("Terrain3DUI: setup_live_info_panel(): Failed to get main screen")
		return
	var viewport_container = main_screen.find_child("*Node3DEditorViewportContainer*", true, false)
	if not viewport_container:
		push_error("Terrain3DUI: setup_live_info_panel(): Failed to get main viewport_container")
		return
	viewport_container.add_child(live_info_panel, true)
	live_info_panel.visible = false
