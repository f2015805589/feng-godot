extends SceneTree
## Receiver footprint must preserve smooth transport and never cross a wall.
const Builder = preload("../feng_magic_gi_clv_transfer_builder.gd")
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Placement = preload("../feng_magic_gi_placement.gd")
const Volume = preload("../feng_magic_gi_volume.gd")

class AnalyticBuilder extends Builder:
	var traced_rays := 0
	var points: Array[Vector3] = []
	func _bake_direct_surface_target(point: Vector3, _normal: Vector3, sample_count := 0,
			_sampling_stratum := 0) -> Dictionary:
		traced_rays += sample_count if sample_count > 0 else int(_source.bake_samples)
		points.append(point)
		return {"ok": true, "columns": PackedFloat64Array([1.0, 2.0 + point.x])}

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var volume := Volume.new()
	volume.size = Vector3(4.0, 2.0, 4.0)
	scene.add_child(volume)
	_add_box(scene, "Floor", Vector3(4, 0.1, 4), Vector3(0, -0.05, 0))
	await process_frame
	var geometry := Placement.new()
	_check(geometry.collect(volume, true, true, true, false, AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))), "collect floor")
	var source := Chunk.new()
	source.bake_samples = 17
	var builder := AnalyticBuilder.new()
	builder.set("_source", source)
	builder.set("_geometry", geometry)
	builder.set("_columns", 2)
	var constraint := {"surface_point": Vector3(0.01, 0, 0), "normal": Vector3.UP,
		"face_bounds": AABB(Vector3(-2, -0.1, -2), Vector3(4, 0.1, 4))}
	var result: Dictionary = builder.call("_bake_surface_footprint_target", constraint, 0.25)
	_check(result.ok and builder.points.size() == 4, "flat receiver has a complete footprint")
	_check(absf(result.columns[0] - 1.0) < 0.000001, "constant transport is preserved exactly")
	_check(absf(result.columns[1] - 2.01) < 0.000001, "linear transport is reproduced without spatial bias")
	_check(builder.traced_rays == 17, "quadrature splits the requested ray budget including its remainder")

	_add_box(scene, "ThinWall", Vector3(0.01, 0.5, 1), Vector3(0.03, 0.25, 0))
	await process_frame
	geometry = Placement.new()
	_check(geometry.collect(volume, true, true, true, false, AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))), "collect thin wall")
	builder.set("_geometry", geometry)
	builder.points.clear()
	builder.traced_rays = 0
	result = builder.call("_bake_surface_footprint_target", constraint, 0.25)
	var crosses_wall := false
	for point in builder.points: crosses_wall = crosses_wall or point.x > 0.025
	_check(not crosses_wall and builder.points.size() == 2, "occluded footprint taps do not borrow light through a thin wall")
	_check(absf(result.columns[0] - 1.0) < 0.000001, "valid taps renormalize instead of darkening contact edges")
	_check(builder.traced_rays == 17, "rejected taps redistribute the same budget to connected surface samples")
	var full_coordinates: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
	for index in 17:
		full_coordinates[0].append((index + 0.5) / 17.0)
		full_coordinates[1].append(index / 17.0)
	builder.set("_surface_coordinates", full_coordinates)
	var split: Array[PackedFloat64Array] = builder.call("_surface_sampling_coordinates", 4)
	_check(split[0] == PackedFloat64Array([0.125, 0.375, 0.625, 0.875]),
		"split Hammersley sequences still cover the complete hemisphere/sphere")
	_check(split[1] == full_coordinates[1], "count-independent radical inverse dimensions remain shared")
	print("CLV_SURFACE_FOOTPRINT_TESTS ", JSON.stringify({"checks": checks, "failures": failures}))
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func _add_box(scene: Node, node_name: String, size: Vector3, position: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = position
	scene.add_child(node)

func _check(passed: bool, message: String) -> void:
	checks += 1
	if not passed:
		failures += 1
		push_error(message)
