@tool
extends EditorNode3DGizmoPlugin
## Draws the finite influence region of a FengVolume in the 3D editor.
##
## FengVolume.influence_at() uses the distance to the nearest box face. This is
## therefore an axis-aligned box transition in the volume's local space, rather
## than a rounded or spherical falloff. The two wireframes below are the exact
## boundaries of that transition: influence 0 at `size`, and normalized influence
## 1 at `size - 2 * blend_distance`.

const Volume = preload("feng_volume.gd")

const BOX_EDGES := [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]

func _init() -> void:
	# The materials are deliberately different so the full-influence boundary
	# remains readable when it coincides with the zero-influence boundary.
	create_material("influence_zero", Color(0.25, 0.65, 1.0, 0.9), false, true)
	create_material("influence_one", Color(1.0, 0.72, 0.25, 0.95), false, true)
	create_material("influence_transition", Color(0.8, 0.45, 1.0, 0.85), false, true)

func _get_gizmo_name() -> String:
	return "FengVolume"

func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is Volume

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()

	var volume := gizmo.get_node_3d()
	if volume == null or not volume is Volume or volume.unbound:
		# An unbound volume has no finite boundary to draw.
		return

	var geometry := _volume_geometry(volume)
	var zero_lines: PackedVector3Array = geometry["zero"]
	if zero_lines.is_empty():
		return
	gizmo.add_lines(zero_lines, get_material("influence_zero", gizmo))
	# Make the finite volume selectable through its outer boundary as well as
	# through the scene tree. The inner boundary is visual only.
	gizmo.add_collision_segments(zero_lines)

	var one_lines: PackedVector3Array = geometry["one"]
	if not one_lines.is_empty():
		gizmo.add_lines(one_lines, get_material("influence_one", gizmo))

	var transition_lines: PackedVector3Array = geometry["transition"]
	if not transition_lines.is_empty():
		gizmo.add_lines(transition_lines, get_material("influence_transition", gizmo))

func _volume_geometry(volume) -> Dictionary:
	var geometry := {
		"zero": PackedVector3Array(),
		"one": PackedVector3Array(),
		"transition": PackedVector3Array(),
	}
	if volume == null or volume.unbound:
		return geometry

	var zero_lines := _box_lines(volume.get_influence_zero_size())
	if zero_lines.is_empty():
		return geometry
	geometry["zero"] = zero_lines
	geometry["one"] = _box_lines(volume.get_influence_one_size())
	geometry["transition"] = _transition_lines(volume)
	return geometry

func _transition_lines(volume) -> PackedVector3Array:
	if volume == null or volume.unbound or volume.blend_distance <= 0.0:
		return PackedVector3Array()
	return _corner_lines(volume.get_influence_zero_size(), volume.get_influence_one_size())

func _corner_lines(outer_size: Vector3, inner_size: Vector3) -> PackedVector3Array:
	var outer_corners := _box_corners(outer_size)
	var inner_corners := _box_corners(inner_size)
	if outer_corners.is_empty() or inner_corners.is_empty():
		return PackedVector3Array()

	var lines := PackedVector3Array()
	for i in outer_corners.size():
		lines.append(outer_corners[i])
		lines.append(inner_corners[i])
	return lines

func _box_lines(box_size: Vector3) -> PackedVector3Array:
	var corners := _box_corners(box_size)
	if corners.is_empty():
		return PackedVector3Array()

	var lines := PackedVector3Array()
	for edge in BOX_EDGES:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])
	return lines

func _box_corners(box_size: Vector3) -> Array:
	if box_size.x <= 0.0 or box_size.y <= 0.0 or box_size.z <= 0.0:
		return []

	var half := box_size * 0.5
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
