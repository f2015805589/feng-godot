@tool
class_name FengRTGIWorldSnapshot
extends RefCounted
## Incremental main-thread registry for one World3D's GI geometry and motion.
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
var _unsupported_payload_material_keys: Dictionary = {} # failed captures only; retry when a material source changes
var _dirty_mesh_ids: Dictionary = {} # source mesh changed; verify geometry before recapture
var _mesh_callbacks: Dictionary = {}
var _resource_change_epochs: Dictionary = {} # changed signals, including texture contents
var _skeleton_refs: Dictionary = {} # instance id -> WeakRef
var _skeleton_callbacks: Dictionary = {} # instance id -> finalized-pose callback
var _skeleton_pose_cache: Dictionary = {} # instance id -> Array[Transform3D], captured at skeleton_updated
var _revision := 0
var _topology_revision := 0
var _material_revision := 0
var _surface_tracking_revision := 0
var _default_material := StandardMaterial3D.new()
var _instance_keys: Dictionary = {}
var _surface_slots: Dictionary = {} # stable instance/mesh/surface key -> 24-bit TLAS custom index
var _surface_slot_records: Array[Dictionary] = [] # inactive rows remain until a slot is reused
var _surface_slot_generation: Array[int] = []
var _free_surface_slots: Array[int] = []
var _next_surface_slot := 0

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
	for skeleton_id in _skeleton_callbacks:
		var skeleton_ref: WeakRef = _skeleton_refs.get(skeleton_id)
		var skeleton: Skeleton3D = skeleton_ref.get_ref() if skeleton_ref != null else null
		var skeleton_callback: Callable = _skeleton_callbacks[skeleton_id]
		if is_instance_valid(skeleton) and skeleton_callback.is_valid() \
				and skeleton.skeleton_updated.is_connected(skeleton_callback):
			skeleton.skeleton_updated.disconnect(skeleton_callback)
	_node_refs.clear()
	_mesh_payloads.clear()
	_unsupported_payload_material_keys.clear()
	_dirty_mesh_ids.clear()
	_resource_change_epochs.clear()
	_skeleton_refs.clear()
	_skeleton_callbacks.clear()
	_skeleton_pose_cache.clear()
	_instance_keys.clear()
	_surface_slots.clear()
	_surface_slot_records.clear()
	_surface_slot_generation.clear()
	_free_surface_slots.clear()
	_next_surface_slot = 0
	_mesh_callbacks.clear()
	_world = null
	_root = null
	_tree = null
	_world_id = 0
	_world_generation = 0
	_revision += 1
	_topology_revision += 1

func snapshot(target: RID, targets: Array[RID]) -> Dictionary:
	if _world == null or not is_instance_valid(_world) or _world_id == 0 or not targets.has(target):
		return {}
	var instances: Array[Dictionary] = []
	var unsupported: Array[String] = []
	var stale: Array[int] = []
	var checked_mesh_ids: Dictionary = {}
	var active_surface_keys: Dictionary = {}
	var tracking_changed := false
	for id_variant in _node_refs.keys():
		var id := int(id_variant)
		var weak: WeakRef = _node_refs[id]
		var node: Node3D = weak.get_ref() if weak != null else null
		if node == null or not is_instance_valid(node):
			stale.append(id)
			continue
		if not node.is_inside_tree() or node.get_world_3d() != _world:
			continue
		if not node.is_visible_in_tree():
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
		checked_mesh_ids[mesh_id] = true
		if _dirty_mesh_ids.has(mesh_id) and _mesh_payloads.has(id):
			var old_payload: Dictionary = _mesh_payloads[id]
			if not _mesh_geometry_matches(mesh, old_payload):
				_mesh_payloads.erase(id)
		var key: Array = [mesh_id, mesh_node.material_overlay != null, mesh.get_surface_count()]
		if _instance_keys.get(id, []) != key:
			_instance_keys[id] = key
			_mesh_payloads.erase(id)
			_unsupported_payload_material_keys.erase(id)
			_revision += 1
			_topology_revision += 1
		if _mesh_payloads.has(id):
			var cached_payload: Dictionary = _mesh_payloads[id]
			if not cached_payload.has("surfaces"):
				var recovery_key := _unsupported_capture_material_key(mesh_node, mesh)
				if _unsupported_payload_material_keys.get(id, []) != recovery_key:
					_mesh_payloads.erase(id)
					_unsupported_payload_material_keys.erase(id)
		if not _mesh_payloads.has(id):
			var capture_value: Variant = _capture_mesh(mesh_node, mesh)
			var captured_payload: Dictionary = capture_value if capture_value is Dictionary \
					else {"unsupported_reason": "rtgi_mesh_capture_failed"}
			_mesh_payloads[id] = captured_payload
			if not captured_payload.has("surfaces"):
				_unsupported_payload_material_keys[id] = _unsupported_capture_material_key(mesh_node, mesh)
		var payload: Dictionary = _mesh_payloads[id]
		if payload.has("surfaces"):
			_unsupported_payload_material_keys.erase(id)
			payload = _refresh_payload_materials(mesh_node, payload)
			_mesh_payloads[id] = payload
		if payload.has("unsupported_reason"):
			unsupported.append(str(payload.unsupported_reason))
			continue
		# Match the transform VisualInstance3D publishes for rasterization when
		# physics interpolation is enabled. With interpolation off this resolves to
		# the ordinary global transform.
		var transform := mesh_node.get_global_transform_interpolated()
		if not transform.is_finite() or absf(transform.basis.determinant()) < 1e-8:
			unsupported.append("singular_mesh_transform")
			continue
		var surface_rows: Array[Dictionary] = []
		var instance_deformation_revision := 0
		for surface_index in payload.surfaces.size():
			var surface: Dictionary = payload.surfaces[surface_index]
			var material: Dictionary = payload.materials[surface.material_index]
			var slot_key := "%d:%d:%d" % [id, mesh_id, surface_index]
			var deform := _capture_surface_deformation(mesh_node, mesh, surface_index, surface)
			if not bool(deform.get("supported", false)):
				unsupported.append(str(deform.get("reason", "unsupported_deformation")))
				continue
			var geometry_signature: Array = [mesh_id, surface_index,
				int(surface.vertex_count), int(surface.index_count),
				int(surface.get("source_geometry_signature", 0))]
			var material_signature := int(material.get("material_signature", 0))
			var previous_tracking: Dictionary = {}
			if _surface_slots.has(slot_key):
				previous_tracking = _surface_slot_records[int(_surface_slots[slot_key])].duplicate(true)
			var slot := _acquire_surface_slot(slot_key, geometry_signature, material_signature)
			if slot < 0:
				unsupported.append("surface_tracking_slot_limit_exceeded")
				continue
			active_surface_keys[slot_key] = true
			var deformation_signature: int = hash([
				deform.get("blend_weights", PackedFloat32Array()),
				deform.get("bone_palette", PackedFloat32Array())])
			var motion_signature: int = hash([transform, deformation_signature])
			var slot_record: Dictionary = _surface_slot_records[slot]
			if int(slot_record.get("motion_signature", -1)) != motion_signature:
				slot_record["motion_revision"] = (int(slot_record.get("motion_revision", 0)) + 1) & 0xffffffff
				slot_record["motion_signature"] = motion_signature
			_surface_slot_records[slot] = slot_record
			instance_deformation_revision = hash([instance_deformation_revision, motion_signature])
			var tracking := _surface_tracking_row(transform, slot_record,
				bool(deform.get("deforming", false)))
			if previous_tracking.is_empty() \
					or previous_tracking.get("local_to_world", Transform3D.IDENTITY) != tracking.local_to_world \
					or previous_tracking.get("normal_to_world", Basis.IDENTITY) != tracking.normal_to_world \
					or previous_tracking.get("identity", PackedInt32Array()) != tracking.identity:
				tracking_changed = true
			_surface_slot_records[slot] = tracking
			surface_rows.append({"surface_index": surface_index, "slot": slot,
				"generation": int(tracking.identity[0]),
				"geometry_revision": int(tracking.identity[1]),
				"motion_revision": int(tracking.identity[2]),
				"deforming": bool(deform.get("deforming", false)),
				"nee_unsampled": bool(deform.get("deforming", false)) and bool(material.get("emission_enabled", false)),
				"material_signature": material_signature,
				"deformation_revision": deformation_signature,
				"deformation": deform})
		instances.append({"instance_id": id, "mesh_id": mesh_id,
			"transform": transform, "mesh": payload, "layers": mesh_node.layers,
			"cast_shadow": mesh_node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"surface_rows": surface_rows, "deformation_revision": instance_deformation_revision})
	for slot_key in _surface_slots.keys().duplicate():
		if active_surface_keys.has(slot_key):
			continue
		var removed_slot := int(_surface_slots[slot_key])
		_surface_slots.erase(slot_key)
		if removed_slot >= 0 and removed_slot < _surface_slot_records.size():
			var removed_record: Dictionary = _surface_slot_records[removed_slot]
			tracking_changed = true
			removed_record["active"] = false
			removed_record["generation"] = (int(removed_record.get("generation", 0)) + 1) & 0xffffffff
			var removed_identity: PackedInt32Array = removed_record.get("identity", PackedInt32Array([0, 0, 0, 0]))
			if removed_identity.size() != 4:
				removed_identity = PackedInt32Array([0, 0, 0, 0])
			removed_identity[0] = int(removed_record["generation"])
			removed_identity[3] = 0
			removed_record["identity"] = removed_identity
			_surface_slot_generation[removed_slot] = int(removed_record["generation"])
			_surface_slot_records[removed_slot] = removed_record
			if not bool(removed_record.get("free_queued", false)):
				removed_record["free_queued"] = true
				_free_surface_slots.append(removed_slot)
			_revision += 1
			_topology_revision += 1

	for id in stale:
		_node_refs.erase(id)
	for mesh_id_variant in checked_mesh_ids:
		_dirty_mesh_ids.erase(int(mesh_id_variant))
	if tracking_changed:
		_surface_tracking_revision += 1
	return {
		"valid": unsupported.is_empty() and not instances.is_empty(),
		"abi_version": 1,
		"world_id": _world_id,
		"world_generation": _world_generation,
		"snapshot_generation": _revision,
		"topology_revision": _topology_revision,
		"geometry_revision": _topology_revision,
		"material_revision": _material_revision,
		"surface_tracking_revision": _surface_tracking_revision,
		"surface_tracking_stride": 128,
		"surface_tracking": _surface_slot_records.duplicate(true),
		"render_target": target,
		"instances": instances,
		"unsupported_reasons": unsupported,
		"capability": "dynamic_array_primitive_opaque_meshes_v2",
	}

func _on_node_added(node: Node) -> void:
	if node is Node3D:
		_register_node(node)

func _on_node_removed(node: Node) -> void:
	if node is Node3D:
		var id := node.get_instance_id()
		if _node_refs.erase(id):
			_mesh_payloads.erase(id)
			_unsupported_payload_material_keys.erase(id)
			_instance_keys.erase(id)
			_revision += 1
			_topology_revision += 1

func _register_node(node: Node) -> void:
	if not node is Node3D or not node.is_inside_tree() or node.get_world_3d() != _world:
		return
	if node is Skeleton3D:
		_watch_skeleton(node as Skeleton3D)
		return
	if node is GeometryInstance3D or node is GridMap or node.is_class("Terrain3D"):
		_node_refs[node.get_instance_id()] = weakref(node)
		_revision += 1
		_topology_revision += 1

func _watch_mesh(mesh: Resource) -> void:
	var mesh_id := mesh.get_instance_id()
	if _mesh_callbacks.has(mesh_id):
		return
	var callback := Callable(self, "_on_mesh_changed").bind(mesh_id)
	if mesh.has_signal("changed"):
		mesh.changed.connect(callback)
	_mesh_callbacks[mesh_id] = {"mesh": weakref(mesh), "callback": callback}

func _on_mesh_changed(_mesh_id: int) -> void:
	_dirty_mesh_ids[_mesh_id] = true

func _watch_material(resource: Resource) -> void:
	var resource_id := resource.get_instance_id()
	if _mesh_callbacks.has(resource_id):
		return
	var callback := Callable(self, "_on_material_changed").bind(resource_id)
	if resource.has_signal("changed"):
		resource.changed.connect(callback)
	_mesh_callbacks[resource_id] = {"mesh": weakref(resource), "callback": callback}

func _on_material_changed(_resource_id: int) -> void:
	_resource_change_epochs[_resource_id] = int(_resource_change_epochs.get(_resource_id, 0)) + 1

func _invalidate_payloads_for_mesh(mesh_id: int) -> void:
	var stale: Array[int] = []
	for node_id_variant in _mesh_payloads:
		var node_id := int(node_id_variant)
		var payload: Variant = _mesh_payloads[node_id_variant]
		if payload is Dictionary and int(payload.get("source_mesh_id", 0)) == mesh_id:
			stale.append(node_id)
	for node_id in stale:
		_mesh_payloads.erase(node_id)

func _material_source(node: MeshInstance3D, surface_index: int) -> Material:
	var material := node.get_active_material(surface_index)
	return material if material != null else _default_material


func _unsupported_capture_material_key(node: MeshInstance3D, mesh: Mesh) -> Array:
	var result: Array = [node.material_overlay.get_instance_id() if node.material_overlay != null else 0,
		_material_state_signature(node.material_overlay) if node.material_overlay != null else 0]
	for surface_index in mesh.get_surface_count():
		var material := _material_source(node, surface_index)
		result.append([material.get_instance_id(), _material_state_signature(material)])
	return result


func _material_state_signature(material: Material) -> int:
	if material == null:
		material = _default_material
	var resource_id := material.get_instance_id()
	_watch_material(material)
	var common: Array = [resource_id, material.get_class(),
		int(_resource_change_epochs.get(resource_id, 0))]
	if not material is BaseMaterial3D:
		return int(hash(common))
	var base := material as BaseMaterial3D
	var texture := base.albedo_texture
	var texture_id := texture.get_instance_id() if texture != null else 0
	if texture != null:
		_watch_material(texture)
	var texture_epoch := int(_resource_change_epochs.get(texture_id, 0))
	return int(hash(common + [base.transparency, base.shading_mode, base.cull_mode,
		base.albedo_color, base.normal_enabled, base.emission_texture,
		base.metallic_texture, base.roughness_texture, base.uv1_triplanar,
		base.vertex_color_use_as_albedo, base.next_pass, base.detail_enabled,
		base.heightmap_enabled, texture_id, texture_epoch,
		texture.get_width() if texture != null else 0,
		texture.get_height() if texture != null else 0, base.texture_filter,
		base.texture_repeat, base.uv1_scale, base.uv1_offset, base.metallic,
		base.roughness, base.metallic_specular, base.emission_enabled,
		base.emission, base.emission_energy_multiplier, base.emission_intensity,
		bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))]))


func _refresh_payload_materials(node: MeshInstance3D, payload: Dictionary) -> Dictionary:
	var next_payload := payload
	var surfaces: Array = payload.get("surfaces", [])
	var materials: Array = payload.get("materials", [])
	var copied := false
	var unsupported_reason := ""
	for surface_index in mini(surfaces.size(), node.mesh.get_surface_count()):
		var surface_value: Variant = surfaces[surface_index]
		if not surface_value is Dictionary:
			continue
		var surface: Dictionary = surface_value
		var material_index := int(surface.get("material_index", -1))
		if material_index < 0 or material_index >= materials.size():
			unsupported_reason = "rtgi_material_snapshot_index_invalid"
			break
		var material: Material = _material_source(node, surface_index)
		var signature := _material_state_signature(material)
		var previous: Dictionary = materials[material_index]
		if previous.get("material_state_signature", []) == signature:
			if not bool(previous.get("supported", false)) and unsupported_reason.is_empty():
				unsupported_reason = str(previous.get("reason", "rtgi_material_unsupported"))
			continue
		if not copied:
			next_payload = payload.duplicate(false)
			surfaces = surfaces.duplicate()
			materials = materials.duplicate()
			copied = true
		var next_material := _capture_material(material)
		next_material["source_material_id"] = material.get_instance_id()
		next_material["material_state_signature"] = signature
		next_material["material_signature"] = signature
		if not bool(next_material.get("supported", false)):
			unsupported_reason = str(next_material.get("reason", "rtgi_material_unsupported"))
		materials[material_index] = next_material
		surface = surface.duplicate(false)
		surface["flags"] = int(next_material.get("flags", 0))
		surfaces[surface_index] = surface
	if copied:
		if not unsupported_reason.is_empty():
			next_payload["unsupported_reason"] = unsupported_reason
		else:
			next_payload.erase("unsupported_reason")
		next_payload["materials"] = materials
		next_payload["surfaces"] = surfaces
	return next_payload


func _mesh_geometry_matches(mesh: Mesh, payload: Dictionary) -> bool:
	if int(payload.get("source_mesh_id", 0)) != mesh.get_instance_id():
		return false
	var surfaces_value: Variant = payload.get("surfaces", [])
	if not surfaces_value is Array or surfaces_value.size() != mesh.get_surface_count():
		return false
	for surface_index in mesh.get_surface_count():
		var surface_value: Variant = surfaces_value[surface_index]
		if not surface_value is Dictionary:
			return false
		var surface: Dictionary = surface_value
		if int(surface.get("source_geometry_signature", -1)) != _current_surface_geometry_signature(mesh, surface_index):
			return false
	return true


func _current_surface_geometry_signature(mesh: Mesh, surface_index: int) -> int:
	var arrays := mesh.surface_get_arrays(surface_index)
	if arrays.size() < Mesh.ARRAY_MAX \
			or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array \
			or not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		return -1
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if vertices.is_empty() or vertices.size() != normals.size():
		return -1
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] \
		if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array else PackedVector2Array()
	if uvs.is_empty():
		uvs.resize(vertices.size())
	if uvs.size() != vertices.size():
		return -1
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
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] is PackedInt32Array else PackedInt32Array()
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array else PackedFloat32Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
	if indices.is_empty():
		if vertices.size() % 3 != 0:
			return -1
		indices.resize(vertices.size())
		for index in vertices.size():
			indices[index] = index
	var blend_shape_signature: Array = []
	if mesh is ArrayMesh:
		var shapes: Array = mesh.surface_get_blend_shape_arrays(surface_index)
		if shapes.size() != mesh.get_blend_shape_count():
			return -1
		for shape_value in shapes:
			var shape: Array = shape_value
			if shape.size() < Mesh.ARRAY_MAX \
					or not shape[Mesh.ARRAY_VERTEX] is PackedVector3Array \
					or not shape[Mesh.ARRAY_NORMAL] is PackedVector3Array:
				return -1
			blend_shape_signature.append(shape[Mesh.ARRAY_VERTEX].to_byte_array())
			blend_shape_signature.append(shape[Mesh.ARRAY_NORMAL].to_byte_array())
	var blend_shape_mode := (mesh as ArrayMesh).get_blend_shape_mode() \
		if mesh is ArrayMesh else Mesh.BLEND_SHAPE_MODE_RELATIVE
	return int(hash([packed.to_byte_array(), indices.to_byte_array(),
		bones.to_byte_array(), weights.to_byte_array(), blend_shape_signature,
		blend_shape_mode, _surface_primitive_type(mesh, surface_index)]))


func _surface_primitive_type(mesh: Mesh, surface_index: int) -> int:
	# These methods are bound on ArrayMesh, not PrimitiveMesh in GDScript.
	# PrimitiveMesh generates triangle surfaces and exposes no skin format flags.
	if mesh is ArrayMesh:
		var array_mesh := mesh as ArrayMesh
		return int(array_mesh.surface_get_primitive_type(surface_index))
	return Mesh.PRIMITIVE_TRIANGLES


func _surface_format(mesh: Mesh, surface_index: int) -> int:
	if mesh is ArrayMesh:
		var array_mesh := mesh as ArrayMesh
		return int(array_mesh.surface_get_format(surface_index))
	return 0

func _watch_skeleton(skeleton: Skeleton3D) -> void:
	var skeleton_id := skeleton.get_instance_id()
	if _skeleton_callbacks.has(skeleton_id):
		return
	var callback := Callable(self, "_on_skeleton_updated").bind(skeleton_id)
	skeleton.skeleton_updated.connect(callback)
	_skeleton_refs[skeleton_id] = weakref(skeleton)
	_skeleton_callbacks[skeleton_id] = callback
	_capture_skeleton_pose(skeleton)

func _on_skeleton_updated(skeleton_id: int) -> void:
	var skeleton_ref: WeakRef = _skeleton_refs.get(skeleton_id)
	var skeleton: Skeleton3D = skeleton_ref.get_ref() if skeleton_ref != null else null
	if not is_instance_valid(skeleton):
		_skeleton_refs.erase(skeleton_id)
		_skeleton_callbacks.erase(skeleton_id)
		_skeleton_pose_cache.erase(skeleton_id)
		return
	_capture_skeleton_pose(skeleton)

func _capture_skeleton_pose(skeleton: Skeleton3D) -> void:
	var poses: Array[Transform3D] = []
	for bone_index in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_global_pose(bone_index))
	_skeleton_pose_cache[skeleton.get_instance_id()] = poses

func _acquire_surface_slot(key: String, geometry_signature: Array, material_signature: int) -> int:
	var slot := -1
	if _surface_slots.has(key):
		slot = int(_surface_slots[key])
		var record: Dictionary = _surface_slot_records[slot]
		if record.get("geometry_signature", []) != geometry_signature:
			record["generation"] = (int(record.get("generation", 0)) + 1) & 0xffffffff
			record["geometry_revision"] = (int(record.get("geometry_revision", 0)) + 1) & 0xffffffff
			record["motion_signature"] = -1
			record["free_queued"] = false
			_surface_slot_generation[slot] = int(record["generation"])
			record["geometry_signature"] = geometry_signature.duplicate(true)
			record["material_signature"] = material_signature
			_revision += 1
			_topology_revision += 1
		elif int(record.get("material_signature", -1)) != material_signature:
			# Material/emission edits change shading inputs and the emitter CDF,
			# but do not change the triangle identity or the local-space anchor.
			# Keep the stable geometry generation and motion revision intact.
			record["material_signature"] = material_signature
			_revision += 1
			_material_revision += 1
		_surface_slots[key] = slot
	else:
		if not _free_surface_slots.is_empty():
			slot = _free_surface_slots.pop_back()
		else:
			if _next_surface_slot > 0x00ffffff:
				return -1
			slot = _next_surface_slot
			_next_surface_slot += 1
			_surface_slot_generation.append(0)
			_surface_slot_records.append({})
		var generation := int(_surface_slot_generation[slot])
		_surface_slot_records[slot] = {
			"generation": generation,
			"geometry_revision": 1,
			"motion_revision": 0,
			"motion_signature": -1,
			"geometry_signature": geometry_signature.duplicate(true),
			"material_signature": material_signature,
			"free_queued": false,
		}
		_surface_slots[key] = slot
		_revision += 1
		_topology_revision += 1
	var active_record: Dictionary = _surface_slot_records[slot]
	active_record["active"] = true
	active_record["free_queued"] = false
	_surface_slot_records[slot] = active_record
	return slot

func _surface_tracking_row(transform: Transform3D, slot_record: Dictionary, deforming: bool) -> Dictionary:
	var normal_basis := transform.basis.inverse().transposed()
	var flags := 1 | (2 if deforming else 0)
	var result := slot_record.duplicate(true)
	result["local_to_world"] = transform
	result["normal_to_world"] = normal_basis
	result["identity"] = PackedInt32Array([
		int(slot_record.get("generation", 0)),
		int(slot_record.get("geometry_revision", 0)),
		int(slot_record.get("motion_revision", 0)), flags])
	result["active"] = true
	result["free_queued"] = false
	return result

func _capture_surface_deformation(node: MeshInstance3D, mesh: Mesh, surface_index: int,
		surface: Dictionary) -> Dictionary:
	var skinned := bool(surface.get("skinned", false))
	var palette := PackedFloat32Array()
	if skinned:
		var skin_reference: Variant = node.get_skin_reference()
		var skin: Variant = skin_reference.call("get_skin") if skin_reference != null else node.get_skin()
		var skeleton_path := node.get_skeleton_path()
		var skeleton: Skeleton3D = node.get_node_or_null(skeleton_path) as Skeleton3D if not skeleton_path.is_empty() else null
		if skeleton == null and node.get_parent() is Skeleton3D:
			skeleton = node.get_parent() as Skeleton3D
		if skin == null or skeleton == null:
			return {"supported": false, "reason": "rtgi_skin_skeleton_binding_unavailable"}
		_watch_skeleton(skeleton)
		var finalized_poses: Array[Transform3D] = _skeleton_pose_cache.get(
			skeleton.get_instance_id(), [])
		var bind_count := int(skin.call("get_bind_count"))
		if bind_count <= 0:
			return {"supported": false, "reason": "rtgi_skin_has_no_binds"}
		if int(surface.get("max_weighted_bone_index", -1)) >= bind_count:
			return {"supported": false, "reason": "rtgi_skin_bone_index_out_of_bind_range"}
		for bind_index in bind_count:
			var bind_name: StringName = skin.call("get_bind_name", bind_index)
			var bone_index := skeleton.find_bone(String(bind_name)) \
					if not String(bind_name).is_empty() else int(skin.call("get_bind_bone", bind_index))
			if bone_index < 0 or bone_index >= skeleton.get_bone_count():
				return {"supported": false, "reason": "rtgi_skin_bone_binding_invalid"}
			if bone_index >= finalized_poses.size():
				return {"supported": false, "reason": "rtgi_skeleton_final_pose_unavailable"}
			var bind_pose: Transform3D = skin.call("get_bind_pose", bind_index)
			# Match Skeleton3D's renderer upload exactly: global pose is in the
			# skeleton's pose space, then the bind pose. The MeshInstance model
			# transform is applied later by rasterization and by the TLAS instance;
			# folding a mesh/skeleton node-space correction here would double it.
			var bone_transform: Transform3D = finalized_poses[bone_index] * bind_pose
			if not bone_transform.is_finite():
				return {"supported": false, "reason": "rtgi_skin_transform_nonfinite"}
			_append_skin_transform(palette, bone_transform)
			for palette_index in range(palette.size() - 16, palette.size()):
				if not is_finite(palette[palette_index]):
					return {"supported": false, "reason": "rtgi_skin_palette_nonfinite"}
	var blend_shapes: Array = surface.get("blend_shapes", [])
	var blend_shape_count: int = blend_shapes.size()
	var blend_weights := PackedFloat32Array()
	blend_weights.resize(blend_shape_count)
	for shape_index in blend_shape_count:
		var weight := node.get_blend_shape_value(shape_index) if shape_index < mesh.get_blend_shape_count() else 0.0
		if not is_finite(weight):
			return {"supported": false, "reason": "rtgi_blend_shape_weight_nonfinite"}
		blend_weights[shape_index] = weight
	return {"supported": true, "deforming": skinned or blend_shape_count > 0,
		"skinned": skinned, "bones_per_vertex": int(surface.get("bones_per_vertex", 4)),
		"bones": surface.get("bones", PackedInt32Array()),
		"weights": surface.get("weights", PackedFloat32Array()),
		"blend_shapes": surface.get("blend_shapes", []),
		"blend_shape_mode": int(surface.get("blend_shape_mode", Mesh.BLEND_SHAPE_MODE_RELATIVE)),
		"blend_weights": blend_weights, "bone_palette": palette,
		"surface_index": surface_index}

func _append_skin_transform(output: PackedFloat32Array, transform: Transform3D) -> void:
	# Match skeleton.glsl: its mat4 is built from the three basis rows and the
	# translated row, then multiplied by vec4(position, 1) on the left.
	output.append_array(PackedFloat32Array([
		transform.basis.x.x, transform.basis.y.x, transform.basis.z.x, transform.origin.x,
		transform.basis.x.y, transform.basis.y.y, transform.basis.z.y, transform.origin.y,
		transform.basis.x.z, transform.basis.y.z, transform.basis.z.z, transform.origin.z,
		0.0, 0.0, 0.0, 1.0]))

func _capture_mesh(node: MeshInstance3D, mesh: Mesh) -> Dictionary:
	if not (mesh is ArrayMesh or mesh is PrimitiveMesh):
		return {"unsupported_reason": "rtgi_requires_array_or_primitive_mesh"}
	if node.material_overlay != null:
		return {"unsupported_reason": "rtgi_overlay_material"}
	_watch_mesh(mesh)
	var vertices_bytes := PackedByteArray()
	var indices_bytes := PackedByteArray()
	var surfaces: Array[Dictionary] = []
	var materials: Array[Dictionary] = []
	var unsupported_material_reason := ""
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		if _surface_primitive_type(mesh, surface_index) != Mesh.PRIMITIVE_TRIANGLES \
				or arrays.size() < Mesh.ARRAY_MAX \
				or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array \
				or not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			return {"unsupported_reason": "rtgi_requires_vertex_normal_uv1"}
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array else PackedVector2Array()
		if vertices.is_empty() or vertices.size() != normals.size():
			return {"unsupported_reason": "rtgi_mesh_attribute_count_mismatch"}
		for vertex_index in vertices.size():
			if not vertices[vertex_index].is_finite() or not normals[vertex_index].is_finite():
				return {"unsupported_reason": "rtgi_mesh_source_contains_nonfinite_position_or_normal"}
		if uvs.is_empty():
			uvs.resize(vertices.size())
		for uv in uvs:
			if not is_finite(uv.x) or not is_finite(uv.y):
				return {"unsupported_reason": "rtgi_mesh_source_contains_nonfinite_uv"}
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] is PackedInt32Array else PackedInt32Array()
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array else PackedFloat32Array()
		var bones_per_vertex := 8 if (_surface_format(mesh, surface_index) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0 else 4
		var skinned := not bones.is_empty() or not weights.is_empty()
		if skinned and (bones.size() != vertices.size() * bones_per_vertex or weights.size() != bones.size()):
			return {"unsupported_reason": "rtgi_skin_attribute_count_mismatch"}
		if skinned:
			for bone_index in bones:
				if bone_index < 0:
					return {"unsupported_reason": "rtgi_skin_bone_index_negative"}
			for bone_weight in weights:
				if not is_finite(bone_weight) or bone_weight < 0.0:
					return {"unsupported_reason": "rtgi_skin_weight_nonfinite_or_negative"}
		var max_weighted_bone_index := -1
		if skinned:
			for influence_index in bones.size():
				if weights[influence_index] > 0.0:
					max_weighted_bone_index = maxi(max_weighted_bone_index, bones[influence_index])
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
		var source_material: Material = material if material != null else _default_material
		var material_row := _capture_material(source_material)
		material_row["source_material_id"] = source_material.get_instance_id()
		material_row["material_state_signature"] = _material_state_signature(source_material)
		material_row["material_signature"] = int(material_row.material_state_signature)
		if not bool(material_row.get("supported", false)):
			if unsupported_material_reason.is_empty():
				unsupported_material_reason = str(material_row.get("reason", "rtgi_material_unsupported"))
		var material_index := materials.size()
		materials.append(material_row)
		var blend_shape_rows: Array[Dictionary] = []
		if mesh is ArrayMesh:
			var shape_arrays: Array = mesh.surface_get_blend_shape_arrays(surface_index)
			if shape_arrays.size() != mesh.get_blend_shape_count():
				return {"unsupported_reason": "rtgi_blend_shape_surface_mismatch"}
			for shape_index in shape_arrays.size():
				var shape: Array = shape_arrays[shape_index]
				if shape.size() < Mesh.ARRAY_MAX or not shape[Mesh.ARRAY_VERTEX] is PackedVector3Array:
					return {"unsupported_reason": "rtgi_blend_shape_vertex_data_unavailable"}
				var shape_vertices: PackedVector3Array = shape[Mesh.ARRAY_VERTEX]
				var shape_normals: PackedVector3Array = shape[Mesh.ARRAY_NORMAL] if shape[Mesh.ARRAY_NORMAL] is PackedVector3Array else PackedVector3Array()
				if shape_vertices.size() != vertices.size() or shape_normals.size() != vertices.size():
					return {"unsupported_reason": "rtgi_blend_shape_attribute_count_mismatch"}
				for shape_vertex_index in shape_vertices.size():
					if not shape_vertices[shape_vertex_index].is_finite() \
							or not shape_normals[shape_vertex_index].is_finite():
						return {"unsupported_reason": "rtgi_blend_shape_source_contains_nonfinite_data"}
				blend_shape_rows.append({"vertices": shape_vertices, "normals": shape_normals})
		var blend_shape_signature: Array = []
		for blend_shape in blend_shape_rows:
			blend_shape_signature.append(blend_shape.vertices.to_byte_array())
			blend_shape_signature.append(blend_shape.normals.to_byte_array())
		var blend_shape_mode := (mesh as ArrayMesh).get_blend_shape_mode() \
				if mesh is ArrayMesh else Mesh.BLEND_SHAPE_MODE_RELATIVE
		var source_geometry_signature := int(hash([packed.to_byte_array(), indices.to_byte_array(),
			bones.to_byte_array(), weights.to_byte_array(), blend_shape_signature,
			blend_shape_mode, _surface_primitive_type(mesh, surface_index)]))
		surfaces.append({"vertex_base_byte": vertex_base, "index_base_byte": index_base,
			"vertex_count": vertices.size(), "index_count": indices.size(), "material_index": material_index,
			"source_geometry_signature": source_geometry_signature,
			"surface_index": surface_index,
			"flags": int(material_row.get("flags", 0)), "bones": bones, "weights": weights,
			"bones_per_vertex": bones_per_vertex, "skinned": skinned,
			"max_weighted_bone_index": max_weighted_bone_index,
			"blend_shapes": blend_shape_rows,
			"blend_shape_mode": blend_shape_mode})
	if surfaces.is_empty():
		return {"unsupported_reason": "rtgi_mesh_has_no_triangle_surfaces"}
	var payload := {"source_mesh_id": mesh.get_instance_id(),
		"vertex_stride_bytes": 32, "vertex_bytes": vertices_bytes,
		"index_bytes": indices_bytes, "surfaces": surfaces, "materials": materials}
	if not unsupported_material_reason.is_empty():
		payload["unsupported_reason"] = unsupported_material_reason
	return payload

func _capture_material(material: Material) -> Dictionary:
	if material == null:
		material = _default_material
	_watch_material(material)
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
	if base.normal_enabled or base.emission_texture != null or base.metallic_texture != null \
			or base.roughness_texture != null or base.uv1_triplanar or base.vertex_color_use_as_albedo \
			or base.next_pass != null or base.detail_enabled or base.heightmap_enabled:
		return {"supported": false, "reason": "rtgi_unsupported_material_features"}
	var texture_data := {}
	if base.albedo_texture != null:
		if not base.albedo_texture is Texture2D:
			return {"supported": false, "reason": "rtgi_albedo_texture_not_2d"}
		_watch_material(base.albedo_texture)
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
	return {"supported": true, "source_material_id": base.get_instance_id(),
		"albedo": base.albedo_color.srgb_to_linear(),
		"metallic": base.metallic, "roughness": base.roughness,
		"specular": base.metallic_specular, "emission_enabled": base.emission_enabled,
		"emission": base.emission.srgb_to_linear(), "emission_energy_multiplier": base.emission_energy_multiplier * (base.emission_intensity if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false) else 1.0),
		"uv_transform": Vector4(base.uv1_scale.x, base.uv1_scale.y, base.uv1_offset.x, base.uv1_offset.y),
		"cull_mode": base.cull_mode, "flags": (1 if base.albedo_texture != null else 0) | (2 if base.cull_mode == BaseMaterial3D.CULL_DISABLED else 0),
		"albedo_texture": texture_data}
