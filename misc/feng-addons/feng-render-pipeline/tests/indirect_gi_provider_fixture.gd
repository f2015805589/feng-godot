extends "res://addons/feng-render-pipeline/passes/pass_base.gd"

var kind: StringName = &""
var key := ""
var strength := 0.0
var required_before := PackedInt32Array()

func get_indirect_gi_kind() -> StringName:
	return kind

func get_parameter_key() -> Variant:
	return key

func get_required_before_native_ids() -> PackedInt32Array:
	return required_before
