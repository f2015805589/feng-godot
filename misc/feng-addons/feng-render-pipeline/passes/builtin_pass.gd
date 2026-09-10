@tool
class_name FengBuiltinPass
extends "pass_base.gd"
## A named entry for one executable native FRP pass.
##
## Built-in entries are resources so that the complete renderer schedule can
## be edited in one list with custom FengPass resources.  They do not own a
## shader and are never dispatched as compositor callbacks; the renderer uses
## native_id to emit a token for the FRP renderer.

@export_storage var native_id: int = -1

func _init(p_native_id: int = -1, p_resource_name: String = "") -> void:
	native_id = p_native_id
	if p_resource_name != "":
		resource_name = p_resource_name

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if native_id < 0 or native_id > 15:
		warnings.append("Native FRP pass id must be between 0 and 15.")
	return warnings

func _validate_property(property: Dictionary) -> void:
	if property.name in ["stage", "inputs", "outputs", "effect_callback_type", "access_resolved_color", "access_resolved_depth", "needs_motion_vectors", "needs_normal_roughness", "needs_separate_specular"]:
		property.usage = PROPERTY_USAGE_STORAGE
