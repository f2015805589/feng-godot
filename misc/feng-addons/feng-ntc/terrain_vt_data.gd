@tool
class_name FengNTCTerrainVTData
extends Resource
## Encoded evaluated VT pages. This resource has no CUDA or SDK runtime dependency.
const Decoder = preload("terrain_vt_decoder.gd")
const Sampling = preload("terrain_vt_sample.gd")
const Validation = preload("gpu_decoder.gd")
@export_storage var source_signature := ""
@export_storage var pages: Dictionary = {}
@export_storage var packages: Array[Dictionary] = []
## Compressed residency retains an independent decoded working set. A cache miss
## samples the original neural payload, without changing virtual mip or resolution.
@export_enum("压缩驻留 + 有界页缓存:0", "完整硬件页缓存:1") var runtime_storage := 0:
	set(value):
		runtime_storage = clampi(value, 0, 1)
		notify_property_list_changed()
		emit_changed()
## Maximum hot decoded pages; the byte budget can reduce this on non-BC devices.
@export_range(0, 1024) var decoded_cache_pages := 384:
	set(value):
		decoded_cache_pages = 0 if value <= 0 else clampi(value, 2, 1024)
		emit_changed()
@export_range(16, 1024) var decoded_cache_mib := 128:
	set(value):
		decoded_cache_mib = clampi(value, 16, 1024)
		emit_changed()
@export_range(1, 16) var max_pages_per_frame := 4:
	set(value):
		max_pages_per_frame = clampi(value, 1, 16)
		emit_changed()
@export_range(1, 8) var gpu_model_cache := 2:
	set(value):
		gpu_model_cache = clampi(value, 1, 8)
		emit_changed()
@export_enum("Auto (BC7 / RGBA16F):-1", "RGBA16F:0", "BC7:1", "BC3:2") var cache_compression := -1:
	set(value):
		cache_compression = clampi(value, -1, 2)
		emit_changed()

func _validate_property(property: Dictionary) -> void:
	if (property.name in ["decoded_cache_pages","decoded_cache_mib"] and runtime_storage!=0) or (property.name=="gpu_model_cache" and runtime_storage!=1):
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR

func create_terrain_decoder() -> Dictionary:
	if source_signature.is_empty() or pages.is_empty() or packages.is_empty(): return {}
	for package: Dictionary in packages:
		var error := Validation.validate(package)
		if not error.is_empty() or package.get("kind", "") != "terrain_vt":
			push_error("NTC VT: " + (error if not error.is_empty() else "Invalid page package"))
			return {}
		for i in range(3):
			var map: Dictionary = package.maps[["albedo_height", "normal_roughness", "params"][i]]
			if int(map.first) != i*4 or int(map.rgb_space) != 0 or int(map.alpha_space) != 0: return {}
	for key: String in pages:
		var entry: Dictionary = pages[key]
		var model := int(entry.get("model", -1))
		var rect: Rect2i = entry.get("rect", Rect2i())
		if model < 0 or model >= packages.size() or rect.size.x < 1 or rect.size.y < 1 or rect.position.x < 0 or rect.position.y < 0: return {}
		if rect.end.x > int(packages[model].width) or rect.end.y > int(packages[model].height): return {}
	var decoder: RefCounted = Sampling.new() if runtime_storage == 0 else Decoder.new()
	decoder.packages = packages
	if runtime_storage == 0:
		decoder.catalog = pages
		decoder.cache_pages = decoded_cache_pages
		decoder.cache_budget_mib = decoded_cache_mib
		decoder.cache_compression = cache_compression
		decoder.max_pages_per_frame = max_pages_per_frame
	if runtime_storage == 1: decoder.cache_limit = gpu_model_cache
	return {"decoder": decoder, "pages": pages.duplicate(true), "source_signature": source_signature, "max_pages_per_frame": max_pages_per_frame, "cache_compression": cache_compression, "direct_sampling": runtime_storage == 0,
		"shader_code": Sampling.shader_code(packages) if runtime_storage == 0 else ""}


func get_storage_info() -> Dictionary:
	var bytes := 0
	for package: Dictionary in packages:
		for field: String in ["constants", "weights", "latents", "layout"]:
			bytes += package[field].size() * (4 if field == "layout" else 1)
	var bc7_bytes := 0
	for page: Dictionary in pages.values():
		var rect: Rect2i = page.rect
		bc7_bytes += ceili(rect.size.x / 4.0) * ceili(rect.size.y / 4.0) * 16 * 3
	return {"pages": pages.size(), "models": packages.size(), "encoded_bytes": bytes, "bc7_page_bytes": bc7_bytes, "cache_compression": cache_compression, "gpu_model_cache": gpu_model_cache, "runtime_storage": runtime_storage, "decoded_cache_pages": decoded_cache_pages, "decoded_cache_mib": decoded_cache_mib}


func compact() -> void:
	var remap := {}
	var used: Array[Dictionary] = []
	for entry: Dictionary in pages.values():
		var old := int(entry.model)
		if not remap.has(old):
			remap[old] = used.size()
			used.append(packages[old])
		entry.model = remap[old]
	packages = used
