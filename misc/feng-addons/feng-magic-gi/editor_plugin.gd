@tool
extends EditorPlugin
## Feng Magic GI: surface PRT transport and dynamic lighting for the FRP pipeline.
## One editor integration owns MagicGI and its OLV child component.

const InspectorPlugin = preload("editor/magic_gi_inspector_plugin.gd")
const Runtime = preload("feng_magic_gi_runtime.gd")
const OLVVolume = preload("../feng-olv/feng_olv_volume.gd")
const OLVInspector = preload("../feng-olv/editor/olv_inspector.gd")
const OLVGizmo = preload("../feng-olv/editor/olv_gizmo.gd")

var _inspector_plugin
var _olv_inspector: EditorInspectorPlugin
var _olv_gizmo: EditorNode3DGizmoPlugin
var _editing_olv: FOLVVolume
var _registered_viewports: Array[Viewport] = []

func _enter_tree() -> void:
	_inspector_plugin = InspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)
	_olv_inspector = OLVInspector.new()
	_olv_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_olv_inspector)
	_olv_gizmo = OLVGizmo.new()
	add_node_3d_gizmo_plugin(_olv_gizmo)
	for i in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport != null:
			_registered_viewports.append(viewport)
			Runtime.register_viewport(viewport, self)
			Runtime.register_editor_preview_viewport(viewport, self, i)

func _exit_tree() -> void:
	if _olv_gizmo != null:
		remove_node_3d_gizmo_plugin(_olv_gizmo)
		_olv_gizmo = null
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
	_editing_olv = object as FOLVVolume

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not is_instance_valid(_editing_olv) or not _editing_olv.edit_probes or not _editing_olv.show_probes:
		return AFTER_GUI_INPUT_PASS
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed or event.alt_pressed:
		return AFTER_GUI_INPUT_PASS
	var source := _editing_olv.get_probe_source()
	if source == null: return AFTER_GUI_INPUT_PASS
	var nearest := -1
	var best := 144.0
	var nearest_depth := INF
	for index in source.probe_count:
		if not source.cell_is_valid(index): continue
		var point: Vector3 = source.cell_position(index)
		if camera.is_position_behind(point): continue
		var distance := camera.unproject_position(point).distance_squared_to(event.position)
		var depth := camera.global_position.distance_squared_to(point)
		if distance < best-0.01 or absf(distance-best) < 0.01 and depth < nearest_depth:
			best = distance
			nearest_depth = depth
			nearest = index
	if nearest < 0: return AFTER_GUI_INPUT_PASS
	_editing_olv.select_probe(nearest,event.ctrl_pressed or event.meta_pressed or event.shift_pressed)
	return AFTER_GUI_INPUT_STOP
