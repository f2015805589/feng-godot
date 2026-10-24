extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene: Node = load("res://box_test.tscn").instantiate()
	for node in scene.find_children("*","",true,false):
		if node is Node3D and not node is VisualInstance3D and not node is Camera3D:
			if node.name != "FengLightmapVolume":
				node.set_script(null)
	root.add_child(scene)
	current_scene = scene
	var volume: Node = scene.get_node("FengLightmapVolume")
	var collected: Dictionary = volume._collect_scene(scene,scene)
	if not collected.get("ok",false):
		push_error(str(collected))
		quit(1)
		return
	var meshes: Array[Dictionary] = []
	for receiver in collected.mesh_nodes:
		meshes.append({"path":str(receiver.get_path()),"triangles":[]})
	for triangle in collected.mesh_ids.size():
		var mesh_id: int = collected.mesh_ids[triangle]
		if mesh_id < 0:
			continue
		var uv: Array = []
		for vertex in 3:
			var coordinate: Vector2 = collected.uv2[triangle*3+vertex]
			uv.append([coordinate.x,coordinate.y])
		meshes[mesh_id].triangles.append({"global_id":triangle,"uv":uv})
	var output := "user://feng_lightmap_mc_test/actual_uv_snapshot.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.get_base_dir()))
	var file := FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(meshes))
	file.close()
	print("UV_AUDIT_SNAPSHOT ",ProjectSettings.globalize_path(output))
	scene.free()
	quit(0)
