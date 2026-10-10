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
	# An active RTGI pass is a candidate independently of its authored strength. Volumes
	# can turn diffuse RTGI on or off per frame, so preserve a unique MagicGI fallback.
	if not rt_candidates.is_empty():
		var owner := _single_or_blocked(KIND_RT, rt_candidates)
		if not bool(owner.get("blocked", false)) and not magic_candidates.is_empty():
			var fallback := _single_or_blocked(KIND_MAGIC, magic_candidates)
			owner["fallback_kind"] = fallback.get("kind", &"")
			owner["fallback_key"] = fallback.get("key", "")
			owner["fallback_blocked"] = bool(fallback.get("blocked", false))
		return owner
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
		"fallback_kind": StringName(owner.get("fallback_kind", &"")),
		"fallback_key": String(owner.get("fallback_key", "")),
		"fallback_blocked": bool(owner.get("fallback_blocked", true)),
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
	var owner: Variant = values.get(OWNER_PARAMETER, null)
	if owner == null:
		return allow_missing_legacy
	var owner_values := values
	if owner is Dictionary and StringName(owner.get("kind", &"")) == KIND_RT:
		owner_values = ctx.get_pass_parameters(String(owner.get("key", "")))
	return is_resolved_owner(owner, pass_key, expected_kind, owner_values, allow_missing_legacy)

## The reflection replacement slot is unique among planned RTGI providers, but it is
## independent of diffuse strength so it can coexist with MagicGI diffuse ownership.
static func is_reflection_owner(ctx: FRPPassContext, pass_key: String) -> bool:
	if ctx == null:
		return false
	var values := ctx.get_pass_parameters(pass_key)
	return is_resolved_reflection_owner(values.get(OWNER_PARAMETER, null), pass_key)

static func is_resolved_reflection_owner(owner_value: Variant, pass_key: String) -> bool:
	if owner_value == null or not owner_value is Dictionary or bool(owner_value.get("blocked", false)):
		return false
	return StringName(owner_value.get("kind", &"")) == KIND_RT \
			and String(owner_value.get("key", "")) == pass_key

static func is_resolved_owner(owner_value: Variant, pass_key: String,
		expected_kind: StringName, resolved_parameters: Dictionary = {}, allow_missing_legacy := false) -> bool:
	if owner_value == null:
		return allow_missing_legacy
	var owner: Variant = owner_value
	if not owner is Dictionary or bool(owner.get("blocked", false)):
		return false
	var owner_kind := StringName(owner.get("kind", &""))
	var owner_key := String(owner.get("key", ""))
	if owner_kind == expected_kind and owner_key == pass_key:
		if expected_kind == KIND_RT:
			var amount := float(resolved_parameters.get("strength", 0.0))
			return is_finite(amount) and amount > 0.0
		return true
	# Volumes can turn diffuse RTGI off after the pipeline plan was built. Transfer
	# only that diffuse slot to its unique planned MagicGI fallback for this frame;
	# reflection execution remains independent of this decision.
	if expected_kind == KIND_MAGIC and owner_kind == KIND_RT:
		var amount := float(resolved_parameters.get("strength", 0.0))
		return (not is_finite(amount) or amount <= 0.0) \
				and StringName(owner.get("fallback_kind", &"")) == KIND_MAGIC \
				and not bool(owner.get("fallback_blocked", true)) \
				and String(owner.get("fallback_key", "")) == pass_key
	return false
