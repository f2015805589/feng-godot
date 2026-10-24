extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var scene: Node = load("res://box_test.tscn").instantiate()
	for node in scene.find_children("*", "", true, false):
		if node is Node3D and not node is VisualInstance3D and not node is Camera3D:
			if node.name != "FengLightmapVolume": node.set_script(null)
	root.add_child(scene)
	current_scene = scene
	var volume: Node = scene.get_node("FengLightmapVolume")
	var inputs: Dictionary = volume._collect_scene(scene,scene)
	if not inputs.get("ok",false):
		print(inputs)
		quit(1)
		return
	var names := []
	for node in inputs.mesh_nodes: names.append(str(node.get_path()))
	inputs.erase("mesh_nodes")
	inputs.directional_lights=[]
	inputs.area_lights=[]
	inputs.environment_radiance=Color.BLACK
	for i in inputs.albedo.size():
		inputs.albedo[i]=Color.BLACK
		inputs.emission[i]=Color.BLACK
		inputs.metallic[i]=0.0
		inputs.specular[i]=0.0
	var fixture := FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/actual_scene_inputs.bin",FileAccess.WRITE)
	fixture.store_var(inputs)
	fixture.close()
	var report := {"meshes":names,"cases":[],"uv2":[],"mesh_ids":Array(inputs.mesh_ids)}
	for uv in inputs.uv2: report.uv2.append([uv.x,uv.y])
	var original: PackedInt32Array=inputs.mesh_ids.duplicate()
	for mesh in names.size():
		for i in original.size(): inputs.mesh_ids[i]=0 if original[i]==mesh else -1
		var backend=ClassDB.instantiate("FengLightmapMCIntegrator")
		var result: Dictionary=backend.bake_scene_atlases(inputs,{"mesh_count":1,"resolution":128,"samples_per_texel":4,"seed":1,"worker_count":1})
		result.erase("layers")
		report.cases.append({"mesh":names[mesh],"result":result})
		print("UV_MESH ",names[mesh]," ",result)
	var f:=FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/uv_diagnosis.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"  "))
	f.close()
	scene.free()
	quit(0)
