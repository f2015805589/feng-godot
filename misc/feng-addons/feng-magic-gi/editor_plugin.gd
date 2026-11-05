@tool
extends EditorPlugin
## Feng Magic GI: surface PRT transport and dynamic lighting for the FRP pipeline.
## One editor integration owns MagicGI and its OLV child component.

const InspectorPlugin = preload("editor/magic_gi_inspector_plugin.gd")
const Runtime = preload("feng_magic_gi_runtime.gd")
const OLVVolume = preload("../feng-olv/feng_olv_volume.gd")
const OLVInspector = preload("../feng-olv/editor/olv_inspector.gd")
const OLVOverlay = preload("../feng-olv/editor/olv_probe_overlay.gd")
const ExclusionGizmo = preload("editor/probe_exclusion_gizmo.gd")
var _exclusion_gizmo: EditorNode3DGizmoPlugin

var _inspector_plugin
var _olv_inspector: EditorInspectorPlugin
var _editing_olv: FOLVVolume
var _registered_viewports: Array[Viewport] = []
var _olv_overlays: Dictionary = {}
var _probe_dragging := false
var _probe_drag_start := Vector2.ZERO
var _probe_drag_end := Vector2.ZERO
var _probe_drag_camera: Camera3D
var _probe_drag_mode := OLVVolume.SelectionMode.REPLACE

func _enter_tree() -> void:
	_exclusion_gizmo = ExclusionGizmo.new()
	add_node_3d_gizmo_plugin(_exclusion_gizmo)
	_inspector_plugin = InspectorPlugin.new()
	_inspector_plugin.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector_plugin)
	_olv_inspector = OLVInspector.new()
	_olv_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_olv_inspector)
	for i in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport != null:
			_registered_viewports.append(viewport)
			Runtime.register_viewport(viewport, self)
			Runtime.register_editor_preview_viewport(viewport, self, i)

func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_exclusion_gizmo)
	_exclusion_gizmo = null
	_edit(null)
	for overlay: Control in _olv_overlays.values():
		if is_instance_valid(overlay): overlay.queue_free()
	_olv_overlays.clear()
	if _olv_inspector != null:
		remove_inspector_plugin(_olv_inspector)
		_olv_inspector = null
	_editing_olv = null
	for viewport in _registered_viewports:
		if is_instance_valid(viewport):
			Runtime.unregister_editor_preview_viewport(viewport, self)
			Runtime.unregister_viewport(viewport, self)
	_registered_viewports.clear()
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

func _handles(object: Object) -> bool:
	return object is OLVVolume

func _edit(object: Object) -> void:
	_cancel_probe_drag()
	if is_instance_valid(_editing_olv):
		_editing_olv.status_changed.disconnect(_refresh_probe_overlays)
		_editing_olv.selection_changed.disconnect(_refresh_probe_overlays)
	_editing_olv = object as FOLVVolume
	if is_instance_valid(_editing_olv):
		_editing_olv.status_changed.connect(_refresh_probe_overlays)
		_editing_olv.selection_changed.connect(_refresh_probe_overlays)
	_refresh_probe_overlays()

func _make_visible(visible: bool) -> void:
	if not visible:
		_edit(null)

func _probe_edit_active() -> bool:
	return is_instance_valid(_editing_olv) and _editing_olv.show_probes \
		and EditorInterface.get_selection().get_selected_nodes().has(_editing_olv)

func _refresh_probe_overlays() -> void:
	var active := is_instance_valid(_editing_olv) and _editing_olv.show_probes
	for overlay: Control in _olv_overlays.values():
		if not is_instance_valid(overlay): continue
		overlay.visible = active
		overlay.node = _editing_olv
		overlay.queue_redraw()
	update_overlays()

func _cancel_probe_drag() -> void:
	_probe_dragging = false
	_probe_drag_camera = null
	update_overlays()

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _probe_edit_active():
		if _probe_dragging: _cancel_probe_drag()
		return AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _probe_dragging: _cancel_probe_drag()
			else: _editing_olv.clear_probe_selection()
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_A and (event.ctrl_pressed or event.meta_pressed):
			_editing_olv.select_probes(_editing_olv.get_visible_probe_view(camera).get("indices",PackedInt32Array()))
			return AFTER_GUI_INPUT_STOP
	# Leave orbit, pan and right-button fly navigation to the editor.
	if event is InputEventMouse and (event.alt_pressed or (event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) != 0):
		if _probe_dragging: _cancel_probe_drag()
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion and _probe_dragging:
		_probe_drag_end = event.position
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return AFTER_GUI_INPUT_PASS
	if event.pressed:
		if _editing_olv.get_probe_view().is_empty(): return AFTER_GUI_INPUT_PASS
		_probe_dragging = true
		_probe_drag_start = event.position
		_probe_drag_end = event.position
		_probe_drag_camera = camera
		_probe_drag_mode = OLVVolume.SelectionMode.TOGGLE if event.ctrl_pressed or event.meta_pressed \
			else OLVVolume.SelectionMode.ADD if event.shift_pressed else OLVVolume.SelectionMode.REPLACE
		return AFTER_GUI_INPUT_STOP
	if _probe_dragging:
		if not is_instance_valid(_probe_drag_camera):
			_cancel_probe_drag()
			return AFTER_GUI_INPUT_PASS
		_probe_drag_end = event.position
		if _probe_drag_start.distance_squared_to(_probe_drag_end) >= 25.0:
			_editing_olv.select_screen_rect(_probe_drag_camera, Rect2(_probe_drag_start, _probe_drag_end - _probe_drag_start), _probe_drag_mode)
		else:
			var nearest := _editing_olv.pick_probe(_probe_drag_camera, _probe_drag_end)
			_editing_olv.select_probes(PackedInt32Array([nearest]) if nearest >= 0 else PackedInt32Array(), _probe_drag_mode)
		_cancel_probe_drag()
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if _probe_edit_active():
		for viewport in _registered_viewports:
			if not is_instance_valid(viewport) or viewport.get_parent().get_parent() != overlay.get_parent(): continue
			var key := viewport.get_instance_id()
			var display: Control = _olv_overlays.get(key)
			if not is_instance_valid(display):
				display = OLVOverlay.new()
				display.name = "OLVProbeOverlay"
				overlay.add_child(display)
				display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				_olv_overlays[key] = display
			display.node = _editing_olv
			display.camera = viewport.get_camera_3d()
			display.show()
			break
	if not _probe_dragging or not is_instance_valid(_probe_drag_camera): return
	# Each split viewport has its own overlay; do not draw the marquee in all four.
	var viewport := _probe_drag_camera.get_viewport()
	if viewport.get_parent() == null or viewport.get_parent().get_parent() != overlay.get_parent(): return
	if _probe_drag_start.distance_squared_to(_probe_drag_end) < 25.0: return
	var rect := Rect2(_probe_drag_start, _probe_drag_end - _probe_drag_start).abs()
	overlay.draw_rect(rect, Color(0.3, 0.7, 1.0, 0.12))
	overlay.draw_rect(rect, Color(0.65, 0.85, 1.0), false, 1.0)
