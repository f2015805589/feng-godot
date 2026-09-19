@tool
extends RefCounted
## Stateless per-camera blending. Knows profiles and values, not the renderer or UI.

static func ordered(volumes: Array) -> Array:
	# Stable insertion: equal priority retains scene registration order.
	var result: Array = []
	for volume in volumes:
		var index := result.size()
		while index > 0 and result[index - 1].priority > volume.priority:
			index -= 1
		result.insert(index, volume)
	return result

## Parameters and switches use one ordered sample of the same spatial influences.
static func evaluate(volumes: Array, base: Dictionary, point: Vector3, schema: Dictionary = {}, aliases: Dictionary = {}, enforce_schema: bool = false) -> Dictionary:
	var result := {}
	var states := {}
	for volume in ordered(volumes):
		var influence: float = volume.influence_at(point)
		if influence <= 0.0:
			continue
		if influence >= 0.5:
			for pass_id in volume.profile.disabled_passes:
				var state_key: Variant = aliases.get(int(pass_id), int(pass_id))
				if not enforce_schema or int(schema.get(state_key, {}).get("enabled", {}).get("type", TYPE_NIL)) == TYPE_BOOL:
					states[state_key] = false
			for pass_id in volume.profile.enabled_passes:
				var state_key: Variant = aliases.get(int(pass_id), int(pass_id))
				if not enforce_schema or int(schema.get(state_key, {}).get("enabled", {}).get("type", TYPE_NIL)) == TYPE_BOOL:
					states[state_key] = true
		var settings: Dictionary = volume.profile.get_parameters()
		for profile_key in settings:
			if not settings[profile_key] is Dictionary:
				continue
			var module_key: Variant = aliases.get(profile_key, profile_key)
			var target: Dictionary = result.get(module_key, {})
			var defaults: Dictionary = base.get(module_key, {})
			for key in settings[profile_key]:
				if enforce_schema and not schema.get(module_key, {}).has(key):
					continue
				var previous: Variant = target.get(key, defaults.get(key))
				var next: Variant = settings[profile_key][key]
				var info: Dictionary = schema.get(module_key, {}).get(key, {})
				if int(info.get("hint", PROPERTY_HINT_NONE)) in [PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS]:
					target[key] = next if influence >= 0.5 else previous
				else:
					target[key] = blend(previous, next, influence)
				# Only author-declared boolean fields can control scheduling.
				if key == "enabled" and int(info.get("type", TYPE_NIL)) == TYPE_BOOL and target[key] is bool:
					states[module_key] = target[key]
			if not target.is_empty():
				result[module_key] = target
	return {"parameters": result, "pass_states": states}

static func parameters(volumes: Array, base: Dictionary, point: Vector3, schema: Dictionary = {}, aliases: Dictionary = {}) -> Dictionary:
	return evaluate(volumes, base, point, schema, aliases).parameters

static func blend(previous: Variant, next: Variant, weight: float) -> Variant:
	if previous == null or weight >= 1.0:
		return next
	if (previous is int or previous is float) and (next is int or next is float):
		return lerpf(float(previous), float(next), weight)
	if typeof(previous) == typeof(next) and (previous is Vector2 or previous is Vector3 or previous is Vector4 or previous is Color):
		return previous.lerp(next, weight)
	return next if weight >= 0.5 else previous

static func pass_states(volumes: Array, point: Vector3) -> Dictionary:
	return evaluate(volumes, {}, point).pass_states
