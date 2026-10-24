@tool
extends RefCounted
## Immutable CPU tracing snapshot. Workers never access scene Nodes or GPU state.

const EmitterBakeSet = preload("feng_magic_gi_emitter_bake_set.gd")

var bvh: TriangleMesh
var faces := PackedVector3Array()
var reflectance := PackedVector3Array()
var face_materials := PackedInt32Array()
var face_uv := PackedVector2Array()
var face_uv2 := PackedVector2Array()
var face_emitter_indices := PackedInt32Array()
var material_sampler: RefCounted
var emitters: RefCounted
var _inverse := Transform3D.IDENTITY
var half_size := Vector3.ONE
var spacing := 1.0
var preferred := 0.03

func initialize(geometry: RefCounted, volume: Node3D, offset: float) -> void:
	initialize_snapshot(geometry, volume.global_transform.affine_inverse(),
			volume.size, volume.probe_spacing, offset)

## Initializes from captured value data; safe to call after scene/resource capture
## when geometry work is dispatched to a worker thread.
func initialize_snapshot(geometry: RefCounted, inverse: Transform3D,
		volume_size: Vector3, probe_spacing: float, offset: float,
		cancellation: Object = null) -> bool:
	bvh = geometry.bvh
	faces = PackedVector3Array()
	faces.resize(geometry.faces.size())
	for vertex in geometry.faces.size():
		if vertex % 384 == 0 and _cancelled(cancellation):
			faces.clear()
			return false
		faces[vertex] = EmitterBakeSet.canonical_vertex(geometry.faces[vertex])
	if _cancelled(cancellation):
		faces.clear()
		return false
	reflectance = geometry.reflectance
	face_materials = geometry.face_materials
	face_uv = geometry.face_uv
	face_uv2 = geometry.face_uv2
	face_emitter_indices = geometry.face_emitter_indices
	material_sampler = geometry.material_sampler
	emitters = geometry.emitters
	_inverse = inverse
	half_size = volume_size * 0.5
	spacing = probe_spacing
	preferred = offset
	return true

func _cancelled(cancellation: Object) -> bool:
	return cancellation != null and is_instance_valid(cancellation) \
			and bool(cancellation.call("is_cancelled"))

func trace(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	if bvh == null:
		return {}
	var hit := bvh.intersect_segment(origin, origin + direction * max_distance)
	return _decorate_hit(hit, direction.normalized())

## Geometry-only variant for placement feature queries. It uses the same bounded
## BVH segment and canonical face-forward normal as trace(), without sampling
## receiver albedo or emitter texture metadata that the feature test never reads.
func trace_geometry(origin: Vector3, direction: Vector3,
		max_distance: float) -> Dictionary:
	if bvh == null:
		return {}
	var hit := bvh.intersect_segment(origin, origin + direction * max_distance)
	return _decorate_geometry_hit(hit, direction.normalized())

## Continue from the exact path vertex along its sampled direction. The tiny
## advance is collinear, so the reconstructed emitter hit stays on that path;
## MIS distance/PDF are always measured back to the unshifted vertex.
func trace_path(origin: Vector3, direction: Vector3, max_distance: float,
		start_face_index := -1) -> Dictionary:
	if bvh == null:
		return {}
	var normalized_direction := direction.normalized()
	var hit := _trace_first_path_hit(origin, normalized_direction, max_distance, start_face_index)
	return _decorate_hit(hit, normalized_direction)

## Return the same bounded physical first hit used by path tracing, before any
## shading/material data is sampled. Callers decide how much hit metadata they
## need; the BSDF path still decorates the result below.
func _trace_first_path_hit(origin: Vector3, normalized_direction: Vector3,
		max_distance: float, start_face_index: int) -> Dictionary:
	if bvh == null:
		return {}
	var hit := bvh.intersect_segment(origin, origin + normalized_direction * max_distance)
	if hit.is_empty():
		return {}
	var hit_face := int(hit["face_index"])
	var start_step := EmitterBakeSet.ray_epsilon(origin)
	if hit_face == start_face_index and hit.position.distance_to(origin) <= start_step * 2.0:
		# Drop only a t≈0 intersection with the surface we just left. Starting
		# a full sampling epsilon ahead would leap over a thin nearby blocker.
		if max_distance <= start_step:
			return {}
		hit = bvh.intersect_segment(origin + normalized_direction * start_step,
				origin + normalized_direction * max_distance)
		if hit.is_empty():
			return {}
	return hit

## Area-NEE visibility first uses the bounded segment. If its endpoint misses
## numerically, retry the same physical ray with TriangleMesh's native ray
## query. The caller still has to match the selected source face; any nearer
## blocker or unrelated face is returned as the first hit and remains opaque.
func trace_emitter_connection(origin: Vector3, direction: Vector3,
		max_distance: float, start_face_index := -1) -> Dictionary:
	if bvh == null or direction.length_squared() <= 0.000000000001:
		return {}
	var normalized_direction := direction.normalized()
	# Keep trace_path's second normalization exactly: historically this method
	# normalized once above and trace_path normalized that vector again for its
	# bounded segment. The native-ray fallback below continues to use the first.
	var path_direction := normalized_direction.normalized()
	var hit := _trace_first_path_hit(origin, path_direction, max_distance, start_face_index)
	if not hit.is_empty():
		return _emitter_visibility_hit(hit, path_direction)
	var ray_hit: Dictionary = bvh.intersect_ray(origin, normalized_direction)
	if ray_hit.is_empty():
		return {}
	var ray_face := int(ray_hit.get("face_index", -1))
	var start_step := EmitterBakeSet.ray_epsilon(origin)
	if ray_face == start_face_index \
			and ray_hit.position.distance_to(origin) <= start_step * 2.0:
		# Match trace_path's existing t≈0 start-face skip. The advance stays
		# collinear and is kept far below ordinary sub-millimeter blockers.
		ray_hit = bvh.intersect_ray(origin + normalized_direction * start_step,
				normalized_direction)
		if ray_hit.is_empty():
			return {}
	return _emitter_visibility_hit(ray_hit, normalized_direction)

## Test an infinitely distant directional source against the captured static BVH.
## Only a t≈0 hit on the face we just left is ignored; other triangles, however
## close or thin, remain blockers.
func trace_directional_visibility(origin: Vector3, direction: Vector3,
		start_face_index := -1) -> bool:
	if bvh == null or direction.length_squared() <= 0.000000000001:
		return false
	var normalized_direction := direction.normalized()
	var hit: Dictionary = bvh.intersect_ray(origin, normalized_direction)
	if hit.is_empty():
		return true
	var start_step := EmitterBakeSet.ray_epsilon(origin)
	if int(hit.get("face_index", -1)) == start_face_index \
			and hit.position.distance_to(origin) <= start_step * 2.0:
		hit = bvh.intersect_ray(origin + normalized_direction * start_step,
				normalized_direction)
	return hit.is_empty()

func _emitter_visibility_hit(hit: Dictionary, normalized_direction: Vector3) -> Dictionary:
	if hit.is_empty():
		return {}
	var face_index := int(hit["face_index"])
	if face_index < 0 or face_index >= face_emitter_indices.size():
		return hit
	var emitter_index := int(face_emitter_indices[face_index])
	if emitter_index < 0:
		return hit
	var geometric_normal := _canonical_face_normal(face_index)
	if _visible_emitter_index(face_index, normalized_direction, geometric_normal) >= 0:
		hit["emitter_index"] = emitter_index
	return hit

func _decorate_hit(hit: Dictionary, normalized_direction: Vector3) -> Dictionary:
	if hit.is_empty():
		return hit
	var face_index := int(hit["face_index"])
	var geometric_normal := _canonical_face_normal(face_index)
	if geometric_normal.length_squared() > 0.5:
		hit["normal"] = _face_forward_normal(geometric_normal, normalized_direction)
	hit["albedo"] = reflectance[face_index]
	var material_index := int(face_materials[face_index]) if face_materials.size() > face_index else -1
	var emitter_index := int(face_emitter_indices[face_index]) if face_emitter_indices.size() > face_index else -1
	if material_index < 0 and emitter_index < 0:
		return hit
	var uv_data := _hit_uvs(face_index, hit.position)
	var uv1: Vector2 = uv_data.uv1
	var uv2: Vector2 = uv_data.uv2
	if material_index >= 0:
		hit["albedo"] *= material_sampler.sample(material_index, uv1)
	if emitter_index >= 0:
		if _visible_emitter_index(face_index, normalized_direction, geometric_normal) >= 0:
			hit["emitter_index"] = emitter_index
			hit["emission_normal"] = geometric_normal
			hit["emission_texture_rgb"] = emitters.sample_texture(emitter_index, uv1, uv2)
	return hit

func _decorate_geometry_hit(hit: Dictionary,
		normalized_direction: Vector3) -> Dictionary:
	if hit.is_empty():
		return hit
	var face_index := int(hit["face_index"])
	var geometric_normal := _canonical_face_normal(face_index)
	if geometric_normal.length_squared() > 0.5:
		hit["normal"] = _face_forward_normal(geometric_normal, normalized_direction)
	return hit

static func _face_forward_normal(geometric_normal: Vector3,
		normalized_direction: Vector3) -> Vector3:
	# TriangleMesh returns a face-forward normal. Rebuild it from the canonical
	# face so placement and shading agree with the snapped intersection geometry.
	return -geometric_normal if geometric_normal.dot(normalized_direction) > 0.0 \
			else geometric_normal

func _canonical_face_normal(face_index: int) -> Vector3:
	var base := face_index * 3
	return (faces[base + 2] - faces[base]).cross(
			faces[base + 1] - faces[base]).normalized()

func _visible_emitter_index(face_index: int, normalized_direction: Vector3,
		geometric_normal: Vector3) -> int:
	if face_index < 0 or face_index >= face_emitter_indices.size():
		return -1
	var emitter_index := int(face_emitter_indices[face_index])
	if emitter_index < 0 or emitter_index >= emitters.groups.size():
		return -1
	var source: Dictionary = emitters.groups[emitter_index]
	var emission_normal := geometric_normal
	var cull_mode := int(source["cull_mode"])
	if cull_mode == BaseMaterial3D.CULL_FRONT:
		emission_normal = -emission_normal
	var cosine_source := emission_normal.dot(-normalized_direction)
	if cull_mode == BaseMaterial3D.CULL_DISABLED:
		cosine_source = absf(cosine_source)
	return emitter_index if cosine_source > 0.0 else -1

func _hit_uvs(face_index: int, point: Vector3) -> Dictionary:
	var base := face_index * 3
	var edge_b := faces[base + 1] - faces[base]
	var edge_c := faces[base + 2] - faces[base]
	var delta := point - faces[base]
	var bb := edge_b.dot(edge_b)
	var bc := edge_b.dot(edge_c)
	var cc := edge_c.dot(edge_c)
	var denominator := bb * cc - bc * bc
	if denominator <= 0.000000000001:
		return {"uv1": Vector2.ZERO, "uv2": Vector2.ZERO}
	var b := (cc * delta.dot(edge_b) - bc * delta.dot(edge_c)) / denominator
	var c := (bb * delta.dot(edge_c) - bc * delta.dot(edge_b)) / denominator
	var a := 1.0 - b - c
	return {
		"uv1": face_uv[base] * a + face_uv[base + 1] * b + face_uv[base + 2] * c,
		"uv2": face_uv2[base] * a + face_uv2[base + 1] * b + face_uv2[base + 2] * c
	}

func safe_surface_offset(surface: Vector3, normal: Vector3) -> float:
	if normal.length_squared() < 0.5 or not is_finite(preferred) or preferred <= 0.0:
		return 0.0
	var safe_offset := preferred
	var ray_epsilon := maxf(0.00001, minf(preferred * 0.1,
			spacing * 0.0005))
	if bvh != null:
		var hit := bvh.intersect_segment(surface + normal * ray_epsilon,
				surface + normal * preferred)
		if not hit.is_empty():
			var hit_distance: float = (hit.position - surface).dot(normal)
			safe_offset = minf(safe_offset, (hit_distance - ray_epsilon) * 0.45)
	# Keep the center inside the oriented volume even when the surface lies on a
	# boundary. The inverse-basis direction accounts for nonuniform volume scale.
	var local_surface := _inverse * surface
	var local_direction := _inverse.basis * normal
	var local_boundary_epsilon := maxf(0.00001, spacing * 0.00001)
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
			spacing * 0.002)
	return safe_offset if safe_offset >= minimum_clearance else 0.0

