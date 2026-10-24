@tool
extends EditorNode3DGizmoPlugin
## Shows the editable receiver volume in the 3D editor.

const Volume = preload("../feng_lightmap_volume.gd")
const BOX_EDGES := [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]


func _init() -> void:
	create_material("receiver_bounds", Color(0.25, 0.9, 0.55, 0.95), false, true)


func _get_gizmo_name() -> String:
	return "FengLightmapVolume"


func _has_gizmo(node: Node3D) -> bool:
	return node is Volume


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var volume := gizmo.get_node_3d()
	if volume == null or not volume is Volume:
		return
	var box: AABB = volume.bounds
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return
	var corners := _box_corners(box)
	var lines := PackedVector3Array()
	for edge in BOX_EDGES:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])
	gizmo.add_lines(lines, get_material("receiver_bounds", gizmo))
	gizmo.add_collision_segments(lines)


func _box_corners(box: AABB) -> Array[Vector3]:
	var end := box.position + box.size
	return [
		Vector3(box.position.x, box.position.y, box.position.z),
		Vector3(end.x, box.position.y, box.position.z),
		Vector3(box.position.x, end.y, box.position.z),
		Vector3(end.x, end.y, box.position.z),
		Vector3(box.position.x, box.position.y, end.z),
		Vector3(end.x, box.position.y, end.z),
		Vector3(box.position.x, end.y, end.z),
		Vector3(end.x, end.y, end.z),
	]
