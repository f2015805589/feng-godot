@tool
class_name FengRTGIWorldSnapshot
extends RefCounted
## Incremental main-thread registry for one World3D's static GI geometry.
## Tree membership is scanned once at attach and maintained from SceneTree
## notifications. Published snapshots contain only packed bytes, value types,
## IDs and RIDs; render callbacks never dereference Nodes or Resources.

var _world: World3D
var _root: Node
var _tree: SceneTree
var _world_id := 0
var _world_generation := 0
var _node_refs: Dictionary = {} # instance id -> WeakRef, includes unsupported geometry
var _mesh_payloads: Dictionary = {} # instance id -> immutable surface/material payload
var _mesh_callbacks: Dictionary = {}
var _revision := 0
var _default_material := StandardMaterial3D.new()
var _instance_keys: Dictionary = {}

func attach(world: World3D, root: Node, world_generation: int) -> bool:
	if world == null or root == null or not root.is_inside_tree():
		return false
	detach()
	_world = world
	_root = root
	_tree = root.get_tree()
	_world_id = world.get_instance_id()
	_world_generation = world_generation
	if _tree == null:
		detach()
		return false
	_tree.node_added.connect(_on_node_added)
	_tree.node_removed.connect(_on_node_removed)
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node := pending.pop_back()
		_register_node(node)
		for child in node.get_children():
			pending.append(child)
	_revision += 1
	return true

func detach() -> void:
	if _tree != null:
		if _tree.node_added.is_connected(_on_node_added):
			_tree.node_added.disconnect(_on_node_added)
		if _tree.node_removed.is_connected(_on_node_removed):
			_tree.node_removed.disconnect(_on_node_removed)
	for mesh_id in _mesh_callbacks:
		var weak: WeakRef = _mesh_callbacks[mesh_id].get("mesh")
		var mesh: Resource = weak.get_ref() if weak != null else null
		var callback: Callable = _mesh_callbacks[mesh_id].get("callback", Callable())
		if is_instance_valid(mesh) and callback.is_valid() and mesh.changed.is_connected(callback):
			mesh.changed.disconnect(callback)
	_node_refs.clear()
	_mesh_payloads.clear()
	_instance_keys.clear()
	_mesh_callbacks.clear()
	_world = null
	_root = null
	_tree = null
	_world_id = 0
	_world_generation = 0
	_revision += 1

func snapshot(target: RID, targets: Array[RID]) -> Dictionary:
	if _world == null or not is_instance_valid(_world) or _world_id == 0 or not targets.has(target):
		return {}
	var instances: Array[Dictionary] = []
	var unsupported: Array[String] = []
	var stale: Array[int] = []
	for id_variant in _node_refs.keys():
		var id := int(id_variant)
		var weak: WeakRef = _node_refs[id]
		var node: Node3D = weak.get_ref() if weak != null else null
		if node == null or not is_instance_valid(node):
			stale.append(id)
			continue
		if not node.is_inside_tree() or node.get_world_3d() != _world or not node.is_visible_in_tree():
			continue
		if not node is MeshInstance3D:
			unsupported.append("unsupported_visible_geometry:%s" % node.get_class())
			continue
		var mesh_node := node as MeshInstance3D
		var mesh := mesh_node.mesh
		if mesh == null:
			unsupported.append("mesh_instance_without_mesh:%d" % id)
			continue
		var mesh_id := mesh.get_instance_id()
		var key: Array = [mesh_id, mesh_node.material_override, mesh_node.material_overlay]
		for surface in mesh.get_surface_count():
			key.append(mesh_node.get_active_material(surface))
		if _instance_keys.get(id, []) != key:
			_instance_keys[id] = key
			_mesh_payloads.erase(id)
			_revision += 1
		if not _mesh_payloads.has(id):
			_mesh_payloads[id] = _capture_mesh(mesh_node, mesh)
		var payload: Dictionary = _mesh_payloads[id]
		if payload.has("unsupported_reason"):
			unsupported.append(str(payload.unsupported_reason))
			continue
		var transform := mesh_node.global_transform
		if not transform.is_finite() or absf(transform.basis.determinant()) < 1e-8:
			unsupported.append("singular_mesh_transform")
			continue
		instances.append({"instance_id": id, "mesh_id": mesh_id,
			"transform": transform, "mesh": payload, "layers": mesh_node.layers,
			"cast_shadow": mesh_node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF})

	for id in stale:
		_node_refs.erase(id)
	return {
		"valid": unsupported.is_empty() and not instances.is_empty(),
		"abi_version": 1,
		"world_id": _world_id,
		"world_generation": _world_generation,
		"snapshot_generation": _revision,
		"render_target": target,
		"instances": instances,
		"unsupported_reasons": unsupported,
		"capability": "static_array_primitive_opaque_meshes_v1",
	}

func _on_node_added(node: Node) -> void:
	if node is Node3D:
		_register_node(node)

func _on_node_removed(node: Node) -> void:
	if node is Node3D:
		var id := node.get_instance_id()
		if _node_refs.erase(id):
			_mesh_payloads.erase(id)
			_instance_keys.erase(id)
			_revision += 1

func _register_node(node: Node) -> void:
	if not node is Node3D or not node.is_inside_tree() or node.get_world_3d() != _world:
		return
	if node is GeometryInstance3D or node is GridMap or node.is_class("Terrain3D"):
		_node_refs[node.get_instance_id()] = weakref(node)
		_revision += 1

func _watch_mesh(mesh: Resource) -> void:
	var mesh_id := mesh.get_instance_id()
	if _mesh_callbacks.has(mesh_id):
		return
	var callback := Callable(self, "_on_mesh_changed").bind(mesh_id)
	if mesh.has_signal("changed"):
		mesh.changed.connect(callback)
	_mesh_callbacks[mesh_id] = {"mesh": weakref(mesh), "callback": callback}

func _on_mesh_changed(_mesh_id: int) -> void:
	_mesh_payloads.clear()
	_revision += 1

func _capture_mesh(node: MeshInstance3D, mesh: Mesh) -> Dictionary:
	if not (mesh is ArrayMesh or mesh is PrimitiveMesh):
		return {"unsupported_reason": "rtgi_requires_array_or_primitive_mesh"}
	if (mesh is ArrayMesh and mesh.get_blend_shape_count() > 0) or node.skin != null or node.material_overlay != null:
		return {"unsupported_reason": "rtgi_deformed_or_overlay_material"}
	_watch_mesh(mesh)
	var vertices_bytes := PackedByteArray()
	var indices_bytes := PackedByteArray()
	var surfaces: Array[Dictionary] = []
	var materials: Array[Dictionary] = []
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if (mesh is ArrayMesh and mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES) or arrays.size() < Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			return {"unsupported_reason": "rtgi_requires_vertex_normal_uv1"}
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array else PackedVector2Array()
		if uvs.is_empty():
			uvs.resize(vertices.size())
		if arrays[Mesh.ARRAY_BONES] != null and arrays[Mesh.ARRAY_BONES].size() > 0:
			return {"unsupported_reason": "rtgi_skinned_mesh"}
		if vertices.is_empty() or vertices.size() != normals.size() or vertices.size() != uvs.size():
			return {"unsupported_reason": "rtgi_mesh_attribute_count_mismatch"}
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		if indices.is_empty():
			if vertices.size() % 3 != 0:
				return {"unsupported_reason": "rtgi_non_triangle_surface"}
			indices.resize(vertices.size())
			for index in vertices.size():
				indices[index] = index
		if indices.size() % 3 != 0:
			return {"unsupported_reason": "rtgi_non_triangle_indices"}
		for index in indices:
			if index < 0 or index >= vertices.size():
				return {"unsupported_reason": "rtgi_index_out_of_range"}
		var vertex_base := vertices_bytes.size()
		var packed := PackedFloat32Array()
		packed.resize(vertices.size() * 8)
		for index in vertices.size():
			var v := vertices[index]
			var n := normals[index]
			var uv := uvs[index]
			var offset := index * 8
			packed[offset] = v.x
			packed[offset + 1] = v.y
			packed[offset + 2] = v.z
			packed[offset + 3] = n.x
			packed[offset + 4] = n.y
			packed[offset + 5] = n.z
			packed[offset + 6] = uv.x
			packed[offset + 7] = uv.y
		vertices_bytes.append_array(packed.to_byte_array())
		var index_base := indices_bytes.size()
		indices_bytes.append_array(indices.to_byte_array())
		var material: Material = node.get_active_material(surface_index)
		var material_row := _capture_material(material)
		if not bool(material_row.get("supported", false)):
			return {"unsupported_reason": str(material_row.get("reason", "rtgi_material_unsupported"))}
		var material_index := materials.size()
		materials.append(material_row)
		surfaces.append({"vertex_base_byte": vertex_base, "index_base_byte": index_base,
			"vertex_count": vertices.size(), "index_count": indices.size(), "material_index": material_index,
			"flags": int(material_row.get("flags", 0))})
	if surfaces.is_empty():
		return {"unsupported_reason": "rtgi_mesh_has_no_triangle_surfaces"}
	return {"vertex_stride_bytes": 32, "vertex_bytes": vertices_bytes,
		"index_bytes": indices_bytes, "surfaces": surfaces, "materials": materials}

func _capture_material(material: Material) -> Dictionary:
	if material == null:
		material = _default_material
	_watch_mesh(material)
	if not material is BaseMaterial3D:
		return {"supported": false, "reason": "rtgi_requires_base_material_3d"}
	var base := material as BaseMaterial3D
	if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return {"supported": false, "reason": "rtgi_transparent_material"}
	if base.shading_mode != BaseMaterial3D.SHADING_MODE_PER_PIXEL:
		return {"supported": false, "reason": "rtgi_requires_per_pixel_material"}
	if base.cull_mode == BaseMaterial3D.CULL_FRONT:
		return {"supported": false, "reason": "rtgi_front_cull_material"}
	if base.albedo_color.a < 0.9999:
		return {"supported": false, "reason": "rtgi_material_alpha_is_not_opaque"}
	if base.normal_enabled or base.emission_texture != null or base.metallic_texture != null or base.uv1_triplanar or base.vertex_color_use_as_albedo or base.next_pass != null or base.detail_enabled or base.heightmap_enabled:
		return {"supported": false, "reason": "rtgi_unsupported_material_features"}
	var texture_data := {}
	if base.albedo_texture != null:
		if not base.albedo_texture is Texture2D:
			return {"supported": false, "reason": "rtgi_albedo_texture_not_2d"}
		_watch_mesh(base.albedo_texture)
		var image := base.albedo_texture.get_image()
		if image == null or image.is_empty():
			return {"supported": false, "reason": "rtgi_albedo_image_unavailable"}
		image = image.duplicate()
		if image.is_compressed() and image.decompress() != OK:
			return {"supported": false, "reason": "rtgi_texture_decompression_failed"}
		image.clear_mipmaps()
		image.convert(Image.FORMAT_RGBA8)
		texture_data = {"id": base.albedo_texture.get_instance_id(), "filter": base.texture_filter,"width": image.get_width(), "height": image.get_height(),
			"format": image.get_format(), "data": image.get_data(), "repeat": base.texture_repeat}
	return {"supported": true, "albedo": base.albedo_color.srgb_to_linear(),
		"metallic": base.metallic, "roughness": base.roughness,
		"specular": base.metallic_specular, "emission_enabled": base.emission_enabled,
		"emission": base.emission.srgb_to_linear(), "emission_energy_multiplier": base.emission_energy_multiplier * (base.emission_intensity if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false) else 1.0),
		"uv_transform": Vector4(base.uv1_scale.x, base.uv1_scale.y, base.uv1_offset.x, base.uv1_offset.y),
		"cull_mode": base.cull_mode, "flags": (1 if base.albedo_texture != null else 0) | (2 if base.cull_mode == BaseMaterial3D.CULL_DISABLED else 0),
		"albedo_texture": texture_data}
