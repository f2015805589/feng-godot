@tool
extends EditorExportPlugin

func _get_name() -> String: return "FengNTCPortableRuntime"

func _export_begin(_features: PackedStringArray,_debug: bool,_path: String,_flags: int) -> void:
	# The decoder compiles this source on the active RenderingDevice backend.
	for source: String in ["decode.glsl", "terrain_sample.gdshaderinc"]:
		var path := "res://addons/feng-ntc/shaders/"+source
		add_file(path,FileAccess.get_file_as_bytes(path),false)
	for license_name: String in ["NVIDIA-LICENSE.txt","NVIDIA-ThirdPartyLicenses.txt","CVTT.txt","godot-cpp.txt"]:
		var license_path := "res://addons/feng-ntc/LICENSES/"+license_name
		if FileAccess.file_exists(license_path): add_file(license_path,FileAccess.get_file_as_bytes(license_path),false)

func _export_file(path: String,_type: String,_features: PackedStringArray) -> void:
	if path == "res://addons/feng-ntc/feng_ntc.gdextension" or path.begins_with("res://addons/feng-ntc/bin/"):
		skip()

func _begin_customize_resources(_platform: EditorExportPlatform,_features: PackedStringArray) -> bool: return true
func _get_customization_configuration_hash() -> int: return 1
func _customize_resource(resource: Resource,_path: String) -> Resource:
	if resource.get_script() == preload("texture_set.gd") and not resource.payload.is_empty():
		var converted: Resource = resource.duplicate()
		if converted.ensure_portable(): return converted
		push_error("NTC export: " + converted.last_error)
	return null
