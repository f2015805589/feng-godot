@tool
extends EditorPlugin
## Headless editor test for the FengVolume influence gizmo geometry.

const Gizmo = preload("res://addons/feng-render-pipeline/volume/feng_volume_gizmo.gd")
const Volume = preload("res://addons/feng-render-pipeline/volume/feng_volume.gd")

const BOX_EDGES := [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]

var _failures: Array[String] = []

func _enter_tree() -> void:
	_run.call_deferred()

func _run() -> void:
	var gizmo := Gizmo.new()
	var volume := Volume.new()
	volume.size = Vector3(10.0, 8.0, 6.0)
	volume.blend_distance = 1.0

	var geometry: Dictionary = gizmo._volume_geometry(volume)
	var zero_lines: PackedVector3Array = geometry["zero"]
	var one_lines: PackedVector3Array = geometry["one"]
	var transition_lines: PackedVector3Array = geometry["transition"]
	_check_box_lines(zero_lines, gizmo._box_corners(volume.get_influence_zero_size()), "influence-0")
	_check_box_lines(one_lines, gizmo._box_corners(volume.get_influence_one_size()), "influence-1")
	_check(transition_lines.size() == 16, "corner connectors must contain 8 segments / 16 vertices")

	var outer_corners: Array = gizmo._box_corners(volume.get_influence_zero_size())
	var inner_corners: Array = gizmo._box_corners(volume.get_influence_one_size())
	_check(outer_corners.size() == 8, "influence-0 box must have 8 corners")
	_check(inner_corners.size() == 8, "influence-1 box must have 8 corners")
	for corner in 8:
		_check(
			_vector_matches(transition_lines[corner * 2], outer_corners[corner]),
			"connector %d does not start at its corresponding outer corner" % corner
		)
		_check(
			_vector_matches(transition_lines[corner * 2 + 1], inner_corners[corner]),
			"connector %d does not end at its corresponding inner corner" % corner
		)

	# A zero or negative blend has coincident influence boundaries and must not
	# add connector lines. The two boxes themselves remain valid.
	volume.blend_distance = 0.0
	geometry = gizmo._volume_geometry(volume)
	_check((geometry["zero"] as PackedVector3Array).size() == 24, "zero-blend outer box disappeared")
	_check((geometry["one"] as PackedVector3Array).size() == 24, "zero-blend inner box disappeared")
	_check((geometry["transition"] as PackedVector3Array).is_empty(), "zero blend added corner connectors")
	volume.blend_distance = -1.0
	geometry = gizmo._volume_geometry(volume)
	_check((geometry["transition"] as PackedVector3Array).is_empty(), "negative blend added corner connectors")

	# Unbound volumes have no finite editor boundary.
	volume.blend_distance = 1.0
	volume.unbound = true
	geometry = gizmo._volume_geometry(volume)
	_check((geometry["zero"] as PackedVector3Array).is_empty(), "unbound volume drew an influence-0 box")
	_check((geometry["one"] as PackedVector3Array).is_empty(), "unbound volume drew an influence-1 box")
	_check((geometry["transition"] as PackedVector3Array).is_empty(), "unbound volume drew corner connectors")

	# Non-positive dimensions are not finite runtime volumes and have no gizmo geometry.
	volume.unbound = false
	volume.size = Vector3(-1.0, 8.0, 6.0)
	geometry = gizmo._volume_geometry(volume)
	_check((geometry["zero"] as PackedVector3Array).is_empty(), "invalid volume drew an influence-0 box")
	_check((geometry["one"] as PackedVector3Array).is_empty(), "invalid volume drew an influence-1 box")
	_check((geometry["transition"] as PackedVector3Array).is_empty(), "invalid volume drew corner connectors")

	# When the fade is wider than the shortest half-extent, no 3D influence-1
	# box exists, so neither its frame nor its connectors are drawn.
	volume.size = Vector3(10.0, 8.0, 6.0)
	volume.blend_distance = 4.0
	geometry = gizmo._volume_geometry(volume)
	_check((geometry["zero"] as PackedVector3Array).size() == 24, "wide-blend outer box disappeared")
	_check((geometry["one"] as PackedVector3Array).is_empty(), "wide-blend degenerate inner box was drawn")
	_check((geometry["transition"] as PackedVector3Array).is_empty(), "wide-blend volume drew corner connectors")

	volume.free()
	_finish()

func _vector_matches(first: Vector3, second: Vector3) -> bool:
	return first.distance_to(second) <= 0.00001

func _check_box_lines(lines: PackedVector3Array, corners: Array, label: String) -> void:
	_check(lines.size() == 24, "%s box must contain 12 segments / 24 vertices" % label)
	if lines.size() != 24 or corners.size() != 8:
		return
	for edge in BOX_EDGES.size():
		var pair: Array = BOX_EDGES[edge]
		_check(_vector_matches(lines[edge * 2], corners[pair[0]]), "%s edge %d has the wrong start corner" % [label, edge])
		_check(_vector_matches(lines[edge * 2 + 1], corners[pair[1]]), "%s edge %d has the wrong end corner" % [label, edge])

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _finish() -> void:
	if _failures.is_empty():
		print("PASS FRP Volume gizmo boxes, corresponding corner connectors and boundary semantics")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("FRP Volume gizmo: " + failure)
	get_tree().quit(1)
