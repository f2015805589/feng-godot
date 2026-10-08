@tool
class_name FMagicGIEmitterBakeSet
extends RefCounted
## Ordered static source geometry and CPU next-event sampling for one bake.

const Data = preload("feng_magic_gi_data.gd")
const Binding = preload("feng_magic_gi_emitter_binding.gd")

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

func append_triangle(emitter_index: int, a: Vector3, b: Vector3, c: Vector3,
		normal: Vector3, uv1_a: Vector2, uv1_b: Vector2, uv1_c: Vector2,
		uv2_a: Vector2, uv2_b: Vector2, uv2_c: Vector2) -> void:
	if emitter_index < 0 or emitter_index >= groups.size():
		return
	var source: Dictionary = groups[emitter_index]
	var area := 0.5 * (b - a).cross(c - a).length()
	if area <= 0.0000001:
		return
	source["area"] = float(source["area"]) + area
	var source_triangles: Array = source["triangles"]
	source_triangles.append({
		"a": a, "b": b, "c": c, "normal": normal,
		"cumulative_area": source["area"],
		"uv1_a": uv1_a, "uv1_b": uv1_b, "uv1_c": uv1_c,
		"uv2_a": uv2_a, "uv2_b": uv2_b, "uv2_c": uv2_c
	})

## Uniform-area next-event sample for one fixed emissive surface binding.
## Returns the geometric estimator weight and texture sample, but no live color.
func sample_connection(emitter_index: int, receiver: Vector3, receiver_normal: Vector3,
		u_triangle: float, u_barycentric: float, u_edge: float,
		max_distance: float, surface_offset: float) -> Dictionary:
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
	if distance <= 0.0001 or distance > max_distance:
		return {}
	var direction := delta / distance
	var cosine_receiver := receiver_normal.normalized().dot(direction)
	if cosine_receiver <= 0.0:
		return {}
	var source_normal: Vector3 = chosen["normal"]
	var cull_mode := int(source["cull_mode"])
	if cull_mode == BaseMaterial3D.CULL_FRONT:
		source_normal = -source_normal
	var cosine_source := source_normal.dot(-direction)
	if cull_mode == BaseMaterial3D.CULL_DISABLED:
		cosine_source = absf(cosine_source)
	if cosine_source <= 0.0:
		return {}
	var uv1: Vector2 = chosen["uv1_a"] * w0 + chosen["uv1_b"] * w1 + chosen["uv1_c"] * w2
	var uv2: Vector2 = chosen["uv2_a"] * w0 + chosen["uv2_b"] * w1 + chosen["uv2_c"] * w2
	var texture_rgb := _sample_texture(source, uv1, uv2)
	var epsilon := maxf(0.001, surface_offset)
	var ray_origin: Vector3 = receiver + receiver_normal.normalized() * epsilon
	var shadow_delta := target - ray_origin
	var shadow_distance := shadow_delta.length()
	var endpoint_epsilon := maxf(0.0001, shadow_distance * 0.00001)
	var ray_distance := shadow_distance - endpoint_epsilon
	if ray_distance <= 0.0:
		return {}
	var estimator_weight := total_area * cosine_receiver * cosine_source / (PI * distance * distance)
	if not is_finite(estimator_weight) or estimator_weight <= 0.0:
		return {}
	return {
		"direction": shadow_delta / shadow_distance,
		"distance": distance,
		"ray_origin": ray_origin,
		"ray_distance": ray_distance,
		"weight": estimator_weight,
		"texture_rgb": texture_rgb
	}

func _sample_texture(source: Dictionary, uv1: Vector2, uv2: Vector2) -> Vector3:
	var image: Image = source["texture_image"]
	if image == null:
		return Vector3.ZERO # Godot's StandardMaterial emission texture defaults to black.
	var uv := uv2 if bool(source["use_uv2"]) else uv1
	var scale: Vector3 = source["uv_scale"]
	var offset: Vector3 = source["uv_offset"]
	uv = uv * Vector2(scale.x, scale.y) + Vector2(offset.x, offset.y)
	var repeat := bool(source["repeat"])
	if repeat:
		uv = Vector2(fposmod(uv.x, 1.0), fposmod(uv.y, 1.0))
	else:
		uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Vector3.ZERO
	var nearest := int(source["filter"]) in [BaseMaterial3D.TEXTURE_FILTER_NEAREST,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC]
	if nearest:
		var px := int(floor(uv.x * width))
		var py := int(floor(uv.y * height))
		return _emission_pixel_linear(image, _wrap_texel(px, width, repeat), _wrap_texel(py, height, repeat))
	var fx := uv.x * width - 0.5
	var fy := uv.y * height - 0.5
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx: float = fx - floor(fx)
	var ty: float = fy - floor(fy)
	var c00 := _emission_pixel_linear(image, _wrap_texel(x0, width, repeat), _wrap_texel(y0, height, repeat))
	var c10 := _emission_pixel_linear(image, _wrap_texel(x0 + 1, width, repeat), _wrap_texel(y0, height, repeat))
	var c01 := _emission_pixel_linear(image, _wrap_texel(x0, width, repeat), _wrap_texel(y0 + 1, height, repeat))
	var c11 := _emission_pixel_linear(image, _wrap_texel(x0 + 1, width, repeat), _wrap_texel(y0 + 1, height, repeat))
	return c00.lerp(c10, tx).lerp(c01.lerp(c11, tx), ty)

static func _wrap_texel(value: int, extent: int, repeat: bool) -> int:
	return posmod(value, extent) if repeat else clampi(value, 0, extent - 1)

static func _emission_pixel_linear(image: Image, x: int, y: int) -> Vector3:
	var color := image.get_pixel(x, y)
	var format := image.get_format()
	var linear_format := format in [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF,
			Image.FORMAT_RGBAF, Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH,
			Image.FORMAT_RGBAH, Image.FORMAT_RGBE9995, Image.FORMAT_BPTC_RGBF,
			Image.FORMAT_BPTC_RGBFU, Image.FORMAT_ASTC_4x4_HDR, Image.FORMAT_ASTC_8x8_HDR]
	if not linear_format:
		color = color.srgb_to_linear()
	var linear_rgb := Vector3(color.r, color.g, color.b)
	return linear_rgb.max(Vector3.ZERO) if linear_rgb.is_finite() else Vector3.ZERO
