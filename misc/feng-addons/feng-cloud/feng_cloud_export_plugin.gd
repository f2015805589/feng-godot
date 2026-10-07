@tool
extends EditorExportPlugin

const SHADER_ROOT := "res://addons/feng-cloud/shaders"
const ENTRYPOINTS := [
	"cloud_ao_filter.glslinc",
	"cloud_composite.glslinc",
	"cloud_shadow_filter.glslinc",
	"cloud_sky_ambient.glslinc",
	"cloud_ao.glslinc",
	"cloud_reconstruct.glslinc",
	"cloud_trace.glslinc",
	"cloud_shadow.glslinc",
]
const CloudMaterialScript = preload("feng_cloud_material.gd")
const CloudRuntime = preload("feng_cloud_runtime.gd")

var _include_pattern := RegEx.new()
var _packaged_paths: Dictionary = {}


func _init() -> void:
	_include_pattern.compile("^\\s*#include\\s+\"([^\"]+)\"")


func _get_name() -> String:
	return "FengCloudRuntimeSources"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_packaged_paths.clear()
	for filename in ENTRYPOINTS:
		_add_shader_tree(SHADER_ROOT.path_join(filename), 0)
	_add_shader_tree(CloudMaterialScript.DEFAULT_UE58_KERNEL_SOURCE_PATH, 0)
	for path in [
		CloudRuntime.BLUE_NOISE_TEXTURE_PATH,
		CloudMaterialScript.DEFAULT_MATERIAL_RESOURCE_PATH,
		CloudMaterialScript.DEFAULT_SHAPE_DENSITY_TEXTURE_PATH,
		CloudMaterialScript.DEFAULT_LAYOUT_PATTERN_TEXTURE_PATH,
		CloudMaterialScript.DEFAULT_LAYOUT_CLOUD_MASK_TEXTURE_PATH,
		CloudMaterialScript.DEFAULT_LAYOUT_HEIGHT_PROFILE_TEXTURE_PATH,
	]:
		_add_raw_file(path)


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if _packaged_paths.has(path.simplify_path()):
		skip()


func _add_shader_tree(path: String, depth: int) -> bool:
	var normalized_path := path.simplify_path()
	if _packaged_paths.has(normalized_path):
		return true
	if depth > 32:
		push_error("Feng Cloud export include depth exceeded at %s." % normalized_path)
		return false
	if not FileAccess.file_exists(normalized_path):
		push_error("Feng Cloud export source is missing: %s." % normalized_path)
		return false

	var source_text := FileAccess.get_file_as_string(normalized_path)
	if source_text.is_empty():
		push_error("Feng Cloud export source is empty or unreadable: %s." % normalized_path)
		return false
	if not _add_raw_file(normalized_path):
		return false

	for line in source_text.split("\n"):
		var include_match := _include_pattern.search(line)
		if include_match == null:
			continue
		var include_path := normalized_path.get_base_dir().path_join(include_match.get_string(1)).simplify_path()
		if not _add_shader_tree(include_path, depth + 1):
			return false
	return true


func _add_raw_file(path: String) -> bool:
	var normalized_path := path.simplify_path()
	if _packaged_paths.has(normalized_path):
		return true
	if not FileAccess.file_exists(normalized_path):
		push_error("Feng Cloud export file is missing: %s." % normalized_path)
		return false
	var bytes := FileAccess.get_file_as_bytes(normalized_path)
	if bytes.is_empty():
		push_error("Feng Cloud export file is empty or unreadable: %s." % normalized_path)
		return false
	add_file(normalized_path, bytes, false)
	_packaged_paths[normalized_path] = true
	return true
