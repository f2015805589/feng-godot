@tool
class_name FFogRayTracingGeometryRegistry
extends RefCounted
## Main-thread snapshot registry for triangle shadow geometry.
##
## Scene membership is walked once at attach time. Later changes are received
## from SceneTree add/remove notifications; per-frame snapshots inspect only
## registered renderable nodes, never the whole scene tree.

const SNAPSHOT_VERSION := 1

var _root: Node
var _tree: SceneTree
var _world: World3D
var _entries: Dictionary = {} # instance id -> WeakRef
var _mesh_snapshots: Dictionary = {} # mesh instance id -> plain packed-array payload
var _mesh_revisions: Dictionary = {}
var _mesh_dirty: Dictionary = {}
var _mesh_connections: Dictionary = {}
var _alpha_texture_cache: Dictionary = {}
var _alpha_texture_dirty: Dictionary = {}
var _alpha_texture_connections: Dictionary = {}
var _alpha_texture_revisions: Dictionary = {}
var _dynamic_states: Dictionary = {} # instance id -> private baked mesh/cache and source signature
var _dynamic_dirty: Dictionary = {}
var _skeleton_connections: Dictionary = {} # skeleton id -> weak resource and signal callback
var _terrain_mesh_cache: Dictionary = {} # terrain id -> baked mesh and data revision
var _terrain_connections: Dictionary = {} # terrain id -> weak data and signal callbacks
var _cpu_deformation_enabled := false
var _geometry_revision := 0
var _snapshot_revision := 0
var _last_snapshot_signature := 0
var _alpha_payload_revision := 0
var _last_alpha_payload_signature := -1
var _world_generation := 0
var _unsupported_counts: Dictionary = {}


func attach(p_root: Node, p_world: World3D) -> bool:
	if p_root == null or p_world == null or not p_root.is_inside_tree():
		return false
	detach()
	_root = p_root
	_tree = p_root.get_tree()
	_world = p_world
	_world_generation += 1
	if _tree == null:
		detach()
		return false
	if not _tree.node_added.is_connected(_on_node_added):
		_tree.node_added.connect(_on_node_added)
	if not _tree.node_removed.is_connected(_on_node_removed):
		_tree.node_removed.connect(_on_node_removed)
	var pending: Array[Node] = [p_root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		_register_node(node)
		for child in node.get_children():
			pending.append(child)
	return true


func detach() -> void:
	if _tree != null:
		if _tree.node_added.is_connected(_on_node_added):
			_tree.node_added.disconnect(_on_node_added)
		if _tree.node_removed.is_connected(_on_node_removed):
			_tree.node_removed.disconnect(_on_node_removed)
	for mesh_id in _mesh_connections:
		var weak: WeakRef = _mesh_connections[mesh_id].get("resource")
		var resource = weak.get_ref() if weak != null else null
		var callback: Callable = _mesh_connections[mesh_id].get("callback", Callable())
		if is_instance_valid(resource) and callback.is_valid() \
				and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	for texture_id in _alpha_texture_connections:
		var weak: WeakRef = _alpha_texture_connections[texture_id].get("resource")
		var resource = weak.get_ref() if weak != null else null
		var callback: Callable = _alpha_texture_connections[texture_id].get("callback", Callable())
		if is_instance_valid(resource) and callback.is_valid() \
				and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	for skeleton_id in _skeleton_connections:
		var weak: WeakRef = _skeleton_connections[skeleton_id].get("resource")
		var skeleton = weak.get_ref() if weak != null else null
		var callback: Callable = _skeleton_connections[skeleton_id].get("callback", Callable())
		if is_instance_valid(skeleton) and callback.is_valid() \
				and skeleton.skeleton_updated.is_connected(callback):
			skeleton.skeleton_updated.disconnect(callback)
	for terrain_id in _terrain_connections.keys():
		_unwatch_terrain_data(terrain_id)
	_entries.clear()
	_mesh_snapshots.clear()
	_mesh_revisions.clear()
	_mesh_dirty.clear()
	_mesh_connections.clear()
	_alpha_texture_cache.clear()
	_alpha_texture_dirty.clear()
	_alpha_texture_connections.clear()
	_alpha_texture_revisions.clear()
	_dynamic_states.clear()
	_dynamic_dirty.clear()
	_skeleton_connections.clear()
	_terrain_mesh_cache.clear()
	_terrain_connections.clear()
	_unsupported_counts.clear()
	_root = null
	_tree = null
	_world = null
	_last_snapshot_signature = 0
	_alpha_payload_revision += 1
	_last_alpha_payload_signature = -1
	_snapshot_revision += 1
	_world_generation += 1


func get_world_generation() -> int:
	return _world_generation


func set_cpu_deformation_enabled(p_enabled: bool) -> void:
	if _cpu_deformation_enabled == p_enabled:
		return
	_cpu_deformation_enabled = p_enabled
	for instance_id in _dynamic_states:
		_dynamic_dirty[instance_id] = true


func get_snapshot() -> Dictionary:
	if not is_instance_valid(_root) or _world == null or not is_instance_valid(_world):
		return {}
	var geometry_by_id: Dictionary = {}
	var instances: Array[Dictionary] = []
	var unsupported_shadow_geometry: Array[Dictionary] = []
	var alpha_textures: Dictionary = {}
	var alpha_records: Dictionary = {}
	var stale_ids: Array[int] = []
	for instance_id in _entries:
		var weak: WeakRef = _entries[instance_id]
		var node = weak.get_ref() if weak != null else null
		if not is_instance_valid(node):
			stale_ids.append(instance_id)
			continue
		if not node.is_inside_tree() or not _belongs_to_world(node):
			continue
		var node_kind := _node_kind(node)
		if node_kind.is_empty():
			continue
		if node is GeometryInstance3D:
			if not node.is_visible_in_tree() or not _casts_shadow(node):
				continue
		elif node_kind == "terrain3d":
			if not node.is_visible_in_tree() or not _terrain_casts_shadow(node):
				continue
		if node_kind == "unsupported_geometry_instance":
			_append_unsupported_caster(unsupported_shadow_geometry, node,
				"unsupported_geometry_instance:%s" % node.get_class())
			continue
		var layer_info := _get_shadow_layer_mask(node)
		if not bool(layer_info.get("valid", false)):
			_append_unsupported_caster(unsupported_shadow_geometry, node,
				"shadow_caster_layer_mask_unavailable")
			continue
		var layer_mask := int(layer_info["mask"])
		if node_kind == "csg" and not bool(node.call("is_root_shape")):
			continue
		var terrain_result: Dictionary = {}
		var mesh: Mesh
		if node_kind == "terrain3d":
			terrain_result = _capture_terrain_mesh(node)
			mesh = terrain_result.get("mesh", null)
		else:
			mesh = _node_mesh(node, node_kind)
		if mesh == null:
			var reason := str(terrain_result.get("reason", "terrain3d_bake_mesh_unavailable")) \
					if node_kind == "terrain3d" \
					else "shadow_caster_mesh_unavailable:%s" % node.get_class()
			_append_unsupported_caster(unsupported_shadow_geometry, node, reason)
			continue
		var mesh_id := mesh.get_instance_id()
		_watch_mesh(mesh, mesh_id)
		if not _mesh_snapshots.has(mesh_id) or bool(_mesh_dirty.get(mesh_id, false)):
			_mesh_snapshots[mesh_id] = _capture_mesh(mesh)
			_mesh_dirty.erase(mesh_id)
			_geometry_revision += 1
			_mesh_revisions[mesh_id] = int(_mesh_revisions.get(mesh_id, 0)) + 1
		var source_geometry: Dictionary = _mesh_snapshots[mesh_id]
		var source_revision := int(_mesh_revisions.get(mesh_id, 0))
		var deformation := _prepare_dynamic_geometry(node, mesh, source_geometry, source_revision)
		var geometry: Dictionary = deformation.get("geometry", source_geometry)
		var instance_mesh_id := int(deformation.get("mesh_id", mesh_id))
		geometry_by_id[instance_mesh_id] = geometry.merged({
			"mesh_id": instance_mesh_id,
			"mesh_revision": int(deformation.get("mesh_revision", source_revision)),
		}, true)
		var surface_materials := _opaque_surface_materials(geometry) if node_kind == "terrain3d" \
				else _capture_instance_materials(node, mesh, geometry, alpha_textures)
		alpha_records[instance_id] = [mesh_id, source_revision, surface_materials]
		var unsupported_reasons: Array[String] = []
		for reason in geometry.get("unsupported_reasons", []):
			unsupported_reasons.append(str(reason))
		for material in surface_materials:
			if not bool(material.get("supported", false)):
				unsupported_reasons.append(str(material.get("reason", "unsupported_material")))
		if bool(deformation.get("unsupported", false)):
			unsupported_reasons.append(str(deformation.get("reason", "dynamic_geometry_unsupported")))
		if geometry.get("surfaces", []).is_empty():
			unsupported_reasons.append("mesh_has_no_supported_triangle_surfaces")
		if not unsupported_reasons.is_empty():
			unsupported_shadow_geometry.append({
				"instance_id": node.get_instance_id(),
				"mesh_id": instance_mesh_id,
				"reasons": unsupported_reasons,
			})
			for reason in unsupported_reasons:
				_continue_with_reason(reason)
			continue
		if node is MultiMeshInstance3D:
			_append_multimesh_instances(instances, node, mesh_id, surface_materials, layer_mask)
		else:
			instances.append({
				"instance_id": instance_id,
				"source_node_id": instance_id,
				"mesh_id": instance_mesh_id,
				"transform": _node_world_transform(node, node_kind),
				"surface_materials": surface_materials,
				"skinned": bool(deformation.get("skinned", false)),
				"deformation_mode": str(deformation.get("mode", "static")),
				"geometry_source": node_kind,
				"baked_lod": int(terrain_result.get("lod", -1)),
				"visible": true,
				"cast_shadow": true,
				"layer_mask": layer_mask,
			})
	for stale_id in stale_ids:
		_entries.erase(stale_id)
	var alpha_record_ids: Array = alpha_records.keys()
	alpha_record_ids.sort()
	var alpha_signature_records: Array = []
	for record_id in alpha_record_ids:
		alpha_signature_records.append([record_id, alpha_records[record_id]])
	# `_ensure_alpha_buffers()` packs instance metadata in the exact order used
	# below for TLAS custom indices. Include that ordered mapping in the alpha
	# cache key, but omit transforms so movement only rebuilds the TLAS.
	var alpha_instance_mapping: Array = []
	for custom_index in instances.size():
		var instance: Dictionary = instances[custom_index]
		alpha_instance_mapping.append([
			custom_index,
			int(instance.get("instance_id", 0)),
			int(instance.get("source_node_id", 0)),
			int(instance.get("mesh_id", 0)),
			int(instance.get("layer_mask", 0)),
			int(instance.get("multimesh_index", -1)),
			instance.get("surface_materials", []),
		])
	var alpha_signature := hash([alpha_signature_records, alpha_instance_mapping])
	if alpha_signature != _last_alpha_payload_signature:
		_alpha_payload_revision += 1
		_last_alpha_payload_signature = alpha_signature
	var geometry_ids: Array = geometry_by_id.keys()
	geometry_ids.sort()
	var geometries: Array[Dictionary] = []
	for mesh_id in geometry_ids:
		geometries.append({
			"mesh_id": mesh_id,
			"mesh_revision": int(geometry_by_id[mesh_id].get("mesh_revision", 0)),
			"surfaces": geometry_by_id[mesh_id]["surfaces"],
		})
	var signature := hash([_world_generation, _geometry_revision, instances])
	if signature != _last_snapshot_signature:
		_snapshot_revision += 1
		_last_snapshot_signature = signature
	return {
		"abi_version": SNAPSHOT_VERSION,
		"world_generation": _world_generation,
		"snapshot_revision": _snapshot_revision,
		"alpha_payload_revision": _alpha_payload_revision,
		"geometry_revision": _geometry_revision,
		"geometries": geometries,
		"instances": instances,
		"alpha_textures": alpha_textures.values(),
		"unsupported_shadow_geometry": unsupported_shadow_geometry,
		"unsupported_counts": _unsupported_counts.duplicate(),
		"geometry_mode": "triangle_surfaces_with_per_instance_materials",
	}


func get_capability_report() -> Dictionary:
	return {
		"supports_static_array_mesh": true,
		"supports_primitive_mesh": true,
		"supports_csg_root_mesh": true,
		"csg_mesh_updates_are_deferred": true,
		"supports_terrain3d_bake_mesh": true,
		"terrain3d_bake_lod_matches_screen_lod": false,
		"unsupported_geometry_instances_force_complete_raster_fallback": true,
		"supports_mesh_instance_transform_updates": true,
		"supports_multimesh_transforms": true,
		"supports_visible_and_cast_shadow_filtering": true,
		"supports_full_32_bit_instance_layers": true,
		"unknown_instance_layer_masks_force_complete_raster_fallback": true,
		"uses_highest_detail_mesh_lod": true,
		"captures_all_mesh_lods": true,
		"supports_screen_lod_selection": false,
		"supports_alpha_scissor_geometry": true,
		"supports_alpha_hash_geometry": true,
		"supports_transparent_geometry": false,
		"supports_skinned_geometry": _cpu_deformation_enabled,
		"supports_blend_shape_geometry": _cpu_deformation_enabled,
		"cpu_deformation_opt_in": true,
		"cpu_deformation_may_stall_renderer": true,
		"supports_arbitrary_vertex_deformation": false,
		"supports_screen_lod_match": false,
		"per_frame_scene_tree_scan": false,
	}


func _on_node_added(p_node: Node) -> void:
	if p_node != null:
		call_deferred("_register_node_if_ready", weakref(p_node))


func _register_node_if_ready(p_weak: WeakRef) -> void:
	var node = p_weak.get_ref() if p_weak != null else null
	if is_instance_valid(node):
		_register_node(node)


func _on_node_removed(p_node: Node) -> void:
	if is_instance_valid(p_node):
		var instance_id := p_node.get_instance_id()
		_entries.erase(instance_id)
		_dynamic_states.erase(instance_id)
		_dynamic_dirty.erase(instance_id)
		_unwatch_terrain_data(instance_id)
		_terrain_mesh_cache.erase(instance_id)


func _register_node(p_node: Node) -> void:
	if not p_node is Node3D or not p_node.is_inside_tree() or not _belongs_to_world(p_node):
		return
	if _node_kind(p_node).is_empty():
		return
	_entries[p_node.get_instance_id()] = weakref(p_node)


func _belongs_to_world(p_node: Node3D) -> bool:
	return p_node.get_world_3d() == _world


func _node_kind(p_node: Node) -> String:
	if p_node is MeshInstance3D:
		return "mesh_instance"
	if p_node is MultiMeshInstance3D:
		return "multimesh_instance"
	if p_node.is_class("CSGShape3D") and p_node.has_method("get_meshes"):
		return "csg"
	if _is_terrain3d_node(p_node):
		return "terrain3d"
	if p_node is GeometryInstance3D:
		return "unsupported_geometry_instance"
	return ""


func _is_terrain3d_node(p_node: Node) -> bool:
	return p_node is Node3D and p_node.is_class("Terrain3D") \
			and p_node.has_method("bake_mesh") and p_node.has_method("get_data")


func _node_mesh(p_node: Node, p_node_kind: String) -> Mesh:
	match p_node_kind:
		"mesh_instance":
			return (p_node as MeshInstance3D).mesh
		"multimesh_instance":
			var multimesh := (p_node as MultiMeshInstance3D).multimesh
			return multimesh.mesh if multimesh != null else null
		"csg":
			var meshes: Array = p_node.call("get_meshes")
			if meshes.size() >= 2 and meshes[1] is Mesh:
				return meshes[1] as Mesh
	return null


func _node_world_transform(p_node: Node3D, p_node_kind: String) -> Transform3D:
	if p_node_kind == "csg":
		var meshes: Array = p_node.call("get_meshes")
		if not meshes.is_empty() and meshes[0] is Transform3D:
			return p_node.global_transform * meshes[0]
	return p_node.global_transform


func _terrain_casts_shadow(p_node: Node) -> bool:
	return int(p_node.get("cast_shadows")) != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _capture_terrain_mesh(p_terrain: Node) -> Dictionary:
	var terrain_id := p_terrain.get_instance_id()
	var data = p_terrain.call("get_data")
	if data == null or not is_instance_valid(data) or not data.has_method("get_region_locations"):
		return {"mesh": null, "reason": "terrain3d_data_unavailable"}
	_watch_terrain_data(terrain_id, data)
	var region_size := int(p_terrain.get("region_size"))
	var vertex_spacing := float(p_terrain.get("vertex_spacing"))
	var cache: Dictionary = _terrain_mesh_cache.get(terrain_id, {})
	var cache_key := [data.get_instance_id(), region_size, vertex_spacing]
	if cache.get("cache_key", []) != cache_key or bool(cache.get("dirty", true)):
		var locations: Array = data.call("get_region_locations")
		var region_count := locations.size()
		if region_count <= 0 or region_size <= 0 or vertex_spacing <= 0.0:
			cache = {"cache_key": cache_key, "mesh": null, "dirty": false,
				"reason": "terrain3d_has_no_bakeable_regions", "revision": int(cache.get("revision", 0)) + 1}
		else:
			var lod := _terrain_bake_lod(region_count, region_size)
			if lod < 0:
				cache = {"cache_key": cache_key, "mesh": null, "dirty": false,
					"reason": "terrain3d_bake_exceeds_triangle_budget", "revision": int(cache.get("revision", 0)) + 1}
			else:
				# Terrain3D's public bake_mesh returns local-space triangles. LOD 0 is
				# the exact height-map grid; larger terrains use a coarser cached LOD.
				var baked_mesh = p_terrain.call("bake_mesh", lod, 0) # HEIGHT_FILTER_NEAREST.
				if not baked_mesh is Mesh or baked_mesh.get_surface_count() <= 0:
					cache = {"cache_key": cache_key, "mesh": null, "dirty": false,
						"reason": "terrain3d_bake_mesh_empty", "revision": int(cache.get("revision", 0)) + 1,
						"lod": lod}
				else:
					cache = {"cache_key": cache_key, "mesh": baked_mesh, "dirty": false,
						"revision": int(cache.get("revision", 0)) + 1, "lod": lod,
						"region_count": region_count}
		_terrain_mesh_cache[terrain_id] = cache
	return cache


func _terrain_bake_lod(p_region_count: int, p_region_size: int) -> int:
	const MAX_BAKED_TRIANGLES := 1_000_000
	var estimated_triangles := maxi(1, p_region_count * p_region_size * p_region_size * 2)
	var lod := 0
	while estimated_triangles > MAX_BAKED_TRIANGLES and lod < 8:
		estimated_triangles = ceili(float(estimated_triangles) / 4.0)
		lod += 1
	return lod if estimated_triangles <= MAX_BAKED_TRIANGLES else -1


func _watch_terrain_data(p_terrain_id: int, p_data: Object) -> void:
	var current: Dictionary = _terrain_connections.get(p_terrain_id, {})
	var existing_weak: WeakRef = current.get("resource")
	if existing_weak != null and existing_weak.get_ref() == p_data:
		return
	_unwatch_terrain_data(p_terrain_id)
	var callbacks: Array[Dictionary] = []
	for signal_name in ["maps_edited", "region_map_changed", "height_maps_changed", "control_maps_changed"]:
		if not p_data.has_signal(signal_name):
			continue
		var callback := Callable(self, "_on_terrain_data_changed").bind(p_terrain_id)
		if not p_data.is_connected(signal_name, callback):
			p_data.connect(signal_name, callback)
		callbacks.append({"signal": signal_name, "callback": callback})
	_terrain_connections[p_terrain_id] = {"resource": weakref(p_data), "callbacks": callbacks}


func _unwatch_terrain_data(p_terrain_id: int) -> void:
	var connection: Dictionary = _terrain_connections.get(p_terrain_id, {})
	var weak: WeakRef = connection.get("resource")
	var data = weak.get_ref() if weak != null else null
	if is_instance_valid(data):
		for record in connection.get("callbacks", []):
			var signal_name := StringName(record.get("signal", ""))
			var callback: Callable = record.get("callback", Callable())
			if data.has_signal(signal_name) and data.is_connected(signal_name, callback):
				data.disconnect(signal_name, callback)
	_terrain_connections.erase(p_terrain_id)


func _on_terrain_data_changed(p_terrain_id: int, _p_change: Variant = null) -> void:
	if _terrain_mesh_cache.has(p_terrain_id):
		_terrain_mesh_cache[p_terrain_id]["dirty"] = true


func _append_unsupported_caster(p_output: Array[Dictionary], p_node: Node, p_reason: String) -> void:
	p_output.append({
		"instance_id": p_node.get_instance_id(),
		"mesh_id": 0,
		"node_class": p_node.get_class(),
		"reasons": [p_reason],
	})
	_continue_with_reason(p_reason)


func _opaque_surface_materials(p_geometry: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for _surface in p_geometry.get("surfaces", []):
		result.append({"supported": true, "mode": "opaque", "base_alpha": 1.0})
	return result


func _prepare_dynamic_geometry(p_node: Node, p_mesh: Mesh, p_geometry: Dictionary,
		p_source_revision: int) -> Dictionary:
	var has_weights := bool(p_geometry.get("has_skin_weights", false))
	var has_blend_shapes := bool(p_geometry.get("has_blend_shapes", false))
	if not has_weights and not has_blend_shapes:
		return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
			"mesh_revision": p_source_revision, "mode": "static"}
	if not _cpu_deformation_enabled:
		return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
			"mesh_revision": p_source_revision, "skinned": has_weights,
			"unsupported": true, "reason": "cpu_deformation_opt_in_required"}
	if not p_node is MeshInstance3D or not p_mesh is ArrayMesh:
		return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
			"mesh_revision": p_source_revision, "skinned": has_weights,
			"unsupported": true, "reason": "deformation_requires_arraymesh_instance"}
	var mesh_instance := p_node as MeshInstance3D
	var skeleton: Skeleton3D
	var skeleton_rid := RID()
	if has_weights:
		var skeleton_path := mesh_instance.get_skeleton_path()
		var resolved_skeleton := mesh_instance.get_node_or_null(skeleton_path) \
				if not skeleton_path.is_empty() else null
		if not resolved_skeleton is Skeleton3D:
			return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
				"mesh_revision": p_source_revision, "skinned": true,
				"unsupported": true, "reason": "weighted_mesh_has_no_resolved_skeleton3d"}
		skeleton = resolved_skeleton as Skeleton3D
		var skin_reference: SkinReference = mesh_instance.get_skin_reference()
		if skin_reference == null:
			return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
				"mesh_revision": p_source_revision, "skinned": true,
				"unsupported": true, "reason": "weighted_mesh_has_no_registered_skin_reference"}
		skeleton_rid = skin_reference.get_skeleton()
		if not skeleton_rid.is_valid() or RenderingServer.skeleton_get_bone_count(skeleton_rid) <= 0:
			return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
				"mesh_revision": p_source_revision, "skinned": true,
				"unsupported": true, "reason": "weighted_mesh_skeleton_rid_is_invalid"}
		_watch_skeleton(skeleton)
	var blend_weights := PackedFloat32Array()
	if has_blend_shapes:
		blend_weights.resize(mesh_instance.get_blend_shape_count())
		for blend_index in blend_weights.size():
			blend_weights[blend_index] = mesh_instance.get_blend_shape_value(blend_index)
	var instance_id := mesh_instance.get_instance_id()
	var skeleton_id := skeleton.get_instance_id() if skeleton != null else 0
	var cached: Dictionary = _dynamic_states.get(instance_id, {})
	var changed: bool = bool(_dynamic_dirty.get(instance_id, true)) \
			or int(cached.get("source_mesh_id", -1)) != p_mesh.get_instance_id() \
			or int(cached.get("source_revision", -1)) != p_source_revision \
			or int(cached.get("skeleton_id", 0)) != skeleton_id \
			or cached.get("blend_weights", PackedFloat32Array()) != blend_weights
	if changed:
		var output_mesh: ArrayMesh = cached.get("baked_mesh", null)
		if output_mesh == null:
			output_mesh = ArrayMesh.new()
		if has_weights:
			output_mesh = mesh_instance.bake_mesh_from_current_skeleton_pose(output_mesh)
			if output_mesh == null:
				return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
					"mesh_revision": p_source_revision, "skinned": true,
					"unsupported": true, "reason": "skeleton_pose_bake_failed"}
			if has_blend_shapes and not _apply_blend_shapes_to_skinned_mesh(
					p_mesh as ArrayMesh, output_mesh, blend_weights, skeleton_rid):
				return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
					"mesh_revision": p_source_revision, "skinned": true,
					"unsupported": true, "reason": "combined_skin_and_blendshape_bake_failed"}
		elif has_blend_shapes:
			output_mesh = mesh_instance.bake_mesh_from_current_blend_shape_mix(output_mesh)
			if output_mesh == null:
				return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
					"unsupported": true, "reason": "blendshape_bake_failed"}
		var baked_geometry := _capture_mesh(output_mesh)
		if baked_geometry.get("surfaces", []).is_empty() \
				or not baked_geometry.get("unsupported_reasons", []).is_empty():
			return {"mesh_id": p_mesh.get_instance_id(), "geometry": p_geometry,
				"unsupported": true, "reason": "deformed_mesh_is_not_triangle_geometry"}
		_geometry_revision += 1
		var dynamic_revision := int(cached.get("dynamic_revision", 0)) + 1
		cached = {
			"source_mesh_id": p_mesh.get_instance_id(),
			"source_revision": p_source_revision,
			"skeleton_id": skeleton_id,
			"blend_weights": blend_weights,
			"baked_mesh": output_mesh,
			"geometry": baked_geometry,
			"dynamic_revision": dynamic_revision,
			"mesh_id": output_mesh.get_instance_id(),
		}
		_dynamic_states[instance_id] = cached
		_dynamic_dirty.erase(instance_id)
	return {
		"mesh_id": int(cached.get("mesh_id", p_mesh.get_instance_id())),
		"geometry": cached.get("geometry", p_geometry),
		"mesh_revision": int(cached.get("dynamic_revision", p_source_revision)),
		"skinned": has_weights,
		"mode": "cpu_skin_and_blendshape" if has_weights and has_blend_shapes else \
				("cpu_skin" if has_weights else "cpu_blendshape"),
	}


func _watch_skeleton(p_skeleton: Skeleton3D) -> void:
	var skeleton_id := p_skeleton.get_instance_id()
	if _skeleton_connections.has(skeleton_id):
		return
	var callback := Callable(self, "_on_skeleton_updated").bind(skeleton_id)
	if not p_skeleton.skeleton_updated.is_connected(callback):
		p_skeleton.skeleton_updated.connect(callback)
	_skeleton_connections[skeleton_id] = {"resource": weakref(p_skeleton), "callback": callback}


func _on_skeleton_updated(p_skeleton_id: int) -> void:
	for instance_id in _dynamic_states:
		if int(_dynamic_states[instance_id].get("skeleton_id", 0)) == p_skeleton_id:
			_dynamic_dirty[instance_id] = true


func _apply_blend_shapes_to_skinned_mesh(p_source: ArrayMesh,
		p_baked: ArrayMesh, p_blend_weights: PackedFloat32Array, p_skeleton: RID) -> bool:
	if p_source.get_surface_count() != p_baked.get_surface_count():
		return false
	var bone_count := RenderingServer.skeleton_get_bone_count(p_skeleton)
	if bone_count <= 0:
		return false
	var bone_transforms: Array[Transform3D] = []
	bone_transforms.resize(bone_count)
	for bone_index in bone_count:
		bone_transforms[bone_index] = RenderingServer.skeleton_bone_get_transform(p_skeleton, bone_index)
	var rewritten_surfaces: Array[Dictionary] = []
	for surface_index in p_source.get_surface_count():
		var source_arrays := p_source.surface_get_arrays(surface_index)
		var baked_arrays := p_baked.surface_get_arrays(surface_index)
		if source_arrays.size() < Mesh.ARRAY_MAX or baked_arrays.size() < Mesh.ARRAY_MAX:
			return false
		var source_vertices: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
		var baked_vertices: PackedVector3Array = baked_arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = source_arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = source_arrays[Mesh.ARRAY_WEIGHTS]
		var bones_per_vertex := 8 if (p_source.surface_get_format(surface_index) \
				& Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0 else 4
		if source_vertices.size() != baked_vertices.size() \
				or bones.size() != source_vertices.size() * bones_per_vertex \
				or weights.size() != bones.size():
			return false
		var shape_arrays: Array = p_source.surface_get_blend_shape_arrays(surface_index)
		if shape_arrays.size() != p_blend_weights.size():
			return false
		for shape_index in p_blend_weights.size():
			if is_zero_approx(p_blend_weights[shape_index]):
				continue
			var shape: Array = shape_arrays[shape_index]
			if shape.size() < Mesh.ARRAY_MAX:
				return false
			var shape_vertices: PackedVector3Array = shape[Mesh.ARRAY_VERTEX]
			if shape_vertices.size() != source_vertices.size():
				return false
		var blend_deltas := PackedVector3Array()
		blend_deltas.resize(source_vertices.size())
		for vertex_index in source_vertices.size():
			var source_vertex := source_vertices[vertex_index]
			var morphed_vertex := source_vertex
			for shape_index in p_blend_weights.size():
				var blend_weight := p_blend_weights[shape_index]
				if is_zero_approx(blend_weight):
					continue
				var shape: Array = shape_arrays[shape_index]
				var shape_vertices: PackedVector3Array = shape[Mesh.ARRAY_VERTEX]
				var shape_vertex := shape_vertices[vertex_index]
				if p_source.get_blend_shape_mode() == Mesh.BLEND_SHAPE_MODE_NORMALIZED:
					morphed_vertex += source_vertex.lerp(shape_vertex, blend_weight) - source_vertex
				else:
					morphed_vertex += shape_vertex * blend_weight
			var morph_delta := morphed_vertex - source_vertex
			var skinned_delta := morph_delta
			for influence in bones_per_vertex:
				var influence_offset := vertex_index * bones_per_vertex + influence
				var influence_weight := weights[influence_offset]
				if influence_weight < 0.00000011920928955078125:
					continue
				var bone_index := bones[influence_offset]
				if bone_index < 0 or bone_index >= bone_transforms.size():
					return false
				var transformed_delta := bone_transforms[bone_index].basis * morph_delta
				skinned_delta += (transformed_delta - morph_delta) * influence_weight
			blend_deltas[vertex_index] = skinned_delta
		var result_vertices := baked_vertices.duplicate()
		for vertex_index in result_vertices.size():
			result_vertices[vertex_index] += blend_deltas[vertex_index]
		baked_arrays[Mesh.ARRAY_VERTEX] = result_vertices
		rewritten_surfaces.append({
			"arrays": baked_arrays,
			"format": p_baked.surface_get_format(surface_index),
		})
	p_baked.clear_surfaces()
	for surface in rewritten_surfaces:
		p_baked.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface["arrays"], [], {}, int(surface["format"]))
	return true


func _casts_shadow(p_node: GeometryInstance3D) -> bool:
	return p_node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _get_shadow_layer_mask(p_node: Node) -> Dictionary:
	if p_node is VisualInstance3D:
		return {"valid": true, "mask": int(p_node.layers)}
	for property in p_node.get_property_list():
		if str(property.get("name", "")) == "layers":
			var value: Variant = p_node.get("layers")
			if value is int:
				return {"valid": true, "mask": int(value)}
	return {"valid": false, "mask": 0}


func _append_multimesh_instances(p_instances: Array[Dictionary], p_node: MultiMeshInstance3D,
		p_mesh_id: int, p_surface_materials: Array[Dictionary], p_layer_mask: int) -> void:
	var multimesh: MultiMesh = p_node.multimesh
	if multimesh == null:
		return
	var count := multimesh.instance_count
	if multimesh.visible_instance_count >= 0:
		count = mini(count, multimesh.visible_instance_count)
	for subindex in count:
		p_instances.append({
			"instance_id": hash([p_node.get_instance_id(), subindex]) & 0x7fffffff,
			"source_node_id": p_node.get_instance_id(),
			"mesh_id": p_mesh_id,
			"transform": p_node.global_transform * multimesh.get_instance_transform(subindex),
			"surface_materials": p_surface_materials,
			"skinned": false,
			"visible": true,
			"cast_shadow": true,
			"layer_mask": p_layer_mask,
			"multimesh_index": subindex,
		})


func _watch_mesh(p_mesh: Mesh, p_mesh_id: int) -> void:
	if _mesh_connections.has(p_mesh_id):
		return
	var callback := Callable(self, "_on_mesh_changed").bind(p_mesh_id)
	if not p_mesh.changed.is_connected(callback):
		p_mesh.changed.connect(callback)
	_mesh_connections[p_mesh_id] = {"resource": weakref(p_mesh), "callback": callback}
	_mesh_dirty[p_mesh_id] = true


func _on_mesh_changed(p_mesh_id: int) -> void:
	_mesh_dirty[p_mesh_id] = true


func _capture_mesh(p_mesh: Mesh) -> Dictionary:
	var surfaces: Array[Dictionary] = []
	var unsupported_reasons: Array[String] = []
	var has_skin_weights := false
	var has_blend_shapes := p_mesh is ArrayMesh and (p_mesh as ArrayMesh).get_blend_shape_count() > 0
	for surface in p_mesh.get_surface_count():
		var server_surface: Dictionary = RenderingServer.mesh_get_surface(p_mesh.get_rid(), surface)
		if int(server_surface.get("primitive", -1)) != Mesh.PRIMITIVE_TRIANGLES:
			unsupported_reasons.append("non_triangle_primitive")
			continue
		var arrays: Array
		if p_mesh is PrimitiveMesh:
			arrays = p_mesh.get_mesh_arrays()
		else:
			arrays = p_mesh.surface_get_arrays(surface)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			unsupported_reasons.append("surface_has_no_vertices")
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			unsupported_reasons.append("surface_has_empty_vertices")
			continue
		var index_data = arrays[Mesh.ARRAY_INDEX]
		var indices: PackedInt32Array = index_data if index_data != null else PackedInt32Array()
		if indices.is_empty():
			if vertices.size() % 3 != 0:
				unsupported_reasons.append("non_indexed_vertex_count_not_triangular")
				continue
			indices.resize(vertices.size())
			for index in vertices.size():
				indices[index] = index
		if indices.size() % 3 != 0:
			unsupported_reasons.append("index_count_not_triangular")
			continue
		var valid := true
		for index in indices:
			if index < 0 or index >= vertices.size():
				valid = false
				break
		if not valid:
			unsupported_reasons.append("index_out_of_range")
			continue
		var uvs := PackedVector2Array()
		if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] != null:
			uvs = arrays[Mesh.ARRAY_TEX_UV]
		var colors := PackedColorArray()
		if arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] != null:
			colors = arrays[Mesh.ARRAY_COLOR]
		var lods := _capture_lods(server_surface, vertices.size())
		if arrays.size() > Mesh.ARRAY_WEIGHTS and arrays[Mesh.ARRAY_WEIGHTS] != null:
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for weight in weights:
				if weight > 0.0:
					has_skin_weights = true
					break
		surfaces.append({
			"surface_index": surface,
			"vertices": vertices,
			"indices": indices,
			"lods": lods,
			"uvs": uvs,
			"colors": colors,
			"vertex_stride": 12,
			"vertex_format": RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT,
			"index_format": RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,
		})
	return {"mesh_id": p_mesh.get_instance_id(), "surfaces": surfaces,
		"has_skin_weights": has_skin_weights,
		"has_blend_shapes": has_blend_shapes,
		"unsupported_reasons": unsupported_reasons}


func _capture_lods(p_surface_data: Dictionary, p_vertex_count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var source_lods: Array = p_surface_data.get("lods", [])
	for lod_data in source_lods:
		if not lod_data is Dictionary:
			continue
		var bytes: PackedByteArray = lod_data.get("index_data", PackedByteArray())
		var index_width := 2 if p_vertex_count <= 65536 else 4
		if bytes.is_empty() or bytes.size() % index_width != 0:
			_continue_with_reason("invalid_lod_index_data")
			continue
		var indices := PackedInt32Array()
		indices.resize(bytes.size() / index_width)
		for index in indices.size():
			indices[index] = bytes.decode_u16(index * 2) if index_width == 2 else bytes.decode_u32(index * 4)
		if indices.size() % 3 != 0:
			_continue_with_reason("non_triangle_lod_index_data")
			continue
		var valid := true
		for index in indices:
			if index < 0 or index >= p_vertex_count:
				valid = false
				break
		if not valid:
			_continue_with_reason("lod_index_out_of_range")
			continue
		result.append({
			"edge_length": float(lod_data.get("edge_length", 0.0)),
			"indices": indices,
		})
	return result


func _capture_instance_materials(p_node: GeometryInstance3D, p_mesh: Mesh,
		p_geometry: Dictionary, p_alpha_textures: Dictionary) -> Array[Dictionary]:
	var materials: Array[Dictionary] = []
	var surfaces_by_index: Dictionary = {}
	for surface in p_geometry.get("surfaces", []):
		surfaces_by_index[int(surface.get("surface_index", -1))] = surface
	for surface in p_mesh.get_surface_count():
		var material := _active_material_for_surface(p_node, p_mesh, surface)
		var snapshot := _material_snapshot(material)
		var base_material := material as BaseMaterial3D
		if bool(snapshot.get("supported", false)) and str(snapshot.get("mode", "opaque")) in ["scissor", "hash"] \
				and base_material != null and base_material.albedo_texture != null:
			var captured_surface: Dictionary = surfaces_by_index.get(surface, {})
			if captured_surface.get("uvs", PackedVector2Array()).is_empty():
				snapshot["supported"] = false
				snapshot["reason"] = "alpha_texture_surface_has_no_uv1"
			else:
				var texture: Texture2D = base_material.albedo_texture
				var texture_snapshot := _capture_alpha_texture(texture)
				if not bool(texture_snapshot.get("valid", false)):
					snapshot["supported"] = false
					snapshot["reason"] = str(texture_snapshot.get("reason", "alpha_texture_unavailable"))
				elif bool(texture_snapshot.get("has_mipmaps", false)) \
						and int(snapshot.get("texture_filter", 1)) >= 2:
					snapshot["supported"] = false
					snapshot["reason"] = "mip_filtered_alpha_texture_requires_derivative_lod"
				else:
					var texture_id := texture.get_instance_id()
					snapshot["alpha_texture_id"] = texture_id
					snapshot["alpha_texture_revision"] = int(texture_snapshot.get("revision", 0))
					snapshot["alpha_texture_width"] = int(texture_snapshot["width"])
					snapshot["alpha_texture_height"] = int(texture_snapshot["height"])
					p_alpha_textures[texture_id] = texture_snapshot
		materials.append(snapshot)
	return materials


func _active_material_for_surface(p_node: GeometryInstance3D, p_mesh: Mesh, p_surface: int) -> Material:
	if p_node.material_override != null:
		return p_node.material_override
	if p_node is MeshInstance3D:
		var mesh_instance := p_node as MeshInstance3D
		var override_material: Material = mesh_instance.get_surface_override_material(p_surface)
		if override_material != null:
			return override_material
	return p_mesh.surface_get_material(p_surface)


func _material_snapshot(p_material: Material) -> Dictionary:
	if p_material == null:
		return {"supported": true, "mode": "opaque", "base_alpha": 1.0}
	if not p_material is BaseMaterial3D:
		return {"supported": false, "reason": "custom_material_alpha_not_supported"}
	var material: BaseMaterial3D = p_material
	var base := {
		"supported": true,
		"base_alpha": material.albedo_color.a,
		"uv_scale": Vector2(material.uv1_scale.x, material.uv1_scale.y),
		"uv_offset": Vector2(material.uv1_offset.x, material.uv1_offset.y),
		"uses_vertex_color_alpha": material.vertex_color_use_as_albedo,
		"alpha_texture_id": 0,
		"alpha_texture_repeat": material.texture_repeat,
		"texture_filter": material.texture_filter,
	}
	if material.uv1_triplanar:
		base["supported"] = false
		base["reason"] = "triplanar_alpha_texture_not_supported"
		return base
	match material.transparency:
		BaseMaterial3D.TRANSPARENCY_DISABLED:
			base["mode"] = "opaque"
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			base["mode"] = "scissor"
			base["threshold"] = material.alpha_scissor_threshold
		BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
			if material.alpha_antialiasing_mode != BaseMaterial3D.ALPHA_ANTIALIASING_OFF:
				base["supported"] = false
				base["reason"] = "alpha_antialiasing_not_supported"
				return base
			base["mode"] = "hash"
			base["hash_scale"] = material.alpha_hash_scale
		_:
			base["supported"] = false
			base["reason"] = "transparent_material_not_supported"
	return base


func _capture_alpha_texture(p_texture: Texture2D) -> Dictionary:
	if p_texture == null:
		return {"valid": true, "width": 0, "height": 0, "alpha": PackedByteArray(), "revision": 0}
	var texture_id := p_texture.get_instance_id()
	_watch_alpha_texture(p_texture, texture_id)
	if not _alpha_texture_cache.has(texture_id) or bool(_alpha_texture_dirty.get(texture_id, false)):
		var image := p_texture.get_image()
		if image == null or image.is_empty():
			return {"valid": false, "reason": "alpha_texture_has_no_cpu_image"}
		if image.is_compressed() and image.decompress() != OK:
			return {"valid": false, "reason": "alpha_texture_cannot_be_decompressed"}
		var width := image.get_width()
		var height := image.get_height()
		if width <= 0 or height <= 0 or width * height > 16_777_216:
			return {"valid": false, "reason": "alpha_texture_dimensions_out_of_range"}
		var alpha := PackedByteArray()
		alpha.resize(width * height)
		for y in height:
			for x in width:
				alpha[y * width + x] = roundi(clampf(image.get_pixel(x, y).a, 0.0, 1.0) * 255.0)
		var revision := int(_alpha_texture_revisions.get(texture_id, 0)) + 1
		_alpha_texture_revisions[texture_id] = revision
		_alpha_texture_cache[texture_id] = {"valid": true, "width": width, "height": height,
			"texture_id": texture_id, "alpha": alpha, "revision": revision,
			"has_mipmaps": image.has_mipmaps()}
		_alpha_texture_dirty.erase(texture_id)
	return _alpha_texture_cache[texture_id]


func _watch_alpha_texture(p_texture: Texture2D, p_texture_id: int) -> void:
	if _alpha_texture_connections.has(p_texture_id):
		return
	var callback := Callable(self, "_on_alpha_texture_changed").bind(p_texture_id)
	if not p_texture.changed.is_connected(callback):
		p_texture.changed.connect(callback)
	_alpha_texture_connections[p_texture_id] = {"resource": weakref(p_texture), "callback": callback}
	_alpha_texture_dirty[p_texture_id] = true


func _on_alpha_texture_changed(p_texture_id: int) -> void:
	_alpha_texture_dirty[p_texture_id] = true


func _continue_with_reason(p_reason: String) -> void:
	_unsupported_counts[p_reason] = int(_unsupported_counts.get(p_reason, 0)) + 1
