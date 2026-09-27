@tool
class_name FMagicGISceneTracker
extends RefCounted
## Shared scene-boundary and resource-change tracking for Magic GI.

const BROADPHASE_EPSILON := 0.001

static var _watched_objects: Dictionary = {}
static var _resource_revisions: Dictionary = {}
static var _next_resource_prune := 0

static func scene_root(node: Node) -> Node:
	var root := node
	while root.get_parent() != null and not root.get_parent() is Viewport:
		root = root.get_parent()
	return root

static func should_skip_world_boundary(node: Node, root: Node, world: World3D) -> bool:
	if node is Viewport and node != root and node.find_world_3d() != world:
		return true
	if node is Node3D and node != root and node.get_world_3d() != world:
		return true
	return false

## Cheap editor/runtime polling fingerprint. This does not inspect mesh vertices.
static func quick_signature(volume: Node3D) -> int:
	var values: Array = [volume.global_transform, volume.size, volume.probe_spacing,
			volume.surface_offset, volume.bake_distance, volume.terrain_reflectance,
			volume.fallback_material_reflectance]
	var root := scene_root(volume)
	_append_quick_signature(root, root, volume.get_world_3d(), values)
	return hash(values)

static func _append_quick_signature(node: Node, root: Node, world: World3D, values: Array) -> void:
	if should_skip_world_boundary(node, root, world):
		return
	if node is MeshInstance3D and node.mesh != null:
		var mesh: Mesh = node.mesh
		watch_resource(mesh)
		var material_values: Array = []
		for surface in mesh.get_surface_count():
			var material: Material = node.get_active_material(surface)
			if material == null:
				material_values.append([0, resource_revision(null)])
				continue
			var properties: Array = [material.get_instance_id()]
			if material is BaseMaterial3D:
				properties.append_array([material.albedo_color, material.metallic,
						material.transparency, material.albedo_texture.get_instance_id() if material.albedo_texture != null else 0])
				if material.albedo_texture != null:
					watch_resource(material.albedo_texture)
				var emission_texture: Texture2D = material.emission_texture
				if emission_texture != null:
					watch_resource(emission_texture)
				properties.append_array([
						material.emission_on_uv2,
						emission_texture.get_instance_id() if emission_texture != null else 0,
						resource_revision(emission_texture),
						material.cull_mode,
						material.uv1_scale, material.uv1_offset, material.uv2_scale, material.uv2_offset,
						material.uv1_triplanar, material.uv2_triplanar,
						material.texture_repeat, material.texture_filter
				])
			else:
				watch_resource(material)
				properties.append(resource_revision(material))
			material_values.append(properties)
		values.append([node.get_instance_id(), node.global_transform, node.is_visible_in_tree(),
				mesh.get_instance_id(), resource_revision(mesh), mesh.get_surface_count(), material_values])
	elif node.is_class("Terrain3D"):
		var data = node.get("data")
		if data is Object:
			watch_object(data)
		values.append([node.get_instance_id(), node.global_transform, node.is_visible_in_tree(),
				data.get_instance_id() if data is Object else 0, resource_revision(data),
				node.get("vertex_spacing")])
	for child in node.get_children():
		_append_quick_signature(child, root, world, values)

static func watch_resource(resource: Resource) -> void:
	watch_object(resource)

static func watch_object(object_value: Object) -> void:
	if object_value == null:
		return
	var now := Time.get_ticks_msec()
	if now >= _next_resource_prune:
		_prune_watched_objects()
		_next_resource_prune = now + 10000
	var id := object_value.get_instance_id()
	if _watched_objects.has(id):
		return
	_watched_objects[id] = weakref(object_value)
	_resource_revisions[id] = 0
	if object_value.has_signal("changed"):
		object_value.connect("changed", _on_object_changed.bind(id))
	for signal_name in ["maps_changed", "region_map_changed", "height_maps_changed",
			"control_maps_changed", "color_maps_changed", "surface_maps_changed"]:
		if object_value.has_signal(signal_name):
			object_value.connect(signal_name, _on_object_changed.bind(id))
	if object_value.has_signal("maps_edited"):
		object_value.connect("maps_edited", _on_object_area_changed.bind(id))

static func resource_revision(object_value: Object) -> int:
	if object_value == null:
		return 0
	return int(_resource_revisions.get(object_value.get_instance_id(), 0))

static func _on_object_changed(id: int) -> void:
	_resource_revisions[id] = int(_resource_revisions.get(id, 0)) + 1

static func _on_object_area_changed(_area: AABB, id: int) -> void:
	_resource_revisions[id] = int(_resource_revisions.get(id, 0)) + 1

static func _prune_watched_objects() -> void:
	for id in _watched_objects.keys():
		var reference: WeakRef = _watched_objects[id]
		if reference.get_ref() == null:
			_watched_objects.erase(id)
			_resource_revisions.erase(id)
