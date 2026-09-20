@tool
extends RefCounted
## Parameter collection and Volume permissions, independent of scheduling and UI.

static func sources(entries: Array) -> Array[FengPass]:
	var result: Array[FengPass] = []
	var visited := {}
	for entry in entries:
		_collect(entry, result, visited)
	return result

static func _collect(entry: FengPass, result: Array[FengPass], visited: Dictionary) -> void:
	if entry == null or visited.has(entry):
		return
	visited[entry] = true
	result.append(entry)
	for carried in entry.carried_passes():
		_collect(carried, result, visited)

static func authored(entries: Array) -> Dictionary:
	var result := {}
	# Children first: the containing pipeline entry is the final authored layer.
	var all := sources(entries)
	all.reverse()
	for entry in all:
		var source := entry.get_parameter_source()
		var values := source.get_frp_parameters().duplicate()
		if values.has("enabled"):
			# An entry and its implementation jointly own the authored switch.
			values["enabled"] = entry.is_enabled()
		values.merge(source.pass_parameters, true)
		values.merge(entry.pass_parameters, true)
		if values.is_empty():
			continue
		result[entry.get_parameter_key()] = values
		result[source.get_parameter_key()] = values.duplicate()
		for native_id in entry.provides_native_ids:
			var target: Dictionary = result.get(native_id, {})
			target.merge(values, true)
			result[native_id] = target
	return result

static func volume_modules(entries: Array) -> Array[FengPass]:
	var result: Array[FengPass] = []
	var keys := {}
	for entry in sources(entries):
		var source := entry.get_parameter_source()
		var key: Variant = source.get_parameter_key()
		if keys.has(key) or source.get_volume_parameter_list().is_empty():
			continue
		keys[key] = true
		result.append(source)
	return result

static func volume_schema(entries: Array) -> Dictionary:
	var schema := {}
	for source in volume_modules(entries):
		var fields := {}
		for info in source.get_volume_parameter_list():
			fields[String(info.name)] = info
		schema[source.get_parameter_key()] = fields
		for native_id in source.provides_native_ids:
			schema[native_id] = fields
	for entry in sources(entries):
		var source_key: Variant = entry.get_parameter_source().get_parameter_key()
		if schema.has(source_key):
			schema[entry.get_parameter_key()] = schema[source_key]
	return schema

static func volume_aliases(entries: Array) -> Dictionary:
	var result := {}
	for entry in sources(entries):
		var key: Variant = entry.get_parameter_source().get_parameter_key()
		result[entry.get_parameter_key()] = key
		for native_id in entry.provides_native_ids:
			result[native_id] = key
	return result

static func resolve(entries: Array, overrides: Dictionary) -> Dictionary:
	return resolve_context(entries, overrides, {"base": authored(entries), "schema": volume_schema(entries)})

static func parameter_bindings(entries: Array) -> Array:
	var result: Array = []
	for entry in sources(entries):
		var aliases: Array = [entry.get_parameter_key()]
		aliases.append_array(entry.provides_native_ids)
		result.append({"key": entry.get_parameter_source().get_parameter_key(), "aliases": aliases})
	return result

## Reuse the renderer's revision-cached author schema on numeric Volume updates.
## Alias expansion retains the same precedence as a full pipeline application.
static func resolve_context(entries: Array, overrides: Dictionary, context: Dictionary) -> Dictionary:
	if overrides.is_empty():
		return context.get("base", {}).duplicate(true)
	var expanded := overrides.duplicate(true)
	# A script that implements a native slot has two consumers: the script reads
	# its own key, while native feature setup (for example jitter) reads the slot.
	var bindings: Array = context.bindings if context.has("bindings") else parameter_bindings(entries)
	for binding in bindings:
		var key: Variant = binding.key
		var aliases: Array = binding.aliases
		var merged: Dictionary = expanded.get(key, {}).duplicate()
		for alias in aliases:
			merged.merge(expanded.get(alias, {}), true)
		if not merged.is_empty():
			expanded[key] = merged
			for alias in aliases:
				expanded[alias] = merged.duplicate()
	return with_overrides(context.get("base", {}), expanded, context.get("schema", {}))

static func warnings(entries: Array) -> PackedStringArray:
	var result := PackedStringArray()
	var owners := {}
	for entry in sources(entries):
		var source := entry.get_parameter_source()
		if source.get_frp_parameters().is_empty():
			continue
		var key: Variant = source.get_parameter_key()
		if key == null or (key is String or key is StringName) and str(key).is_empty():
			result.append("Pass parameter keys must not be empty.")
		elif owners.has(key) and owners[key] != source:
			result.append("Pass parameter key '%s' is shared by different passes; assign distinct stable IDs." % str(key))
		else:
			owners[key] = source
	return result

static func with_overrides(base: Dictionary, overrides: Dictionary, schema: Dictionary) -> Dictionary:
	# Resolved frame data must never alias the caller's authored snapshot.
	base = base.duplicate(true)
	for module_key in overrides:
		if not schema.has(module_key) or not base.has(module_key) or not overrides[module_key] is Dictionary:
			continue
		var target: Dictionary = base[module_key].duplicate()
		for key in overrides[module_key]:
			if not schema[module_key].has(key) or not target.has(key):
				continue
			var value: Variant = overrides[module_key][key]
			var expected := int(schema[module_key][key].type)
			if expected == TYPE_INT and (value is int or value is float):
				value = roundi(value)
			elif expected == TYPE_FLOAT and (value is int or value is float):
				value = float(value)
			elif typeof(value) != expected:
				continue
			target[key] = value
		base[module_key] = target
	return base
