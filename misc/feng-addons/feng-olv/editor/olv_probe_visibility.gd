@tool
extends RefCounted
## Editor-only mesh visibility, independent of physics collision shapes and FRP exposure.
## Triangle acceleration and projected views are reused until the scene/camera changes.
const Tracker = preload("../../feng-magic-gi/feng_magic_gi_scene_tracker.gd")
var _geometry_key := ""
var _mesh: TriangleMesh
var _views: Dictionary = {}

func visible_view(node: Node3D, camera: Camera3D, view: Dictionary, revision: String) -> Dictionary:
	if view.is_empty() or camera == null: return {}
	var volume: Node3D = node.get_source_volume()
	if volume == null: return {}
	var geometry_key := str([Tracker.quick_source_signature(volume),camera.cull_mask])
	if geometry_key != _geometry_key:
		_geometry_key = geometry_key
		_views.clear()
		var faces := PackedVector3Array()
		_collect(Tracker.scene_root(volume),volume.get_world_3d(),camera.cull_mask,faces)
		_mesh = TriangleMesh.new() if not faces.is_empty() else null
		if _mesh != null: _mesh.create_from_faces(faces)
	var key := str([geometry_key,revision,camera.get_camera_transform(),camera.get_camera_projection(),
		camera.get_viewport().get_visible_rect().size,node.xray_probes])
	var id := camera.get_instance_id()
	var cached: Dictionary = _views.get(id,{})
	if cached.get("key","") == key: return cached.view
	var started := Time.get_ticks_usec()
	var result := {"positions":PackedVector3Array(),"indices":PackedInt32Array(),"labels":PackedByteArray()}
	var positions: PackedVector3Array = view.positions
	var transform := camera.get_camera_transform()
	var rect := camera.get_viewport().get_visible_rect()
	for i in positions.size():
		var point := positions[i]
		var depth := -transform.basis.z.dot(point-transform.origin)
		if depth < camera.near or depth > camera.far: continue
		var screen := camera.unproject_position(point)
		if not rect.has_point(screen): continue
		if not node.xray_probes and _mesh != null:
			# project_ray_origin handles orthographic and perspective editor views.
			var origin := camera.project_ray_origin(screen)
			var direction := camera.project_ray_normal(screen)
			var start := origin if camera.projection == Camera3D.PROJECTION_ORTHOGONAL \
				else origin + direction * camera.near / maxf(0.00001,-transform.basis.z.dot(direction))
			if not _mesh.intersect_segment(start,point-direction*0.0001).is_empty(): continue
		result.positions.append(point)
		result.indices.append(view.indices[i])
		result.labels.append(view.labels[i])
	result["elapsed_usec"] = Time.get_ticks_usec()-started
	result["key"] = key
	_views[id] = {"key":key,"view":result}
	return result

func _collect(node: Node, world: World3D, mask: int, faces: PackedVector3Array) -> void:
	if node is Viewport or (node is Node3D and node.get_world_3d() != world): return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree() and (node.layers & mask) != 0:
		faces.append_array(node.global_transform * node.mesh.get_faces())
	elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null \
			and node.is_visible_in_tree() and (node.layers & mask) != 0:
		var base: PackedVector3Array = node.multimesh.mesh.get_faces()
		var count: int = node.multimesh.instance_count if node.multimesh.visible_instance_count < 0 else node.multimesh.visible_instance_count
		for i in count:
			faces.append_array((node.global_transform * node.multimesh.get_instance_transform(i)) * base)
	for child in node.get_children(): _collect(child,world,mask,faces)
