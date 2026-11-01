extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(passed: bool, message: String) -> void:
	if not passed:
		_failures += 1
		push_error(message)


func _run() -> void:
	var floor_body := StaticBody3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(10, 1, 10)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	floor_body.add_child(collision)
	floor_body.position.y = -0.5
	root.add_child(floor_body)
	await physics_frame
	await physics_frame
	var space := root.world_3d.direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(Vector3(0, 5, 0), Vector3(0, -5, 0))
	var hit := space.intersect_ray(ray)
	_check(not hit.is_empty() and hit.get("collider") == floor_body, "Ray did not return the collider node")
	if not hit.is_empty():
		_check(absf(hit.position.y) < 0.01 and hit.normal.dot(Vector3.UP) > 0.99, "Invalid ray position/normal")
	ray.exclude = [floor_body.get_rid()]
	_check(space.intersect_ray(ray).is_empty(), "Ray exclusions were ignored")
	ray.exclude = []
	ray.collision_mask = 2
	_check(space.intersect_ray(ray).is_empty(), "Ray collision mask was ignored")
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform.origin = Vector3(0, 2, 0)
	query.motion = Vector3(0, -4, 0)
	var fractions := space.cast_motion(query)
	_check(fractions.size() == 2 and absf(fractions[0] - 0.375) < 0.02, "Shape cast returned an invalid collision fraction")
	query.transform.origin.y = 0.25
	query.motion = Vector3.ZERO
	var overlaps := space.intersect_shape(query)
	_check(overlaps.size() == 1 and overlaps[0].get("collider") == floor_body, "Shape overlap did not return the collider node")
	var point_query := PhysicsPointQueryParameters3D.new()
	point_query.position = Vector3(0, -0.25, 0)
	var points := space.intersect_point(point_query)
	_check(points.size() == 1 and points[0].get("collider") == floor_body, "Point overlap did not return the collider node")
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	collision.shape = mesh.create_trimesh_shape()
	await physics_frame
	ray.collision_mask = 1
	hit = space.intersect_ray(ray)
	_check(not hit.is_empty() and hit.get("face_index", -1) >= 0, "Mesh ray did not return its triangle index")
	floor_body.queue_free()
	await process_frame
	print("RESULT: PASS - ray, mask, exclude, shape cast, point/shape overlap and mesh face queries" if _failures == 0 else "RESULT: FAIL - space queries")
	quit(0 if _failures == 0 else 1)
