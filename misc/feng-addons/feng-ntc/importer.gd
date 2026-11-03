@tool
extends EditorImportPlugin

const TextureSet = preload("texture_set.gd")

func _get_importer_name() -> String: return "feng.ntc.texture_set"
func _get_visible_name() -> String: return "Feng NTC 材质纹理组"
func _get_recognized_extensions() -> PackedStringArray: return PackedStringArray(["ntc"])
func _get_save_extension() -> String: return "res"
func _get_resource_type() -> String: return "Resource"
func _get_preset_count() -> int: return 0
func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]: return []
func _get_priority() -> float: return 1.0
func _get_import_order() -> int: return 0

func _import(source_file: String, save_path: String, _options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var data := FileAccess.get_file_as_bytes(source_file)
	if data.is_empty(): return ERR_FILE_CORRUPT
	var asset := TextureSet.new()
	asset.payload = data
	# Metadata extraction is CPU-only; game exports need neither the native SDK nor CUDA.
	if not asset.ensure_portable():
		push_error(asset.last_error)
		return ERR_FILE_CORRUPT
	return ResourceSaver.save(asset, save_path + ".res", ResourceSaver.FLAG_COMPRESS)
