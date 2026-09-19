@tool
class_name FengBuiltinPass
extends "pass_base.gd"
## A named entry for one executable native FRP pass.
##
## Built-in entries are resources so that the complete renderer schedule can be
## edited in one list with custom FengPass resources. An entry with an
## implementation is dispatched like any other pass (the script runs the work);
## without one it stays a pure schedule token and the engine runs its own pass.

const PassBase = preload("pass_base.gd")

@export_storage var native_id: int = -1
## The pass script that implements this entry (see FengNativePass). When set, the
## entry is driven by the addon: it is dispatched as a compositor effect and its
## native id is reported to the engine as provided, so the engine keeps the pass's
## attachments and feature switches while the script runs the work. Without one the
## entry emits the engine's own token, which is the fallback for a project that does
## not use the pipeline.
@export var implementation: PassBase

const NativeSpec = preload("native_spec.gd")

func _init(p_native_id: int = -1, p_resource_name: String = "") -> void:
	native_id = p_native_id
	if p_resource_name != "":
		resource_name = p_resource_name

func _frp_execute(ctx: FRPPassContext) -> void:
	if implementation != null:
		implementation._frp_execute(ctx)

## The resource contract of this entry belongs to the pass script that implements it
## (which may delegate further, to an overlay), because that is the object which reads
## and writes textures. Without an implementation the entry is a plain schedule token.
func get_contract_source() -> PassBase:
	if implementation != null:
		return implementation.get_contract_source()
	return self

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if not NativeSpec.is_valid_id(native_id):
		warnings.append("Native FRP pass id %d is not part of this engine's FRP pass set." % native_id)
	return warnings

func _validate_property(property: Dictionary) -> void:
	if property.name in ["stage", "inputs", "outputs", "effect_callback_type", "access_resolved_color", "access_resolved_depth", "needs_motion_vectors", "needs_normal_roughness", "needs_separate_specular"]:
		property.usage = PROPERTY_USAGE_STORAGE
