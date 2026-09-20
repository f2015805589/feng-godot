@tool
extends "../passes/pass_base.gd"
## Per-view effect RID. The executor may be shared, but enabled/attachment state
## belongs to this binding and must never be written into the author's effect.

var source: FengPass
var execution: FengPass

func configure(pass_source: FengPass, executor: FengPass, active: bool) -> void:
	source = pass_source
	execution = executor
	resource_name = source.resource_name
	effect_callback_type = source.effect_callback_type
	enabled = active
	var contract := get_contract_source()
	contract.refresh_resource_flags()
	access_resolved_color = contract.access_resolved_color
	access_resolved_depth = contract.access_resolved_depth
	needs_motion_vectors = contract.needs_motion_vectors
	needs_normal_roughness = contract.needs_normal_roughness
	needs_separate_specular = contract.needs_separate_specular

func get_contract_source() -> FengPass:
	return execution.get_contract_source() if execution != null else source.get_contract_source()

func _frp_execute(ctx: FRPPassContext) -> void:
	if execution != null:
		execution._frp_execute(ctx)
