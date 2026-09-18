# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Plugin for Terrain3D
@tool
extends EditorPlugin


# Includes
const Terrain3DUI: Script = preload("res://addons/feng-idweight-terrain/src/ui.gd")
const ASSET_DOCK: String = "res://addons/feng-idweight-terrain/src/asset_dock.tscn"
const ASSET_DOCK_45: String = "res://addons/feng-idweight-terrain/src/asset_dock_45.tscn"
const VT_INSPECTOR_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/terrain_vt_inspector.gd")

# Editor Plugin
var debug: int = 0 # Set in _edit()
var terrain_setup: Node
var editor: Terrain3DEditor
var editor_settings: EditorSettings
var ui: Node # Terrain3DUI see Godot #75388
var asset_dock: PanelContainer
var vt_inspector_plugin: EditorInspectorPlugin
var mouse_global_position: Vector3 = Vector3.ZERO
var mouse_viewport_position: Vector2 = Vector2.ZERO
var godot_editor_window: Window # The Godot Editor window
var viewport: SubViewport # Viewport the mouse was last in
var mouse_in_main: bool = false # Helper to track when mouse is in the editor vp

# Terrain
var terrain: Terrain3D
var _last_terrain: Terrain3D
var nav_region: NavigationRegion3D

# Input
var modifier_ctrl: bool
var modifier_alt: bool
var modifier_shift: bool
var _last_modifiers: int = 0
var _input_mode: int = 0 # -1: camera move, 0: none, 1: operating
var rmb_release_time: int = 0
var _use_meta: bool = false


func _init() -> void:
	if debug:
		print("Terrain3DEditorPlugin: _init")
	if OS.get_name() == "macOS":
		_use_meta = true
	
	# Get the Godot Editor window. Structure is root:Window/EditorNode/Base Control
	godot_editor_window = EditorInterface.get_base_control().get_parent().get_parent()
	godot_editor_window.focus_entered.connect(_on_godot_focus_entered)
	EditorInterface.get_inspector().mouse_entered.connect(func(): mouse_in_main = false)


func _enter_tree() -> void:
	if debug:
		print("Terrain3DEditorPlugin: _enter_tree")
	editor = Terrain3DEditor.new()
	setup_editor_settings()
	ui = Terrain3DUI.new()
	ui.plugin = self
	add_child(ui)

	scene_changed.connect(_on_scene_changed)

	# Load Godot 4.6+ asset dock or pre-4.6
	if Engine.get_version_info().hex >= 0x040600:
		asset_dock = load(ASSET_DOCK).instantiate()
	else:
		asset_dock = load(ASSET_DOCK_45).instantiate()
	asset_dock.initialize(self)
	vt_inspector_plugin = VT_INSPECTOR_SCRIPT.new()
	vt_inspector_plugin.editor_plugin = self
	add_inspector_plugin(vt_inspector_plugin)
	terrain_setup = preload("res://addons/feng-idweight-terrain/src/terrain_setup.gd").new()
	terrain_setup.plugin = self
	add_child(terrain_setup)


func _exit_tree() -> void:
	if debug:
		print("Terrain3DEditorPlugin: _exit_tree")
	if vt_inspector_plugin != null:
		remove_inspector_plugin(vt_inspector_plugin)
		vt_inspector_plugin = null
	asset_dock.remove_dock(true)
	asset_dock.queue_free()
	ui.queue_free()
	editor.free()

	scene_changed.disconnect(_on_scene_changed)
	godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)


## Open the shared Surface VT editor for an Inspector-selected terrain.
## Keeping this as a public plugin action avoids reaching into the Inspector
## plugin's private dock/window state from custom controls.
func open_vt_editor(p_terrain: Object = null) -> void:
	var target := p_terrain if p_terrain != null and is_instance_valid(p_terrain) else terrain
	if target == null or not is_instance_valid(target):
		return
	if asset_dock == null or not is_instance_valid(asset_dock):
		return
	asset_dock.call("_open_vt_editor", target)


## Open Surface VT and focus its top-level VT Page hierarchy entry. The window
## refreshes its stitched baked overview explicitly; no GPU readback is queued.
func open_vt_page_overview(p_terrain: Object = null) -> void:
	open_vt_editor(p_terrain)
	if asset_dock == null or not is_instance_valid(asset_dock):
		return
	var window := asset_dock.get("vt_editor") as Window
	if window != null and is_instance_valid(window) and window.has_method("open_vt_page_view"):
		window.call("open_vt_page_view")


func _on_godot_focus_entered() -> void:
	if debug > 1:
		print("Terrain3DEditorPlugin: _on_godot_focus_entered")
	_read_input()


## EditorPlugin selection function call chain isn't consistent. Here's the map of calls:
## Assume we handle Terrain3D and NavigationRegion3D  
# Click Terrain3D: 					_handles(Terrain3D), _edit(Terrain3D), _make_visible(true)
# Deselect:							_edit(null), _make_visible(false)
# Click other node:					_handles(OtherNode)
# Click NavRegion3D:				_handles(NavReg3D), _edit(NavReg3D), _make_visible(true)
# Click NavRegion3D, Terrain3D:		_handles(Terrain3D), _make_visible(true), _edit(Terrain3D)
# Click Terrain3D, NavRegion3D:		_handles(NavReg3D), _make_visible(true), _edit(NavReg3D)
func _handles(p_object: Object) -> bool:
	if p_object is Terrain3D:
		return true
	elif p_object is NavigationRegion3D and is_instance_valid(_last_terrain):
		return true
	
	# Terrain3DObjects requires access to EditorUndoRedoManager. The only way to make sure it
	# always has it, is to pass it in here. _edit is NOT called if the node is cut and pasted.
	elif p_object is Terrain3DObjects:
		p_object.editor_setup(self)
	elif p_object is Node3D and p_object.get_parent() is Terrain3DObjects:
		p_object.get_parent().editor_setup(self)
	
	return false


func _edit(p_object: Object) -> void:
	if !p_object:
		_clear()

	if p_object is Terrain3D:
		if p_object == terrain:
			return
		terrain = p_object
		_last_terrain = terrain
		terrain.set_plugin(self)
		terrain.set_editor(editor)
		debug = terrain.debug_level
		editor.set_terrain(terrain)
		terrain.set_meta("_edit_lock_", true)
		ui.set_visible(true)

		# Get alerted when a new asset list is loaded
		if not terrain.assets_changed.is_connected(asset_dock.update_assets):
			terrain.assets_changed.connect(asset_dock.update_assets)
		asset_dock.update_assets()
		if terrain_setup:
			terrain_setup.call_deferred("request", terrain)
	else:
		_clear()

	if is_terrain_valid(_last_terrain):
		if p_object is NavigationRegion3D:
			ui.set_visible(true, true)
			nav_region = p_object
		else:
			nav_region = null

	
func _make_visible(p_visible: bool, p_redraw: bool = false) -> void:
	if debug:
		print("Terrain3DEditorPlugin: _make_visible(%s, %s)" % [ p_visible, p_redraw ])
	if p_visible and is_selected():
		ui.set_visible(true)
		asset_dock.update_dock()
	elif p_visible and is_terrain_valid() and _is_editing_terrain_asset():
		# Inspector is showing a Terrain3D asset (e.g. a texture clicked in
		# the asset dock). Keep the terrain tool UI active so painting still
		# works while the asset properties are editable.
		ui.set_visible(true)
		asset_dock.update_dock()
	else:
		ui.set_visible(false)


func _is_editing_terrain_asset() -> bool:
	var obj: Object = EditorInterface.get_inspector().get_edited_object()
	if not obj:
		return false
	return obj is Terrain3DTextureAsset or obj is Terrain3DMeshAsset or obj is Terrain3DAssets


func _clear() -> void:
	if is_terrain_valid():
		editor.set_tool(Terrain3DEditor.TOOL_MAX)
		editor.set_operation(Terrain3DEditor.OP_MAX)
		terrain = null
		editor.set_terrain(null)
		ui.clear_picking()


func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> AfterGUIInput:
	mouse_in_main = true
	if not is_terrain_valid():
		return AFTER_GUI_INPUT_PASS

	var continue_input: AfterGUIInput = _read_input(p_event)
	## Keep the terrain clipmap/residency target in sync even while the explicit
	## None tool is selected or the viewport is handling camera navigation. The
	## edit guard below only skips hit testing and painting.
	terrain.set_camera(p_viewport_camera)
	# A release may be delivered after the cursor has left the terrain.  End
	# the native operation before trying to resolve a new hit point, otherwise
	# an invalid ray would leave the stroke open and corrupt the next undo.
	if p_event is InputEventMouseButton and p_event.is_released() and \
		p_event.get_button_index() == MOUSE_BUTTON_LEFT and editor.is_operating():
		editor.stop_operation()
		return AFTER_GUI_INPUT_STOP
	if continue_input != AFTER_GUI_INPUT_CUSTOM:
		return continue_input
	# TOOL_MAX is the toolbar's explicit None state. Let camera/navigation input
	# pass through, but never resolve a terrain hit or start an edit operation.
	if editor.get_tool() == Terrain3DEditor.TOOL_MAX:
		ui.hide_decal()
		return AFTER_GUI_INPUT_PASS
	
	## Setup active viewport
	# Always update this for all inputs, as the mouse position can move without
	# necessarily being a InputEventMouseMotion object. get_intersection() also
	# returns the last frame position, and should be updated more frequently.

	# Detect if viewport is set to half_resolution
	# Structure is: Node3DEditorViewportContainer/Node3DEditorViewport(4)/SubViewportContainer/SubViewport/Camera3D
	var input_viewport: SubViewport = p_viewport_camera.get_parent()
	var shrink: int = maxi(1, input_viewport.get_parent().stretch_shrink)
	# Scene forwards mouse events in its overlay's local coordinates. Polling
	# the SubViewport independently can return a different cursor position,
	# especially across dock/focus changes. Use the event being processed.
	if p_event is InputEventMouse:
		mouse_viewport_position = p_event.position / float(shrink)
	elif viewport != input_viewport:
		mouse_viewport_position = input_viewport.get_mouse_position() / float(shrink)
	viewport = input_viewport
	var camera_pos: Vector3 = p_viewport_camera.project_ray_origin(mouse_viewport_position)
	var camera_dir: Vector3 = p_viewport_camera.project_ray_normal(mouse_viewport_position)

	ui.update_decal()

	# Add Region must work outside the rendered terrain too. With background
	# disabled there is no geometry to GPU-pick there, so use the ground plane.
	var intersection_point: Vector3
	if editor.get_tool() == Terrain3DEditor.REGION:
		var plane_hit = Plane(Vector3.UP, 0.0).intersects_ray(camera_pos, camera_dir)
		if plane_hit == null:
			return AFTER_GUI_INPUT_PASS
		intersection_point = plane_hit
	else:
		intersection_point = terrain.get_intersection(camera_pos, camera_dir, true)
	var intersection_valid: bool = intersection_point.is_finite() and intersection_point.z < 3.4e38
	if not intersection_valid and _input_mode > 0:
		# The mouse viewport is rendered asynchronously.  Its first read after a
		# camera/position update can still contain the clear value, so do the
		# deterministic CPU raymarch for this event instead of dropping a click.
		intersection_point = terrain.get_intersection(camera_pos, camera_dir, false)
		intersection_valid = intersection_point.is_finite() and intersection_point.z < 3.4e38
	if not intersection_valid: # max double or nan
		return AFTER_GUI_INPUT_PASS
	mouse_global_position = intersection_point
	
	## Handle mouse movement
	if p_event is InputEventMouseMotion:

		if ui.live_info_panel:
			ui.live_info_panel.update(mouse_global_position)

		if _input_mode != -1: # Not cam rotation
			## Update region highlight
			var region_position: Vector2 = ( Vector2(mouse_global_position.x, mouse_global_position.z) \
				/ (terrain.get_region_size() * terrain.get_vertex_spacing()) ).floor()

			if _input_mode > 0 and editor.is_operating():
				# Inject pressure - Relies on C++ set_brush_data() using same dictionary instance
				ui.brush_data["mouse_pressure"] = p_event.pressure

				editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP
			
		return AFTER_GUI_INPUT_PASS

	if p_event is InputEventMouseButton and _input_mode > 0 and \
		p_event.get_button_index() == MOUSE_BUTTON_LEFT:
		if p_event.is_pressed():
			# If picking
			if ui.is_picking():
				ui.pick(mouse_global_position)
				if not ui.operation_builder or not ui.operation_builder.is_ready():
					return AFTER_GUI_INPUT_STOP
			
			if modifier_ctrl and editor.get_tool() == Terrain3DEditor.HEIGHT:
				var height: float = terrain.data.get_height(mouse_global_position)
				ui.brush_data["height"] = height
				ui.tool_settings.set_setting("height", height)
				
			# If adjusting regions
			if editor.get_tool() == Terrain3DEditor.REGION:
				# Skip regions that already exist or don't
				var has_region: bool = terrain.data.has_regionp(mouse_global_position)
				var op: int = editor.get_operation()
				if	( has_region and op == Terrain3DEditor.ADD) or \
					( not has_region and op == Terrain3DEditor.SUBTRACT ):
					return AFTER_GUI_INPUT_STOP
			
			# If an automatic operation is ready to go (e.g. gradient)
			if ui.operation_builder and ui.operation_builder.is_ready():
				ui.operation_builder.apply_operation(editor, mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP

			# Mouse clicked, start editing. The overlay/background pair is
			# chosen in the asset dock (left = overlay, right = background);
			# the 3D viewport always paints the selected pair with the left
			# button, while the right button keeps rotating the camera.
			editor.start_operation(mouse_global_position)
			editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
			return AFTER_GUI_INPUT_STOP
		
		# Left button released: close the stroke, which stores the undo data
		elif editor.is_operating():
			editor.stop_operation()
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


func _read_input(p_event: InputEvent = null) -> AfterGUIInput:
	## Determine if user is moving camera or applying
	var left_button_event: bool = p_event is InputEventMouseButton and \
		p_event.get_button_index() == MOUSE_BUTTON_LEFT
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or \
		left_button_event:
			_input_mode = 1 
	else:
			_input_mode = 0
	
	match get_setting("editors/3d/navigation/navigation_scheme", 0):
		2, 1: # Modo, Maya
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
	 			( Input.is_key_pressed(KEY_ALT) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) ):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				( Input.is_key_pressed(KEY_ALT) and p_event.get_button_index() == MOUSE_BUTTON_LEFT )):
					rmb_release_time = Time.get_ticks_msec()
		0, _: # Godot
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
				Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				p_event.get_button_index() == MOUSE_BUTTON_MIDDLE ):
					rmb_release_time = Time.get_ticks_msec()
	if _input_mode < 0:
		# Camera is moving, skip input
		return AFTER_GUI_INPUT_PASS

	## Determine modifiers pressed
	modifier_shift = Input.is_key_pressed(KEY_SHIFT)
	
	# Editor responds to modifier_ctrl so we must register touchscreen Invert 
	if _use_meta:
		modifier_ctrl = Input.is_key_pressed(KEY_META) || ui.inverted_input
	else:
		modifier_ctrl = Input.is_key_pressed(KEY_CTRL) || ui.inverted_input
	
	# Keybind enum: Alt,Space,Meta,Capslock
	var alt_key: int
	match get_setting("terrain3d/config/alt_key_bind", 0):
		3: alt_key = KEY_CAPSLOCK
		2: alt_key = KEY_META
		1: alt_key = KEY_SPACE
		0, _: alt_key = KEY_ALT
	modifier_alt = Input.is_key_pressed(alt_key)
	var current_mods: int = int(modifier_shift) | int(modifier_ctrl) << 1 | int(modifier_alt) << 2

	## Process Hotkeys
	if p_event is InputEventKey and \
			current_mods == 0 and \
			p_event.is_pressed() and \
			consume_hotkey(p_event):
		# Hotkey found, consume event, and stop input processing
		EditorInterface.get_editor_viewport_3d().set_input_as_handled()
		return AFTER_GUI_INPUT_STOP

	# Brush data is cleared on set_tool, or clicking textures in the asset dock
	# Update modifiers if changed or missing
	if  _last_modifiers != current_mods or not ui.brush_data.has("modifier_shift"):
		_last_modifiers = current_mods
		ui.brush_data["modifier_shift"] = modifier_shift
		ui.brush_data["modifier_ctrl"] = modifier_ctrl
		ui.brush_data["modifier_alt"] = modifier_alt
		ui.set_active_operation()

	## Continue processing input
	return AFTER_GUI_INPUT_CUSTOM


# Returns true if hotkey matches and operation triggered
func consume_hotkey(p_event: InputEventKey) -> bool:
	# Handle repeatable keys
	match p_event.keycode:
		KEY_BRACKETLEFT:
			ui.tool_settings.set_setting("size", ui.tool_settings.get_setting("size") - 1)
			return true
		KEY_BRACKETRIGHT:
			ui.tool_settings.set_setting("size", ui.tool_settings.get_setting("size") + 1)
			return true
		KEY_MINUS:
			ui.tool_settings.set_setting("strength", ui.tool_settings.get_setting("strength") - 1)
			return true
		KEY_EQUAL:
			ui.tool_settings.set_setting("strength", ui.tool_settings.get_setting("strength") + 1)
			return true
		
	if p_event.is_echo():
		return false
		
	# Handle non-repeatable keys
	match p_event.keycode:
		KEY_1, KEY_KP_1:
			terrain.set_show_region_grid(!terrain.get_show_region_grid())
		KEY_2, KEY_KP_2:
			terrain.label_distance = 4096.0 if is_zero_approx(terrain.label_distance) else 0.0 
		KEY_3, KEY_KP_3:
			terrain.material.set_show_contours(!terrain.get_show_contours())
		KEY_4, KEY_KP_4:
			terrain.set_show_slope(!terrain.get_show_slope())
		KEY_5, KEY_KP_5:
			terrain.set_show_vertex_grid(!terrain.get_show_vertex_grid())
		KEY_E:
			ui.toolbar.get_button("AddRegion").set_pressed(true)
		KEY_R:
			ui.toolbar.get_button("Raise").set_pressed(true)
		KEY_H:
			ui.toolbar.get_button("Height").set_pressed(true)
		KEY_S:
			ui.toolbar.get_button("Slope").set_pressed(true)
		KEY_C:
			ui.toolbar.get_button("PaintColor").set_pressed(true)
		KEY_N:
			ui.toolbar.get_button("PaintNavigableArea").set_pressed(true)
		KEY_I:
			ui.toolbar.get_button("InstanceMeshes").set_pressed(true)
		KEY_X:
			ui.toolbar.get_button("AddHoles").set_pressed(true)
		KEY_W:
			ui.toolbar.get_button("PaintWetness").set_pressed(true)
		KEY_B:
			ui.toolbar.get_button("PaintTexture").set_pressed(true)
		KEY_V:
			ui.toolbar.get_button("SprayTexture").set_pressed(true)
		KEY_A:
			ui.toolbar.get_button("PaintAutoshader").set_pressed(true)
		KEY_T:
			ui.tool_settings.inverse_slope_range()
		_:
			return false
	return true


func _on_scene_changed(scene_root: Node) -> void:
	if debug:
		print("Terrain3DEditorPlugin: _on_scene_changed: ", scene_root)
	if not scene_root:
		return
		
	for node in scene_root.find_children("", "Terrain3DObjects"):
		node.editor_setup(self)

	asset_dock.update_assets()


func get_terrain() -> Terrain3D:
	if is_terrain_valid():
		return terrain
	elif is_instance_valid(_last_terrain) and is_terrain_valid(_last_terrain):
		return _last_terrain
	else:
		return null


func is_terrain_valid(p_terrain: Terrain3D = null) -> bool:
	var t: Terrain3D
	if p_terrain:
		t = p_terrain
	else:
		t = terrain
	if is_instance_valid(t) and t.is_inside_tree() and t.data:
		return true
	return false


func is_selected() -> bool:
	var selected: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for node in selected:
		if ( is_instance_valid(_last_terrain) and node.get_instance_id() == _last_terrain.get_instance_id() ) or \
			node is Terrain3D:
				return true
	return false	


func select_terrain() -> void:
	if not is_instance_valid(_last_terrain) or not is_terrain_valid(_last_terrain):
		return
	# Showing the toolbar alone does not register this plugin for Scene input.
	# Re-enter the actual node editor before the caller opens the asset in the
	# Inspector; texture and mesh selection both use this path.
	if not is_terrain_valid() or not is_selected():
		var selection := EditorInterface.get_selection()
		selection.clear()
		selection.add_node(_last_terrain)
		EditorInterface.edit_node(_last_terrain)
	call_deferred("_restore_terrain_editor")

func _restore_terrain_editor() -> void:
	if not is_instance_valid(_last_terrain) or not is_terrain_valid(_last_terrain):
		return
	ui.set_visible(true)
	asset_dock.update_dock()
	_read_input()


## Editor Settings


func setup_editor_settings() -> void:
	editor_settings = EditorInterface.get_editor_settings()
	if not editor_settings.has_setting("terrain3d/config/alt_key_bind"):
		editor_settings.set("terrain3d/config/alt_key_bind", 0)
	var property_info = {
		"name": "terrain3d/config/alt_key_bind",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Alt,Space,Meta,Capslock"
	}
	editor_settings.add_property_info(property_info)
	

func set_setting(p_str: String, p_value: Variant) -> void:
	editor_settings.set_setting(p_str, p_value)


func get_setting(p_str: String, p_default: Variant) -> Variant:
	if editor_settings.has_setting(p_str):
		return editor_settings.get_setting(p_str)
	else:
		return p_default


func has_setting(p_str: String) -> bool:
	return editor_settings.has_setting(p_str)


func erase_setting(p_str: String) -> void:
	editor_settings.erase(p_str)


## Undo / Redo Functions


func create_undo_action(p_action_name: String) -> void:
	get_undo_redo().create_action(p_action_name, UndoRedo.MERGE_DISABLE, terrain)


func add_undo_method(p_method: Callable) -> void:
	var args := [ p_method.get_object(), p_method.get_method() ]
	args.append_array(p_method.get_bound_arguments())
	get_undo_redo().add_undo_method.callv(args)


func add_do_method(p_method: Callable) -> void:
	var args := [ p_method.get_object(), p_method.get_method() ]
	args.append_array(p_method.get_bound_arguments())
	get_undo_redo().add_do_method.callv(args)


func commit_action(p_execute: bool) -> void:
	get_undo_redo().commit_action(p_execute)
