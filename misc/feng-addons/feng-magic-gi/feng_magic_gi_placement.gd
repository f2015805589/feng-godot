@tool
class_name FMagicGIPlacement
extends RefCounted
## Physics-independent surface sampling and the offline PRT triangle BVH.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const EmitterBakeSet = preload("feng_magic_gi_emitter_bake_set.gd")
const MAX_PROBES := 65536
const MAX_GEOMETRY_TRIANGLES := 250000
const MAX_TERRAIN_CELLS := 500000
const MAX_SAMPLE_CANDIDATES := 2000000
const MAX_TRIANGLE_STEPS := 512
const MAX_OCCLUSION_TRIANGLES := 250000
const OCCLUSION_MAX_CROSSINGS := 256
const OCCLUSION_WELD_EPSILON := 0.00001
const DUPLICATE_PLANE_EPSILON := 0.001
const BROADPHASE_EPSILON := SceneTracker.BROADPHASE_EPSILON

var faces := PackedVector3Array()
var reflectance := PackedVector3Array()
var face_emitter_indices := PackedInt32Array()
var face_source_ids := PackedInt64Array()
var face_surface_indices := PackedInt32Array()
var emitter_keys := PackedStringArray()
var emitter_static_signatures := PackedInt64Array()
var emitter_groups: Array[Dictionary] = []
var bvh: TriangleMesh
var positions := PackedVector3Array()
var normals := PackedVector3Array()
var scene_signature := 0
var error_message := ""
var bvh_ready := false

var _spatial_hash: Dictionary = {}
var _cell_counts: Dictionary = {}
var _occlusion_volumes: Array[Dictionary] = []
var _volume: Node3D
var _world: World3D
var _collect_emission := false
var _world_bounds: AABB
var _bake_world_bounds: AABB
var _inverse := Transform3D.IDENTITY
var _dimensions := Vector3i.ONE
var _material_cache: Dictionary = {}
var _candidate_count := 0
var _terrain_work := 0
var _triangle_reflectance: Vector3
var _triangle_emitter_index := -1
var _triangle_source_id := 0
var _triangle_surface_index := -1
var _sample_source_id := 0
var _sample_surface_index := -1
var rejected_occluded_count := 0
var rejected_duplicate_count := 0
var rejected_center_outside_count := 0
var _scene_root: Node
var _emitter_set: EmitterBakeSet

func collect(volume: Node3D, for_bake := false, build_bvh := true, collect_emission := false) -> bool:
	_volume = volume
	_world = volume.get_world_3d()
	_collect_emission = collect_emission
	_emitter_set = EmitterBakeSet.new()
	_inverse = volume.global_transform.affine_inverse()
	_dimensions = volume.grid_dimensions()
	_world_bounds = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	# Preview must include geometry that can intersect the short surface-offset
	# segment, even before a bake exists. Bake collection already has the wider
	# ray-tracing bounds and therefore also contains this local occupancy region.
	_bake_world_bounds = _world_bounds.grow(volume.bake_distance) if for_bake \
			else _world_bounds.grow(volume.surface_offset + BROADPHASE_EPSILON)
	error_message = ""
	faces.clear()
	reflectance.clear()
	face_emitter_indices.clear()
	face_source_ids.clear()
	face_surface_indices.clear()
	emitter_keys.clear()
	emitter_static_signatures.clear()
	emitter_groups.clear()
	positions.clear()
	normals.clear()
	_spatial_hash.clear()
	_cell_counts.clear()
	_occlusion_volumes.clear()
	_material_cache.clear()
	_candidate_count = 0
	_terrain_work = 0
	_triangle_emitter_index = -1
	_triangle_source_id = 0
	_triangle_surface_index = -1
	_sample_source_id = 0
	_sample_surface_index = -1
	rejected_occluded_count = 0
	rejected_duplicate_count = 0
	rejected_center_outside_count = 0
	bvh = null
	bvh_ready = false
	if _dimensions.x <= 0 or _dimensions.y <= 0 or _dimensions.z <= 0 \
			or _dimensions.x > Data.MAX_GRID_AXIS or _dimensions.y > Data.MAX_GRID_AXIS \
			or _dimensions.z > Data.MAX_GRID_AXIS:
		error_message = "Lookup grid exceeds the supported 64 cells per axis."
		return false
	_scene_root = SceneTracker.scene_root(volume)
	_collect_node(_scene_root)
	if not error_message.is_empty():
		return false
	# Build once after all faces are collected. Placement filtering and the baker
	# then share this same accelerated geometry instead of scanning triangles per
	# sample. Preview also needs it to match the bake's accepted sample layout.
	if not faces.is_empty():
		bvh = TriangleMesh.new()
		bvh_ready = bvh.create_from_faces(faces)
		if not bvh_ready:
			error_message = "Godot could not create the static PRT triangle BVH."
			return false
	if not _sample_collected_geometry():
		positions.clear()
		normals.clear()
		return false
	if not build_bvh:
		bvh = null
		bvh_ready = false
	emitter_keys = _emitter_set.keys
	emitter_static_signatures = _emitter_set.static_signatures
	emitter_groups = _emitter_set.groups
	scene_signature = hash([faces, reflectance, positions, normals])
	return true

func _sample_collected_geometry() -> bool:
	for face_offset in range(0, faces.size(), 3):
		var source_face_index := int(face_offset / 3)
		_sample_source_id = int(face_source_ids[source_face_index])
		_sample_surface_index = int(face_surface_indices[source_face_index])
		var a: Vector3 = faces[face_offset]
		var b: Vector3 = faces[face_offset + 1]
		var c: Vector3 = faces[face_offset + 2]
		var polygon := [_inverse * a, _inverse * b, _inverse * c]
		polygon = _clip_polygon(polygon, 0, -_volume.size.x * 0.5, true)
		polygon = _clip_polygon(polygon, 0, _volume.size.x * 0.5, false)
		polygon = _clip_polygon(polygon, 1, -_volume.size.y * 0.5, true)
		polygon = _clip_polygon(polygon, 1, _volume.size.y * 0.5, false)
		polygon = _clip_polygon(polygon, 2, -_volume.size.z * 0.5, true)
		polygon = _clip_polygon(polygon, 2, _volume.size.z * 0.5, false)
		if polygon.size() < 3:
			continue
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

func _collect_node(node: Node) -> void:
	if not error_message.is_empty():
		return
	# A nested SubViewport with its own World3D is a hard scene boundary. Geometry
	# and sources from it must not leak into another world's transport.
	if SceneTracker.should_skip_world_boundary(node, _scene_root, _world):
		return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
		_collect_mesh(node)
	elif node.is_class("Terrain3D") and node.get("data") != null and node.is_visible_in_tree():
		_collect_terrain(node)
	for child in node.get_children():
		_collect_node(child)
		if not error_message.is_empty():
			return

func _collect_mesh(node: MeshInstance3D) -> void:
	var mesh: Mesh = node.mesh
	var mesh_world_box: AABB = node.global_transform * mesh.get_aabb()
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return
	_register_occlusion_volume(node, mesh, mesh_world_box)
	if mesh is PrimitiveMesh:
		var arrays: Array = mesh.get_mesh_arrays()
		if not arrays.is_empty() and arrays[Mesh.ARRAY_VERTEX] != null:
			_collect_surface_triangles(node, 0, arrays, mesh)
			return
		_collect_faces_only_mesh(node, mesh)
		return
	if not mesh is ArrayMesh:
		if mesh.get_surface_count() > 1:
			error_message = "Non-ArrayMesh resources with multiple material surfaces cannot provide per-face reflectance."
			return
		_collect_faces_only_mesh(node, mesh)
		return
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		_collect_surface_triangles(node, surface, arrays)
		if not error_message.is_empty():
			return

func _register_occlusion_volume(node: MeshInstance3D, mesh: Mesh, mesh_world_box: AABB) -> void:
	var instance_id := node.get_instance_id()
	var placement_box := _world_bounds.grow(float(_volume.surface_offset) + BROADPHASE_EPSILON)
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(placement_box):
		return
	if _mesh_has_transparent_surface(node, mesh):
		return # Transparent faces are omitted from the static BVH, so they cannot define occupied volume.
	var local_faces: PackedVector3Array = mesh.get_faces()
	if local_faces.size() < 12 or local_faces.size() % 3 != 0 \
			or local_faces.size() / 3 > MAX_OCCLUSION_TRIANGLES:
		return
	if not _mesh_faces_are_watertight(local_faces):
		return # Open meshes and terrain are not interpreted as solid volumes.
	var world_faces := PackedVector3Array()
	world_faces.resize(local_faces.size())
	for index in local_faces.size():
		world_faces[index] = node.global_transform * local_faces[index]
	var mesh_bvh := TriangleMesh.new()
	if not mesh_bvh.create_from_faces(world_faces):
		return
	_occlusion_volumes.append({
		"instance_id": instance_id,
		"world_aabb": mesh_world_box,
		"bvh": mesh_bvh,
	})

func _mesh_has_transparent_surface(node: MeshInstance3D, mesh: Mesh) -> bool:
	for surface in mesh.get_surface_count():
		var material: Material = node.get_active_material(surface)
		if material is BaseMaterial3D \
				and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false

func _mesh_faces_are_watertight(local_faces: PackedVector3Array) -> bool:
	var vertex_ids: Dictionary = {}
	var edge_counts: Dictionary = {}
	for face_offset in range(0, local_faces.size(), 3):
		var triangle_ids := PackedInt32Array()
		for corner in 3:
			var point: Vector3 = local_faces[face_offset + corner]
			var vertex_key := Vector3i(
					roundi(point.x / OCCLUSION_WELD_EPSILON),
					roundi(point.y / OCCLUSION_WELD_EPSILON),
					roundi(point.z / OCCLUSION_WELD_EPSILON))
			if not vertex_ids.has(vertex_key):
				vertex_ids[vertex_key] = vertex_ids.size()
			triangle_ids.append(int(vertex_ids[vertex_key]))
		if triangle_ids[0] == triangle_ids[1] or triangle_ids[1] == triangle_ids[2] \
				or triangle_ids[2] == triangle_ids[0]:
			return false
		for edge_index in 3:
			var first := triangle_ids[edge_index]
			var second := triangle_ids[(edge_index + 1) % 3]
			var low := mini(first, second)
			var high := maxi(first, second)
			var edge_key: int = (low << 32) | high
			edge_counts[edge_key] = int(edge_counts.get(edge_key, 0)) + 1
	if edge_counts.is_empty():
		return false
	for count in edge_counts.values():
		if int(count) != 2:
			return false # Boundary and non-manifold edges are not closed solids.
	return true

func _collect_faces_only_mesh(node: MeshInstance3D, mesh: Mesh) -> void:
	var primitive_faces: PackedVector3Array = mesh.get_faces()
	if primitive_faces.is_empty():
		return
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = 0
	if not _prepare_surface(node, 0):
		return
	if _triangle_emitter_index >= 0:
		error_message = "An emissive mesh without CPU-accessible UV arrays cannot be baked as an area source."
		return
	for i in range(0, primitive_faces.size() - 2, 3):
		var a: Vector3 = node.global_transform * primitive_faces[i]
		var b: Vector3 = node.global_transform * primitive_faces[i + 1]
		var c: Vector3 = node.global_transform * primitive_faces[i + 2]
		if not _triangle(a, b, c):
			return

func _collect_surface_triangles(node: MeshInstance3D, surface: int, arrays: Array,
		primitive_mesh: PrimitiveMesh = null) -> void:
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays.size() > Mesh.ARRAY_TEX_UV2 and arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var count := indices.size() if not indices.is_empty() else vertices.size()
	var snapped_faces: PackedVector3Array
	if primitive_mesh != null:
		snapped_faces = primitive_mesh.get_faces()
		if count % 3 != 0 or snapped_faces.size() != count:
			error_message = "PrimitiveMesh face positions and array UV indices disagree; refusing unstable surface data."
			return
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = surface
	if not _prepare_surface(node, surface, uv1, uv2, vertices.size()):
		return
	for i in range(0, count - 2, 3):
		var ia := indices[i] if not indices.is_empty() else i
		var ib := indices[i + 1] if not indices.is_empty() else i + 1
		var ic := indices[i + 2] if not indices.is_empty() else i + 2
		# PrimitiveMesh.get_faces() snaps positions through TriangleMesh; preserve
		# that legacy geometry order while taking UVs from the matching arrays.
		var a: Vector3 = node.global_transform * (snapped_faces[i] if primitive_mesh != null else vertices[ia])
		var b: Vector3 = node.global_transform * (snapped_faces[i + 1] if primitive_mesh != null else vertices[ib])
		var c: Vector3 = node.global_transform * (snapped_faces[i + 2] if primitive_mesh != null else vertices[ic])
		var ta := uv1[ia] if uv1.size() == vertices.size() else Vector2.ZERO
		var tb := uv1[ib] if uv1.size() == vertices.size() else Vector2.ZERO
		var tc := uv1[ic] if uv1.size() == vertices.size() else Vector2.ZERO
		var t2a := uv2[ia] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2b := uv2[ib] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2c := uv2[ic] if uv2.size() == vertices.size() else Vector2.ZERO
		if not _triangle(a, b, c, ta, tb, tc, t2a, t2b, t2c):
			return

func _prepare_surface(node: MeshInstance3D, surface: int,
		uv1 := PackedVector2Array(), uv2 := PackedVector2Array(), vertex_count := 0) -> bool:
	_triangle_emitter_index = -1
	var material := node.get_active_material(surface)
	if material is BaseMaterial3D and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		if _collect_emission and material.emission_enabled:
			error_message = "Transparent emissive surfaces are not supported by the static area-source baker."
		return false # Transparent surfaces cannot be represented by this opaque PRT bake.
	_triangle_reflectance = _material_reflectance(material)
	if _collect_emission and material is BaseMaterial3D and material.emission_enabled:
		_triangle_emitter_index = _emitter_set.register_surface(
				_scene_root, node, surface, material, uv1, uv2, vertex_count)
		if not _emitter_set.error_message.is_empty():
			error_message = _emitter_set.error_message
			return false
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

func _collect_terrain(terrain: Node3D) -> void:
	_triangle_emitter_index = -1
	_triangle_source_id = terrain.get_instance_id()
	_triangle_surface_index = -1
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
			if not _triangle(a, b, c) or not _triangle(b, d, c):
				return

func _triangle(a: Vector3, b: Vector3, c: Vector3,
		uv1_a := Vector2.ZERO, uv1_b := Vector2.ZERO, uv1_c := Vector2.ZERO,
		uv2_a := Vector2.ZERO, uv2_b := Vector2.ZERO, uv2_c := Vector2.ZERO) -> bool:
	var triangle_box := AABB(a, Vector3.ZERO).expand(b).expand(c)
	if not triangle_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return true
	var normal := (c - a).cross(b - a).normalized() # Godot triangle surfaces use clockwise front faces.
	if normal.length_squared() < 0.5:
		return true
	if reflectance.size() >= MAX_GEOMETRY_TRIANGLES:
		error_message = "PRT geometry exceeds the 250,000-triangle sampling/signature budget."
		return false
	faces.append_array([a, b, c])
	reflectance.append(_triangle_reflectance)
	face_emitter_indices.append(_triangle_emitter_index)
	face_source_ids.append(_triangle_source_id)
	face_surface_indices.append(_triangle_surface_index)
	if _triangle_emitter_index >= 0:
		_emitter_set.append_triangle(_triangle_emitter_index, a, b, c, normal,
				uv1_a, uv1_b, uv1_c, uv2_a, uv2_b, uv2_c)
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
	# tessellated/curved meshes. A 1x probe-spacing radius avoids filling a
	# lookup cell with several near-duplicate triangle samples.
	var min_separation: float = float(_volume.get("probe_spacing"))
	var hash_cell := Vector3i(floori(surface.x / min_separation),
			floori(surface.y / min_separation), floori(surface.z / min_separation))
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nearby: Array = _spatial_hash.get(hash_cell + Vector3i(dx, dy, dz), [])
				for existing in nearby:
					if _surfaces_are_duplicate(surface, normal, existing, min_separation):
						rejected_duplicate_count += 1
						return
	if _probe_offset_is_occluded(surface, normal):
		rejected_occluded_count += 1
		return
	var probe_center: Vector3 = surface + normal * float(_volume.surface_offset)
	var center_local := _inverse * probe_center
	if center_local.x < -_volume.size.x * 0.5 - epsilon \
			or center_local.x > _volume.size.x * 0.5 + epsilon \
			or center_local.y < -_volume.size.y * 0.5 - epsilon \
			or center_local.y > _volume.size.y * 0.5 + epsilon \
			or center_local.z < -_volume.size.z * 0.5 - epsilon \
			or center_local.z > _volume.size.z * 0.5 + epsilon:
		rejected_center_outside_count += 1
		return
	if _probe_center_is_inside_other_solid(probe_center):
		rejected_occluded_count += 1
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
	if positions.size() >= MAX_PROBES:
		error_message = "Surface sampling exceeds the 65,536-probe limit; increase Probe Spacing or reduce the volume."
		return
	_cell_counts[cell_key] = count + 1
	var point_entry := {
		"position": surface,
		"normal": normal,
		"source_id": _sample_source_id,
		"surface_index": _sample_surface_index,
	}
	var bucket: Array = _spatial_hash.get(hash_cell, [])
	bucket.append(point_entry)
	_spatial_hash[hash_cell] = bucket
	positions.append(probe_center)
	normals.append(normal)

func _surfaces_are_duplicate(surface: Vector3, normal: Vector3,
		existing: Dictionary, min_separation: float) -> bool:
	var existing_normal: Vector3 = existing.normal
	var alignment := normal.dot(existing_normal)
	if alignment <= 0.5 or surface.distance_squared_to(existing.position) \
			>= min_separation * min_separation:
		return false
	var same_surface_domain := int(existing.source_id) == _sample_source_id \
			and int(existing.surface_index) == _sample_surface_index
	var plane_tolerance := DUPLICATE_PLANE_EPSILON
	if same_surface_domain:
		# Curved meshes need a little slack across adjacent facets. The allowance
		# vanishes as normals become parallel, so thickness-separated parallel
		# sides of one shell still remain distinct.
		plane_tolerance += min_separation * sqrt(maxf(0.0, 1.0 - alignment * alignment))
	elif alignment < 0.995:
		return false # Across source surfaces/nodes, only same-facing planes merge.
	var separation := maxf(
			absf((surface - existing.position).dot(normal)),
			absf((surface - existing.position).dot(existing_normal)))
	return separation <= plane_tolerance

func _probe_offset_is_occluded(surface: Vector3, normal: Vector3) -> bool:
	if not bvh_ready or normal.length_squared() < 0.5:
		return false
	var offset := float(_volume.surface_offset)
	var epsilon := minf(offset * 0.25, BROADPHASE_EPSILON)
	var start := surface + normal * epsilon
	var end := surface + normal * offset
	return not bvh.intersect_segment(start, end).is_empty()

func _probe_center_is_inside_other_solid(point: Vector3) -> bool:
	for solid in _occlusion_volumes:
		# Do not treat the source mesh's own normal offset as an obstruction. The
		# short BVH segment test above still rejects offsets that immediately cross
		# the source surface; this skip only applies to whole-volume containment.
		if int(solid.instance_id) == _sample_source_id:
			continue
		var solid_box: AABB = solid.world_aabb
		if solid_box.has_point(point) and _point_inside_closed_mesh(
				point, solid_box, solid.bvh):
			return true
	return false

func _point_inside_closed_mesh(point: Vector3, bounds: AABB, mesh_bvh: TriangleMesh) -> bool:
	var directions := [
		Vector3(1.0, 0.371, 0.529).normalized(),
		Vector3(-0.291, 1.0, 0.417).normalized(),
		Vector3(0.613, -0.337, 1.0).normalized(),
		Vector3(-1.0, 0.743, 0.263).normalized(),
		Vector3(0.229, -1.0, 0.811).normalized(),
	]
	var ray_length := bounds.size.length() + 1.0
	var ray_epsilon := maxf(0.00001, bounds.size.length() * 0.000001)
	var valid_rays := 0
	var inside_votes := 0
	for direction in directions:
		var crossings := _ray_crossing_count(point, direction, ray_length,
				ray_epsilon, mesh_bvh)
		if crossings < 0:
			continue # A ray landed on the boundary; let the other directions decide.
		valid_rays += 1
		if crossings % 2 == 1:
			inside_votes += 1
	return valid_rays >= 3 and inside_votes >= 3

func _ray_crossing_count(origin: Vector3, direction: Vector3, ray_length: float,
		advance_epsilon: float, mesh_bvh: TriangleMesh) -> int:
	var ray_end := origin + direction * ray_length
	var ray_start := origin
	var crossings := 0
	for _hit_index in OCCLUSION_MAX_CROSSINGS:
		var hit: Dictionary = mesh_bvh.intersect_segment(ray_start, ray_end)
		if hit.is_empty():
			return crossings
		var hit_position: Vector3 = hit["position"]
		var along_ray := (hit_position - origin).dot(direction)
		if along_ray <= advance_epsilon * 4.0:
			return -1 # The query lies on or too close to this mesh boundary.
		crossings += 1
		ray_start = hit_position + direction * (advance_epsilon * 4.0)
		if ray_start.distance_squared_to(ray_end) <= advance_epsilon * advance_epsilon:
			return crossings
	return -1 # Avoid pathological work on malformed/intersecting topology.

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
		var face_index := int(hit["face_index"])
		hit["albedo"] = reflectance[face_index]
		hit["emitter_index"] = face_emitter_indices[face_index]
	return hit

## Uniform-area next-event sample for one fixed emissive surface binding.
## Returns the geometric estimator weight and texture sample, but never source color.
func sample_emitter_connection(emitter_index: int, receiver: Vector3, receiver_normal: Vector3,
		u_triangle: float, u_barycentric: float, u_edge: float, max_distance: float) -> Dictionary:
	if _emitter_set == null:
		return {}
	return _emitter_set.sample_connection(emitter_index, receiver, receiver_normal,
			u_triangle, u_barycentric, u_edge, max_distance, _volume.surface_offset)
