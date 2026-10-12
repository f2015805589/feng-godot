@tool
extends EditorNode3DGizmoPlugin
## Visualizes the probe's local influence box and its offset capture origin.

const Probe = preload("../feng_reflect_probe.gd")
const BOX_EDGES := [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]

func _init() -> void:
	create_material("probe_box", Color(0.3, 0.8, 1.0, 0.9), false, true)
	create_material("capture_origin", Color(1.0, 0.68, 0.22, 1.0), false, true)
	create_icon_material("probe_icon",
			EditorInterface.get_editor_theme().get_icon("GizmoReflectionProbe", "EditorIcons"))

func _get_gizmo_name() -> String:
	return "FengReflectProbe"

func _has_gizmo(node: Node3D) -> bool:
	return node is Probe

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var probe := gizmo.get_node_3d()
	if probe == null or not probe is Probe:
		return
	# Like the native ReflectionProbe gizmo, keep an unscaled, selectable icon at
	# the node origin even when the probe is disabled or its box is not drawable.
	gizmo.add_unscaled_billboard(get_material("probe_icon", gizmo), 0.05)
	if not EditorInterface.get_selection().get_selected_nodes().has(probe):
		return
	var size: Vector3 = probe.box_size
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return
	var corners := _box_corners(size)
	var lines := PackedVector3Array()
	for edge in BOX_EDGES:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])
	gizmo.add_lines(lines, get_material("probe_box", gizmo))
	gizmo.add_collision_segments(lines)
	var center: Vector3 = probe.capture_position_offset
	var radius := maxf(minf(size.x, minf(size.y, size.z)) * 0.035, 0.08)
	var origin := PackedVector3Array([
		center + Vector3(-radius, 0, 0), center + Vector3(radius, 0, 0),
		center + Vector3(0, -radius, 0), center + Vector3(0, radius, 0),
		center + Vector3(0, 0, -radius), center + Vector3(0, 0, radius),
		Vector3.ZERO, center,
	])
	gizmo.add_lines(origin, get_material("capture_origin", gizmo))

func _box_corners(size: Vector3) -> Array:
	var half := size * 0.5
	return [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, -half.z),
		Vector3(-half.x, half.y, -half.z),
		Vector3(half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z),
		Vector3(half.x, -half.y, half.z),
		Vector3(-half.x, half.y, half.z),
		Vector3(half.x, half.y, half.z),
	]
