extends "res://addons/feng-render-pipeline/passes/pass_base.gd"

var kind: StringName = &""
var key := ""
var strength := 0.0
var indirect_gi_available := true
var hardware_rt_supported := true
var indirect_gi_unavailable_reason := "fixture_raytracing_unavailable"
var omit_indirect_gi_availability_flag := false
var required_before := PackedInt32Array()

func get_indirect_gi_kind() -> StringName:
	return kind

func get_parameter_key() -> Variant:
	return key

func get_indirect_gi_availability() -> Dictionary:
	if omit_indirect_gi_availability_flag:
		return {"reason": "fixture_availability_flag_missing"}
	return {"available": indirect_gi_available,
		"hardware_supported": hardware_rt_supported,
		"reason": indirect_gi_unavailable_reason if not indirect_gi_available else ""}

func get_required_before_native_ids() -> PackedInt32Array:
	return required_before
