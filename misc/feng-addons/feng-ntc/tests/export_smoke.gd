extends Node
func _ready() -> void:
	get_tree().create_timer(10.0).timeout.connect(func(): push_error("Export smoke timed out"); get_tree().quit(1))
	if ClassDB.class_exists(&"FengNTCCodec"):
		push_error("Native authoring SDK leaked into exported game"); get_tree().quit(1); return
	var material: Resource = load("res://runtime_material.tres")
	var neural: bool = material.get_script()==preload("res://addons/feng-ntc/neural_material.gd")
	print("EXPORT_STAGE: loaded neural=",neural)
	if neural:
		var session: RefCounted=material.texture_set.get_sample_session()
		while not session.ready and session.last_error.is_empty(): await get_tree().process_frame
		print("EXPORT_STAGE: uploaded ",session.last_error)
		if not session.last_error.is_empty(): push_error(session.last_error); get_tree().quit(1); return
		if not material.texture_set.get_runtime_stats().is_empty(): push_error("Unexpected full decode"); get_tree().quit(1); return
		var scene:=Node3D.new(); add_child(scene)
		var camera:=Camera3D.new(); camera.position=Vector3(0,0,2); scene.add_child(camera)
		var mesh:=MeshInstance3D.new(); mesh.mesh=QuadMesh.new(); mesh.material_override=material; scene.add_child(mesh)
		var light:=DirectionalLight3D.new(); scene.add_child(light)
		print("EXPORT_STAGE: rendering")
		for frame in range(8): await get_tree().process_frame
		print("EXPORTED_NEURAL_STATS: ",material.get_runtime_stats())
	else:
		var textures: Dictionary = await material.texture_set.prepare_async()
		if textures.is_empty(): push_error(material.texture_set.last_error); get_tree().quit(1); return
	for path in ["tools/feng_ntc.gdextension","bin/feng_ntc.dll","bin/ntc.dll"]:
		if FileAccess.file_exists("res://addons/feng-ntc/"+path):
			push_error("Authoring dependency present in game pack: "+path); get_tree().quit(1); return
	print("EXPORT_RUNTIME_PASS: ","neural sampling" if neural else "GPU decode"," without native SDK")
	get_tree().quit()
