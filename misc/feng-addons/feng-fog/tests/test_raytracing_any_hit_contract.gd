extends SceneTree
## CPU-only source contract for accepted and rejected RT any-hit candidates.

const SHADER_PATH := "res://addons/feng-fog/rendering/raytracing/fog_shadow_any_hit.glslinc"
const RAYGEN_PATH := "res://addons/feng-fog/rendering/raytracing/fog_shadow_raygen.glslinc"
const PROVIDER_PATH := "res://addons/feng-fog/rendering/raytracing/fog_rt_shadow_provider.gd"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(p_condition: bool, p_message: String) -> void:
	_checks += 1
	if not p_condition:
		_failures += 1
		push_error("REGRESSION: " + p_message)


func _run() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	var raygen_source := FileAccess.get_file_as_string(RAYGEN_PATH)
	var provider_source := FileAccess.get_file_as_string(PROVIDER_PATH)
	_require(not source.is_empty(), "the production any-hit stage must be readable as a raw shader include")
	_require(not raygen_source.is_empty(), "the production raygen stage must be readable as a raw shader include")
	_require(not provider_source.is_empty(), "the production RT provider must be readable")
	if source.is_empty() or raygen_source.is_empty() or provider_source.is_empty():
		_finish()
		return

	var accept_helper_start := source.find("void fog_shadow_accept_occluder() {")
	var accept_helper_end := source.find("\n}", accept_helper_start)
	var accept_helper := ""
	if accept_helper_start >= 0 and accept_helper_end > accept_helper_start:
		accept_helper = source.substr(accept_helper_start, accept_helper_end - accept_helper_start + 2)
	var payload_write := accept_helper.find("visibility = 0u;")
	var ray_termination := accept_helper.find("terminateRayEXT;")
	_require(not accept_helper.is_empty() and payload_write >= 0 and ray_termination > payload_write,
			"an accepted candidate must write binary blocked visibility before terminating the ray")
	_require(source.count("terminateRayEXT;") == 1,
			"all accepted opaque, conservative, and alpha-tested candidates share one termination path")

	var main_start := source.find("void main() {")
	var main_source := source.substr(main_start) if main_start >= 0 else ""
	var abi_guard := main_source.find("#if FENG_FOG_RAY_ABI == 2")
	var mask_gate := main_source.find("uint light_mask = ray.cone_words.z;")
	var mask_reject := main_source.find("ignoreIntersectionEXT;", mask_gate)
	var abi_guard_end := main_source.find("#endif", mask_gate)
	var geometry_gate := main_source.find("if (geometry_index >= instance.z)")
	var opaque_gate := main_source.find("if (mode == 0u)")
	var alpha_reject := main_source.find("if (alpha < threshold)")
	var final_accept := main_source.rfind("fog_shadow_accept_occluder();")
	_require(abi_guard >= 0 and mask_gate > abi_guard and mask_reject > mask_gate
			and abi_guard_end > mask_reject and abi_guard_end < geometry_gate,
			"ABI 2 layer-mask rejection is compiled only into the matching shader variant")
	_require(geometry_gate > abi_guard_end and opaque_gate > geometry_gate and alpha_reject > opaque_gate,
			"mask, conservative metadata, opaque mode, and alpha decisions remain ordered")
	_require(final_accept > alpha_reject and main_source.count("fog_shadow_accept_occluder();") == 3,
			"out-of-range metadata, opaque mode, and threshold-accepted alpha all use the blocked-hit path")
	_require(main_source.count("ignoreIntersectionEXT;") == 2,
			"only rejected layer-mask and alpha candidates are ignored")
	_require(main_source.contains("uint light_mask = ray.cone_words.z;")
			and main_source.contains("(instance.w & light_mask) == 0u"),
			"ABI 2 keeps the complete raw 32-bit light/caster mask comparison")
	var input_contract := ""
	var contract_start := provider_source.find("func get_ray_input_contract() -> Dictionary:")
	if contract_start >= 0:
		var contract_end := provider_source.find("\n\nstatic func shader_source_for_abi", contract_start)
		if contract_end > contract_start:
			input_contract = provider_source.substr(contract_start, contract_end - contract_start)
	_require(not source.contains("FogShadowProtocol")
			and source.contains("layout(set = 0, binding = 10, std430) readonly buffer FogShadowRayInputs")
			and not source.contains("layout(set = 0, binding = 1, std430) readonly buffer FogShadowRayInputs")
			and raygen_source.contains("layout(set = 0, binding = 1, std430) readonly buffer FogShadowRayInputs")
			and not raygen_source.contains("FogShadowProtocol")
			and not raygen_source.contains("binding = 10")
			and provider_source.contains("input_uniform.binding = 1")
			and provider_source.contains("any_hit_input_uniform.binding = 10")
			and provider_source.count("add_id(p_ray_input_buffer)") == 2
			and input_contract.contains('"raygen_input": 1')
			and input_contract.contains('"any_hit_input": 10')
			and input_contract.contains('"same_borrowed_input_rid": true')
			and raygen_source.contains("#if FENG_FOG_RAY_ABI == 2")
			and raygen_source.contains("light_mask == 0u"),
			"raygen b1 and any-hit b10 alias the same borrowed input RID without a protocol descriptor")
	_require(main_source.contains("if (mode == 0u) {\n\t\tfog_shadow_accept_occluder();\n\t\treturn;\n\t}"),
			"opaque mode explicitly marks the hit blocked instead of relying on closest-hit execution")
	_require(main_source.contains("if (geometry_index >= instance.z) {\n"
			+ "\t\t// Missing surface metadata is conservative: this intersection still blocks.\n"
			+ "\t\tfog_shadow_accept_occluder();\n\t\treturn;\n\t}"),
			"missing geometry metadata retains conservative blocking behavior")
	_finish()


func _finish() -> void:
	if _failures == 0:
		print("PASS RT any-hit accepted/rejected contract (%d checks)" % _checks)
		quit(0)
	else:
		push_error("RT any-hit accepted/rejected contract failed: %d/%d" % [_failures, _checks])
		quit(1)
