@tool
class_name FMagicGIPlacement
extends RefCounted
## Physics-independent surface sampling and the offline PRT triangle BVH.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const EmitterBakeSet = preload("feng_magic_gi_emitter_bake_set.gd")
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const MAX_PROBES := 65536
const MAX_GEOMETRY_TRIANGLES := 250000
const MAX_TERRAIN_CELLS := 500000
const MAX_SAMPLE_CANDIDATES := 2000000
const MAX_STAGED_WORLD_CELLS := MAX_PROBES
const MAX_STAGED_CANDIDATE_RECORDS := MAX_STAGED_WORLD_CELLS \
		* ProbeLayout.MAX_DOMAINS_PER_WORLD_CELL * ProbeLayout.CANDIDATES_PER_DOMAIN
const MAX_TRIANGLE_STEPS := 512
const MAX_OCCLUSION_TRIANGLES := 250000
const OCCLUSION_MAX_CROSSINGS := 256
const OCCLUSION_WELD_EPSILON := 0.00001
const FLOAT32_EPSILON := 0.00000011920928955078125
const MIN_PROBE_OFFSET_SPACING_RATIO := 0.002
const BASE_PROBE_OFFSET_SPACING_RATIO := 0.025
const MAX_PROBE_OFFSET_SPACING_RATIO := 0.08
const OCCLUSION_GRID_AXIS := 8
const BROADPHASE_EPSILON := SceneTracker.BROADPHASE_EPSILON

var faces := PackedVector3Array()
var reflectance := PackedVector3Array()
var face_source_ids := PackedInt64Array()
var face_surface_indices := PackedInt32Array()
var face_domain_sources := PackedStringArray()
var emitters := EmitterBakeSet.new()
var bvh: TriangleMesh
var positions := PackedVector3Array()
var surface_positions := PackedVector3Array()
var normals := PackedVector3Array()
var scene_signature := 0
var error_message := ""
var warning_message := ""
var bvh_ready := false

var _world_candidate_cells: Dictionary = {}
var _cell_counts: Dictionary = {}
var _occlusion_volumes: Array[Dictionary] = []
var _occlusion_cells: Dictionary = {}
var _source_volume_indices: Dictionary = {}
var _face_outward_signs: Dictionary = {}
var _volume: Node3D
var _world: World3D
var _collect_emission := false
var _world_bounds: AABB
var _bake_world_bounds: AABB
var _inverse := Transform3D.IDENTITY
var _dimensions := Vector3i.ONE
var _probe_spacing := 1.0
var _material_cache: Dictionary = {}
var _candidate_count := 0
var _canonical_candidate_count := 0
var _fallback_candidate_count := 0
var _fallback_triangle_count := 0
var _fallback_candidate_reservations := 0
var _terrain_work := 0
var _triangle_reflectance: Vector3
var _triangle_emitter_index := -1
var _triangle_source_id := 0
var _triangle_surface_index := -1
var _triangle_domain_source := ""
var _sample_source_id := 0
var _sample_surface_index := -1
var _sample_domain_source := ""
var _sample_face_index := -1
var _domain_source_cache: Dictionary = {}
var _fallback_triangle_vertices := PackedVector3Array()
var _fallback_triangle_normals := PackedVector3Array()
var _fallback_triangle_source_ids := PackedInt64Array()
var _fallback_triangle_surface_indices := PackedInt32Array()
var _fallback_triangle_face_indices := PackedInt32Array()
var _fallback_triangle_domain_indices := PackedInt32Array()
var _interned_domain_sources := PackedStringArray()
var _interned_domain_source_indices: Dictionary = {}
var _valid_candidate_count := 0
var _staged_candidate_count := 0
var _bounded_candidate_pruned_count := 0
var rejected_no_safe_offset_count := 0
var rejected_inside_or_indeterminate_center_count := 0
# Preserve the old aggregate diagnostic for the repository's existing harnesses.
var rejected_occluded_count: int:
	get:
		return rejected_no_safe_offset_count + rejected_inside_or_indeterminate_center_count
var rejected_duplicate_count := 0
var rejected_center_outside_count := 0
var rejected_foreign_surface_center_count := 0
var rejected_owner_connection_count := 0
var rejected_owner_connection_empty_count := 0
var rejected_owner_connection_mismatch_count := 0
var owner_connection_raw_anchor_count := 0
var rejected_owner_backside_center_count := 0
var rejected_center_clearance_count := 0
var rejected_ambiguous_side_count := 0
var rejected_center_overlap_count := 0
var rejected_world_cell_competition_count := 0
var rejected_lookup_capacity_count := 0
var rejected_world_cell_limit_count := 0
var adjusted_center_count := 0
var _scene_root: Node

func collect(volume: Node3D, for_bake := false, build_bvh := true, collect_emission := false) -> bool:
	_volume = volume
	_world = volume.get_world_3d()
	_collect_emission = collect_emission
	emitters = EmitterBakeSet.new()
	_inverse = volume.global_transform.affine_inverse()
	_dimensions = volume.grid_dimensions()
	_probe_spacing = maxf(float(volume.get("probe_spacing")), 0.1)
	error_message = ""
	warning_message = ""
	_world_bounds = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	# Preview must include geometry that can intersect the short surface-offset
	# segment, even before a bake exists. Bake collection already has the wider
	# ray-tracing bounds and therefore also contains this local occupancy region.
	var max_probe_offset := _preferred_probe_offset(volume)
	_bake_world_bounds = _world_bounds.grow(volume.bake_distance) if for_bake \
			else _world_bounds.grow(max_probe_offset + BROADPHASE_EPSILON)
	faces.clear()
	reflectance.clear()
	face_source_ids.clear()
	face_surface_indices.clear()
	face_domain_sources.clear()
	positions.clear()
	surface_positions.clear()
	normals.clear()
	_world_candidate_cells.clear()
	_cell_counts.clear()
	_occlusion_volumes.clear()
	_occlusion_cells.clear()
	_source_volume_indices.clear()
	_face_outward_signs.clear()
	_material_cache.clear()
	_candidate_count = 0
	_terrain_work = 0
	_triangle_emitter_index = -1
	_triangle_source_id = 0
	_triangle_surface_index = -1
	_triangle_domain_source = ""
	_sample_source_id = 0
	_sample_surface_index = -1
	_sample_domain_source = ""
	_sample_face_index = -1
	_domain_source_cache.clear()
	_fallback_triangle_vertices.clear()
	_fallback_triangle_normals.clear()
	_fallback_triangle_source_ids.clear()
	_fallback_triangle_surface_indices.clear()
	_fallback_triangle_face_indices.clear()
	_fallback_triangle_domain_indices.clear()
	_interned_domain_sources.clear()
	_interned_domain_source_indices.clear()
	_valid_candidate_count = 0
	_staged_candidate_count = 0
	_bounded_candidate_pruned_count = 0
	_canonical_candidate_count = 0
	_fallback_candidate_count = 0
	_fallback_triangle_count = 0
	_fallback_candidate_reservations = 0
	rejected_no_safe_offset_count = 0
	rejected_inside_or_indeterminate_center_count = 0
	rejected_duplicate_count = 0
	rejected_center_outside_count = 0
	rejected_foreign_surface_center_count = 0
	rejected_owner_connection_count = 0
	rejected_owner_connection_empty_count = 0
	rejected_owner_connection_mismatch_count = 0
	owner_connection_raw_anchor_count = 0
	rejected_owner_backside_center_count = 0
	rejected_center_clearance_count = 0
	rejected_ambiguous_side_count = 0
	rejected_center_overlap_count = 0
	rejected_world_cell_competition_count = 0
	rejected_lookup_capacity_count = 0
	rejected_world_cell_limit_count = 0
	adjusted_center_count = 0
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
	_build_occlusion_broadphase()
	if not _sample_collected_geometry():
		positions.clear()
		surface_positions.clear()
		normals.clear()
		return false
	if not _finalize_world_candidates():
		positions.clear()
		surface_positions.clear()
		normals.clear()
		return false
	_world_candidate_cells.clear()
	if not build_bvh:
		bvh = null
		bvh_ready = false
	if rejected_no_safe_offset_count > 0 or rejected_inside_or_indeterminate_center_count > 0 \
			or rejected_foreign_surface_center_count > 0 \
			or rejected_ambiguous_side_count > 0 or rejected_lookup_capacity_count > 0:
		warning_message = "Placed %d probes; rejected %d candidates with no safe offset, %d centers inside or indeterminate, %d centers without a clear source-face connection (%d on the back side), %d centers outside the volume, and %d candidates at lookup-cell capacity; skipped %d clipped triangles with unproven outward side." % [
			positions.size(), rejected_no_safe_offset_count,
			rejected_inside_or_indeterminate_center_count,
			rejected_foreign_surface_center_count, rejected_owner_backside_center_count,
			rejected_center_outside_count,
			rejected_lookup_capacity_count, rejected_ambiguous_side_count]
	scene_signature = hash([faces, reflectance, surface_positions, positions, normals])
	return true

func _sample_collected_geometry() -> bool:
	for face_offset in range(0, faces.size(), 3):
		var source_face_index := int(face_offset / 3)
		_sample_source_id = int(face_source_ids[source_face_index])
		_sample_surface_index = int(face_surface_indices[source_face_index])
		_sample_domain_source = String(face_domain_sources[source_face_index])
		_sample_face_index = source_face_index
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
			var source_normal_sign := _source_face_outward_sign(
					_sample_source_id, source_face_index, p0, p1, p2, clipped_normal)
			if source_normal_sign == 0.0:
				rejected_ambiguous_side_count += 1
				continue
			clipped_normal *= source_normal_sign
			if not _sample_triangle(p0, p1, p2, clipped_normal, source_face_index):
				_clear_fallback_triangle_queue()
				return false
	if not _sample_fallback_triangles():
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
	var placement_box := _world_bounds.grow(_preferred_probe_offset(_volume) + BROADPHASE_EPSILON)
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
	var solid_index := _occlusion_volumes.size()
	_occlusion_volumes.append({
		"instance_id": instance_id,
		"world_aabb": mesh_world_box,
		"bvh": mesh_bvh,
		"faces": world_faces,
	})
	_source_volume_indices[instance_id] = solid_index

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
	_triangle_domain_source = _mesh_domain_source(node, mesh)
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
	_triangle_domain_source = _mesh_domain_source(node, node.mesh)
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
		_triangle_emitter_index = emitters.register_surface(
				_scene_root, node, surface, material, uv1, uv2, vertex_count)
		if not emitters.error_message.is_empty():
			error_message = emitters.error_message
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
	_triangle_domain_source = _terrain_domain_source(terrain)
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
	face_source_ids.append(_triangle_source_id)
	face_surface_indices.append(_triangle_surface_index)
	face_domain_sources.append(_triangle_domain_source)
	if _triangle_emitter_index >= 0:
		emitters.append_triangle(_triangle_emitter_index, a, b, c, normal,
				uv1_a, uv1_b, uv1_c, uv2_a, uv2_b, uv2_c)
	return true

func _sample_triangle(a: Vector3, b: Vector3, c: Vector3, normal: Vector3,
		owner_face_index: int) -> bool:
	if not _world_point_coordinates_are_supported(a) \
			or not _world_point_coordinates_are_supported(b) \
			or not _world_point_coordinates_are_supported(c):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return false
	var triangle_centroid := (a + b + c) / 3.0
	var longest := maxf(a.distance_to(b), maxf(a.distance_to(c), b.distance_to(c)))
	var steps := _triangle_fallback_steps(longest)
	if steps > MAX_TRIANGLE_STEPS:
		error_message = "A clipped surface triangle exceeds the sampling budget; increase Probe Spacing."
		return false
	var dominant_axis := _dominant_normal_axis(normal)
	var projected_axes := _projected_axes(dominant_axis)
	var axis_u := projected_axes.x
	var axis_v := projected_axes.y
	var low_u := minf(a[axis_u], minf(b[axis_u], c[axis_u]))
	var high_u := maxf(a[axis_u], maxf(b[axis_u], c[axis_u]))
	var low_v := minf(a[axis_v], minf(b[axis_v], c[axis_v]))
	var high_v := maxf(a[axis_v], maxf(b[axis_v], c[axis_v]))
	var first_u := ceili(low_u / _probe_spacing - 0.5 - 0.000001)
	var last_u := floori(high_u / _probe_spacing - 0.5 + 0.000001)
	var first_v := ceili(low_v / _probe_spacing - 0.5 - 0.000001)
	var last_v := floori(high_v / _probe_spacing - 0.5 + 0.000001)
	var canonical_points_inside := 0
	var dominant_normal := normal[dominant_axis]
	if absf(dominant_normal) > 0.000001 and first_u <= last_u and first_v <= last_v:
		for cell_v in range(first_v, last_v + 1):
			for cell_u in range(first_u, last_u + 1):
				_candidate_count += 1
				if _candidate_count > MAX_SAMPLE_CANDIDATES:
					error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
					return false
				var point := Vector3.ZERO
				point[axis_u] = (float(cell_u) + 0.5) * _probe_spacing
				point[axis_v] = (float(cell_v) + 0.5) * _probe_spacing
				point[dominant_axis] = a[dominant_axis] - (
					normal[axis_u] * (point[axis_u] - a[axis_u])
						+ normal[axis_v] * (point[axis_v] - a[axis_v])) / dominant_normal
				if not _point_is_in_triangle(point, a, b, c):
					continue
				canonical_points_inside += 1
				_canonical_candidate_count += 1
				_add_surface(point, normal, triangle_centroid, owner_face_index, true,
						a, b, c)
				if not error_message.is_empty():
					return false
		# Raw barycentric samples are delayed until all canonical grid candidates
		# have been staged, so a fine tessellation cannot consume their budget or
		# bounded per-cell slots before a later triangle contributes the grid point.
	if canonical_points_inside == 0:
		return _queue_fallback_triangle(a, b, c, normal, owner_face_index, steps)
	return true

func _triangle_fallback_steps(longest: float) -> int:
	# Retain the bounded barycentric lattice only for triangles without a
	# canonical projected grid point. Large faces use a half-spacing fallback.
	var candidate_step := _probe_spacing
	if longest > _probe_spacing * 8.0:
		candidate_step = maxf(0.05, _probe_spacing * 0.5)
	return maxi(1, ceili(longest / candidate_step))

func _queue_fallback_triangle(a: Vector3, b: Vector3, c: Vector3, normal: Vector3,
		owner_face_index: int, steps: int) -> bool:
	var fallback_point_count := int((steps + 1) * (steps + 2) / 2)
	if steps == 1:
		fallback_point_count += 1
	if _candidate_count + _fallback_candidate_reservations + fallback_point_count \
			> MAX_SAMPLE_CANDIDATES:
		error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
		return false
	var source_index := int(_interned_domain_source_indices.get(_sample_domain_source, -1))
	if source_index < 0:
		source_index = _interned_domain_sources.size()
		_interned_domain_sources.append(_sample_domain_source)
		_interned_domain_source_indices[_sample_domain_source] = source_index
	_fallback_triangle_vertices.append_array([a, b, c])
	_fallback_triangle_normals.append(normal)
	_fallback_triangle_source_ids.append(_sample_source_id)
	_fallback_triangle_surface_indices.append(_sample_surface_index)
	_fallback_triangle_face_indices.append(owner_face_index)
	_fallback_triangle_domain_indices.append(source_index)
	_fallback_candidate_reservations += fallback_point_count
	_fallback_triangle_count += 1
	return true

func _sample_fallback_triangles() -> bool:
	for triangle_index in _fallback_triangle_normals.size():
		var vector_index := triangle_index * 3
		var a: Vector3 = _fallback_triangle_vertices[vector_index]
		var b: Vector3 = _fallback_triangle_vertices[vector_index + 1]
		var c: Vector3 = _fallback_triangle_vertices[vector_index + 2]
		var normal: Vector3 = _fallback_triangle_normals[triangle_index]
		_sample_source_id = int(_fallback_triangle_source_ids[triangle_index])
		_sample_surface_index = int(_fallback_triangle_surface_indices[triangle_index])
		_sample_face_index = int(_fallback_triangle_face_indices[triangle_index])
		_sample_domain_source = _interned_domain_sources[
				_fallback_triangle_domain_indices[triangle_index]]
		var steps := _triangle_fallback_steps(maxf(a.distance_to(b),
				maxf(a.distance_to(c), b.distance_to(c))))
		_fallback_candidate_reservations -= int((steps + 1) * (steps + 2) / 2)
		if steps == 1:
			_fallback_candidate_reservations -= 1
		if not _sample_triangle_fallback(a, b, c, normal, _sample_face_index, steps):
			_clear_fallback_triangle_queue()
			return false
	_clear_fallback_triangle_queue()
	return true

func _clear_fallback_triangle_queue() -> void:
	_fallback_triangle_vertices.clear()
	_fallback_triangle_normals.clear()
	_fallback_triangle_source_ids.clear()
	_fallback_triangle_surface_indices.clear()
	_fallback_triangle_face_indices.clear()
	_fallback_triangle_domain_indices.clear()
	_interned_domain_sources.clear()
	_interned_domain_source_indices.clear()
	_fallback_candidate_reservations = 0

func _sample_triangle_fallback(a: Vector3, b: Vector3, c: Vector3,
		normal: Vector3, owner_face_index: int, steps: int) -> bool:
	var triangle_centroid := (a + b + c) / 3.0
	var accepted_before := _valid_candidate_count
	for u in steps + 1:
		for v in steps + 1 - u:
			_candidate_count += 1
			if _candidate_count > MAX_SAMPLE_CANDIDATES:
				error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
				return false
			_fallback_candidate_count += 1
			var point := a + (b - a) * (float(u) / steps) \
					+ (c - a) * (float(v) / steps)
			_add_surface(point, normal, triangle_centroid, owner_face_index, false,
					a, b, c)
			if not error_message.is_empty():
				return false
	# Retain the small-triangle centroid rescue, but only after all canonical grid
	# opportunities and the bounded raw fallback have been considered.
	if steps == 1 and _valid_candidate_count == accepted_before:
		_candidate_count += 1
		if _candidate_count > MAX_SAMPLE_CANDIDATES:
			error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
			return false
		_fallback_candidate_count += 1
		_add_surface(triangle_centroid, normal, triangle_centroid, owner_face_index, false,
				a, b, c)
		if not error_message.is_empty():
			return false
	return true

func _dominant_normal_axis(normal: Vector3) -> int:
	var axis := 0
	if absf(normal.y) > absf(normal.x):
		axis = 1
	if absf(normal.z) > absf(normal[axis]):
		axis = 2
	return axis

func _projected_axes(dominant_axis: int) -> Vector2i:
	if dominant_axis == 0:
		return Vector2i(1, 2)
	if dominant_axis == 1:
		return Vector2i(0, 2)
	return Vector2i(0, 1)

func _point_is_in_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var edge_a := b - a
	var edge_b := c - a
	var relative := point - a
	var dot_aa := edge_a.dot(edge_a)
	var dot_ab := edge_a.dot(edge_b)
	var dot_bb := edge_b.dot(edge_b)
	var dot_ra := relative.dot(edge_a)
	var dot_rb := relative.dot(edge_b)
	var denominator := dot_aa * dot_bb - dot_ab * dot_ab
	if denominator <= 0.000000000001 * maxf(1.0, dot_aa * dot_bb):
		return false
	var bary_a := (dot_bb * dot_ra - dot_ab * dot_rb) / denominator
	var bary_b := (dot_aa * dot_rb - dot_ab * dot_ra) / denominator
	return bary_a >= -0.000001 and bary_b >= -0.000001 \
			and bary_a + bary_b <= 1.000001

func _center_has_owner_surface_connection(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> bool:
	var result := _owner_surface_connection_result(surface, normal, center, owner_face_index)
	return result == -2 or result >= 0

func _owner_surface_connection_result(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> int:
	if not bvh_ready:
		return -2
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return -3
	var offset := (center - surface).dot(normal)
	if offset <= 0.0:
		return -3
	# TriangleMesh snaps BVH vertices to 1e-4 world units. Extend both ends of
	# this proof segment beyond the center/anchor so that quantization does not
	# turn a valid owner-face connection into an empty or neighboring-face hit.
	# This only proves the source connection; it does not move the probe center
	# or relax the separate foreign-surface clearance test.
	var epsilon := maxf(0.0002, _probe_spacing * 0.00001)
	var hit := bvh.intersect_segment(center + normal * epsilon,
			surface - normal * epsilon)
	if hit.is_empty():
		return -1
	var hit_face := int(hit.get("face_index", -1))
	if hit_face == owner_face_index \
			or _face_is_same_coplanar_surface(hit_face, owner_face_index, surface, normal):
		return hit_face
	return -4

func _center_is_on_owner_front_side(center: Vector3, normal: Vector3,
		owner_face_index: int) -> bool:
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var a: Vector3 = faces[owner_face_index * 3]
	var b: Vector3 = faces[owner_face_index * 3 + 1]
	var c: Vector3 = faces[owner_face_index * 3 + 2]
	var raw_normal := (c - a).cross(b - a).normalized()
	var alignment := raw_normal.dot(normal)
	if raw_normal.length_squared() < 0.5 or absf(alignment) < 0.999:
		return false
	if alignment < 0.0:
		raw_normal = -raw_normal
	return (center - a).dot(raw_normal) > 0.0

func _surface_is_on_owner_face(surface: Vector3, owner_face_index: int,
		sample_a: Vector3, sample_b: Vector3, sample_c: Vector3) -> bool:
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var a: Vector3 = faces[owner_face_index * 3]
	var b: Vector3 = faces[owner_face_index * 3 + 1]
	var c: Vector3 = faces[owner_face_index * 3 + 2]
	var face_normal := (c - a).cross(b - a).normalized()
	if face_normal.length_squared() < 0.5:
		return false
	var sample_normal := (sample_c - sample_a).cross(sample_b - sample_a).normalized()
	if sample_normal.length_squared() < 0.5 or absf(face_normal.dot(sample_normal)) < 0.9999:
		return false
	# Clipping transforms world vertices into Volume-local coordinates and back.
	# At large translations this can offset the clipped triangle's plane from the
	# original world face by a few float ulps. Bound that measured discrepancy
	# from this exact source-derived triangle; reject if it is too large relative
	# to probe spacing to remain a safe ownership proof.
	var sample_plane_deviation := maxf(
			absf(face_normal.dot(sample_a - a)),
			maxf(absf(face_normal.dot(sample_b - a)),
					absf(face_normal.dot(sample_c - a))))
	var plane_tolerance := sample_plane_deviation + maxf(0.0002, _probe_spacing * 0.00001)
	if plane_tolerance > _probe_spacing * 0.01:
		return false
	var plane_residual := absf(face_normal.dot(surface - a))
	if plane_residual > plane_tolerance:
		return false
	if not _point_is_in_triangle(surface, a, b, c):
		return false
	return true

func _center_has_foreign_surface_clearance(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> bool:
	# A valid owner-face connection does not prove that the probe center is clear
	# of another perpendicular/open surface. Probe six short, centered segments
	# around the center and reject any nearby finite BVH face outside the owner
	# coplanar continuation. This is deliberately bounded to the existing spacing
	# clearance scale; it does not infer infinite planes or move the probe.
	var clearance := maxf(0.000001, _probe_spacing * MIN_PROBE_OFFSET_SPACING_RATIO)
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for axis_value in axes:
		var axis: Vector3 = axis_value
		var hit := bvh.intersect_segment(center - axis * clearance,
				center + axis * clearance)
		if not hit.is_empty():
			var hit_face := int(hit.get("face_index", -1))
			if hit_face != owner_face_index \
					and not _face_is_same_coplanar_surface(hit_face, owner_face_index, surface, normal):
				return false
		# Cast the same segment in reverse too. If an owner/coplanar face is
		# first from one endpoint, this lets a nearer foreign face win from the
		# other side of the center.
		hit = bvh.intersect_segment(center + axis * clearance,
				center - axis * clearance)
		if not hit.is_empty():
			var reverse_hit_face := int(hit.get("face_index", -1))
			if reverse_hit_face != owner_face_index \
					and not _face_is_same_coplanar_surface(reverse_hit_face, owner_face_index, surface, normal):
				return false
	return true

func _face_is_same_coplanar_surface(hit_face_index: int, owner_face_index: int,
		surface: Vector3, owner_normal: Vector3) -> bool:
	if hit_face_index < 0 or hit_face_index * 3 + 2 >= faces.size() \
			or owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var hit_a: Vector3 = faces[hit_face_index * 3]
	var hit_b: Vector3 = faces[hit_face_index * 3 + 1]
	var hit_c: Vector3 = faces[hit_face_index * 3 + 2]
	var authored_normal := (hit_c - hit_a).cross(hit_b - hit_a).normalized()
	if _face_outward_signs.has(hit_face_index):
		authored_normal *= float(_face_outward_signs[hit_face_index])
	if authored_normal.length_squared() < 0.5 \
			or absf(authored_normal.dot(owner_normal)) < 0.999:
		return false
	var plane_tolerance := maxf(0.0002, _probe_spacing * 0.0001)
	return absf(owner_normal.dot(hit_a - surface)) <= plane_tolerance

func _add_surface(surface: Vector3, normal: Vector3, triangle_centroid: Vector3,
		owner_face_index: int, canonical: bool,
		sample_a: Vector3, sample_b: Vector3, sample_c: Vector3) -> void:
	var local := _inverse * surface
	var epsilon := maxf(0.0001, _probe_spacing * 0.0001)
	if local.x < -_volume.size.x * 0.5 - epsilon or local.x > _volume.size.x * 0.5 + epsilon \
			or local.y < -_volume.size.y * 0.5 - epsilon or local.y > _volume.size.y * 0.5 + epsilon \
			or local.z < -_volume.size.z * 0.5 - epsilon or local.z > _volume.size.z * 0.5 + epsilon:
		return
	var domain_key := _candidate_domain_key(normal, triangle_centroid)
	# Triangle meshes commonly repeat the same vertex on adjacent faces. Drop
	# only a near-identical anchor already retained for the same signed domain,
	# before running the more expensive offset and closed-solid tests.
	var estimated_center := surface + normal * _preferred_probe_offset(_volume)
	if not _world_point_coordinates_are_supported(estimated_center):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return
	var estimated_cell := ProbeLayout.world_cell(estimated_center, _probe_spacing)
	if _has_staged_anchor_duplicate(surface, domain_key, estimated_cell):
		rejected_duplicate_count += 1
		return
	var actual_offset := _safe_probe_offset(surface, normal, _preferred_probe_offset(_volume))
	if actual_offset <= 0.0:
		rejected_no_safe_offset_count += 1
		return
	var probe_center: Vector3 = surface + normal * actual_offset
	if not _world_point_coordinates_are_supported(probe_center):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return
	var center_local := _inverse * probe_center
	if center_local.x < -_volume.size.x * 0.5 - epsilon \
			or center_local.x > _volume.size.x * 0.5 + epsilon \
			or center_local.y < -_volume.size.y * 0.5 - epsilon \
			or center_local.y > _volume.size.y * 0.5 + epsilon \
			or center_local.z < -_volume.size.z * 0.5 - epsilon \
			or center_local.z > _volume.size.z * 0.5 + epsilon:
		rejected_center_outside_count += 1
		return
	if not _center_is_on_owner_front_side(probe_center, normal, owner_face_index):
		rejected_owner_backside_center_count += 1
		rejected_foreign_surface_center_count += 1
		return
	var owner_connection_result := _owner_surface_connection_result(surface, normal,
			probe_center, owner_face_index)
	if owner_connection_result == -1 and _surface_is_on_owner_face(
			surface, owner_face_index, sample_a, sample_b, sample_c):
		# Empty BVH hit means the same segment found no foreign blocker. The raw
		# owner face plus this clipped-triangle containment prove the source side.
		owner_connection_raw_anchor_count += 1
		owner_connection_result = owner_face_index
	if owner_connection_result != -2 and owner_connection_result < 0:
		rejected_owner_connection_count += 1
		if owner_connection_result == -1:
			rejected_owner_connection_empty_count += 1
		else:
			rejected_owner_connection_mismatch_count += 1
		rejected_foreign_surface_center_count += 1
		return
	if not _center_has_foreign_surface_clearance(surface, normal, probe_center,
			owner_face_index):
		rejected_center_clearance_count += 1
		rejected_foreign_surface_center_count += 1
		return
	var grid: Vector3 = (local + _volume.size * 0.5) / _volume.size * Vector3(_dimensions)
	var cell := Data.cell_coordinates(grid, _dimensions)
	if cell.x < 0:
		error_message = "A sampled surface escaped the PRT lookup grid."
		return
	var cell_key := cell.x + cell.y * _dimensions.x + cell.z * _dimensions.x * _dimensions.y
	if _probe_center_is_inside_solid(probe_center):
		rejected_inside_or_indeterminate_center_count += 1
		return
	var world_cell := ProbeLayout.world_cell(probe_center, _probe_spacing)
	_valid_candidate_count += 1
	var candidate := {
		"surface": surface,
		"center": probe_center,
		"normal": normal,
		"lookup_cell": cell_key,
		"domain": domain_key,
		"canonical": canonical,
		"face_index": owner_face_index,
		"world_cell": world_cell,
		"score": probe_center.distance_squared_to(
				ProbeLayout.world_cell_center(world_cell, _probe_spacing)),
	}
	_stage_world_candidate(world_cell, domain_key, candidate)

func _stage_world_candidate(world_cell: Vector3i, domain_key: String,
		candidate: Dictionary) -> void:
	var cell_bucket: Dictionary = _world_candidate_cells.get(world_cell, {})
	if cell_bucket.is_empty():
		if _world_candidate_cells.size() >= MAX_STAGED_WORLD_CELLS:
			rejected_world_cell_limit_count += 1
			error_message = "World-space probe staging exceeds the 65,536-cell limit. Increase Probe Spacing or reduce the volume."
			return
		cell_bucket = {"domains": {}}
		_world_candidate_cells[world_cell] = cell_bucket
	var domains: Dictionary = cell_bucket["domains"]
	var candidate_rank := ProbeLayout.world_cell_rank(domain_key, world_cell)
	if domains.has(domain_key):
		var domain_bucket: Dictionary = domains[domain_key]
		var candidates: Array = domain_bucket["candidates"]
		for candidate_index in candidates.size():
			var existing: Dictionary = candidates[candidate_index]
			var existing_surface: Vector3 = existing["surface"]
			var anchor_epsilon := maxf(0.000001, _probe_spacing * 0.000001)
			if existing_surface.distance_squared_to(candidate["surface"]) \
					<= anchor_epsilon * anchor_epsilon:
				if bool(candidate["canonical"]) and not bool(existing["canonical"]):
					candidates[candidate_index] = candidate
					candidates.sort_custom(Callable(self, "_candidate_less"))
					domain_bucket["canonical"] = true
					domain_bucket["candidates"] = candidates
					domains[domain_key] = domain_bucket
					cell_bucket["domains"] = domains
					_world_candidate_cells[world_cell] = cell_bucket
				return
		candidates.append(candidate)
		candidates.sort_custom(Callable(self, "_candidate_less"))
		if candidates.size() > ProbeLayout.CANDIDATES_PER_DOMAIN:
			candidates.resize(ProbeLayout.CANDIDATES_PER_DOMAIN)
		else:
			_staged_candidate_count += 1
		domain_bucket["canonical"] = bool(domain_bucket.get("canonical", false)) \
				or bool(candidate["canonical"])
		domain_bucket["candidates"] = candidates
		domains[domain_key] = domain_bucket
		cell_bucket["domains"] = domains
		_world_candidate_cells[world_cell] = cell_bucket
		return
	if domains.size() >= ProbeLayout.MAX_DOMAINS_PER_WORLD_CELL:
		var worst_key := ""
		var worst_rank := -1
		var worst_is_canonical := true
		for existing_key in domains:
			var existing_bucket: Dictionary = domains[existing_key]
			var existing_rank := int(existing_bucket["rank"])
			var existing_is_canonical := bool(existing_bucket.get("canonical", false))
			if worst_key.is_empty() \
					or (not existing_is_canonical and worst_is_canonical) \
					or (existing_is_canonical == worst_is_canonical \
					and (existing_rank > worst_rank \
					or (existing_rank == worst_rank and String(existing_key) > worst_key))):
				worst_key = String(existing_key)
				worst_rank = existing_rank
				worst_is_canonical = existing_is_canonical
		var candidate_is_canonical := bool(candidate["canonical"])
		if (not candidate_is_canonical and worst_is_canonical) \
				or (candidate_is_canonical == worst_is_canonical \
				and (candidate_rank > worst_rank \
				or (candidate_rank == worst_rank and domain_key >= worst_key))):
			return
		var evicted: Dictionary = domains[worst_key]
		var evicted_candidates: Array = evicted["candidates"]
		_staged_candidate_count -= evicted_candidates.size()
		domains.erase(worst_key)
	var new_domain := {"rank": candidate_rank, "canonical": bool(candidate["canonical"]),
			"candidates": [candidate]}
	domains[domain_key] = new_domain
	_staged_candidate_count += 1
	if _staged_candidate_count > MAX_STAGED_CANDIDATE_RECORDS:
		error_message = "World-space probe candidate staging exceeds its bounded record limit."
		return
	cell_bucket["domains"] = domains
	_world_candidate_cells[world_cell] = cell_bucket

func _has_staged_anchor_duplicate(surface: Vector3, domain_key: String,
		estimated_cell: Vector3i) -> bool:
	var anchor_epsilon := maxf(0.000001, _probe_spacing * 0.000001)
	var epsilon_squared := anchor_epsilon * anchor_epsilon
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cell_bucket: Dictionary = _world_candidate_cells.get(
						estimated_cell + Vector3i(dx, dy, dz), {})
				var domains: Dictionary = cell_bucket.get("domains", {})
				if not domains.has(domain_key):
					continue
				for candidate in domains[domain_key]["candidates"]:
					var existing_surface: Vector3 = candidate["surface"]
					if existing_surface.distance_squared_to(surface) <= epsilon_squared:
						return true
	return false

func _candidate_domain_key(normal: Vector3, triangle_centroid: Vector3) -> String:
	var normal_bin := Vector3i(roundi(normal.x * 20.0), roundi(normal.y * 20.0),
			roundi(normal.z * 20.0))
	var plane_quantum := maxf(_probe_spacing * 0.05, 0.001)
	var plane_bin := roundi(normal.dot(triangle_centroid) / plane_quantum)
	return "%s\u001f%d\u001f%d,%d,%d\u001f%d" % [
		_sample_domain_source, _sample_surface_index, normal_bin.x, normal_bin.y,
		normal_bin.z, plane_bin]

func _candidate_less(a: Dictionary, b: Dictionary) -> bool:
	var canonical_a := bool(a["canonical"])
	var canonical_b := bool(b["canonical"])
	if canonical_a != canonical_b:
		return canonical_a
	var score_a := float(a["score"])
	var score_b := float(b["score"])
	if score_a != score_b:
		return score_a < score_b
	var surface_a: Vector3 = a["surface"]
	var surface_b: Vector3 = b["surface"]
	if surface_a.x != surface_b.x:
		return surface_a.x < surface_b.x
	if surface_a.y != surface_b.y:
		return surface_a.y < surface_b.y
	if surface_a.z != surface_b.z:
		return surface_a.z < surface_b.z
	var normal_a: Vector3 = a["normal"]
	var normal_b: Vector3 = b["normal"]
	if normal_a.x != normal_b.x:
		return normal_a.x < normal_b.x
	if normal_a.y != normal_b.y:
		return normal_a.y < normal_b.y
	return normal_a.z < normal_b.z

func _finalize_world_candidates() -> bool:
	_bounded_candidate_pruned_count = maxi(0, _valid_candidate_count - _staged_candidate_count)
	var canonical_domain_entries: Dictionary = {}
	var fallback_domain_entries: Dictionary = {}
	var minimum_world_cell := Vector3i(2147483647, 2147483647, 2147483647)
	for cell_value in _world_candidate_cells:
		var world_cell: Vector3i = cell_value
		minimum_world_cell.x = mini(minimum_world_cell.x, world_cell.x)
		minimum_world_cell.y = mini(minimum_world_cell.y, world_cell.y)
		minimum_world_cell.z = mini(minimum_world_cell.z, world_cell.z)
	for cell_value in _world_candidate_cells:
		var world_cell: Vector3i = cell_value
		var domains: Dictionary = _world_candidate_cells[world_cell]["domains"]
		# Shift only arbitration order to a nonnegative local range. Occupancy and
		# spacing remain anchored to world origin.
		var order_cell := world_cell - minimum_world_cell
		var morton := ProbeLayout.morton_words(order_cell)
		for domain_key in domains:
			var domain_bucket: Dictionary = domains[domain_key]
			var canonical_candidates: Array = []
			var fallback_candidates: Array = []
			for candidate in domain_bucket["candidates"]:
				if bool(candidate["canonical"]):
					canonical_candidates.append(candidate)
				else:
					fallback_candidates.append(candidate)
			if not canonical_candidates.is_empty():
				var entries: Array = canonical_domain_entries.get(domain_key, [])
				entries.append({"cell": world_cell, "morton": morton,
						"candidates": canonical_candidates})
				canonical_domain_entries[domain_key] = entries
			if not fallback_candidates.is_empty():
				var fallback_entries: Array = fallback_domain_entries.get(domain_key, [])
				fallback_entries.append({"cell": world_cell, "morton": morton,
						"candidates": fallback_candidates})
				fallback_domain_entries[domain_key] = fallback_entries
	var accepted_world_centers: Dictionary = {}
	var accepted_cells: Dictionary = {}
	var spacing_blocked_cells: Dictionary = {}
	var lookup_blocked_cells: Dictionary = {}
	var minimum_separation_squared := ProbeLayout.world_center_separation_squared(_probe_spacing)
	# Canonical projected world-grid points own the first complete fairness pass.
	# Only after it finishes can small-face barycentric/centroid fallback points
	# compete for cells that remain available.
	if not _run_candidate_phase(canonical_domain_entries, accepted_world_centers,
			accepted_cells, spacing_blocked_cells, lookup_blocked_cells,
			minimum_separation_squared):
		return false
	if not _run_candidate_phase(fallback_domain_entries, accepted_world_centers,
			accepted_cells, spacing_blocked_cells, lookup_blocked_cells,
			minimum_separation_squared):
		return false
	for cell_value in _world_candidate_cells:
		var world_cell: Vector3i = cell_value
		var domains: Dictionary = _world_candidate_cells[world_cell]["domains"]
		var staged_for_cell := 0
		for domain_bucket_value in domains.values():
			staged_for_cell += domain_bucket_value["candidates"].size()
		if accepted_cells.has(world_cell):
			rejected_world_cell_competition_count += maxi(0, staged_for_cell - 1)
		else:
			rejected_world_cell_competition_count += staged_for_cell
			if spacing_blocked_cells.has(world_cell):
				rejected_center_overlap_count += 1
			if lookup_blocked_cells.has(world_cell):
				rejected_lookup_capacity_count += 1
	return true

func _run_candidate_phase(domain_entries: Dictionary,
		accepted_world_centers: Dictionary, accepted_cells: Dictionary,
		spacing_blocked_cells: Dictionary, lookup_blocked_cells: Dictionary,
		minimum_separation_squared: float) -> bool:
	var domain_states: Dictionary = {}
	var scheduler: Array[Dictionary] = []
	for domain_key_value in domain_entries:
		var domain_key := String(domain_key_value)
		var entries: Array = domain_entries[domain_key]
		entries.sort_custom(Callable(self, "_domain_opportunity_less"))
		var opportunities := entries.size()
		if opportunities <= 0:
			continue
		var state := {
			"entries": entries,
			"cursor": 0,
			"accepted": 0,
			"attempted": 0,
			"opportunities": opportunities,
			"rank": ProbeLayout.world_cell_rank(domain_key, Vector3i.ZERO),
		}
		domain_states[domain_key] = state
		_coverage_heap_push(scheduler, _coverage_heap_item(domain_key, state))
	while not scheduler.is_empty():
		var schedule_entry := _coverage_heap_pop(scheduler)
		var domain_key := String(schedule_entry["key"])
		if not domain_states.has(domain_key):
			continue
		var state: Dictionary = domain_states[domain_key]
		var entries: Array = state["entries"]
		var cursor := int(state["cursor"])
		if cursor >= entries.size():
			domain_states.erase(domain_key)
			continue
		var opportunity: Dictionary = entries[cursor]
		var world_cell: Vector3i = opportunity["cell"]
		state["cursor"] = cursor + 1
		state["attempted"] = int(state["attempted"]) + 1
		if accepted_world_centers.has(world_cell):
			domain_states[domain_key] = state
			if int(state["cursor"]) < entries.size():
				_coverage_heap_push(scheduler, _coverage_heap_item(domain_key, state))
			continue
		var spacing_blocked := false
		var lookup_blocked := false
		var cell_accepted := false
		var candidates: Array = opportunity["candidates"]
		for candidate in candidates:
			var lookup_cell := int(candidate["lookup_cell"])
			if int(_cell_counts.get(lookup_cell, 0)) >= Data.CELL_CAPACITY:
				lookup_blocked = true
				continue
			if positions.size() >= MAX_PROBES:
				error_message = "Surface sampling exceeds the 65,536-probe limit; increase Probe Spacing or reduce the volume."
				return false
			var center: Vector3 = candidate["center"]
			if _accepted_world_center_conflict(world_cell, center,
						accepted_world_centers, minimum_separation_squared):
				spacing_blocked = true
				continue
			positions.append(center)
			surface_positions.append(candidate["surface"])
			normals.append(candidate["normal"])
			_cell_counts[lookup_cell] = int(_cell_counts.get(lookup_cell, 0)) + 1
			accepted_world_centers[world_cell] = center
			accepted_cells[world_cell] = true
			state["accepted"] = int(state["accepted"]) + 1
			cell_accepted = true
			break
		if not cell_accepted:
			if spacing_blocked:
				spacing_blocked_cells[world_cell] = true
			if lookup_blocked:
				lookup_blocked_cells[world_cell] = true
		domain_states[domain_key] = state
		if int(state["cursor"]) < entries.size():
			_coverage_heap_push(scheduler, _coverage_heap_item(domain_key, state))
	return true

func _domain_opportunity_less(a: Dictionary, b: Dictionary) -> bool:
	var cell_a: Vector3i = a["cell"]
	var cell_b: Vector3i = b["cell"]
	var morton_a: PackedInt64Array = a["morton"]
	var morton_b: PackedInt64Array = b["morton"]
	if ProbeLayout.morton_words_less(morton_a, morton_b):
		return true
	if ProbeLayout.morton_words_less(morton_b, morton_a):
		return false
	if cell_a.x != cell_b.x:
		return cell_a.x < cell_b.x
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	return cell_a.z < cell_b.z

func _coverage_heap_item(domain_key: String, state: Dictionary) -> Dictionary:
	return {
		"key": domain_key,
		"accepted": int(state["accepted"]),
		"attempted": int(state["attempted"]),
		"opportunities": int(state["opportunities"]),
		"rank": int(state["rank"]),
	}

func _coverage_heap_less(a: Dictionary, b: Dictionary) -> bool:
	var accepted_a := int(a["accepted"])
	var accepted_b := int(b["accepted"])
	var opportunities_a := int(a["opportunities"])
	var opportunities_b := int(b["opportunities"])
	var accepted_cross_a := accepted_a * opportunities_b
	var accepted_cross_b := accepted_b * opportunities_a
	if accepted_cross_a != accepted_cross_b:
		return accepted_cross_a < accepted_cross_b
	# Among equal accepted/opportunity ratios, rotate domains by the fraction of
	# their opportunities already tried. Stable rank/key resolves exact ties.
	var attempted_cross_a := int(a["attempted"]) * opportunities_b
	var attempted_cross_b := int(b["attempted"]) * opportunities_a
	if attempted_cross_a != attempted_cross_b:
		return attempted_cross_a < attempted_cross_b
	var rank_a := int(a["rank"])
	var rank_b := int(b["rank"])
	if rank_a != rank_b:
		return rank_a < rank_b
	return String(a["key"]) < String(b["key"])

func _coverage_heap_push(heap: Array[Dictionary], item: Dictionary) -> void:
	heap.append(item)
	var index := heap.size() - 1
	while index > 0:
		var parent := int((index - 1) / 2)
		if not _coverage_heap_less(item, heap[parent]):
			break
		heap[index] = heap[parent]
		index = parent
	heap[index] = item

func _coverage_heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty():
		return result
	var index := 0
	while true:
		var left := index * 2 + 1
		if left >= heap.size():
			break
		var best := left
		var right := left + 1
		if right < heap.size() and _coverage_heap_less(heap[right], heap[left]):
			best = right
		if not _coverage_heap_less(heap[best], last):
			break
		heap[index] = heap[best]
		index = best
	heap[index] = last
	return result

func _accepted_world_center_conflict(world_cell: Vector3i, center: Vector3,
		accepted: Dictionary, minimum_separation_squared: float) -> bool:
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var neighbor := world_cell + Vector3i(dx, dy, dz)
				if accepted.has(neighbor) \
						and center.distance_squared_to(accepted[neighbor]) \
						< minimum_separation_squared:
					return true
	return false

func _world_point_coordinates_are_supported(point: Vector3) -> bool:
	var scaled := point / _probe_spacing
	return scaled.is_finite() and absf(scaled.x) < 2147483000.0 \
			and absf(scaled.y) < 2147483000.0 and absf(scaled.z) < 2147483000.0

func _mesh_domain_source(node: MeshInstance3D, mesh: Mesh) -> String:
	var instance_id := node.get_instance_id()
	if _domain_source_cache.has(instance_id):
		return String(_domain_source_cache[instance_id])
	var values := _transform_domain_values(node.global_transform)
	var local_bounds := mesh.get_aabb()
	# Use the same canonical face extent as the collector. PrimitiveMesh.get_aabb()
	# describes its analytic surface, while get_faces() snaps generated triangles;
	# a canonical ArrayMesh made from those faces must keep the same domain key.
	var local_faces: PackedVector3Array = mesh.get_faces()
	if not local_faces.is_empty():
		var minimum := local_faces[0]
		var maximum := local_faces[0]
		for point in local_faces:
			minimum = minimum.min(point)
			maximum = maximum.max(point)
		local_bounds = AABB(minimum, maximum - minimum)
	values = _append_quantized_vector(values, local_bounds.position)
	values = _append_quantized_vector(values, local_bounds.size)
	var identity := "mesh:%s" % _stable_domain_hash(values)
	_domain_source_cache[instance_id] = identity
	return identity

func _terrain_domain_source(terrain: Node3D) -> String:
	var instance_id := terrain.get_instance_id()
	if _domain_source_cache.has(instance_id):
		return String(_domain_source_cache[instance_id])
	var values := _transform_domain_values(terrain.global_transform)
	values = _append_quantized_vector(values, _world_bounds.position)
	values = _append_quantized_vector(values, _world_bounds.size)
	values.append(roundi(float(terrain.get("vertex_spacing")) * 100000.0))
	var identity := "terrain:%s" % _stable_domain_hash(values)
	_domain_source_cache[instance_id] = identity
	return identity

func _transform_domain_values(transform: Transform3D) -> PackedInt64Array:
	var values := PackedInt64Array()
	values = _append_quantized_vector(values, transform.basis.x)
	values = _append_quantized_vector(values, transform.basis.y)
	values = _append_quantized_vector(values, transform.basis.z)
	values = _append_quantized_vector(values, transform.origin)
	return values

func _append_quantized_vector(values: PackedInt64Array, vector: Vector3) -> PackedInt64Array:
	const QUANTIZATION := 100000.0
	var result := values
	result.append(roundi(vector.x * QUANTIZATION))
	result.append(roundi(vector.y * QUANTIZATION))
	result.append(roundi(vector.z * QUANTIZATION))
	return result

func _stable_domain_hash(values: PackedInt64Array) -> String:
	# Geometry domain identity must survive scene re-instantiation; runtime IDs and
	# node paths are used only to cache this value, never to derive its contents.
	var low: int = 2166136261
	var high: int = 2246822519
	for value in values:
		for shift in range(0, 64, 8):
			var byte_value := (int(value) >> shift) & 0xff
			low = int((low ^ byte_value) * 16777619) & 0xffffffff
			high = int((high ^ (byte_value ^ 0x5b)) * 16777619) & 0xffffffff
	return "%08x%08x" % [low, high]

static func _preferred_probe_offset(volume: Node3D) -> float:
	var spacing := maxf(float(volume.get("probe_spacing")), 0.1)
	var lower := spacing * MIN_PROBE_OFFSET_SPACING_RATIO
	var upper := spacing * MAX_PROBE_OFFSET_SPACING_RATIO
	return clampf(maxf(float(volume.get("surface_offset")),
			spacing * BASE_PROBE_OFFSET_SPACING_RATIO), lower, upper)

func _source_face_outward_sign(source_id: int, face_index: int,
		a: Vector3, b: Vector3, c: Vector3, authored_normal: Vector3) -> float:
	if _face_outward_signs.has(face_index):
		return float(_face_outward_signs[face_index])
	if not _source_volume_indices.has(source_id):
		_face_outward_signs[face_index] = 1.0
		return 1.0 # Open meshes retain their authored face direction.
	var solid: Dictionary = _occlusion_volumes[int(_source_volume_indices[source_id])]
	var bounds: AABB = solid.world_aabb
	var scale := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	var longest_edge := maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))
	var cross_length := (c - a).cross(b - a).length()
	if longest_edge <= 0.00000001 or cross_length <= 0.00000001:
		_face_outward_signs[face_index] = 0.0
		return 0.0
	var altitude := cross_length / longest_edge
	var max_distance := minf(scale * 0.001, altitude * 0.1)
	var test_distance := maxf(0.0000001, scale * 0.000001)
	if max_distance < test_distance:
		_face_outward_signs[face_index] = 0.0
		return 0.0
	var center := (a + b + c) / 3.0
	var test_distances := [test_distance, minf(max_distance, test_distance * 4.0),
			minf(max_distance, test_distance * 16.0), max_distance]
	for distance in test_distances:
		var offset := authored_normal * float(distance)
		var positive_side := _point_inside_closed_mesh_state(center + offset, bounds,
				solid.bvh, solid.faces)
		var negative_side := _point_inside_closed_mesh_state(center - offset, bounds,
				solid.bvh, solid.faces)
		if positive_side == 0 and negative_side == 1:
			_face_outward_signs[face_index] = 1.0
			return 1.0
		if positive_side == 1 and negative_side == 0:
			_face_outward_signs[face_index] = -1.0
			return -1.0
	_face_outward_signs[face_index] = 0.0
	return 0.0

func _safe_probe_offset(surface: Vector3, normal: Vector3, preferred: float) -> float:
	if normal.length_squared() < 0.5 or not is_finite(preferred) or preferred <= 0.0:
		return 0.0
	var safe_offset := preferred
	var ray_epsilon := maxf(0.00001, minf(preferred * 0.1,
			float(_volume.probe_spacing) * 0.0005))
	if bvh_ready:
		var hit := bvh.intersect_segment(surface + normal * ray_epsilon,
				surface + normal * preferred)
		if not hit.is_empty():
			var hit_distance: float = (hit.position - surface).dot(normal)
			safe_offset = minf(safe_offset, (hit_distance - ray_epsilon) * 0.45)
	# Keep the center inside the oriented volume even when the surface lies on a
	# boundary. The inverse-basis direction accounts for nonuniform volume scale.
	var local_surface := _inverse * surface
	var local_direction := _inverse.basis * normal
	var half_size: Vector3 = _volume.size * 0.5
	var local_boundary_epsilon := maxf(0.00001, float(_volume.probe_spacing) * 0.00001)
	for axis in 3:
		var direction_component := local_direction[axis]
		if absf(direction_component) < 0.000001:
			continue
		var boundary := half_size[axis] if direction_component > 0.0 else -half_size[axis]
		var distance_to_boundary := (boundary - local_surface[axis]) / direction_component
		if distance_to_boundary >= 0.0:
			safe_offset = minf(safe_offset,
					distance_to_boundary - local_boundary_epsilon / absf(direction_component))
	var minimum_clearance := maxf(ray_epsilon * 2.0,
			float(_volume.probe_spacing) * MIN_PROBE_OFFSET_SPACING_RATIO)
	return safe_offset if safe_offset >= minimum_clearance else 0.0

func _build_occlusion_broadphase() -> void:
	_occlusion_cells.clear()
	if _occlusion_volumes.is_empty():
		return
	var grid_scale := Vector3(OCCLUSION_GRID_AXIS, OCCLUSION_GRID_AXIS, OCCLUSION_GRID_AXIS)
	var local_volume := AABB(-_volume.size * 0.5, _volume.size)
	for solid_index in _occlusion_volumes.size():
		var solid: Dictionary = _occlusion_volumes[solid_index]
		var world_box: AABB = solid.world_aabb
		var local_box := AABB(_inverse * world_box.get_endpoint(0), Vector3.ZERO)
		for corner_index in range(1, 8):
			local_box = local_box.expand(_inverse * world_box.get_endpoint(corner_index))
		local_box = local_box.grow(maxf(0.00001, _volume.probe_spacing * 0.00001))
		if not local_box.intersects(local_volume):
			continue
		var clipped_min := local_box.position.max(local_volume.position)
		var clipped_max := local_box.end.min(local_volume.end)
		var cell_min := Vector3i(((clipped_min - local_volume.position) / _volume.size * grid_scale).floor()) \
				.clamp(Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
		var cell_max := Vector3i(((clipped_max - local_volume.position) / _volume.size * grid_scale).floor()) \
				.clamp(Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
		for z in range(cell_min.z, cell_max.z + 1):
			for y in range(cell_min.y, cell_max.y + 1):
				for x in range(cell_min.x, cell_max.x + 1):
					var key := x + y * OCCLUSION_GRID_AXIS + z * OCCLUSION_GRID_AXIS * OCCLUSION_GRID_AXIS
					var solids: Array = _occlusion_cells.get(key, [])
					solids.append(solid_index)
					_occlusion_cells[key] = solids

func _probe_center_is_inside_solid(point: Vector3) -> bool:
	var local := _inverse * point
	var normalized: Vector3 = (local + _volume.size * 0.5) / _volume.size
	var broad_cell := Vector3i((normalized * float(OCCLUSION_GRID_AXIS)).floor()).clamp(
			Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
	var key := broad_cell.x + broad_cell.y * OCCLUSION_GRID_AXIS \
			+ broad_cell.z * OCCLUSION_GRID_AXIS * OCCLUSION_GRID_AXIS
	for solid_index in _occlusion_cells.get(key, []):
		var solid: Dictionary = _occlusion_volumes[solid_index]
		var solid_box: AABB = solid.world_aabb
		if solid_box.grow(maxf(0.000001, solid_box.size.length() * 0.000001)).has_point(point):
			if _point_inside_closed_mesh_state(point, solid_box,
					solid.bvh, solid.faces) != 0:
				return true # Ambiguous containment is unsafe for probe placement.
	return false

func _point_inside_closed_mesh_state(point: Vector3, bounds: AABB, mesh_bvh: TriangleMesh,
		mesh_faces: PackedVector3Array = PackedVector3Array()) -> int:
	var directions := [
		Vector3(1.0, 0.371, 0.529).normalized(),
		Vector3(-0.291, 1.0, 0.417).normalized(),
		Vector3(0.613, -0.337, 1.0).normalized(),
		Vector3(-1.0, 0.743, 0.263).normalized(),
		Vector3(0.229, -1.0, 0.811).normalized(),
	]
	var scale := maxf(bounds.size.length(), 0.000001)
	var ray_length := scale * 1.5 + 0.000001
	var boundary_epsilon := maxf(0.00000001, scale * 0.0000001)
	var max_advance := maxf(_probe_spacing * 0.005, scale * 0.0001)
	var valid_rays := 0
	var inside_votes := 0
	for direction in directions:
		var crossings := _ray_crossing_count(point, direction, ray_length,
				boundary_epsilon, max_advance, mesh_bvh, mesh_faces)
		if crossings < 0:
			continue # A ray landed on the boundary; let the other directions decide.
		valid_rays += 1
		if crossings % 2 == 1:
			inside_votes += 1
	if valid_rays < 3:
		return -1
	if inside_votes >= 3:
		return 1
	if valid_rays - inside_votes >= 3:
		return 0
	return -1

func _ray_crossing_count(origin: Vector3, direction: Vector3, ray_length: float,
		boundary_epsilon: float, max_advance: float, mesh_bvh: TriangleMesh,
		mesh_faces: PackedVector3Array) -> int:
	var ray_end := origin + direction * ray_length
	var ray_start := origin
	var crossings := 0
	for _hit_index in OCCLUSION_MAX_CROSSINGS:
		var hit: Dictionary = mesh_bvh.intersect_segment(ray_start, ray_end)
		if hit.is_empty():
			return crossings
		var hit_position: Vector3 = hit["position"]
		var hit_normal: Vector3 = hit["normal"]
		var hit_face := int(hit.get("face_index", -1))
		var along_ray := (hit_position - origin).dot(direction)
		if along_ray <= boundary_epsilon * 4.0:
			return -1 # The query lies on or too close to this mesh boundary.
		# At large world coordinates the nominal geometric epsilon can be smaller
		# than one representable Vector3 step. Find the smallest bounded advance
		# that changes coordinates and demonstrably passes the hit plane.
		var world_magnitude := maxf(absf(hit_position.x), maxf(absf(hit_position.y),
				absf(hit_position.z)))
		var advance_distance := maxf(boundary_epsilon, world_magnitude * FLOAT32_EPSILON)
		var crossed_hit_plane := false
		while advance_distance <= max_advance:
			var candidate_start := hit_position + direction * advance_distance
			var movement := candidate_start - hit_position
			var plane_step := movement.dot(hit_normal)
			if movement.dot(direction) > 0.0 \
					and absf(plane_step) >= boundary_epsilon \
					and plane_step * hit_normal.dot(direction) > 0.0:
				ray_start = candidate_start
				crossed_hit_plane = true
				break
			advance_distance *= 2.0
		if not crossed_hit_plane:
			return -1
		# Confirm that the tiny interval around the crossing resolves to the same
		# face or an exactly coplanar continuation. A nearby distinct shell makes
		# this ray ambiguous instead of being skipped by the ULP advance.
		var verify_span := maxf(advance_distance, _probe_spacing * 0.0001)
		var reverse_end := hit_position - direction * verify_span
		var reverse_hit := mesh_bvh.intersect_segment(ray_start, reverse_end)
		if reverse_hit.is_empty():
			return -1
		var reverse_face := int(reverse_hit.get("face_index", -1))
		if reverse_face != hit_face and not _mesh_faces_share_coplanar_crossing(
				mesh_faces, hit_face, reverse_face, hit_position):
			return -1
		crossings += 1
		if ray_start.distance_squared_to(ray_end) <= advance_distance * advance_distance:
			return crossings
	return -1 # Avoid pathological work on malformed/intersecting topology.

func _mesh_faces_share_coplanar_crossing(mesh_faces: PackedVector3Array,
		first_face: int, second_face: int, point: Vector3) -> bool:
	if first_face < 0 or second_face < 0 \
			or first_face * 3 + 2 >= mesh_faces.size() \
			or second_face * 3 + 2 >= mesh_faces.size():
		return false
	var first_a: Vector3 = mesh_faces[first_face * 3]
	var first_b: Vector3 = mesh_faces[first_face * 3 + 1]
	var first_c: Vector3 = mesh_faces[first_face * 3 + 2]
	var second_a: Vector3 = mesh_faces[second_face * 3]
	var second_b: Vector3 = mesh_faces[second_face * 3 + 1]
	var second_c: Vector3 = mesh_faces[second_face * 3 + 2]
	var first_normal := (first_c - first_a).cross(first_b - first_a).normalized()
	var second_normal := (second_c - second_a).cross(second_b - second_a).normalized()
	if first_normal.length_squared() < 0.5 or second_normal.length_squared() < 0.5 \
			or absf(first_normal.dot(second_normal)) < 0.9999:
		return false
	# Plane proximity alone is not enough at large world coordinates: a ULP-sized
	# parallel shell can fall inside the floating-point plane tolerance. Continuation
	# between distinct faces requires a real shared geometric edge in the source BVH
	# face data, using the same absolute weld tolerance as occlusion topology.
	var first_vertices := PackedVector3Array([first_a, first_b, first_c])
	var second_vertices := PackedVector3Array([second_a, second_b, second_c])
	var weld_distance_squared := OCCLUSION_WELD_EPSILON * OCCLUSION_WELD_EPSILON
	var shares_edge := false
	for first_i in 3:
		for first_j in range(first_i + 1, 3):
			for second_i in 3:
				for second_j in range(second_i + 1, 3):
					var same_order := first_vertices[first_i].distance_squared_to(
							second_vertices[second_i]) < weld_distance_squared \
							and first_vertices[first_j].distance_squared_to(
							second_vertices[second_j]) < weld_distance_squared
					var reverse_order := first_vertices[first_i].distance_squared_to(
							second_vertices[second_j]) < weld_distance_squared \
							and first_vertices[first_j].distance_squared_to(
							second_vertices[second_i]) < weld_distance_squared
					if same_order or reverse_order:
						shares_edge = true
						break
			if shares_edge:
				break
		if shares_edge:
			break
	if not shares_edge:
		return false
	var magnitude := maxf(absf(point.x), maxf(absf(point.y), absf(point.z)))
	var tolerance := maxf(0.0002, magnitude * FLOAT32_EPSILON * 2.0)
	if tolerance > _probe_spacing * 0.02:
		return false
	return absf(first_normal.dot(second_a - first_a)) <= tolerance \
			and absf(first_normal.dot(point - first_a)) <= tolerance \
			and absf(second_normal.dot(point - second_a)) <= tolerance

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
	return hit

func safe_surface_offset(surface: Vector3, normal: Vector3) -> float:
	return _safe_probe_offset(surface, normal, _preferred_probe_offset(_volume))
