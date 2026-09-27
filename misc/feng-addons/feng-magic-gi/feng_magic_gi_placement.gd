@tool
class_name FMagicGIPlacement
extends RefCounted
## Physics-independent surface sampling and the offline PRT triangle BVH.

const Data = preload("feng_magic_gi_data.gd")
const MAX_PROBES := 65536
const MAX_GEOMETRY_TRIANGLES := 250000
const MAX_TERRAIN_CELLS := 500000
const MAX_SAMPLE_CANDIDATES := 2000000
const MAX_TRIANGLE_STEPS := 512
const BROADPHASE_EPSILON := 0.001

static var _watched_resources: Dictionary = {}
static var _resource_revisions: Dictionary = {}
static var _next_resource_prune := 0

var faces := PackedVector3Array()
var reflectance := PackedVector3Array()
var bvh: TriangleMesh
var positions := PackedVector3Array()
var normals := PackedVector3Array()
var scene_signature := 0
var error_message := ""
var bvh_ready := false

var _cells: Dictionary = {}
var _spatial_hash: Dictionary = {}
var _cell_counts: Dictionary = {}
var _volume: Node3D
var _world: World3D
var _bounds: AABB
var _world_bounds: AABB
var _bake_world_bounds: AABB
var _inverse := Transform3D.IDENTITY
var _dimensions := Vector3i.ONE
var _material_cache: Dictionary = {}
var _candidate_count := 0
var _terrain_work := 0
var _triangle_count := 0
var _triangle_reflectance: Vector3

func collect(volume: Node3D, for_bake := false, build_bvh := true) -> bool:
	_volume = volume
	_world = volume.get_world_3d()
	_inverse = volume.global_transform.affine_inverse()
	_dimensions = volume.grid_dimensions()
	_bounds = AABB(-volume.size * 0.5, volume.size)
	_world_bounds = volume.global_transform * _bounds
	_bake_world_bounds = _world_bounds.grow(volume.bake_distance) if for_bake else _world_bounds
	error_message = ""
	faces.clear()
	reflectance.clear()
	positions.clear()
	normals.clear()
	_cells.clear()
	_spatial_hash.clear()
	_cell_counts.clear()
	_material_cache.clear()
	_candidate_count = 0
	_terrain_work = 0
	_triangle_count = 0
	bvh = null
	bvh_ready = false
	if _dimensions.x <= 0 or _dimensions.y <= 0 or _dimensions.z <= 0 \
			or _dimensions.x > Data.MAX_GRID_AXIS or _dimensions.y > Data.MAX_GRID_AXIS \
			or _dimensions.z > Data.MAX_GRID_AXIS:
		error_message = "Lookup grid exceeds the supported 64 cells per axis."
		return false
	var root: Node = volume
	while root.get_parent() != null and not root.get_parent() is Viewport:
		root = root.get_parent()
	_collect_node(root, for_bake)
	if not error_message.is_empty():
		return false
	if for_bake and build_bvh and not faces.is_empty():
		bvh = TriangleMesh.new()
		bvh_ready = bvh.create_from_faces(faces)
		if not bvh_ready:
			error_message = "Godot could not create the static PRT triangle BVH."
			return false
	for entry in _cells.values():
		positions.append(entry.position)
		normals.append(entry.normal)
	scene_signature = hash([faces, reflectance, positions, normals])
	return true

func _collect_node(node: Node, for_bake: bool) -> void:
	if not error_message.is_empty():
		return
	# A nested SubViewport with its own World3D is a hard scene boundary. Geometry
	# and sources from it must not leak into another world's transport.
	if node is Viewport and node != _volume and node.find_world_3d() != _world:
		return
	if node is Node3D and node != _volume and node.get_world_3d() != _world:
		return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
		_collect_mesh(node, for_bake)
	elif node.is_class("Terrain3D") and node.get("data") != null and node.is_visible_in_tree():
		_collect_terrain(node, for_bake)
	for child in node.get_children():
		_collect_node(child, for_bake)
		if not error_message.is_empty():
			return

func _collect_mesh(node: MeshInstance3D, for_bake: bool) -> void:
	var mesh: Mesh = node.mesh
	var mesh_world_box: AABB = node.global_transform * mesh.get_aabb()
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return
	# PrimitiveMesh and custom Mesh resources expose their triangles through
	# get_faces(), while per-surface array/type access is only bound for ArrayMesh.
	if not mesh is ArrayMesh:
		if mesh.get_surface_count() > 1:
			error_message = "Non-ArrayMesh resources with multiple material surfaces cannot provide per-face reflectance."
			return
		var primitive_faces: PackedVector3Array = mesh.get_faces()
		if primitive_faces.is_empty() or not _prepare_surface(node, 0):
			return
		for i in range(0, primitive_faces.size() - 2, 3):
			var a: Vector3 = node.global_transform * primitive_faces[i]
			var b: Vector3 = node.global_transform * primitive_faces[i + 1]
			var c: Vector3 = node.global_transform * primitive_faces[i + 2]
			if not _triangle(a, b, c, for_bake):
				return
		return
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		if not _prepare_surface(node, surface):
			continue
		for i in range(0, count - 2, 3):
			var a: Vector3 = node.global_transform * vertices[indices[i] if not indices.is_empty() else i]
			var b: Vector3 = node.global_transform * vertices[indices[i + 1] if not indices.is_empty() else i + 1]
			var c: Vector3 = node.global_transform * vertices[indices[i + 2] if not indices.is_empty() else i + 2]
			if not _triangle(a, b, c, for_bake):
				return

func _prepare_surface(node: MeshInstance3D, surface: int) -> bool:
	var material := node.get_active_material(surface)
	if material is BaseMaterial3D and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return false # Transparent surfaces cannot be represented by this opaque PRT bake.
	_triangle_reflectance = _material_reflectance(material)
	return true

func _material_reflectance(material: Material) -> Vector3:
	if material != null and _material_cache.has(material):
		return _material_cache[material]
	var color: Vector3 = Vector3.ONE * float(_volume.get("fallback_material_reflectance"))
	if material is BaseMaterial3D:
		var linear: Color = material.albedo_color.srgb_to_linear()
		color = Vector3(linear.r, linear.g, linear.b) * (1.0 - material.metallic)
		if material.albedo_texture != null:
			push_warning("FMagicGI: albedo textures are not sampled by the offline PRT baker; only the material tint is used.")
	elif material is ShaderMaterial:
		push_warning("FMagicGI: ShaderMaterial reflectance is not evaluated offline; using Fallback Material Reflectance.")
	if material != null:
		_material_cache[material] = color
	return color

func _collect_terrain(terrain: Node3D, for_bake: bool) -> void:
	var data = terrain.get("data")
	if not data.has_method("get_surface_height"):
		error_message = "Terrain3D data is missing get_surface_height(); refusing raw height sampling."
		return
	var box := _bake_world_bounds
	var step: float = _volume.probe_spacing
	var vertex_spacing: float = terrain.get("vertex_spacing")
	step = minf(step, maxf(vertex_spacing, 0.25))
	var start := Vector2(floor(box.position.x / step) * step, floor(box.position.z / step) * step)
	var end := box.end
	var nx := ceili((end.x - start.x) / step) + 1
	var nz := ceili((end.z - start.y) / step) + 1
	_terrain_work += nx * nz
	if nx <= 1 or nz <= 1 or _terrain_work > MAX_TERRAIN_CELLS:
		error_message = "Terrain sampling exceeds the 500,000-cell work limit; increase Probe Spacing or reduce Bake Distance."
		return
	var heights := PackedFloat32Array()
	heights.resize(nx * nz)
	for z in nz:
		for x in nx:
			var query := Vector3(start.x + x * step, 0.0, start.y + z * step)
			heights[z * nx + x] = data.call("get_surface_height", query)
	var color: Vector3 = Vector3.ONE * float(_volume.get("terrain_reflectance"))
	for z in nz - 1:
		for x in nx - 1:
			var h00: float = heights[z * nx + x]
			var h10: float = heights[z * nx + x + 1]
			var h01: float = heights[(z + 1) * nx + x]
			var h11: float = heights[(z + 1) * nx + x + 1]
			# get_surface_height returns NaN over holes (including interpolation
			# footprints touching a hole), so no triangles bridge missing terrain.
			if not is_finite(h00) or not is_finite(h10) or not is_finite(h01) or not is_finite(h11):
				continue
			var a := Vector3(start.x + x * step, h00, start.y + z * step)
			var b := Vector3(start.x + (x + 1) * step, h10, start.y + z * step)
			var c := Vector3(start.x + x * step, h01, start.y + (z + 1) * step)
			var d := Vector3(start.x + (x + 1) * step, h11, start.y + (z + 1) * step)
			_triangle_reflectance = color
			if not _triangle(a, b, c, for_bake) or not _triangle(b, d, c, for_bake):
				return

func _triangle(a: Vector3, b: Vector3, c: Vector3, for_bake: bool) -> bool:
	var triangle_box := AABB(a, Vector3.ZERO).expand(b).expand(c)
	if not triangle_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return true
	var normal := (c - a).cross(b - a).normalized() # Godot triangle surfaces use clockwise front faces.
	if normal.length_squared() < 0.5:
		return true
	_triangle_count += 1
	if _triangle_count > MAX_GEOMETRY_TRIANGLES:
		error_message = "PRT geometry exceeds the 250,000-triangle sampling/signature budget."
		return false
	faces.append_array([a, b, c])
	reflectance.append(_triangle_reflectance)
	var polygon := [_inverse * a, _inverse * b, _inverse * c]
	polygon = _clip_polygon(polygon, 0, -_volume.size.x * 0.5, true)
	polygon = _clip_polygon(polygon, 0, _volume.size.x * 0.5, false)
	polygon = _clip_polygon(polygon, 1, -_volume.size.y * 0.5, true)
	polygon = _clip_polygon(polygon, 1, _volume.size.y * 0.5, false)
	polygon = _clip_polygon(polygon, 2, -_volume.size.z * 0.5, true)
	polygon = _clip_polygon(polygon, 2, _volume.size.z * 0.5, false)
	if polygon.size() < 3:
		return true
	var root: Vector3 = polygon[0]
	for i in range(1, polygon.size() - 1):
		var p0: Vector3 = _volume.global_transform * root
		var p1: Vector3 = _volume.global_transform * polygon[i]
		var p2: Vector3 = _volume.global_transform * polygon[i + 1]
		var clipped_normal := (p2 - p0).cross(p1 - p0).normalized()
		if clipped_normal.length_squared() < 0.5:
			continue
		if not _sample_triangle(p0, p1, p2, clipped_normal):
			return false
	return true

func _sample_triangle(a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> bool:
	var longest := maxf(a.distance_to(b), maxf(a.distance_to(c), b.distance_to(c)))
	# Oversample very large triangles before the global surface-spacing filter.
	# This keeps a coarse plane comparable to its finely tessellated version,
	# without creating unnecessary candidates on already-small object faces.
	var candidate_step: float = _volume.probe_spacing
	if longest > _volume.probe_spacing * 8.0:
		candidate_step = maxf(0.05, _volume.probe_spacing * 0.5)
	var steps := maxi(1, ceili(longest / candidate_step))
	if steps > MAX_TRIANGLE_STEPS:
		error_message = "A clipped surface triangle exceeds the sampling budget; increase Probe Spacing."
		return false
	for u in steps + 1:
		for v in steps + 1 - u:
			_candidate_count += 1
			if _candidate_count > MAX_SAMPLE_CANDIDATES:
				error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
				return false
			var point := a + (b - a) * (float(u) / steps) + (c - a) * (float(v) / steps)
			_add_surface(point, normal)
			if not error_message.is_empty():
				return false
	return true

func _add_surface(surface: Vector3, normal: Vector3) -> void:
	var local := _inverse * surface
	var epsilon := maxf(0.0001, _volume.probe_spacing * 0.0001)
	if local.x < -_volume.size.x * 0.5 - epsilon or local.x > _volume.size.x * 0.5 + epsilon \
			or local.y < -_volume.size.y * 0.5 - epsilon or local.y > _volume.size.y * 0.5 + epsilon \
			or local.z < -_volume.size.z * 0.5 - epsilon or local.z > _volume.size.z * 0.5 + epsilon:
		return
	# Keep the authored surface density close to Probe Spacing even for highly
	# tessellated/curved meshes. A 1x probe-spacing radius avoids filling a 1m
	# lookup cell with several near-duplicate triangle samples.
	var min_separation: float = float(_volume.get("probe_spacing"))
	var hash_cell := Vector3i(floori(surface.x / min_separation),
			floori(surface.y / min_separation), floori(surface.z / min_separation))
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nearby: Array = _spatial_hash.get(hash_cell + Vector3i(dx, dy, dz), [])
				for existing in nearby:
					# Treat nearby samples on a smooth curve as the same local
					# surface while retaining genuinely different walls/faces at
					# corners (orthogonal normals have dot=0).
					if normal.dot(existing.normal) > 0.5 \
							and surface.distance_squared_to(existing.position) < min_separation * min_separation:
						return
	var grid: Vector3 = (local + _volume.size * 0.5) / _volume.size * Vector3(_dimensions)
	var cell := Data.cell_coordinates(grid, _dimensions)
	if cell.x < 0:
		error_message = "A sampled surface escaped the PRT lookup grid."
		return
	var cell_key := cell.x + cell.y * _dimensions.x + cell.z * _dimensions.x * _dimensions.y
	var count := int(_cell_counts.get(cell_key, 0))
	if count >= Data.CELL_CAPACITY:
		error_message = "More than 8 surface samples occupy one lookup cell; increase Probe Spacing or reduce surface detail."
		return
	if _cells.size() >= MAX_PROBES:
		error_message = "Surface sampling exceeds the 65,536-probe limit; increase Probe Spacing or reduce the volume."
		return
	_cell_counts[cell_key] = count + 1
	var point_entry := {"position": surface, "normal": normal}
	var bucket: Array = _spatial_hash.get(hash_cell, [])
	bucket.append(point_entry)
	_spatial_hash[hash_cell] = bucket
	_cells[_cells.size()] = {"position": surface + normal * _volume.surface_offset, "normal": normal}

func _clip_polygon(polygon: Array, axis: int, boundary: float, keep_greater: bool) -> Array:
	var output: Array = []
	if polygon.is_empty():
		return output
	var previous: Vector3 = polygon[polygon.size() - 1]
	var previous_distance := previous[axis] - boundary
	var previous_inside := previous_distance >= -0.000001 if keep_greater else previous_distance <= 0.000001
	for current_value in polygon:
		var current: Vector3 = current_value
		var current_distance := current[axis] - boundary
		var current_inside := current_distance >= -0.000001 if keep_greater else current_distance <= 0.000001
		if current_inside != previous_inside:
			var denominator := previous[axis] - current[axis]
			if absf(denominator) > 0.0000001:
				var t := (previous[axis] - boundary) / denominator
				output.append(previous.lerp(current, t))
		if current_inside:
			output.append(current)
		previous = current
		previous_inside = current_inside
	return output

func trace(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	if not bvh_ready:
		return {}
	var hit := bvh.intersect_segment(origin, origin + direction * max_distance)
	if not hit.is_empty():
		hit["albedo"] = reflectance[int(hit["face_index"])]
	return hit

## Cheap editor/runtime polling fingerprint. It walks scene nodes and their
## transforms/material properties but does not read mesh vertex arrays or sample
## the surface; full placement/signature rebuilds happen only on a change.
static func quick_signature(volume: Node3D) -> int:
	var values: Array = [volume.global_transform, volume.size, volume.probe_spacing,
			volume.surface_offset, volume.bake_distance, volume.terrain_reflectance,
			volume.fallback_material_reflectance]
	var root: Node = volume
	while root.get_parent() != null and not root.get_parent() is Viewport:
		root = root.get_parent()
	_append_quick_signature(root, volume.get_world_3d(), values)
	return hash(values)

static func _append_quick_signature(node: Node, world: World3D, values: Array) -> void:
	if node is Viewport and node.find_world_3d() != world:
		return
	if node is Node3D and node.get_world_3d() != world:
		return
	if node is MeshInstance3D and node.mesh != null:
		var mesh: Mesh = node.mesh
		_watch_resource(mesh)
		var material_values: Array = []
		for surface in mesh.get_surface_count():
			var material: Material = node.get_active_material(surface)
			if material == null:
				material_values.append([0, _resource_revision(null)])
				continue
			_watch_resource(material)
			var properties: Array = [material.get_instance_id(), _resource_revision(material)]
			if material is BaseMaterial3D:
				properties.append_array([material.albedo_color, material.metallic,
						material.transparency, material.albedo_texture.get_instance_id() if material.albedo_texture != null else 0])
				if material.albedo_texture != null:
					_watch_resource(material.albedo_texture)
			material_values.append(properties)
		values.append([node.get_instance_id(), node.global_transform, node.is_visible_in_tree(),
				mesh.get_instance_id(), _resource_revision(mesh), mesh.get_surface_count(), material_values])
	elif node.is_class("Terrain3D"):
		var data = node.get("data")
		if data is Object:
			_watch_object(data)
		values.append([node.get_instance_id(), node.global_transform, node.is_visible_in_tree(),
				data.get_instance_id() if data is Object else 0, _resource_revision(data),
				node.get("vertex_spacing")])
	for child in node.get_children():
		_append_quick_signature(child, world, values)

static func _watch_resource(resource: Resource) -> void:
	_watch_object(resource)

static func _watch_object(object_value: Object) -> void:
	if object_value == null:
		return
	var now := Time.get_ticks_msec()
	if now >= _next_resource_prune:
		_prune_watched_objects()
		_next_resource_prune = now + 10000
	var id := object_value.get_instance_id()
	if _watched_resources.has(id):
		return
	_watched_resources[id] = weakref(object_value)
	_resource_revisions[id] = 0
	if object_value.has_signal("changed"):
		object_value.connect("changed", _on_object_changed.bind(id))
	for signal_name in ["maps_changed", "region_map_changed", "height_maps_changed",
			"control_maps_changed", "color_maps_changed", "surface_maps_changed"]:
		if object_value.has_signal(signal_name):
			object_value.connect(signal_name, _on_object_changed.bind(id))
	if object_value.has_signal("maps_edited"):
		object_value.connect("maps_edited", _on_object_area_changed.bind(id))

static func _on_object_changed(id: int) -> void:
	_resource_revisions[id] = int(_resource_revisions.get(id, 0)) + 1

static func _on_object_area_changed(_area: AABB, id: int) -> void:
	_resource_revisions[id] = int(_resource_revisions.get(id, 0)) + 1

static func _resource_revision(object_value: Object) -> int:
	if object_value == null:
		return 0
	var id := object_value.get_instance_id()
	return int(_resource_revisions.get(id, 0))

static func _prune_watched_objects() -> void:
	for id in _watched_resources.keys():
		var reference: WeakRef = _watched_resources[id]
		if reference.get_ref() == null:
			_watched_resources.erase(id)
			_resource_revisions.erase(id)
