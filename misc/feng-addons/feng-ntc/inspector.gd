@tool
extends EditorInspectorPlugin
const Neural=preload("neural_material.gd")
func _can_handle(object: Object) -> bool: return object is Neural
func _parse_property(_object: Object,_type: Variant.Type,name: String,_hint: PropertyHint,_hint_text: String,_usage: int,_wide: bool) -> bool:
	return name=="shader" or name.begins_with("shader_parameter/ntc_") or name=="shader_parameter/exact_texels"
