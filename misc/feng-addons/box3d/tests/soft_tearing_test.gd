extends SceneTree
const Soft = preload("res://addons/box3d/soft_body_3d.gd")
var failed := false
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, text: String) -> void:
	print("SOFT_TEAR ",text," ",ok)
	failed = failed or not ok
func run() -> void:
	PhysicsServer3D.area_set_param(root.world_3d.space, PhysicsServer3D.AREA_PARAM_GRAVITY, 0.0)
	var source := PlaneMesh.new()
	source.size = Vector2(2,2)
	var mesh := Soft.make_tearable_mesh(source)
	check(mesh != null and mesh.surface_get_array_len(0)==6, "tear layout reserves triangle-corner vertices")
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var scaled := PhysicsServer3D.soft_body_create()
	PhysicsServer3D.soft_body_set_mesh(scaled, mesh.get_rid())
	PhysicsServer3D.soft_body_set_space(scaled, root.world_3d.space)
	PhysicsServer3D.call("soft_body_configure", scaled, {"tearing":true,"tear_ratio":1.1})
	PhysicsServer3D.soft_body_set_state(scaled, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis.from_scale(Vector3(3,3,3)), Vector3.ZERO))
	for i in vertices.size(): PhysicsServer3D.soft_body_pin_point(scaled,i,true)
	for i in 2: await physics_frame
	check(PhysicsServer3D.call("soft_body_get_statistics",scaled).torn_seams==0, "world scaling does not falsely tear intact mesh")
	PhysicsServer3D.free_rid(scaled)
	for automatic in [false,true]:
		var body := PhysicsServer3D.soft_body_create()
		PhysicsServer3D.call("soft_body_configure", body, {"tearing":true})
		PhysicsServer3D.soft_body_set_mesh(body,mesh.get_rid())
		check(PhysicsServer3D.call("soft_body_get_statistics",body).tearing_enabled,"configuration survives deferred mesh submission")
		PhysicsServer3D.soft_body_set_total_mass(body,2.0)
		PhysicsServer3D.soft_body_set_space(body,root.world_3d.space)
		PhysicsServer3D.call("soft_body_configure",body,{"tearing":true,"self_collision":false,"tear_ratio":1.1})
		var before: Dictionary = PhysicsServer3D.call("soft_body_get_statistics",body)
		check(before.particles==4 and before.tearing_enabled,"initial visual seam is welded")
		if automatic:
			for i in vertices.size():
				PhysicsServer3D.soft_body_move_point(body,i,vertices[i]*3.0)
			for i in 2: await physics_frame
		else:
			var cut: int = PhysicsServer3D.call("soft_body_cut",body,Vector3(-2,0,0),Vector3(2,0,0),0.05)
			check(cut==1,"cut finds shared seam")
		var after: Dictionary = PhysicsServer3D.call("soft_body_get_statistics",body)
		check(after.torn_seams==1 and after.particles==6,"strain/cut separates triangle topology")
		check(absf(after.particle_mass_sum-2.0)<0.0001,"splitting conserves particle mass")
		if not automatic:
			PhysicsServer3D.call("soft_body_configure", body, {"self_collision":true})
			for i in 30: await physics_frame
			check(PhysicsServer3D.soft_body_get_bounds(body).size.length()<3.1,"new crack twins do not explode under self collision")
		var pair := Vector2i(-1,-1)
		for i in vertices.size():
			for j in range(i+1,vertices.size()):
				if vertices[i].is_equal_approx(vertices[j]): pair=Vector2i(i,j)
		var unaffected := PhysicsServer3D.soft_body_get_point_global_position(body,pair.y)
		PhysicsServer3D.soft_body_move_point(body,pair.x,unaffected+Vector3(0,1,0))
		check(PhysicsServer3D.soft_body_get_point_global_position(body,pair.y).distance_to(unaffected)<0.00001,"crack sides move independently")
		PhysicsServer3D.free_rid(body)
	print("RESULT: ","FAIL" if failed else "PASS")
	quit(1 if failed else 0)
