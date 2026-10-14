@tool
class_name FMagicGIEmitterBakeSet
extends RefCounted
## Ordered static source geometry and CPU next-event sampling for one bake.

const Data = preload("feng_magic_gi_data.gd")
const TextureSampler = preload("feng_magic_gi_texture_sampler.gd")
const Binding = preload("feng_magic_gi_emitter_binding.gd")
const NATIVE_TRIANGLE_GRID := 0.0001

var keys := PackedStringArray()
var static_signatures := PackedInt64Array()
var groups: Array[Dictionary] = []
var error_message := ""

func clear() -> void:
	keys.clear()
	static_signatures.clear()
	groups.clear()
	error_message = ""

func register_surface(root: Node, node: MeshInstance3D, surface: int,
		material: BaseMaterial3D, uv1: PackedVector2Array, uv2: PackedVector2Array,
		vertex_count: int) -> int:
	var key := Binding.make_key(root, node, surface)
	var existing := keys.find(key)
	if existing >= 0:
		return existing
	if keys.size() >= Data.MAX_EMITTERS:
		error_message = "PRT supports at most %d emissive surface bindings per volume." % Data.MAX_EMITTERS
		return -1
	var texture: Texture2D = material.emission_texture
	var use_uv2: bool = material.emission_on_uv2
	var selected_uv: PackedVector2Array = uv2 if use_uv2 else uv1
	var texture_image: Image
	if texture != null:
		if (material.uv2_triplanar if use_uv2 else material.uv1_triplanar):
			error_message = "Textured emissive triplanar mapping is not supported; use UV0/UV2 or disable the emission texture."
			return -1
		if vertex_count <= 0 or selected_uv.size() != vertex_count:
			error_message = "Textured emissive surface is missing the selected UV0/UV2 channel."
			return -1
		texture_image = texture.get_image()
		if texture_image == null or texture_image.is_empty():
			error_message = "The emissive Texture2D has no CPU-readable image; static emission texture baking was refused."
			return -1
		if texture_image.is_compressed() and texture_image.decompress() != OK:
			error_message = "The emissive texture image could not be decompressed for CPU area sampling."
			return -1
	var signature := Binding.static_signature(node, surface, material)
	var index := keys.size()
	keys.append(key)
	static_signatures.append(signature)
	groups.append({
		"texture_image": texture_image,
		"use_uv2": use_uv2,
		"uv_scale": material.uv2_scale if use_uv2 else material.uv1_scale,
		"uv_offset": material.uv2_offset if use_uv2 else material.uv1_offset,
		"repeat": material.texture_repeat,
		"filter": material.texture_filter,
		"cull_mode": material.cull_mode,
		"area": 0.0,
		"triangles": []
	})
	return index

static func canonical_vertex(point: Vector3) -> Vector3:
	return point.snappedf(NATIVE_TRIANGLE_GRID)

func append_triangle(emitter_index: int, a: Vector3, b: Vector3, c: Vector3,
		uv1_a: Vector2, uv1_b: Vector2, uv1_c: Vector2,
		uv2_a: Vector2, uv2_b: Vector2, uv2_c: Vector2,
		native_face_index: int) -> bool:
	if emitter_index < 0 or emitter_index >= groups.size():
		return false
	var source: Dictionary = groups[emitter_index]
	# TriangleMesh canonicalizes each input vertex to this grid before building
	# its BVH. Sample the identical geometry so area PDFs and first-hit endpoints
	# describe the same surface, including transformed PrimitiveMesh vertices.
	var canonical_a := canonical_vertex(a)
	var canonical_b := canonical_vertex(b)
	var canonical_c := canonical_vertex(c)
	var area := 0.5 * (canonical_b - canonical_a).cross(canonical_c - canonical_a).length()
	if area <= 0.0000001:
		return false
	var normal := (canonical_c - canonical_a).cross(canonical_b - canonical_a).normalized()
	source["area"] = float(source["area"]) + area
	var source_triangles: Array = source["triangles"]
	source_triangles.append({
		"a": canonical_a, "b": canonical_b, "c": canonical_c, "normal": normal,
		"native_face_index": native_face_index,
		"cumulative_area": source["area"],
		"uv1_a": uv1_a, "uv1_b": uv1_b, "uv1_c": uv1_c,
		"uv2_a": uv2_a, "uv2_b": uv2_b, "uv2_c": uv2_c
	})
	return true

func solid_angle_pdf(emitter_index: int, receiver: Vector3, target: Vector3,
		geometric_normal: Vector3) -> float:
	if emitter_index < 0 or emitter_index >= groups.size():
		return 0.0
	var source: Dictionary = groups[emitter_index]
	var area := float(source["area"])
	if not is_finite(area) or area <= 0.0000001:
		return 0.0
	var delta := target - receiver
	var distance_squared := delta.length_squared()
	if not is_finite(distance_squared) or distance_squared <= 0.000000000001:
		return 0.0
	var direction := delta / sqrt(distance_squared)
	var source_normal := geometric_normal.normalized()
	var cull_mode := int(source["cull_mode"])
	if cull_mode == BaseMaterial3D.CULL_FRONT:
		source_normal = -source_normal
	var cosine_source := source_normal.dot(-direction)
	if cull_mode == BaseMaterial3D.CULL_DISABLED:
		cosine_source = absf(cosine_source)
	if cosine_source <= 0.0:
		return 0.0
	var pdf := distance_squared / (area * cosine_source)
	return pdf if is_finite(pdf) and pdf > 0.0 else 0.0

static func power_heuristic(pdf_a: float, pdf_b: float) -> float:
	if not is_finite(pdf_a) or pdf_a <= 0.0:
		return 0.0
	if not is_finite(pdf_b) or pdf_b <= 0.0:
		return 1.0
	if pdf_a >= pdf_b:
		var ratio := pdf_b / pdf_a
		return 1.0 / (1.0 + ratio * ratio)
	var inverse_ratio := pdf_a / pdf_b
	return inverse_ratio * inverse_ratio / (1.0 + inverse_ratio * inverse_ratio)

## Uniform-area next-event sample for one fixed emissive surface binding.
## Returns the geometric estimator weight and texture sample, but no live color.
func sample_connection(emitter_index: int, receiver: Vector3, receiver_normal: Vector3,
		u_triangle: float, u_barycentric: float, u_edge: float,
		max_distance: float, spherical_receiver := false,
		defer_texture_sampling := false) -> Dictionary:
	if emitter_index < 0 or emitter_index >= groups.size():
		return {}
	var source: Dictionary = groups[emitter_index]
	var total_area := float(source["area"])
	if total_area <= 0.0000001:
		return {}
	var pick := clampf(u_triangle, 0.0, 0.99999994) * total_area
	var triangles: Array = source["triangles"]
	var low := 0
	var high := triangles.size() - 1
	while low < high:
		var middle := floori(float(low + high) * 0.5)
		var middle_triangle: Dictionary = triangles[middle]
		if pick < float(middle_triangle["cumulative_area"]):
			high = middle
		else:
			low = middle + 1
	var chosen: Dictionary = triangles[low]
	var root := sqrt(clampf(u_barycentric, 0.0, 0.99999994))
	var v := clampf(u_edge, 0.0, 0.99999994)
	var w0 := 1.0 - root
	var w1 := root * (1.0 - v)
	var w2 := root * v
	var target: Vector3 = chosen["a"] * w0 + chosen["b"] * w1 + chosen["c"] * w2
	var delta := target - receiver
	var distance := delta.length()
	if not is_finite(distance) or distance <= 0.0000001 or distance > max_distance:
		return {}
	var sample_direction := delta / distance
	var cosine_receiver := 1.0 if spherical_receiver else receiver_normal.normalized().dot(sample_direction)
	if cosine_receiver <= 0.0:
		return {}
	var source_normal: Vector3 = chosen["normal"]
	var cull_mode := int(source["cull_mode"])
	if cull_mode == BaseMaterial3D.CULL_FRONT:
		source_normal = -source_normal
	var cosine_source := source_normal.dot(-sample_direction)
	if cull_mode == BaseMaterial3D.CULL_DISABLED:
		cosine_source = absf(cosine_source)
	if cosine_source <= 0.0:
		return {}
	# Visibility uses the exact same physical line and origin as the MIS endpoint.
	# This small tolerance is for selected-point and shared-edge identity checks;
	# it does not guarantee that every bounded TriangleMesh segment reaches its
	# endpoint. Emitter NEE uses a native first-hit ray retry only when that
	# bounded segment has no hit, then still checks the selected source face.
	var endpoint_tolerance := maxf(ray_epsilon(receiver), ray_epsilon(target)) * 8.0
	var visibility_distance := distance + endpoint_tolerance
	var compatible_hit_faces := _compatible_boundary_faces(triangles, chosen,
			target, endpoint_tolerance)
	var estimator_weight := total_area * cosine_receiver * cosine_source / (distance * distance)
	if not spherical_receiver:
		estimator_weight /= PI
	if not is_finite(estimator_weight) or estimator_weight <= 0.0:
		return {}
	var texture_rgb := Vector3.ZERO
	var has_texture_image: bool = source.get("texture_image") != null
	var texture_uv1 := Vector2.ZERO
	var texture_uv2 := Vector2.ZERO
	if has_texture_image:
		texture_uv1 = chosen["uv1_a"] * w0 + chosen["uv1_b"] * w1 + chosen["uv1_c"] * w2
		texture_uv2 = chosen["uv2_a"] * w0 + chosen["uv2_b"] * w1 + chosen["uv2_c"] * w2
		if not defer_texture_sampling:
			texture_rgb = _sample_texture(source, texture_uv1, texture_uv2)
	var light_pdf := distance * distance / (total_area * cosine_source)
	if not is_finite(light_pdf) or light_pdf <= 0.0:
		return {}
	var result := {
		"sample_direction": sample_direction,
		"shadow_direction": sample_direction,
		"shadow_origin": receiver,
		"sample_position": target,
		"sample_face_index": int(chosen.get("native_face_index", -1)),
		"compatible_hit_faces": compatible_hit_faces,
		"distance": distance,
		"visibility_distance": visibility_distance,
		"endpoint_tolerance": endpoint_tolerance,
		"light_pdf": light_pdf,
		"weight": estimator_weight,
		"texture_rgb": texture_rgb
	}
	if defer_texture_sampling and has_texture_image:
		# Texture color affects radiance, never the area or solid-angle PDF. The
		# baker fills this only after visibility confirms the selected first hit.
		result["texture_uv1"] = texture_uv1
		result["texture_uv2"] = texture_uv2
	return result

static func ray_epsilon(point: Vector3) -> float:
	var scale := maxf(absf(point.x), maxf(absf(point.y), absf(point.z)))
	return maxf(0.000000001, scale * 0.0000001)

static func _compatible_boundary_faces(triangles: Array, chosen: Dictionary,
		target: Vector3, tolerance: float) -> PackedInt32Array:
	var compatible := PackedInt32Array()
	var chosen_face := int(chosen.get("native_face_index", -1))
	if chosen_face >= 0:
		compatible.append(chosen_face)
	var a: Vector3 = chosen["a"]
	var b: Vector3 = chosen["b"]
	var c: Vector3 = chosen["c"]
	var near_vertices: Array[Vector3] = []
	for vertex in [a, b, c]:
		if target.distance_to(vertex) <= tolerance:
			near_vertices.append(vertex)
	var near_edges: Array = []
	for edge in [[a, b], [b, c], [c, a]]:
		if _point_segment_distance(target, edge[0], edge[1]) <= tolerance:
			near_edges.append(edge)
	if near_vertices.is_empty() and near_edges.is_empty():
		return compatible
	for triangle in triangles:
		var candidate_face := int(triangle.get("native_face_index", -1))
		if candidate_face < 0 or candidate_face == chosen_face:
			continue
		var candidate_vertices: Array[Vector3] = [triangle["a"], triangle["b"], triangle["c"]]
		var shares_boundary := false
		for vertex in near_vertices:
			if candidate_vertices.has(vertex):
				shares_boundary = true
				break
		if not shares_boundary:
			for edge in near_edges:
				if candidate_vertices.has(edge[0]) and candidate_vertices.has(edge[1]):
					shares_boundary = true
					break
		if shares_boundary and not compatible.has(candidate_face):
			compatible.append(candidate_face)
	return compatible

static func _point_segment_distance(point: Vector3, a: Vector3, b: Vector3) -> float:
	var edge := b - a
	var length_squared := edge.length_squared()
	if length_squared <= 0.000000000001:
		return point.distance_to(a)
	var fraction := clampf((point - a).dot(edge) / length_squared, 0.0, 1.0)
	return point.distance_to(a + edge * fraction)

func _sample_texture(source: Dictionary, uv1: Vector2, uv2: Vector2) -> Vector3:
	var image: Image = source["texture_image"]
	if image == null:
		return Vector3.ZERO # Godot's StandardMaterial emission texture defaults to black.
	var uv := uv2 if bool(source["use_uv2"]) else uv1
	var scale: Vector3 = source["uv_scale"]
	var offset: Vector3 = source["uv_offset"]
	uv = uv * Vector2(scale.x, scale.y) + Vector2(offset.x, offset.y)
	return TextureSampler.sample(image, uv, bool(source["repeat"]), int(source["filter"]))

func sample_texture(emitter_index: int, uv1: Vector2, uv2: Vector2) -> Vector3:
	if emitter_index < 0 or emitter_index >= groups.size():
		return Vector3.ZERO
	return _sample_texture(groups[emitter_index], uv1, uv2)
