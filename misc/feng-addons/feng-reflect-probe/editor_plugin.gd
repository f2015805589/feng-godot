@tool
extends EditorPlugin
## The Node3D is registered through its global script class. This plugin only adds
## explicit capture and bake actions to its Inspector.

const InspectorPlugin = preload("editor/feng_reflect_probe_inspector.gd")
const GizmoPlugin = preload("editor/feng_reflect_probe_gizmo.gd")

var _inspector_plugin: EditorInspectorPlugin
var _gizmo_plugin: EditorNode3DGizmoPlugin

func _enter_tree() -> void:
	_inspector_plugin = InspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)
	_gizmo_plugin = GizmoPlugin.new()
	add_node_3d_gizmo_plugin(_gizmo_plugin)

func _exit_tree() -> void:
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_gizmo_plugin)
		_gizmo_plugin = null
