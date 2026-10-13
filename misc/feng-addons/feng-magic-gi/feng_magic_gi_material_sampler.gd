@tool
extends RefCounted
## Bake-local material snapshots. Texture decompression is paid once per material.

const TextureSampler = preload("feng_magic_gi_texture_sampler.gd")
var records: Array[Dictionary] = []
var _cache: Dictionary = {}
var error_message := ""

func register(material: BaseMaterial3D, has_uv: bool) -> int:
	if material.albedo_texture == null:
		return -1
	if material.uv1_triplanar or not has_uv:
		error_message = "Textured albedo requires UV0 for static transport baking."
		return -1
	if _cache.has(material):
		return _cache[material]
	var image := material.albedo_texture.get_image()
	if image == null or image.is_empty() or (image.is_compressed() and image.decompress() != OK):
		error_message = "The albedo texture could not be read for static transport baking."
		return -1
	var index := records.size()
	records.append({"image": image, "scale": material.uv1_scale, "offset": material.uv1_offset,
		"repeat": material.texture_repeat, "filter": material.texture_filter})
	_cache[material] = index
	return index

func sample(index: int, uv: Vector2) -> Vector3:
	if index < 0:
		return Vector3.ONE
	var record: Dictionary = records[index]
	var scale: Vector3 = record.scale
	var offset: Vector3 = record.offset
	return TextureSampler.sample(record.image,
		uv * Vector2(scale.x, scale.y) + Vector2(offset.x, offset.y), record.repeat, record.filter)

func fingerprint() -> int:
	var values: Array = []
	for record in records:
		# Changes to texels, UV transforms or filtering invalidate persisted transport.
		values.append([record.image.get_size(), record.image.get_format(), record.image.get_data(),
			record.scale, record.offset, record.repeat, record.filter])
	return hash(values)
