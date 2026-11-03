extends SceneTree
var failures := 0
func _init() -> void: _run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value: failures += 1; print("FAIL: ", message)
func _run() -> void:
	var ps := PhysicsServer3D
	var space := ps.space_create()
	var body := ps.body_create()
	var other := ps.body_create()
	var area := ps.area_create()
	ps.body_set_space(body, space)
	ps.body_set_space(other, space)
	ps.area_set_space(area, space)
	var shared := ps.box_shape_create()
	ps.shape_set_data(shared, Vector3.ONE)
	ps.body_add_shape(body, shared)
	ps.body_add_shape(body, shared, Transform3D(Basis.IDENTITY, Vector3(4, 0, 0)))
	ps.body_add_shape(other, shared)
	ps.area_add_shape(area, shared)
	ps.free_rid(shared)
	check(ps.body_get_shape_count(body) == 0, "freeing a shape detaches both instances from one body")
	check(ps.body_get_shape_count(other) == 0, "freeing a shared shape detaches the other body")
	check(ps.area_get_shape_count(area) == 0, "freeing a shared shape detaches areas")
	if failures > 0:
		# Old adapter keeps dangling attachments. Clear them before freeing the
		# owners, so this regression reports failure instead of spinning forever.
		ps.body_clear_shapes(body); ps.body_clear_shapes(other); ps.area_clear_shapes(area)
		ps.free_rid(body); ps.free_rid(other); ps.free_rid(area); ps.free_rid(space)
		print("RESULT: FAIL"); quit(1); return
	var first := ps.box_shape_create()
	var replacement := ps.sphere_shape_create()
	ps.shape_set_data(first, Vector3.ONE)
	ps.shape_set_data(replacement, 0.5)
	ps.body_add_shape(body, first)
	ps.body_add_shape(body, first)
	ps.body_set_shape(body, 0, replacement)
	ps.body_remove_shape(body, 1)
	ps.free_rid(first)
	check(ps.body_get_shape_count(body) == 1 and ps.body_get_shape(body, 0) == replacement, "removed/replaced shape has no stale owner")
	ps.body_add_shape(other, replacement)
	ps.free_rid(other)
	ps.free_rid(replacement)
	check(ps.body_get_shape_count(body) == 0, "owner destruction unregisters shared-shape ownership")
	# Terrain3DCollision frees each heightmap RID before freeing its static body.
	var heightmap := ps.heightmap_shape_create()
	ps.shape_set_data(heightmap, {"width": 3, "depth": 3, "heights": PackedFloat32Array([0,0,0,0,0,0,0,0,0]), "min_height": 0.0, "max_height": 0.0})
	ps.body_add_shape(body, heightmap)
	ps.free_rid(heightmap)
	check(ps.body_get_shape_count(body) == 0, "terrain heightmap cleanup terminates")
	ps.free_rid(body); ps.free_rid(area); ps.free_rid(space)
	print("RESULT: PASS" if failures == 0 else "RESULT: FAIL")
	quit(0 if failures == 0 else 1)
