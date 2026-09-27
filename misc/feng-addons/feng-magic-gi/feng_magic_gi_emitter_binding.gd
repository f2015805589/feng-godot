@tool
class_name FMagicGIEmitterBinding
extends RefCounted
## Stable scene bindings and runtime material fingerprints for emissive surfaces.

const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")

static func make_key(root: Node, node: Node, surface: int) -> String:
	return "%s#surface=%d" % [str(root.get_path_to(node)), surface]

static func resolve_binding(root: Node, key: String) -> Dictionary:
	var marker := key.rfind("#surface=")
	if marker < 0:
		return {}
	var node_path := NodePath(key.substr(0, marker))
	var surface := key.substr(marker + 9).to_int()
	var node := root.get_node_or_null(node_path)
	if not node is MeshInstance3D or node.mesh == null \
			or surface < 0 or surface >= node.mesh.get_surface_count():
		return {}
	return {"node": node, "surface": surface}

## Stable across save/reload; live source parameters and Resource IDs are excluded.
static func static_signature(node: MeshInstance3D, surface: int, material: BaseMaterial3D) -> int:
	var values: Array = [surface, material.emission_on_uv2, material.cull_mode]
	var texture: Texture2D = material.emission_texture
	if texture == null:
		return hash(values)
	var use_uv2: bool = material.emission_on_uv2
	var triplanar: bool = material.uv2_triplanar if use_uv2 else material.uv1_triplanar
	var uv_scale: Vector3 = material.uv2_scale if use_uv2 else material.uv1_scale
	var uv_offset: Vector3 = material.uv2_offset if use_uv2 else material.uv1_offset
	values.append_array([triplanar, uv_scale, uv_offset, material.texture_repeat, material.texture_filter])
	var arrays := _surface_arrays(node.mesh, surface)
	if not arrays.is_empty():
		var uv_slot := Mesh.ARRAY_TEX_UV2 if use_uv2 else Mesh.ARRAY_TEX_UV
		var uvs = arrays[uv_slot] if arrays.size() > uv_slot else null
		values.append(hash(uvs) if uvs != null else 0)
	else:
		values.append(0)
	var image := texture.get_image()
	if image == null or image.is_empty():
		values.append([-1])
	else:
		values.append([image.get_width(), image.get_height(),
				image.get_format(), image.has_mipmaps(), hash(image.get_data())])
	return hash(values)

## Process-local cache token only; this value is never persisted.
static func runtime_fingerprint(node: MeshInstance3D, surface: int,
		material: BaseMaterial3D) -> int:
	var mesh: Mesh = node.mesh
	var texture: Texture2D = material.emission_texture
	SceneTracker.watch_resource(mesh)
	SceneTracker.watch_resource(texture)
	return hash([
		node.global_transform, surface, material.get_instance_id(),
		mesh.get_instance_id() if mesh != null else 0,
		SceneTracker.resource_revision(mesh),
		texture.get_instance_id() if texture != null else 0,
		SceneTracker.resource_revision(texture),
		material.emission_on_uv2, material.cull_mode,
		material.uv2_triplanar if material.emission_on_uv2 else material.uv1_triplanar,
		material.uv2_scale if material.emission_on_uv2 else material.uv1_scale,
		material.uv2_offset if material.emission_on_uv2 else material.uv1_offset,
		material.texture_repeat, material.texture_filter
	])

static func current_keys(volume: Node3D) -> PackedStringArray:
	var result := PackedStringArray()
	var root := SceneTracker.scene_root(volume)
	var bounds: AABB = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	bounds = bounds.grow(volume.bake_distance)
	_collect_current_keys(root, root, volume.get_world_3d(), bounds, result)
	return result

static func _collect_current_keys(node: Node, root: Node, world: World3D,
		bounds: AABB, result: PackedStringArray) -> void:
	if SceneTracker.should_skip_world_boundary(node, root, world):
		return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
		var mesh_bounds: AABB = node.global_transform * node.mesh.get_aabb()
		if mesh_bounds.grow(SceneTracker.BROADPHASE_EPSILON).intersects(
				bounds.grow(SceneTracker.BROADPHASE_EPSILON)):
			for surface in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(surface)
				if material is BaseMaterial3D and material.emission_enabled:
					result.append(make_key(root, node, surface))
	for child in node.get_children():
		_collect_current_keys(child, root, world, bounds, result)

static func _surface_arrays(mesh: Mesh, surface: int) -> Array:
	if mesh is ArrayMesh:
		return mesh.surface_get_arrays(surface)
	if mesh is PrimitiveMesh and surface == 0:
		return mesh.get_mesh_arrays()
	return []
