extends SceneTree
## A categorical texel must not contain transfer fitted from the other side of
## a roof/wall, even when both disconnected spaces share the indoor OLV label.
const Builder = preload("../feng_magic_gi_clv_transfer_builder.gd")
const Boundary = preload("../feng_magic_gi_boundary_tensor_builder.gd")
const Placement = preload("../feng_magic_gi_placement.gd")
const Volume = preload("../feng_magic_gi_volume.gd")

class ConstraintBuilder extends Builder:
	func _gather(_query: Vector3, _surface: Vector3, _normal: Vector3) -> PackedFloat32Array:
		# Keep the real constraint collection, side/segment checks and rank fit
		# selection, without tracing the unrelated radiance integration paths.
		return PackedFloat32Array([1.0])

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var volume := Volume.new()
	volume.size = Vector3(6, 6, 6)
	scene.add_child(volume)
	_add_box(scene, "Roof", Vector3(4.4, 0.2, 5), Vector3(0, 3.1, 0))
	_add_box(scene, "Left", Vector3(0.2, 3.2, 5), Vector3(-2.2, 1.6, 0))
	_add_box(scene, "Back", Vector3(4.4, 3.2, 0.2), Vector3(0, 1.6, -2.5))
	await process_frame
	var builder := _builder(volume)
	_check(builder != null, "capture thin roof and intersecting walls")
	if builder == null:
		quit(1)
		return
	var inside := Vector3(-1.775, 2.975, -2.075)
	var rows: Array[Dictionary] = builder._collect_constraints(inside, 0.25, inside)
	_check(rows.size() == 3, "interior corner keeps roof underside and two room-facing walls")
	for row in rows:
		_check(row.normal.dot(inside - row.surface_point) >= -0.00001,
			"interior source never fits a backside surface")
	_check(not _contains_normal(rows, Vector3.UP), "sunlit roof exterior cannot enter an indoor texel")
	_check(not _contains_normal(rows, Vector3.LEFT), "outer left wall cannot enter an indoor texel")
	_check(not _contains_normal(rows, Vector3.FORWARD), "outer back wall cannot enter an indoor texel")
	var above := Vector3(-1.775, 3.225, -2.075)
	rows = builder._collect_constraints(above, 0.25, above)
	_check(_contains_normal(rows, Vector3.UP), "outdoor source retains the roof exterior")
	_check(not _contains_normal(rows, Vector3.DOWN), "outdoor source never fits the underside through the slab")
	# Both rooms can legitimately be labelled indoor. A front-facing surface in
	# the second room must still fail the geometric connection check.
	_add_box(scene, "Partition", Vector3(0.02, 2.8, 4), Vector3(0, 1.4, 0))
	await process_frame
	builder = _builder(volume)
	_check(not builder._constraint_reachable(Vector3(-0.1, 1, 0), Vector3(0.2, 0, 0), Vector3.UP),
		"same-domain floor across a thin partition is occluded")
	_check(builder._constraint_reachable(Vector3(-0.1, 1, 0), Vector3(-0.2, 0, 0), Vector3.UP),
		"the floor on the source side remains reachable")
	rows = builder._collect_constraints(Vector3(-2.2, 2.975, -2.075), 0.25)
	_check(not (_contains_normal(rows, Vector3.RIGHT) and _contains_normal(rows, Vector3.LEFT)),
		"invalid extrapolation centers choose one connected side of a slab")
	print("CLV_CONSTRAINT_CONNECTIVITY_TESTS ", JSON.stringify({"checks":checks,"failures":failures}))
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func _builder(volume: Node3D) -> ConstraintBuilder:
	var geometry := Placement.new()
	if not geometry.collect(volume, true, true, true, false, AABB(Vector3(-6,-6,-6),Vector3(12,12,12))):
		return null
	var builder := ConstraintBuilder.new()
	builder._geometry = geometry
	builder._stats = {"constraint_candidates":0,"rank_selected_constraints":0,"rank_dropped_constraints":0}
	for record in geometry.get("_occlusion_volumes"):
		var solid := {"faces":record.faces,"bounds":record.world_aabb,"bvh":record.bvh}
		solid["box"] = Boundary._is_full_axis_aligned_box(solid,Boundary._build_axis_face_pairs(solid))
		builder._solids.append(solid)
	return builder

func _contains_normal(rows: Array[Dictionary], normal: Vector3) -> bool:
	for row in rows:
		if row.normal.dot(normal) > 0.99: return true
	return false

func _add_box(scene: Node, node_name: String, size: Vector3, position: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = position
	scene.add_child(node)

func _check(passed: bool, message: String) -> void:
	checks += 1
	if not passed:
		failures += 1
		push_error(message)
