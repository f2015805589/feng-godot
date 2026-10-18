extends SceneTree

const Snapshot = preload("res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var snapshot: RefCounted = Snapshot.new()
	var mesh_instance := MeshInstance3D.new()
	var meshes: Array[Mesh] = [BoxMesh.new(), PlaneMesh.new(), SphereMesh.new(), CylinderMesh.new()]
	var passed := true
	for mesh in meshes:
		mesh_instance.mesh = mesh
		var capture_value: Variant = snapshot.call("_capture_mesh", mesh_instance, mesh)
		var valid_capture := capture_value is Dictionary
		if valid_capture:
			var payload: Dictionary = capture_value
			var surfaces_value: Variant = payload.get("surfaces", [])
			valid_capture = surfaces_value is Array and not payload.has("unsupported_reason")
			if valid_capture:
				var surfaces: Array = surfaces_value
				valid_capture = surfaces.size() == mesh.get_surface_count() and not surfaces.is_empty()
			if valid_capture:
				var signature := int(snapshot.call("_current_surface_geometry_signature", mesh, 0))
				var first_surface_value: Variant = surfaces_value[0]
				if first_surface_value is Dictionary:
					var first_surface: Dictionary = first_surface_value
					valid_capture = signature == int(first_surface.get("source_geometry_signature", -1))
				else:
					valid_capture = false
		passed = passed and valid_capture
		print("RTGI_PRIMITIVE_CAPTURE ", mesh.get_class(), " ", valid_capture)
	mesh_instance.free()
	snapshot.call("detach")
	quit(0 if passed else 1)
