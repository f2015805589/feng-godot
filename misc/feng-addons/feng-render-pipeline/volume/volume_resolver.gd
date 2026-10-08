@tool
extends RefCounted
## Stateless per-camera blending. Knows profiles and values, not the renderer or UI.

class BlendField:
	extends RefCounted
	var slot: int
	var value: Variant
	var discrete: bool
	var switch: bool

class BlendLayer:
	extends RefCounted
	var volume_id: int
	var switches: Dictionary = {}
	var fields: Array[BlendField] = []

class BlendProgram:
	extends RefCounted
	var layers: Array[BlendLayer] = []
	var defaults: Array = []
	var modules: Array = []
	var names: Array[String] = []

## Compile permissions, aliases and field metadata only when the profile changes.
## Slots replace nested schema/default dictionary lookups during camera motion.
static func compile(prepared: Dictionary, enforce_schema: bool = true) -> BlendProgram:
	var program := BlendProgram.new()
	var context: Dictionary = prepared.context
	var schema: Dictionary = context.get("schema", {})
	var aliases: Dictionary = context.get("aliases", {})
	var base: Dictionary = context.get("base", {})
	var slots := {}
	for volume in prepared.ordered:
		var id: int = volume.get_instance_id()
		if not prepared.settings.has(id):
			continue
		var layer := BlendLayer.new()
		layer.volume_id = id
		for enabled in [false, true]:
			var ids = volume.profile.enabled_passes if enabled else volume.profile.disabled_passes
			for pass_id in ids:
				var key: Variant = aliases.get(int(pass_id), int(pass_id))
				if not enforce_schema or int(schema.get(key, {}).get("enabled", {}).get("type", TYPE_NIL)) == TYPE_BOOL:
					layer.switches[key] = enabled
		var settings: Dictionary = prepared.settings[id]
		for profile_key in settings:
			if not settings[profile_key] is Dictionary:
				continue
			var module_key: Variant = aliases.get(profile_key, profile_key)
			var fields: Dictionary = schema.get(module_key, {})
			var module_slots: Dictionary = slots.get(module_key, {})
			for key in settings[profile_key]:
				if enforce_schema and not fields.has(key):
					continue
				if not module_slots.has(key):
					module_slots[key] = program.defaults.size()
					program.defaults.append(base.get(module_key, {}).get(key))
					program.modules.append(module_key)
					program.names.append(key)
				var field := BlendField.new()
				field.slot = module_slots[key]
				field.value = settings[profile_key][key]
				var info: Dictionary = fields.get(key, {})
				field.discrete = int(info.get("hint", PROPERTY_HINT_NONE)) in [PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS]
				field.switch = key == "enabled" and int(info.get("type", TYPE_NIL)) == TYPE_BOOL
				layer.fields.append(field)
			slots[module_key] = module_slots
		program.layers.append(layer)
	return program

static func evaluate_compiled(program: BlendProgram, influences: Dictionary) -> Dictionary:
	var values := program.defaults.duplicate()
	var touched := PackedByteArray()
	touched.resize(values.size())
	var states := {}
	for layer in program.layers:
		var weight: float = influences[layer.volume_id]
		if weight <= 0.0:
			continue
		if weight >= 0.5:
			states.merge(layer.switches, true)
		for field in layer.fields:
			var previous: Variant = values[field.slot]
			var value: Variant = (field.value if weight >= 0.5 else previous) if field.discrete else blend(previous, field.value, weight)
			values[field.slot] = value
			touched[field.slot] = 1
			if field.switch and value is bool:
				states[program.modules[field.slot]] = value
	var parameters := {}
	for slot in values.size():
		if touched[slot] == 0:
			continue
		var key: Variant = program.modules[slot]
		if not parameters.has(key):
			parameters[key] = {}
		parameters[key][program.names[slot]] = values[slot]
	return {"parameters": parameters, "pass_states": states}

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
static func evaluate(volumes: Array, base: Dictionary, point: Vector3, schema: Dictionary = {}, aliases: Dictionary = {}, enforce_schema: bool = false, prepared: Dictionary = {}) -> Dictionary:
	var sample := prepared.duplicate()
	sample.context = {"base": base, "schema": schema, "aliases": aliases}
	if prepared.is_empty():
		sample.ordered = ordered(volumes)
		sample.settings = {}
		sample.influences = {}
		for volume in sample.ordered:
			var id: int = volume.get_instance_id()
			var influence: float = volume.influence_at(point)
			sample.influences[id] = influence
			if influence > 0.0:
				sample.settings[id] = volume.profile.get_parameters()
	return evaluate_compiled(compile(sample, enforce_schema), sample.influences)

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
