@tool
class_name FMagicGISceneTracker
extends RefCounted
## Shared scene-boundary and resource-change tracking for Magic GI.

const BROADPHASE_EPSILON := 0.001
const SCENE_SCAN_TTL_MSEC := 250
const SIGNATURE_SCHEMA_LEGACY := 0
const SIGNATURE_SCHEMA_ROOT_RELATIVE := 1
const SIGNATURE_SCHEMA_CURRENT := SIGNATURE_SCHEMA_ROOT_RELATIVE
static var _watched_objects: Dictionary = {}
static var _next_resource_prune := 0
static var _scene_scans: Dictionary = {} ## "root_id:world_id" -> {checked_at, signature}

static func is_signature_schema_supported(schema_version: int) -> bool:
	return schema_version == SIGNATURE_SCHEMA_LEGACY \
			or schema_version == SIGNATURE_SCHEMA_CURRENT

static func scene_root(node: Node) -> Node:
	var root := node
	while root.get_parent() != null and not root.get_parent() is Viewport:
		root = root.get_parent()
	return root

static func should_skip_world_boundary(node: Node, root: Node, world: World3D) -> bool:
	if node is Viewport and node != root and node.find_world_3d() != world:
		return true
	if node is Node3D and node != root and _world_for_node(node as Node3D) != world:
		return true
	return false

static func _world_for_node(node: Node3D) -> World3D:
	# The viewport already identifies the correct world while a PackedScene is
	# entering the tree, before Node3D.get_world_3d() becomes safe to call.
	var viewport := node.get_viewport()
	return viewport.find_world_3d() if viewport != null else null

static func scene_relative_path(node: Node) -> String:
	var root := scene_root(node)
	return String(root.get_path_to(node))

static func scene_identity(node: Node) -> String:
	var root := scene_root(node)
	var identity := String(root.scene_file_path)
	return identity if not identity.is_empty() else "unsaved"

## Cheap editor/runtime polling fingerprint. This does not inspect mesh vertices.
## The scene walk is shared per (root, world) for a short window so several
## volumes in one scene amortize a single traversal across their 1s checks.
static func quick_signature(volume: Node3D) -> int:
	return hash([_volume_signature(volume), quick_source_signature(volume)])

## Uncached watcher used after an explicit Refresh or Bake. Normal editor polling
## keeps the shared short-lived traversal above; pointer drags never call either.
static func quick_signature_uncached(volume: Node3D) -> int:
	return hash([_volume_signature(volume), quick_source_signature_uncached(volume)])

## Session-local watcher. IDs/revisions are valid here because this is compared
## only during the current editor/runtime session.
static func quick_source_signature(volume: Node3D) -> int:
	return hash([_physical_light_units_enabled(), _scene_scan_signature(volume, false)])

static func quick_source_signature_uncached(volume: Node3D) -> int:
	return hash([_physical_light_units_enabled(), _scene_scan_signature(volume, true)])

## Stable persisted source fingerprint. Mesh, texture and Terrain contents are
## read only at load/bake boundaries, never during transform notifications or
## regular editor polling.
static func stable_scene_signature(volume: Node3D) -> int:
	return _stable_scene_signature(volume, "")

## Validates pre-schema direct Data against the original absolute-path format.
## Unlike manifests, direct Data has no saved root path to reconstruct.
static func legacy_absolute_scene_signature(volume: Node3D) -> int:
	var root := scene_root(volume)
	var root_path := String(root.get_path())
	if root_path.is_empty():
		return 0
	return _stable_scene_signature(volume, root_path)

## Recreates a pre-schema manifest's absolute source fingerprint. The old
## volume_identity contains the captured absolute path, so its suffix matching
## the current root-relative volume path identifies the saved scene-root path.
static func legacy_manifest_source_signature(volume: Node3D,
		saved_volume_identity: String) -> Dictionary:
	var root_prefix := legacy_manifest_root_prefix(volume, saved_volume_identity)
	if root_prefix.is_empty():
		return {"valid": false, "signature": 0}
	return {"valid": true,
		"signature": _stable_scene_signature(volume, root_prefix)}

static func data_source_signature(volume: Node3D, schema_version: int) -> Dictionary:
	if schema_version == SIGNATURE_SCHEMA_CURRENT:
		return {"valid": true, "signature": stable_scene_signature(volume)}
	if schema_version == SIGNATURE_SCHEMA_LEGACY:
		return {"valid": true, "signature": legacy_absolute_scene_signature(volume)}
	return {"valid": false, "signature": 0}

static func manifest_source_signature(volume: Node3D, schema_version: int,
		saved_volume_identity: String) -> Dictionary:
	if schema_version == SIGNATURE_SCHEMA_CURRENT:
		return {"valid": true, "signature": stable_scene_signature(volume)}
	if schema_version == SIGNATURE_SCHEMA_LEGACY:
		return legacy_manifest_source_signature(volume, saved_volume_identity)
	return {"valid": false, "signature": 0}

static func legacy_manifest_root_prefix(volume: Node3D,
		saved_volume_identity: String) -> String:
	if not volume.is_inside_tree() or not saved_volume_identity.begins_with("/"):
		return ""
	var root := scene_root(volume)
	var relative_volume_path := String(root.get_path_to(volume))
	if relative_volume_path.is_empty() or relative_volume_path == ".":
		return saved_volume_identity
	var suffix := "/" + relative_volume_path.trim_prefix("./").trim_prefix("/")
	if not saved_volume_identity.ends_with(suffix):
		return ""
	var prefix_length := saved_volume_identity.length() - suffix.length()
	var root_prefix := saved_volume_identity.left(prefix_length)
	return root_prefix if root_prefix.begins_with("/") else ""

static func _stable_scene_signature(volume: Node3D, path_root_prefix: String) -> int:
	var root := scene_root(volume)
	var world := _world_for_node(volume)
	var source_bounds: AABB = (volume.global_transform * AABB(-volume.size * 0.5, volume.size)) \
		.grow(volume.bake_distance * float(volume.bake_bounces + 1) + BROADPHASE_EPSILON)
	var values: Array = [_physical_light_units_enabled()]
	_append_stable_source_signature(root, root, world, source_bounds, values, {}, path_root_prefix)
	return hash(values)

## Bake boundary fingerprint. This is intentionally off the frame path: it
## captures resource revisions plus actual Terrain map and texture bytes so a
## partial bake cannot publish if source pixels change without a scene signal.
static func bake_content_signature(volume: Node3D) -> int:
	var root := scene_root(volume)
	var values: Array = [_volume_signature(volume),
		_physical_light_units_enabled()]
	_append_quick_signature(root, root, _world_for_node(volume), values, true, {})
	return hash(values)

static func _physical_light_units_enabled() -> bool:
	return bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))

static func _volume_signature(volume: Node3D) -> Array:
	return [volume.global_transform, volume.size, volume.probe_spacing,
		volume.surface_offset, volume.bake_distance, volume.terrain_reflectance,
		volume.fallback_material_reflectance, volume.adaptive_placement,
		volume.minimum_probe_spacing, volume.bake_samples, volume.bake_bounces]

static func _scene_scan_signature(volume: Node3D, force_uncached := false) -> int:
	var root := scene_root(volume)
	var world := _world_for_node(volume)
	var key := "%d:%d" % [root.get_instance_id(), world.get_instance_id() if world != null else 0]
	var now := Time.get_ticks_msec()
	var cached: Dictionary = _scene_scans.get(key, {})
	if not force_uncached and not cached.is_empty() \
			and now - int(cached["checked_at"]) < SCENE_SCAN_TTL_MSEC:
		return int(cached["signature"])
	var values: Array = []
	_append_quick_signature(root, root, world, values, false)
	var signature := hash(values)
	_scene_scans[key] = {"checked_at": now, "signature": signature}
	if _scene_scans.size() > 16:
		_scene_scans.clear()
		_scene_scans[key] = {"checked_at": now, "signature": signature}
	return signature

static func _append_quick_signature(node: Node, root: Node, world: World3D,
		values: Array, include_bake_inputs := false, content_cache: Dictionary = {}) -> void:
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
			if include_bake_inputs:
				watch_resource(material)
			var properties: Array = [material.get_instance_id(),
					resource_revision(material) if include_bake_inputs else 0]
			if material is BaseMaterial3D:
				var albedo_texture: Texture2D = material.albedo_texture
				var emission_texture: Texture2D = material.emission_texture
				if albedo_texture != null:
					watch_resource(albedo_texture)
				if emission_texture != null:
					watch_resource(emission_texture)
				properties.append_array([material.albedo_color, material.metallic,
						material.transparency, albedo_texture.get_instance_id() if albedo_texture != null else 0,
						resource_revision(albedo_texture), material.uv1_scale, material.uv1_offset,
						material.uv1_triplanar, material.texture_repeat, material.texture_filter,
						emission_texture.get_instance_id() if emission_texture != null else 0,
						resource_revision(emission_texture), material.emission_on_uv2,
						material.uv2_scale, material.uv2_offset, material.uv2_triplanar,
						material.cull_mode])
				if include_bake_inputs:
					# These values are live at render time, but an edit while workers
					# are tracing still invalidates that in-flight generation.
					properties.append_array([material.roughness, material.specular_mode,
							material.emission_enabled, material.emission,
							material.emission_energy_multiplier,
							material.get("emission_intensity"),
							material.get("emission_operator")])
					_append_texture_content(albedo_texture, properties, content_cache)
					_append_texture_content(emission_texture, properties, content_cache)
			else:
				watch_resource(material)
				properties.append(resource_revision(material))
			material_values.append(properties)
		var mesh_values: Array = [node.get_instance_id(), node.get_path(), node.global_transform,
			node.is_visible_in_tree(), mesh.get_instance_id(), resource_revision(mesh),
			mesh.get_class(), mesh.get_surface_count(), mesh.get_aabb(), material_values]
		if include_bake_inputs and not mesh is ArrayMesh and not mesh is PrimitiveMesh:
			# Custom Mesh resources do not inherit the built-in emit_changed guarantees.
			mesh_values.append(hash(mesh.get_faces()))
		values.append(mesh_values)
	elif node.is_class("Terrain3D"):
		var data = node.get("data")
		if data is Object:
			watch_object(data)
		var terrain_values: Array = [node.get_instance_id(), node.get_path(), node.global_transform,
			node.is_visible_in_tree(), data.get_instance_id() if data is Object else 0,
			resource_revision(data), node.get("vertex_spacing")]
		if include_bake_inputs and data is Object:
			_append_terrain_map_content(data, terrain_values, content_cache)
		values.append(terrain_values)
	for child in node.get_children():
		_append_quick_signature(child, root, world, values, include_bake_inputs, content_cache)

static func _append_stable_source_signature(node: Node, root: Node, world: World3D,
		source_bounds: AABB, values: Array, content_cache: Dictionary,
		path_root_prefix: String) -> void:
	if should_skip_world_boundary(node, root, world):
		return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
		var mesh: Mesh = node.mesh
		var mesh_bounds: AABB = node.global_transform * mesh.get_aabb()
		if mesh_bounds.grow(BROADPHASE_EPSILON).intersects(source_bounds):
			var materials: Array = []
			for surface in mesh.get_surface_count():
				materials.append(_stable_material_signature(
						node.get_active_material(surface), content_cache))
			values.append([_stable_node_path(root, node, path_root_prefix), node.get_class(), node.global_transform,
				node.is_visible_in_tree(), _stable_mesh_signature(mesh), materials])
	elif node.is_class("Terrain3D") and node.is_visible_in_tree():
		var terrain_data = node.get("data")
		if terrain_data is Object:
			var terrain_values: Array = [_stable_node_path(root, node, path_root_prefix), node.global_transform,
				node.get("vertex_spacing")]
			_append_stable_terrain_content(terrain_data, terrain_values, content_cache)
			values.append(terrain_values)
	for child in node.get_children():
		_append_stable_source_signature(child, root, world, source_bounds, values,
				content_cache, path_root_prefix)

static func _stable_node_path(root: Node, node: Node, path_root_prefix: String) -> String:
	var relative_path := String(root.get_path_to(node))
	if path_root_prefix.is_empty():
		return relative_path
	if relative_path.is_empty() or relative_path == ".":
		return path_root_prefix
	return path_root_prefix.path_join(relative_path.trim_prefix("./"))

static func _stable_mesh_signature(mesh: Mesh) -> Array:
	var result: Array = [mesh.get_class(), mesh.get_surface_count(), mesh.get_aabb()]
	if mesh is PrimitiveMesh:
		var primitive := mesh as PrimitiveMesh
		result.append(hash(primitive.get_mesh_arrays()))
	elif mesh is ArrayMesh:
		var surfaces: Array = []
		var array_mesh := mesh as ArrayMesh
		for surface in array_mesh.get_surface_count():
			surfaces.append([array_mesh.surface_get_primitive_type(surface),
				hash(array_mesh.surface_get_arrays(surface))])
		result.append(surfaces)
	else:
		result.append(hash(mesh.get_faces()))
	return result

static func _stable_material_signature(material: Material, content_cache: Dictionary) -> Array:
	if material == null:
		return ["null"]
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		return [base.get_class(), base.albedo_color, base.metallic,
			base.transparency, base.cull_mode,
			base.uv1_scale, base.uv1_offset, base.uv1_triplanar,
			base.texture_repeat, base.texture_filter,
			_stable_texture_signature(base.albedo_texture, content_cache),
			base.emission_on_uv2, base.uv2_scale, base.uv2_offset, base.uv2_triplanar,
			_stable_texture_signature(base.emission_texture, content_cache)]
	var result: Array = [material.get_class()]
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		result.append(shader.code if shader != null else "")
		if shader != null:
			for parameter in shader.get_shader_uniform_list():
				var parameter_name := StringName(parameter.get("name", ""))
				if parameter_name.is_empty() \
						or (int(parameter.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
					continue
				var value: Variant = shader_material.get_shader_parameter(parameter_name)
				if value is Texture2D:
					result.append([String(parameter_name),
						_stable_texture_signature(value as Texture2D, content_cache)])
				elif value is bool or value is int or value is float \
						or value is Vector2 or value is Vector3 or value is Vector4 \
						or value is Color or value is Transform3D or value is Basis:
					result.append([String(parameter_name), value])
		return result
	result.append(material.resource_path)
	return result

static func _stable_texture_signature(texture: Texture2D, content_cache: Dictionary) -> Array:
	if texture == null:
		return ["null"]
	var key := "stable_texture:%d" % texture.get_instance_id()
	if not content_cache.has(key):
		content_cache[key] = _image_content_signature(texture.get_image())
	return [texture.get_class(), texture.resource_path, content_cache[key]]

static func _append_stable_terrain_content(data: Object, values: Array,
		content_cache: Dictionary) -> void:
	var region_locations: Variant = data.get("region_locations")
	values.append(region_locations if region_locations is Array else [])
	for method_name in [&"get_height_maps", &"get_color_maps", &"get_control_maps", &"get_surface_maps"]:
		if not data.has_method(method_name):
			continue
		var maps: Variant = data.call(method_name)
		if not maps is Array:
			continue
		var images: Array = []
		for image_value in maps:
			if image_value is Image:
				var image := image_value as Image
				var key := "stable_image:%d" % image.get_instance_id()
				if not content_cache.has(key):
					content_cache[key] = _image_content_signature(image)
				images.append(content_cache[key])
			else:
				images.append(0)
		values.append([String(method_name), images])

static func _append_texture_content(texture: Texture2D, values: Array,
		content_cache: Dictionary) -> void:
	if texture == null:
		values.append(0)
		return
	var key := "texture:%d" % texture.get_instance_id()
	if not content_cache.has(key):
		content_cache[key] = _image_content_signature(texture.get_image())
	values.append([texture.get_instance_id(), content_cache[key]])

static func _append_terrain_map_content(data: Object, values: Array,
		content_cache: Dictionary) -> void:
	var region_locations: Variant = data.get("region_locations")
	values.append(region_locations if region_locations is Array else [])
	for method_name in [&"get_height_maps", &"get_color_maps", &"get_control_maps", &"get_surface_maps"]:
		if not data.has_method(method_name):
			continue
		var maps: Variant = data.call(method_name)
		if not maps is Array:
			continue
		var image_values: Array = []
		for image_value in maps:
			if image_value is Image:
				var image := image_value as Image
				var key := "image:%d" % image.get_instance_id()
				if not content_cache.has(key):
					content_cache[key] = _image_content_signature(image)
				image_values.append(content_cache[key])
			else:
				image_values.append(0)
		values.append([String(method_name), image_values])

static func _image_content_signature(image: Image) -> Variant:
	if image == null or image.is_empty():
		return "unreadable"
	return [image.get_width(), image.get_height(), image.get_format(),
		image.has_mipmaps(), hash(image.get_data())]

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
	_watched_objects[id] = {"reference": weakref(object_value), "revision": 0}
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
	return int(_watched_objects.get(object_value.get_instance_id(), {}).get("revision", 0))

static func _on_object_changed(id: int) -> void:
	_watched_objects[id].revision += 1

static func _on_object_area_changed(_area: AABB, id: int) -> void:
	_on_object_changed(id)

static func _prune_watched_objects() -> void:
	for id in _watched_objects.keys():
		var reference: WeakRef = _watched_objects[id].reference
		if reference.get_ref() == null:
			_watched_objects.erase(id)
