@tool
extends RefCounted
## Resolves the one indirect-diffuse owner for a concrete FRP schedule.
##
## This is a plan-time decision. Consumers must not infer ownership from callback
## order or from whether another provider successfully dispatched this frame.

const ParameterResolver = preload("parameter_resolver.gd")

const OWNER_PARAMETER: StringName = &"feng_indirect_gi_owner"
const KIND_RT: StringName = &"rt_gi"
const KIND_MAGIC: StringName = &"magic_gi"


static func resolve(passes: Array, is_entry_enabled_fn: Callable) -> Dictionary:
	var rt_candidates: Array[Dictionary] = []
	var magic_candidates: Array[Dictionary] = []
	for entry in passes:
		if entry == null or not is_entry_enabled_fn.call(entry):
			continue
		if not entry.has_method("get_indirect_gi_kind"):
			continue
		var kind := StringName(entry.call("get_indirect_gi_kind"))
		if kind not in [KIND_RT, KIND_MAGIC]:
			continue
		var source = entry.get_parameter_source() if entry.has_method("get_parameter_source") else entry
		var key: Variant = source.get_parameter_key() if source.has_method("get_parameter_key") else null
		# An active provider that cannot be addressed is still an owner candidate:
		# silently ignoring it could let MagicGI write while RTGI is active.
		var candidate := {
			"kind": kind,
			"key": str(key) if key != null else "",
			"blocked": key == null or str(key).is_empty(),
			"reason": "active_%s_provider_has_no_parameter_key" % String(kind)
					if key == null or str(key).is_empty() else "",
		}
		if kind == KIND_RT:
			rt_candidates.append(candidate)
		elif kind == KIND_MAGIC:
			magic_candidates.append(candidate)
	# An active RTGI pass owns the selection even if its frame later proves unusable.
	# That failure leaves native SkyDiffuse intact and never runs a second GI producer.
	if not rt_candidates.is_empty():
		return _single_or_blocked(KIND_RT, rt_candidates)
	if not magic_candidates.is_empty():
		return _single_or_blocked(KIND_MAGIC, magic_candidates)
	return {"kind": &"", "key": ""}


static func _single_or_blocked(kind: StringName, candidates: Array[Dictionary]) -> Dictionary:
	if candidates.size() == 1:
		var candidate: Dictionary = candidates[0]
		if not bool(candidate.get("blocked", false)):
			return candidate
		return candidate
	# A parameter dictionary is keyed by the pass's stable parameter key. Two
	# active GI providers with the same key cannot be addressed independently, so
	# fail closed instead of letting both overwrite one output or replace Sky.
	return {"kind": kind, "key": "", "blocked": true,
		"reason": "multiple_active_%s_providers" % String(kind)}


static func inject(parameters: Dictionary, passes: Array, owner: Dictionary) -> Dictionary:
	var result := parameters.duplicate(true)
	var owner_value := {
		"kind": StringName(owner.get("kind", &"")),
		"key": String(owner.get("key", "")),
		"blocked": bool(owner.get("blocked", false)),
		"reason": String(owner.get("reason", "")),
	}
	for entry in ParameterResolver.sources(passes):
		if entry == null:
			continue
		var key: Variant = entry.get_parameter_key()
		if key == null:
			continue
		var pass_parameters: Variant = result.get(key, {})
		var resolved: Dictionary = pass_parameters.duplicate(true) if pass_parameters is Dictionary else {}
		# The renderer owns this reserved field. An authored pass/Volume dictionary
		# cannot claim another provider's output as its own.
		resolved[OWNER_PARAMETER] = owner_value.duplicate(true)
		result[key] = resolved
	return result


static func is_owner(ctx: FRPPassContext, pass_key: String,
		expected_kind: StringName, allow_missing_legacy := false) -> bool:
	if ctx == null:
		return false
	var values := ctx.get_pass_parameters(pass_key)
	if not values.has(OWNER_PARAMETER):
		return allow_missing_legacy
	var owner: Variant = values.get(OWNER_PARAMETER, {})
	return owner is Dictionary and StringName(owner.get("kind", &"")) == expected_kind \
			and not bool(owner.get("blocked", false)) \
			and String(owner.get("key", "")) == pass_key
