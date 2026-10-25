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
	return _authored(sources(entries))

static func _authored(all: Array[FengPass]) -> Dictionary:
	var result := {}
	# Children first: the containing pipeline entry is the final authored layer.
	for index in range(all.size() - 1, -1, -1):
		var entry := all[index]
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

## Build one revision's author snapshot from a single carried-pass graph walk.
static func context(entries: Array) -> Dictionary:
	var all := sources(entries)
	var schema := {}
	var modules := {}
	var aliases := {}
	var bindings: Array = []
	for entry in all:
		var source := entry.get_parameter_source()
		var key: Variant = source.get_parameter_key()
		if not modules.has(key):
			var fields := {}
			for info in source.get_volume_parameter_list():
				fields[String(info.name)] = info
			if not fields.is_empty():
				modules[key] = true
				schema[key] = fields
				for native_id in source.provides_native_ids:
					schema[native_id] = fields
		var entry_aliases: Array = [entry.get_parameter_key()]
		entry_aliases.append_array(entry.provides_native_ids)
		for alias in entry_aliases:
			aliases[alias] = key
		bindings.append({"key": key, "aliases": entry_aliases})
	for entry in all:
		var key: Variant = entry.get_parameter_source().get_parameter_key()
		if schema.has(key):
			schema[entry.get_parameter_key()] = schema[key]
	return {"base": _authored(all), "schema": schema, "aliases": aliases, "bindings": bindings}

static func resolve(entries: Array, overrides: Dictionary) -> Dictionary:
	return resolve_context(overrides, context(entries))

## Reuse the renderer's revision-cached author schema on numeric Volume updates.
## Alias expansion retains the same precedence as a full pipeline application.
static func resolve_context(overrides: Dictionary, context: Dictionary) -> Dictionary:
	if overrides.is_empty():
		return context.base.duplicate(true)
	var expanded := overrides.duplicate(true)
	# A script that implements a native slot has two consumers: the script reads
	# its own key, while native feature setup (for example jitter) reads the slot.
	for binding in context.bindings:
		var key: Variant = binding.key
		var aliases: Array = binding.aliases
		var merged: Dictionary = expanded.get(key, {}).duplicate()
		for alias in aliases:
			merged.merge(expanded.get(alias, {}), true)
		if not merged.is_empty():
			expanded[key] = merged
			for alias in aliases:
				expanded[alias] = merged.duplicate()
	var resolved := with_overrides(context.base, expanded, context.schema)
	# Eye Adaptation's automatic source selection needs to distinguish an authored
	# default from an explicit Volume contribution, even when the resolved value is
	# numerically equal to that default. This private bit is added after schema
	# validation, so it is not an authorable Volume parameter or shared resolver data.
	var eye_values: Variant = expanded.get("library:eye_adaptation", {})
	var eye_schema: Dictionary = context.schema.get("library:eye_adaptation", {})
	if eye_values is Dictionary:
		for field in eye_values:
			if field != "exposure_source" and eye_schema.has(field):
				var parameters: Dictionary = resolved.get("library:eye_adaptation", {})
				parameters["_frp_volume_eye_exposure_override"] = true
				resolved["library:eye_adaptation"] = parameters
				break
	return resolved

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
