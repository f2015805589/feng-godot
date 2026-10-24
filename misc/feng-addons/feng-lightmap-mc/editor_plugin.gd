@tool
extends EditorPlugin

const VolumeGizmo = preload("editor/feng_lightmap_volume_gizmo.gd")

var _volume_gizmo: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_volume_gizmo = VolumeGizmo.new()
	add_node_3d_gizmo_plugin(_volume_gizmo)


func _exit_tree() -> void:
	if _volume_gizmo != null:
		remove_node_3d_gizmo_plugin(_volume_gizmo)
		_volume_gizmo = null
